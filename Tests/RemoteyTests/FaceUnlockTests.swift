import CryptoKit
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

    /// The secret for the salt the password is sealed under now.
    private var secret: Data { phone.secret(for: faceUnlock.key!.salt) }

    func testThePasswordOpensForThePasskeysAnswerAndSecretOnly() throws {
        enrol()
        let challenge = Passkey.challenge()
        XCTAssertEqual(faceUnlock.password(for: phone.answer(challenge), challenge: challenge, secret: secret), "geheim Zß!")
        XCTAssertNil(faceUnlock.password(for: phone.answer(challenge), challenge: challenge, secret: Data(repeating: 6, count: 32)),
                     "the right passkey with another secret")
        XCTAssertNil(faceUnlock.password(for: phone.answer(challenge), challenge: Passkey.challenge(), secret: secret),
                     "an answer to an earlier challenge")
        var other = TestPhone()
        other.seed = phone.seed
        XCTAssertNil(faceUnlock.password(for: other.answer(challenge), challenge: challenge, secret: secret),
                     "the secret alone, without the passkey's signature")
    }

    func testWhatLiesOnTheMacIsPrivateAndDoesNotShowThePassword() throws {
        enrol("correct horse")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        XCTAssertFalse(text.contains("correct horse"))
        XCTAssertFalse(text.contains(Data("correct horse".utf8).base64EncodedString()))
        XCTAssertFalse(text.contains(secret.base64EncodedString()), "the secret stays with the phone")
        // The next start finds it.
        let again = FaceUnlock(file: file)
        XCTAssertEqual(again.key, faceUnlock.key)
        let challenge = Passkey.challenge()
        XCTAssertEqual(again.password(for: phone.answer(challenge), challenge: challenge, secret: secret), "correct horse")
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
        XCTAssertNil(faceUnlock.password(for: phone.answer(challenge), challenge: challenge, secret: phone.secret(for: Data())))
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

    // MARK: A fresh salt with every unlock

    /// One unlock as the server makes it: the answer to an ask, opened with the secret for the current salt,
    /// and the password sealed under the secret for the ask's next salt.
    private func unlock(next: Data?? = nil) -> (password: String?, rotation: FaceUnlock.Rotation?, ask: FaceUnlock.Ask) {
        let ask = faceUnlock.ask()
        let secret = self.secret
        guard let password = faceUnlock.password(for: phone.answer(ask.challenge), challenge: ask.challenge, secret: secret) else {
            return (nil, nil, ask)
        }
        let rotation = faceUnlock.rotation(of: password, secret: secret, to: ask.next, next: next ?? phone.secret(for: ask.next))
        return (password, rotation, ask)
    }

    /// Whoever recorded one unlock and reads the file has a secret and the salt it opens. After the next
    /// unlock that salt is gone and the secret opens nothing.
    func testEveryUnlockSealsThePasswordUnderTheSecretForAFreshSalt() throws {
        enrol()
        let before = try XCTUnwrap(faceUnlock.key)
        let recorded = secret
        let (password, rotation, ask) = unlock()
        XCTAssertEqual(password, "geheim Zß!")
        XCTAssertEqual(faceUnlock.key, before, "nothing changes before the Mac has taken the password")
        faceUnlock.opened(rotating: rotation)
        let after = try XCTUnwrap(FaceUnlock(file: file).key, "kept across a restart")
        XCTAssertEqual(after, faceUnlock.key)
        XCTAssertEqual(after.salt, ask.next)
        XCTAssertEqual(after.passkey, before.passkey)
        XCTAssertNil(FaceUnlock.open(after.sealed, secret: recorded, salt: after.salt), "the recorded secret")
        XCTAssertNil(FaceUnlock.open(after.sealed, secret: recorded, salt: before.salt))
        XCTAssertEqual(unlock().password, "geheim Zß!", "the passkey opens it under the new salt")
    }

    /// No second secret, or one that cannot be the passkey's for another salt: the key stays as it is,
    /// which the passkey opens as before.
    func testWithoutASecondSecretThePasswordStaysWhereItIs() throws {
        enrol()
        let before = try XCTUnwrap(faceUnlock.key)
        XCTAssertNil(unlock(next: .some(nil)).rotation, "an older page or a browser without a second secret")
        XCTAssertNil(unlock(next: secret).rotation, "the first secret again")
        XCTAssertNil(faceUnlock.rotation(of: "geheim Zß!", secret: secret, to: before.salt, next: Passkey.challenge()),
                     "the salt it is sealed under already")
        XCTAssertNil(unlock(next: Data([1, 2, 3])).rotation, "not a secret a passkey gives out")
        faceUnlock.opened(rotating: nil)
        XCTAssertEqual(FaceUnlock(file: file).key, before)
        XCTAssertEqual(unlock().password, "geheim Zß!")
    }

    /// A rotation from before the key changed (enrolled anew, removed) leaves the new key as it is.
    func testARotationForAKeyThatChangedMeanwhileIsDropped() throws {
        enrol()
        let rotation = unlock().rotation
        XCTAssertNotNil(rotation)
        enrol("neu")
        let enrolled = try XCTUnwrap(faceUnlock.key)
        faceUnlock.opened(rotating: rotation)
        XCTAssertEqual(faceUnlock.key, enrolled)
        XCTAssertEqual(FaceUnlock(file: file).key, enrolled)
        faceUnlock.remove()
        faceUnlock.opened(rotating: rotation)
        XCTAssertNil(faceUnlock.key)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// The rotation also forgets a refusal, as an unlock without one does.
    func testAnUnlockThatRotatesForgetsARefusal() {
        enrol()
        faceUnlock.refused()
        faceUnlock.opened(rotating: unlock().rotation)
        XCTAssertEqual(FaceUnlock(file: file).key?.refusals, 0)
    }

    /// Written by the agent before the salt changed with every unlock, as the file of an enrolled Mac is:
    /// it opens and rotates without enrolling again. Made with a fixed key, secret and salt.
    func testAKeyKeptBeforeSaltsChangedStillOpensAndRotates() throws {
        let kept = #"{"sealed":"7bcWs\/HtrYn8qRrEO862LV7csFlBI4AgSk9\/Qod2URLIgqGclQJn","refusals":0,"passkey":{"publicKey":"#
            + #""MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEb\/A7lJJBzh2t1DUZ5pYOCoW0GmmgXDKBA6orzhWUyhY8T3U6Vb8B3FP2wLDH7ueLQMb\/fSWpbiKCuYnO9xwUSg==","#
            + #""id":"AQIDBA==","origin":"https:\/\/mac.example.ts.net:8443"},"salt":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="}"#
        try Data(kept.utf8).write(to: file)
        let old = FaceUnlock(file: file)
        let key = try XCTUnwrap(old.key)
        XCTAssertEqual(key.salt, Data(0..<32))
        var phone = TestPhone()
        phone.key = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))
        XCTAssertEqual(key.passkey.publicKey, phone.publicKey)
        let secret = Data(repeating: 0x2a, count: 32)
        let ask = old.ask()
        let password = try XCTUnwrap(old.password(for: phone.answer(ask.challenge), challenge: ask.challenge, secret: secret))
        XCTAssertEqual(password, "geheim Zß!")
        let next = Data(repeating: 0x2b, count: 32)
        old.opened(rotating: old.rotation(of: password, secret: secret, to: ask.next, next: next))
        let rotated = try XCTUnwrap(FaceUnlock(file: file).key)
        XCTAssertEqual(rotated.salt, ask.next)
        XCTAssertEqual(FaceUnlock.open(rotated.sealed, secret: next, salt: rotated.salt), "geheim Zß!")
        XCTAssertNil(FaceUnlock.open(rotated.sealed, secret: secret, salt: rotated.salt))
    }
}
