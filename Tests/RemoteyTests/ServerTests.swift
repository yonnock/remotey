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
        // Finder always runs in a session with a Dock.
        XCTAssertTrue(apps.contains { $0["icon"] as? String == "com.apple.finder" }, "\(apps.compactMap { $0["name"] })")
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

        // Asked again, the list comes without its icons: the next message is the answer to what follows it.
        for _ in 1...2 {
            try await socket.send(.string(#"{"t":"apps"}"#))
            let again = try await next()
            XCTAssertEqual(again["t"] as? String, "apps")
        }
    }
}
