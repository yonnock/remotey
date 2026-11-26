import Carbon.HIToolbox
import XCTest
@testable import Remotey

/// An agent whose lock screen exists only here, as in `LockScreenTests`: the keys are collected instead of
/// posted, so nothing is typed on this Mac. A phone enrols over the socket and unlocks with its passkey.
@MainActor
final class FaceUnlockServerTests: XCTestCase {
    nonisolated(unsafe) private static var nextPort: UInt16 = 47890
    private let token = "test-token-test-token-test-token-test"
    private let phone = TestPhone()
    private let file = FileManager.default.temporaryDirectory.appendingPathComponent("remotey-face-unlock-\(UUID().uuidString)")
    private var events: [CGEvent] = []
    private var sessionLocked = false
    private var opensAtReturn = false
    private var server: Server!
    private var lock: LockScreen!
    private var socket: URLSessionWebSocketTask!

    override func setUp() async throws {
        let port = Self.nextPort
        Self.nextPort += 2
        lock = LockScreen(session: { [unowned self] in sessionLocked }, field: { 0 }, wake: {}, patience: (field: 0.4, answer: 0.2))
        let input = Input { [unowned self] event in
            events.append(event)
            guard opensAtReturn, event.type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == kVK_Return else { return }
            sessionLocked = false
            lock.note(false)
        }
        server = Server(token: token, input: input, port: port, lock: lock, faceUnlock: FaceUnlock(file: file),
                        devices: .temporary(), permissions: { (true, true) })
        try server.start()
        try await Task.sleep(for: .milliseconds(100)) // the listeners come up asynchronously
        socket = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port + 1)/ws")!)
        socket.resume()
        try await socket.send(.string(#"{"t":"auth","token":"\#(token)"}"#))
        let ok = try await next()
        XCTAssertEqual(ok["t"] as? String, "ok")
        let mac = try await next()
        XCTAssertEqual(mac["t"] as? String, "mac")
    }

    override func tearDown() async throws {
        socket.cancel(with: .goingAway, reason: nil)
        server.stop()
        try? FileManager.default.removeItem(at: file)
    }

    private func next() async throws -> [String: Any] {
        guard case .string(let text) = try await socket.receive() else { return [:] }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    /// What a `lock` that names the phone's passkey asks for: a signature for the challenge, the secret for
    /// the salt, and the secret for the next salt.
    private struct Ask: Equatable {
        let challenge: Data
        let salt: Data
        let next: Data
    }

    private func ask(in message: [String: Any]) throws -> Ask {
        XCTAssertEqual(message["t"] as? String, "lock")
        XCTAssertEqual(message["on"] as? Bool, true)
        let key = try XCTUnwrap(message["key"] as? [String: String], "\(message)")
        XCTAssertEqual(key["id"], phone.id.base64URL)
        func data(_ name: String) throws -> Data { try XCTUnwrap(key[name].flatMap(Data.init(base64URL:)), name) }
        return Ask(challenge: try data("challenge"), salt: try data("salt"), next: try data("next"))
    }

    /// The page's answer to `ask`, signed for `challenge` if not for the ask's own, with both secrets unless `rotates` is false.
    private func answer(_ ask: Ask, challenge: Data? = nil, rotates: Bool = true) -> String {
        phone.message(phone.answer(challenge ?? ask.challenge), salt: ask.salt, next: rotates ? ask.next : nil)
    }

    private var keysDown: [Int] {
        events.filter { $0.type == .keyDown }.map { Int($0.getIntegerValueField(.keyboardEventKeycode)) }
    }

    /// The page's `enrol` message for a passkey made for `challenge`.
    private func enrolment(for challenge: Data, salt: Data) -> String {
        #"{"t":"enrol","cred":"\#(phone.id.base64URL)","key":"\#(phone.publicKey.base64URL)","#
            + #""auth":"\#(phone.authenticator().base64URL)","client":"\#(phone.client("webauthn.create", challenge: challenge).base64URL)","#
            + #""prf":"\#(phone.secret(for: salt).base64URL)"}"#
    }

    /// Enrols the phone at the open Mac with the password "ab", then locks the Mac. Returns the first ask.
    private func enrolAndLock() async throws -> Ask {
        let open = try await next()
        XCTAssertEqual(open as NSDictionary, ["t": "lock", "on": false])
        XCTAssertFalse(server.unlocksWithFaceID)
        // The offer, started at the Mac, reaches the phone; its passkey ends it.
        var ended: Bool?
        server.offerFaceUnlock(password: "ab") { ended = $0 }
        let offer = try await next()
        XCTAssertEqual(offer["t"] as? String, "enrol")
        XCTAssertEqual(offer["name"] as? String, Host.current().localizedName)
        let asked = try XCTUnwrap((offer["challenge"] as? String).flatMap(Data.init(base64URL:)))
        let salt = try XCTUnwrap((offer["salt"] as? String).flatMap(Data.init(base64URL:)))
        try await socket.send(.string(enrolment(for: asked, salt: salt)))
        let enrolled = try await next()
        XCTAssertEqual(enrolled as NSDictionary, ["t": "enrolled", "ok": true])
        XCTAssertEqual(ended, true)
        XCTAssertTrue(server.unlocksWithFaceID)
        // Locked: the Mac names the passkey and gives a challenge.
        return try await lockAgain()
    }

    private func lockAgain() async throws -> Ask {
        sessionLocked = true
        lock.note(true)
        return try ask(in: try await next())
    }

    func testAPhoneEnrolsAtAnOpenMacAndItsPasskeyTypesThePasswordIntoTheLockScreen() async throws {
        let first = try await enrolAndLock()

        // An answer to another challenge, as a recording would be: refused, nothing typed, a new challenge.
        try await socket.send(.string(answer(first, challenge: Passkey.challenge())))
        let refused = try await next()
        XCTAssertEqual(refused as NSDictionary, ["t": "unlock", "ok": false, "why": "key"])
        let second = try ask(in: try await next())
        XCTAssertNotEqual(second.challenge, first.challenge)
        XCTAssertNotEqual(second.next, first.next)
        XCTAssertEqual(second.salt, first.salt)
        XCTAssertTrue(events.isEmpty)
        // The first challenge went with that try.
        try await socket.send(.string(answer(first)))
        let spent = try await next()
        XCTAssertEqual(spent["why"] as? String, "key")
        let third = try ask(in: try await next())
        XCTAssertTrue(events.isEmpty)

        // The passkey's answer: the sealed password goes into the lock screen, then Return.
        try await socket.send(.string(answer(third)))
        let stayed = try await next()
        XCTAssertEqual(stayed as NSDictionary, ["t": "unlock", "ok": false, "why": "password"], "this lock screen never opens")
        XCTAssertEqual(keysDown.count, 3)
        XCTAssertEqual(keysDown.last, kVK_Return)
        let fourth = try ask(in: try await next())
        XCTAssertEqual(fourth.salt, first.salt, "a password the Mac refused is not sealed anew")

        // The Mac refuses that password a second time: it is no longer kept, and the lock names no passkey.
        try await socket.send(.string(answer(fourth)))
        let again = try await next()
        XCTAssertEqual(again["why"] as? String, "password")
        XCTAssertEqual(keysDown.count, 6)
        let plain = try await next()
        XCTAssertEqual(plain as NSDictionary, ["t": "lock", "on": true])
        XCTAssertFalse(server.unlocksWithFaceID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testAMacThatOpensForThePasswordForgetsAnEarlierRefusal() async throws {
        let first = try await enrolAndLock()
        try await socket.send(.string(answer(first)))
        let stayed = try await next()
        XCTAssertEqual(stayed["why"] as? String, "password")
        let second = try ask(in: try await next())
        XCTAssertEqual(FaceUnlock(file: file).key?.refusals, 1)
        // This time the lock screen takes the password: the session opens at Return.
        opensAtReturn = true
        try await socket.send(.string(answer(second)))
        let opened = try await next()
        XCTAssertEqual(opened as NSDictionary, ["t": "lock", "on": false])
        XCTAssertEqual(keysDown.count, 6)
        XCTAssertEqual(FaceUnlock(file: file).key?.refusals, 0)
        XCTAssertTrue(server.unlocksWithFaceID)
    }

    func testALockedMacEnrolsNobodyAndAnOfferEndsWhenItsTimeIsUp() async throws {
        _ = try await next() // lock: false
        var ended: Bool?
        server.offerFaceUnlock(password: "ab", for: 0.3) { ended = $0 }
        let offer = try await next()
        let asked = try XCTUnwrap((offer["challenge"] as? String).flatMap(Data.init(base64URL:)))
        sessionLocked = true
        lock.note(true)
        let locked = try await next()
        XCTAssertEqual(locked as NSDictionary, ["t": "lock", "on": true])
        let salt = try XCTUnwrap((offer["salt"] as? String).flatMap(Data.init(base64URL:)))
        try await socket.send(.string(enrolment(for: asked, salt: salt)))
        let refused = try await next()
        XCTAssertEqual(refused as NSDictionary, ["t": "enrolled", "ok": false])
        let over = try await next()
        XCTAssertEqual(over as NSDictionary, ["t": "enrol", "off": true])
        XCTAssertEqual(ended, false)
        XCTAssertFalse(server.unlocksWithFaceID)
    }

    /// Once the Mac has opened, the password is sealed under the secret for the salt that try named next.
    /// A recorded answer with its secret opens nothing after that.
    func testAnUnlockThatOpensTheMacSealsThePasswordUnderTheNextSalt() async throws {
        let first = try await enrolAndLock()
        opensAtReturn = true
        try await socket.send(.string(answer(first)))
        let opened = try await next()
        XCTAssertEqual(opened as NSDictionary, ["t": "lock", "on": false])
        XCTAssertEqual(FaceUnlock(file: file).key?.salt, first.next)

        let second = try await lockAgain()
        XCTAssertEqual(second.salt, first.next)
        // The secret of the first unlock, as recorded, with a fresh signature: only the secret is old.
        try await socket.send(.string(phone.message(phone.answer(second.challenge), salt: first.salt)))
        let refused = try await next()
        XCTAssertEqual(refused["why"] as? String, "key", "the secret for the old salt")
        let third = try ask(in: try await next())
        XCTAssertEqual(keysDown.count, 3, "nothing typed for it")
        XCTAssertEqual(third.salt, first.next)
        try await socket.send(.string(answer(third)))
        let again = try await next()
        XCTAssertEqual(again as NSDictionary, ["t": "lock", "on": false])
        XCTAssertEqual(keysDown.count, 6)
        XCTAssertEqual(FaceUnlock(file: file).key?.salt, third.next)
    }

    /// A page that asks the passkey for one secret only, as before: the Mac opens and the salt stays.
    func testAnUnlockWithoutTheSecondSecretOpensAndKeepsTheSalt() async throws {
        let first = try await enrolAndLock()
        opensAtReturn = true
        try await socket.send(.string(answer(first, rotates: false)))
        let opened = try await next()
        XCTAssertEqual(opened as NSDictionary, ["t": "lock", "on": false])
        XCTAssertEqual(FaceUnlock(file: file).key?.salt, first.salt)
        let second = try await lockAgain()
        XCTAssertEqual(second.salt, first.salt)
        try await socket.send(.string(answer(second)))
        _ = try await next()
        XCTAssertEqual(FaceUnlock(file: file).key?.salt, second.next)
    }
}
