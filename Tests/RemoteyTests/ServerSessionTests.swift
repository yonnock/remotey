import XCTest
@testable import Remotey

/// The live view as the server sees it, without a capture: it counts what it is asked.
final class FakeScreen: LiveScreen {
    var cameForward: ((CGRect) -> Void)?
    var locked = false
    var requests: [ScreenView.Request?] = []
    /// The requests that switch the view on or change it.
    var views: Int { requests.compactMap { $0 }.count }
    var keyFrames = 0
    var wakes = 0
    func update(_ request: ScreenView.Request?) { requests.append(request) }
    func frameShown(_ number: UInt32) {}
    func pointerMoved() {}
    func move(_ sequence: UInt32?, post: () -> Void) { post() }
    func followText(_ on: Bool) {}
    func keyFrame() { keyFrames += 1 }
    func wake() { wakes += 1 }
}

/// A phone on the socket, as far as the tests need one: it sends JSON and keeps what arrives.
@MainActor
final class SocketPhone {
    private let task: URLSessionWebSocketTask
    private(set) var messages: [[String: Any]] = []
    private(set) var closed = false

    init(port: UInt16, origin: String? = nil) {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/ws")!)
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        pump()
    }

    private func pump() {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(.string(let text)):
                    self.messages.append((try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:])
                    self.pump()
                case .success: self.pump()
                case .failure: self.closed = true
                }
            }
        }
    }

    func send(_ json: String) { task.send(.string(json)) { _ in } }

    func close() { task.cancel(with: .goingAway, reason: nil) }

    /// Messages of kind `t` so far.
    func heard(_ t: String) -> [[String: Any]] { messages.filter { $0["t"] as? String == t } }
}

