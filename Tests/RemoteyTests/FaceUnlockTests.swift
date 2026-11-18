import XCTest
@testable import Remotey

final class FaceUnlockTests: XCTestCase {
    private let phone = TestPhone()
    private let file = FileManager.default.temporaryDirectory.appendingPathComponent("remotey-face-unlock-\(UUID().uuidString)")
    private lazy var faceUnlock = FaceUnlock(file: file)

    override func tearDown() {
        try? FileManager.default.removeItem(at: file)
    }

    private func enrol(_ password: String = "geheim Zß!") {
        XCTAssertTrue(phone.enrol(in: faceUnlock, for: faceUnlock.offerEnrolment(password: password)))
    }

    func testThePasswordOpensForThePasskeysAnswerAndSecretOnly() throws {
        enrol()
        let challenge = Passkey.challenge()
        XCTAssertEqual(faceUnlock.password(for: phone.answer(challenge), challenge: challenge, secret: phone.secret), "geheim Zß!")
        XCTAssertNil(faceUnlock.password(for: phone.answer(challenge), challenge: challenge, secret: Data(repeating: 6, count: 32)),
                     "the right passkey with another secret")
        XCTAssertNil(faceUnlock.password(for: phone.answer(challenge), challenge: Passkey.challenge(), secret: phone.secret),
                     "an answer to an earlier challenge")
        var other = TestPhone()
        other.secret = phone.secret
        XCTAssertNil(faceUnlock.password(for: other.answer(challenge), challenge: challenge, secret: phone.secret),
                     "the secret alone, without the passkey's signature")
    }

    func testWhatLiesOnTheMacIsPrivateAndDoesNotShowThePassword() throws {
        enrol("correct horse")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        XCTAssertFalse(text.contains("correct horse"))
        XCTAssertFalse(text.contains(Data("correct horse".utf8).base64EncodedString()))
        XCTAssertFalse(text.contains(phone.secret.base64EncodedString()), "the secret stays with the phone")
        // The next start finds it.
        let again = FaceUnlock(file: file)
        XCTAssertEqual(again.key, faceUnlock.key)
        let challenge = Passkey.challenge()
        XCTAssertEqual(again.password(for: phone.answer(challenge), challenge: challenge, secret: phone.secret), "correct horse")
    }

    func testOnlyAnOfferEnrolsAndItEndsWithThePhoneThatTakesIt() {
        XCTAssertFalse(phone.enrol(in: faceUnlock, for: FaceUnlock.Offer(challenge: Passkey.challenge(), salt: Passkey.challenge())),
                       "nothing was offered")
        let offer = faceUnlock.offerEnrolment(password: "geheim")
        XCTAssertFalse(phone.enrol(in: faceUnlock, for: FaceUnlock.Offer(challenge: Passkey.challenge(), salt: offer.salt)),
                       "a passkey made for another challenge")
        XCTAssertNil(faceUnlock.key)
        XCTAssertFalse(faceUnlock.enrol(id: phone.id, publicKey: phone.publicKey, authenticator: phone.authenticator(),
                                        client: phone.client("webauthn.create", challenge: offer.challenge), secret: Data([1, 2, 3])),
                       "not a secret a passkey gives out")
        XCTAssertEqual(faceUnlock.offer, offer, "the offer stands until it is taken")
        XCTAssertTrue(phone.enrol(in: faceUnlock, for: offer))
        XCTAssertNil(faceUnlock.offer)
        XCTAssertFalse(TestPhone().enrol(in: faceUnlock, for: offer), "a second phone, after the offer is over")
        XCTAssertEqual(faceUnlock.key?.passkey.id, phone.id)

        faceUnlock.offerEnrolment(password: "neu")
        faceUnlock.withdraw()
        XCTAssertNil(faceUnlock.offer)
        XCTAssertFalse(TestPhone().enrol(in: faceUnlock, for: offer))
    }

    func testAPasswordTheMacRefusesTwiceInARowIsDropped() {
        enrol()
        XCTAssertFalse(faceUnlock.refused())
        XCTAssertEqual(FaceUnlock(file: file).key?.refusals, 1, "counted across a restart")
        faceUnlock.opened()
        XCTAssertEqual(FaceUnlock(file: file).key?.refusals, 0)
        XCTAssertFalse(faceUnlock.refused())
        XCTAssertTrue(faceUnlock.refused())
        XCTAssertNil(faceUnlock.key)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let challenge = Passkey.challenge()
        XCTAssertNil(faceUnlock.password(for: phone.answer(challenge), challenge: challenge, secret: phone.secret))
    }

    func testRemovingLeavesNothing() {
        enrol()
        faceUnlock.remove()
        XCTAssertNil(faceUnlock.key)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(FaceUnlock(file: file).key)
    }

    func testAnAgentOnAnotherPortKeepsItsOwn() {
        XCTAssertEqual(FaceUnlock.file(port: 47800).lastPathComponent, "face-unlock")
        XCTAssertEqual(FaceUnlock.file(port: 47820).lastPathComponent, "face-unlock-47820")
        XCTAssertEqual(FaceUnlock.file(port: 47820).deletingLastPathComponent(), Token.fileURL.deletingLastPathComponent())
    }
}
