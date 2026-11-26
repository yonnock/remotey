import Network
import XCTest
@testable import Remotey

/// Runs a second agent on its own ports. Nothing here authenticates input, so no events are injected.
final class ServerTests: XCTestCase {
    /// A cancelled listener frees its port only after a while, so every test gets its own pair.
    nonisolated(unsafe) private static var nextPort: UInt16 = 47810
    private var httpPort: UInt16 = 0, wsPort: UInt16 = 0
    private var server: Server!

    override func setUpWithError() throws {
        (httpPort, wsPort) = (Self.nextPort, Self.nextPort + 1)
        Self.nextPort += 2
        server = Server(token: "test-token-test-token-test-token-test", input: Input(),
                        port: httpPort, pendingTimeout: 0.5)
        try server.start()
        // Listeners come up asynchronously. NWConnection waits for them, URLSession would not.
        let probes = [idle(port: httpPort), idle(port: wsPort)]
        probes.forEach { $0.cancel() }
        let settled = expectation(description: "probes gone")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settled.fulfill() }
        wait(for: [settled], timeout: 1)
    }

    override func tearDown() {
        server.stop()
        server = nil
    }

    /// A TCP connection that sends nothing; `closed` is fulfilled once the server hangs up.
    private func idle(port: UInt16, closed: XCTestExpectation? = nil) -> NWConnection {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let ready = expectation(description: "connected")
        connection.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16) { _, _, complete, error in
            if complete || error != nil { closed?.fulfill() }
        }
        connection.start(queue: .main)
        wait(for: [ready], timeout: 2)
        return connection
    }

    func testSilentConnectionsAreClosedAfterTheTimeout() {
        let closed = [expectation(description: "http closed"), expectation(description: "ws closed")]
        let connections = [idle(port: httpPort, closed: closed[0]), idle(port: wsPort, closed: closed[1])]
        wait(for: closed, timeout: 3)
        connections.forEach { $0.cancel() }
    }

    func testAFloodOfSilentConnectionsEvictsTheOldest() {
        let extra = 8
        let evicted = expectation(description: "oldest closed")
        evicted.expectedFulfillmentCount = extra
        evicted.assertForOverFulfill = false
        var connections: [NWConnection] = []
        for index in 0..<(Server.maxPending + extra) {
            connections.append(idle(port: index % 2 == 0 ? httpPort : wsPort,
                                    closed: evicted))
        }
        // Well before the 0.5 s timeout would have closed them anyway.
        wait(for: [evicted], timeout: 0.3)
        connections.forEach { $0.cancel() }
    }

    func testAuthenticatedClientOutlivesTheTimeoutAndWrongTokenIsDenied() async throws {
        let url = URL(string: "ws://127.0.0.1:\(wsPort)/ws")!
        func text(_ message: URLSessionWebSocketTask.Message) -> String {
            if case .string(let string) = message { return string }
            return ""
        }
        let bad = URLSession.shared.webSocketTask(with: url)
        bad.resume()
        try await bad.send(.string(#"{"t":"auth","token":"wrong"}"#))
        let denied = text(try await bad.receive())
        XCTAssertEqual(denied, #"{"t":"denied"}"#)

        let good = URLSession.shared.webSocketTask(with: url)
        good.resume()
        try await good.send(.string(#"{"t":"auth","token":"test-token-test-token-test-token-test"}"#))
        let ok = text(try await good.receive())
        XCTAssertTrue(ok.hasPrefix(#"{"t":"ok""#), ok)
        // Read, so that the pong below is not held up behind it.
        let lock = text(try await good.receive())
        XCTAssertTrue(lock.hasPrefix(#"{"t":"lock""#), lock)
        try await Task.sleep(for: .seconds(1))
        // Still connected: an unknown message is ignored, a closed socket would fail the ping.
        try await good.send(.string(#"{"t":"noop"}"#))
        let alive = expectation(description: "pong")
        good.sendPing { error in
            XCTAssertNil(error)
            alive.fulfill()
        }
        await fulfillment(of: [alive], timeout: 2)
        good.cancel(with: .goingAway, reason: nil)
    }

    /// The list comes first and at once; the icons follow, each once per connection.
    func testAClientGetsTheOpenAppsAndEveryIconOnce() async throws {
        let socket = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(wsPort)/ws")!)
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }
        func next() async throws -> [String: Any] {
            guard case .string(let text) = try await socket.receive() else { return [:] }
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }
        try await socket.send(.string(#"{"t":"auth","token":"test-token-test-token-test-token-test"}"#))
        let ok = try await next()
        XCTAssertEqual(ok["t"] as? String, "ok")
        // Whether the Mac is locked follows at once, so the page knows what its field is for.
        let lock = try await next()
        XCTAssertEqual(lock["t"] as? String, "lock")
        XCTAssertEqual(lock["on"] as? Bool, LockScreen.sessionIsLocked())

        try await socket.send(.string(#"{"t":"apps"}"#))
        let first = try await next()
        XCTAssertEqual(first["t"] as? String, "apps")
        let apps = try XCTUnwrap(first["list"] as? [[String: Any]])
        // Finder runs in every session with a Dock; a machine without one lists no apps.
        let finder = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.finder" }
        XCTAssertEqual(apps.contains { $0["icon"] as? String == "com.apple.finder" }, finder, "\(apps.compactMap { $0["name"] })")
        for app in apps {
            XCTAssertGreaterThan(try XCTUnwrap(app["pid"] as? Int), 0)
            XCTAssertFalse(try XCTUnwrap(app["name"] as? String).isEmpty)
            XCTAssertNotNil(app["windows"] as? [[String: Any]])
        }
        XCTAssertLessThanOrEqual(apps.filter { $0["front"] as? Bool == true }.count, 1)

        var icons: Set<String> = []
        for _ in Set(apps.compactMap { $0["icon"] as? String }) {
            let message = try await next()
            XCTAssertEqual(message["t"] as? String, "icon")
            let png = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(message["png"] as? String)))
            XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4e, 0x47])
            icons.insert(try XCTUnwrap(message["id"] as? String))
        }
        XCTAssertEqual(icons, Set(apps.compactMap { $0["icon"] as? String }))

        // The displays for the picker: all of this Mac's, as they are arranged.
        try await socket.send(.string(#"{"t":"displays"}"#))
        let answer = try await next()
        XCTAssertEqual(answer["t"] as? String, "displays")
        let displays = try XCTUnwrap(answer["list"] as? [[String: Any]])
        XCTAssertEqual(displays.count, NSScreen.screens.count)
        XCTAssertEqual(displays.filter { $0["pointer"] as? Bool == true }.count, displays.isEmpty ? 0 : 1)
        XCTAssertTrue(displays.allSatisfy { ($0["w"] as? Double ?? 0) > 0 && ($0["name"] as? String)?.isEmpty == false })

        // Asked again, the list comes without its icons: the next message is the answer to what follows it.
        for _ in 1...2 {
            try await socket.send(.string(#"{"t":"apps"}"#))
            let again = try await next()
            XCTAssertEqual(again["t"] as? String, "apps")
        }

        // After a reconnect the page names the icons it kept: only the one it lacks comes. Before, all came again.
        guard let lacking = icons.sorted().first else { return }
        let later = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(wsPort)/ws")!)
        later.resume()
        defer { later.cancel(with: .goingAway, reason: nil) }
        func nextLater() async throws -> [String: Any] {
            guard case .string(let text) = try await later.receive() else { return [:] }
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }
        try await later.send(.string(#"{"t":"auth","token":"test-token-test-token-test-token-test"}"#))
        _ = try await nextLater() // ok
        _ = try await nextLater() // lock
        let have = try JSONSerialization.data(withJSONObject: Array(icons.subtracting([lacking])))
        try await later.send(.string(#"{"t":"apps","have":\#(String(decoding: have, as: UTF8.self))}"#))
        let list = try await nextLater()
        XCTAssertEqual(list["t"] as? String, "apps")
        let only = try await nextLater()
        XCTAssertEqual(only["t"] as? String, "icon")
        XCTAssertEqual(only["id"] as? String, lacking)
        try await later.send(.string(#"{"t":"apps"}"#))
        let after = try await nextLater()
        XCTAssertEqual(after["t"] as? String, "apps", "no other icon came between")
    }

    // MARK: Health

    /// A port in use failed silently before: the listener's state said so, and nobody read it. The menu offered a
    /// QR code for an agent that listened on nothing.
    @MainActor
    func testASecondServerOnTheSamePortsSaysItFailedAndTriesAgain() async throws {
        XCTAssertEqual(server.health, .listening)
        var heard: [Server.Health] = []
        let second = Server(token: "test-token-test-token-test-token-test", input: Input(), port: httpPort,
                            timing: Server.Timing(retry: Backoff(first: 0.2, longest: 0.2)), screen: { _, _ in FakeScreen() })
        second.healthChanged = { heard.append($0) }
        try second.start()
        defer { second.stop() }
        let failed = await eventually { if case .failed = second.health { true } else { false } }
        XCTAssertTrue(failed)
        guard case .failed(let reason) = second.health else { return XCTFail("\(second.health)") }
        XCTAssertTrue(reason.contains("\(httpPort)") || reason.contains("\(wsPort)"), reason)
        XCTAssertEqual(server.health, .listening, "the first one keeps its ports")
        // The ports come free: the next try takes them.
        server.stop()
        let recovered = await eventually(3) { second.health == .listening }
        XCTAssertTrue(recovered)
        guard case .failed = heard.first else { return XCTFail("\(heard)") }
        XCTAssertTrue(heard.contains(.starting), "the next try")
        XCTAssertEqual(heard.last, .listening)
    }

    // MARK: Where a request comes from

    /// What the HTTP port answers a request with this `Host`, as a browser would send it.
    private func status(host: String?) throws -> String {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: httpPort)!, using: .tcp)
        let answered = expectation(description: "answer")
        var head = ""
        connection.stateUpdateHandler = { if case .ready = $0 {
            let request = "GET / HTTP/1.1\r\n" + (host.map { "Host: \($0)\r\n" } ?? "") + "\r\n"
            connection.send(content: Data(request.utf8), completion: .idempotent)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { data, _, _, _ in
                head = String(decoding: data ?? Data(), as: UTF8.self)
                answered.fulfill()
            }
        } }
        connection.start(queue: .main)
        wait(for: [answered], timeout: 2)
        connection.cancel()
        return String(head.split(separator: "\r\n").first ?? "")
    }

    func testThePageIsServedOnlyUnderItsOwnNames() throws {
        XCTAssertEqual(try status(host: "127.0.0.1:\(httpPort)"), "HTTP/1.1 200 OK")
        XCTAssertEqual(try status(host: "localhost:\(httpPort)"), "HTTP/1.1 200 OK")
        XCTAssertEqual(try status(host: "mac.example.ts.net:8443"), "HTTP/1.1 200 OK", "as tailscale serve hands it on")
        XCTAssertEqual(try status(host: nil), "HTTP/1.1 200 OK", "a program, which reaches the port anyway")
        XCTAssertEqual(try status(host: "rebound.example.com:\(httpPort)"), "HTTP/1.1 403 Forbidden", "DNS rebinding")
    }

    /// A web page in the Mac's browser opened sockets to the loopback port before, and filled the pending slots.
    func testASocketFromAnotherPageIsRefusedAtTheHandshake() async throws {
        func outcome(origin: String) async -> String {
            var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(wsPort)/ws")!)
            request.setValue(origin, forHTTPHeaderField: "Origin")
            let socket = URLSession.shared.webSocketTask(with: request)
            socket.resume()
            defer { socket.cancel(with: .goingAway, reason: nil) }
            do {
                try await socket.send(.string(#"{"t":"auth","token":"test-token-test-token-test-token-test"}"#))
                guard case .string(let text) = try await socket.receive() else { return "binary" }
                return text.hasPrefix(#"{"t":"ok""#) ? "ok" : text
            } catch {
                return "refused"
            }
        }
        let own = await outcome(origin: "https://mac.example.ts.net:8443")
        XCTAssertEqual(own, "ok", "the page behind tailscale serve")
        let development = await outcome(origin: "http://127.0.0.1:\(httpPort)")
        XCTAssertEqual(development, "ok", "the page of a development build")
        let other = await outcome(origin: "https://evil.example.com")
        XCTAssertEqual(other, "refused")
        let sandboxed = await outcome(origin: "null")
        XCTAssertEqual(sandboxed, "refused")
    }
}