/// Waits on the main actor until `condition` holds; false after `timeout`.
@MainActor
func eventually(_ timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Several phones on one agent, the heartbeat, and what each phone holds. The input is collected, not posted,
/// and the live view is a stand-in: nothing here moves the pointer or captures the screen.
@MainActor
final class ServerSessionTests: XCTestCase {
    nonisolated(unsafe) private static var nextPort: UInt16 = 47940
    private let token = "test-token-test-token-test-token-test"
    private let view = #"{"t":"view","on":true,"w":390,"h":844,"zoom":1,"dpr":3,"codec":"h264","fps":60,"v":1}"#
    private var port: UInt16 = 0
    private var events: [CGEvent] = []
    private var screen = FakeScreen()
    private var server: Server!
    private var phones: [SocketPhone] = []

    private func start(timing: Server.Timing = Server.Timing(), canRecord: Bool = true) async throws {
        port = Self.nextPort
        Self.nextPort += 2
        let input = Input { [unowned self] in events.append($0) }
        server = Server(token: token, input: input, port: port, timing: timing, canRecord: { canRecord }, activity: {},
                        screen: { [unowned self] _, _ in screen })
        try server.start()
        let listening = await eventually { server.health == .listening }
        XCTAssertTrue(listening, "\(server.health)")
    }

    override func tearDown() async throws {
        phones.forEach { $0.close() }
        server?.stop()
    }

    private func phone(authenticated: Bool = true) async throws -> SocketPhone {
        let phone = SocketPhone(port: port + 1)
        phones.append(phone)
        guard authenticated else { return phone }
        phone.send(#"{"t":"auth","token":"\#(token)"}"#)
        let accepted = await eventually { !phone.heard("ok").isEmpty }
        XCTAssertTrue(accepted)
        return phone
    }

    private func count(_ type: CGEventType) -> Int { events.filter { $0.type == type }.count }

    private func scrollsEnded() -> Int {
        events.filter {
            $0.type == .scrollWheel && $0.getIntegerValueField(.scrollWheelEventScrollPhase) == Int64(CGScrollPhase.ended.rawValue)
        }.count
    }

    /// A pause in which nothing may happen.
    private func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    // MARK: Heartbeat

    /// iOS freezes a page without closing its socket. Before, its held button stayed down and its view ran on.
    func testASilentPhoneLetsGoOfItsButtonThenIsDropped() async throws {
        try await start(timing: Server.Timing(silence: 0.8, release: 0.3))
        let phone = try await phone()
        phone.send(view)
        phone.send(#"{"t":"b","b":"left","d":true}"#)
        let pressed = await eventually { count(.leftMouseDown) == 1 }
        XCTAssertTrue(pressed)
        let released = await eventually(1) { count(.leftMouseUp) == 1 }
        XCTAssertTrue(released, "let go after the release time")
        XCTAssertFalse(phone.closed, "still connected: the release comes first")
        let dropped = await eventually(2) { phone.closed }
        XCTAssertTrue(dropped, "dropped after the silence")
        XCTAssertEqual(count(.leftMouseUp), 1, "let go once")
        let stopped = await eventually { screen.requests.last.map { $0 == nil } ?? false }
        XCTAssertTrue(stopped, "the view stops as with a close")
    }

    func testAPhoneThatPingsHearsPongAndKeepsItsButton() async throws {
        try await start(timing: Server.Timing(silence: 0.5, release: 0.25))
        let phone = try await phone()
        phone.send(#"{"t":"b","b":"left","d":true}"#)
        for _ in 0..<12 {
            phone.send(#"{"t":"ping"}"#)
            await pause(0.1)
        }
        XCTAssertFalse(phone.closed)
        XCTAssertGreaterThanOrEqual(phone.heard("pong").count, 10)
        XCTAssertEqual(count(.leftMouseUp), 0, "a ping counts as life")
    }

    // MARK: Several phones

    /// Before, any phone that left let go of every button, and ended another phone's drag.
    func testALeavingPhoneLetsGoOnlyOfWhatItHeld() async throws {
        try await start()
        let first = try await phone(), second = try await phone()
        first.send(#"{"t":"b","b":"left","d":true}"#)
        first.send(#"{"t":"s","dx":0,"dy":12}"#)
        second.send(#"{"t":"b","b":"right","d":true}"#)
        // The first one's button is not the second one's to press, click or let go.
        second.send(#"{"t":"b","b":"left","d":false}"#)
        second.send(#"{"t":"c","b":"left"}"#)
        let held = await eventually { count(.rightMouseDown) == 1 && count(.leftMouseDown) == 1 }
        XCTAssertTrue(held)
        XCTAssertEqual(count(.leftMouseUp), 0)

        second.close()
        let gone = await eventually { count(.rightMouseUp) == 1 }
        XCTAssertTrue(gone, "the leaving phone's own button")
        await pause(0.2)
        XCTAssertEqual(count(.leftMouseUp), 0, "the other phone's drag goes on")
        XCTAssertEqual(scrollsEnded(), 0, "and so does its scroll")

        first.close()
        let all = await eventually { count(.leftMouseUp) == 1 && scrollsEnded() == 1 }
        XCTAssertTrue(all, "its own button and scroll go with it")
    }

    // MARK: Live view

    func testADisplacedViewerIsToldAndTheRefusalSaysWhy() async throws {
        try await start()
        let first = try await phone(), second = try await phone()
        first.send(view)
        let viewing = await eventually { screen.views == 1 }
        XCTAssertTrue(viewing)
        second.send(view)
        let told = await eventually { !first.heard("view").isEmpty }
        XCTAssertTrue(told)
        XCTAssertEqual(first.heard("view").first?["ok"] as? Bool, false)
        XCTAssertEqual(first.heard("view").first?["why"] as? String, "taken")
        XCTAssertTrue(second.heard("view").isEmpty, "the phone that took it hears nothing")
        // Asking again only resizes: nobody is displaced.
        second.send(view.replacingOccurrences(of: #""v":1"#, with: #""v":2"#))
        await pause(0.2)
        XCTAssertEqual(first.heard("view").count, 1)
    }

    func testWithoutThePermissionTheViewIsRefusedAsSuch() async throws {
        try await start(canRecord: false)
        let phone = try await phone()
        phone.send(view)
        let refused = await eventually { !phone.heard("view").isEmpty }
        XCTAssertTrue(refused)
        XCTAssertEqual(phone.heard("view").first?["why"] as? String, "permission")
        XCTAssertEqual(screen.views, 0)
    }

    func testAKeyFrameForTheViewerAtMostOnceAnInterval() async throws {
        try await start(timing: Server.Timing(keyFrames: 0.4))
        let viewer = try await phone(), other = try await phone()
        viewer.send(view)
        for _ in 0..<3 { viewer.send(#"{"t":"idr"}"#) }
        other.send(#"{"t":"idr"}"#)
        let asked = await eventually { screen.keyFrames == 1 }
        XCTAssertTrue(asked)
        await pause(0.5)
        XCTAssertEqual(screen.keyFrames, 1, "one for three in a row, none for a phone that does not view")
        viewer.send(#"{"t":"idr"}"#)
        let again = await eventually { screen.keyFrames == 2 }
        XCTAssertTrue(again, "once the interval is over")
    }

    /// Input from the viewer may find the capture waiting to be rebuilt after the display slept.
    func testInputFromTheViewerPromptsARebuild() async throws {
        try await start()
        let viewer = try await phone()
        viewer.send(#"{"t":"m","dx":1,"dy":0}"#)
        await pause(0.1)
        XCTAssertEqual(screen.wakes, 0, "not without a view")
        viewer.send(view)
        viewer.send(#"{"t":"m","dx":-1,"dy":0}"#)
        viewer.send(#"{"t":"media","k":"mute"}"#)
        let woken = await eventually { screen.wakes == 1 }
        XCTAssertTrue(woken)
    }

    // MARK: Malformed messages

    /// Before, one field of the wrong type closed the connection, and a view request missing a field switched
    /// the view off.
    func testAMalformedMessageCostsOnlyItself() async throws {
        try await start()
        let phone = try await phone()
        phone.send(view)
        phone.send(#"{"t":"m","dx":"far","dy":1}"#)
        phone.send(#"{"t":"view","on":true,"w":390}"#)
        phone.send(#"{"t":"shown","n":"one"}"#)
        phone.send(#"{"t":"ping"}"#)
        let alive = await eventually { phone.heard("pong").count == 1 }
        XCTAssertTrue(alive)
        XCTAssertFalse(phone.closed)
        XCTAssertEqual(screen.views, 1)
        XCTAssertNotNil(screen.requests.last ?? nil, "the view stays on")
        phone.send("not json")
        let closed = await eventually { phone.closed }
        XCTAssertTrue(closed, "what is no message at all still ends it")
    }
}
