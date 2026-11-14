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
                        httpPort: httpPort, wsPort: wsPort, pendingTimeout: 0.5)
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
}
