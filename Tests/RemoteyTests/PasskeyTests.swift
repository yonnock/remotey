import CryptoKit
import XCTest
@testable import Remotey

final class PasskeyTests: XCTestCase {
    private let phone = TestPhone()
    private let challenge = Data(repeating: 9, count: 32)
    private lazy var passkey = Passkey(id: phone.id, publicKey: phone.publicKey, origin: phone.origin)

    /// Not made here: Chromium's virtual authenticator made this passkey on the page (`scripts/ui-verify.mjs`,
    /// T14) and answered the challenge with it.
    func testAPasskeyMadeInABrowserAndItsAnswerAreTaken() throws {
        func data(_ text: String) throws -> Data { try XCTUnwrap(Data(base64URL: text)) }
        let made = try XCTUnwrap(Passkey(
            id: data("V42iJfY-AO3XITzAfTpGMZQVr1uULsMNfMSbHV_83TY"),
            publicKey: data("MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAET9lkSaKCEiMU1xsZXB6OJXP8EWqGDh4g36FACXE_0K-CpXVJEKl3cZfA3No2JNzApRIo9z6ZVXIZw1tYwhnVCQ"),
            authenticator: data("SZYN5YgOjGh0NBcPZHZgW4_krrmihjLHmVzzuoMdl2NFAAAAAQECAwQFBgcIAQIDBAUGBwgAIFeNoiX2PgDt1yE8wH06RjGUFa9blC7DDXzEmx1f_N02"
                + "pQECAyYgASFYIE_ZZEmighIjFNcbGVwejiVz_BFqhg4eIN-hQAlxP9CvIlgggqV1SRCpd3GXwNzaNiTcwKUSKPc-mVVyGcNbWMIZ1Qk"),
            client: data("eyJ0eXBlIjoid2ViYXV0aG4uY3JlYXRlIiwiY2hhbGxlbmdlIjoiNElSMFJxYkZlTzYyTWk5UG82VG8wa1dhX3F2YUszWndiNldNX245SVRmSSIsIm9yaWdp"
                + "biI6Imh0dHA6Ly9sb2NhbGhvc3Q6NTAyMTUiLCJjcm9zc09yaWdpbiI6ZmFsc2V9"),
            challenge: data("4IR0RqbFeO62Mi9Po6To0kWa_qvaK3Zwb6WM_n9ITfI")))
        XCTAssertEqual(made.origin, "http://localhost:50215")
        let answer = Passkey.Answer(
            authenticator: try data("SZYN5YgOjGh0NBcPZHZgW4_krrmihjLHmVzzuoMdl2MFAAAAAg"),
            client: try data("eyJ0eXBlIjoid2ViYXV0aG4uZ2V0IiwiY2hhbGxlbmdlIjoiRGROaWNfc3U4eXlVcERJY0ZveWVNT05zSVlzOVdhOFZwSE5qRGhNbkdwdyIsIm9yaWdp"
                + "biI6Imh0dHA6Ly9sb2NhbGhvc3Q6NTAyMTUiLCJjcm9zc09yaWdpbiI6ZmFsc2V9"),
            signature: try data("MEQCIBnIoOHEXp873Qr6g-N0HER8BVQrJxWFybzBblyYzGHXAiAIvJIoRh5i99bmZPWvMGkrhuWI3AvE4Yh0wXbM_-Uisg"))
        let asked = try data("DdNic_su8yyUpDIcFoyeMONsIYs9Wa8VpHNjDhMnGpw")
        XCTAssertTrue(made.verifies(answer, challenge: asked))
        XCTAssertFalse(made.verifies(answer, challenge: challenge), "an answer counts for the challenge it signed")
    }

    func testAnAnswerCountsForItsChallengeOnItsPageWithTheUserVerified() {
        XCTAssertTrue(passkey.verifies(phone.answer(challenge), challenge: challenge))
        XCTAssertFalse(passkey.verifies(phone.answer(Data(repeating: 8, count: 32)), challenge: challenge), "recorded earlier")
        XCTAssertFalse(passkey.verifies(phone.answer(challenge, authenticator: phone.authenticator(flags: 0x01)), challenge: challenge),
                       "the phone did not verify its user")
        XCTAssertFalse(passkey.verifies(phone.answer(challenge, authenticator: phone.authenticator(flags: 0x04)), challenge: challenge),
                       "nobody was there")
        XCTAssertFalse(passkey.verifies(phone.answer(challenge, authenticator: phone.authenticator(host: "other.example.ts.net")),
                                        challenge: challenge), "given for another host")
        for client in [phone.client("webauthn.get", challenge: challenge, origin: "https://mac.example.ts.net:9000"),
                       phone.client("webauthn.create", challenge: challenge),
                       phone.client("webauthn.get", challenge: challenge, crossOrigin: true), Data("{}".utf8), Data()] {
            XCTAssertFalse(passkey.verifies(phone.answer(challenge, client: client), challenge: challenge),
                           String(decoding: client, as: UTF8.self))
        }
    }

    func testOnlyThePasskeysOwnSignatureCounts() {
        let other = TestPhone()
        XCTAssertFalse(passkey.verifies(other.answer(challenge), challenge: challenge), "another key")
        let answer = phone.answer(challenge)
        let altered = Passkey.Answer(authenticator: answer.authenticator + [0], client: answer.client, signature: answer.signature)
        XCTAssertFalse(passkey.verifies(altered, challenge: challenge), "the signature covers the authenticator's data")
        let unsigned = Passkey.Answer(authenticator: answer.authenticator, client: answer.client, signature: Data([1, 2, 3]))
        XCTAssertFalse(passkey.verifies(unsigned, challenge: challenge))
    }

    func testANewPasskeyIsTakenForItsChallengeWithTheUserVerifiedAndAKeyThatCanBeChecked() {
        func made(publicKey: Data? = nil, authenticator: Data? = nil, client: Data? = nil) -> Passkey? {
            Passkey(id: phone.id, publicKey: publicKey ?? phone.publicKey, authenticator: authenticator ?? phone.authenticator(),
                    client: client ?? phone.client("webauthn.create", challenge: challenge), challenge: challenge)
        }
        XCTAssertEqual(made(), passkey)
        XCTAssertNil(made(publicKey: Data([1, 2, 3])))
        XCTAssertNil(made(authenticator: phone.authenticator(flags: 0x01)), "made without verifying the user")
        XCTAssertNil(made(authenticator: phone.authenticator(host: "other.example.ts.net")), "the browser's page and the authenticator's host differ")
        XCTAssertNil(made(client: phone.client("webauthn.create", challenge: Data(repeating: 8, count: 32))), "made for another offer")
        XCTAssertNil(made(client: phone.client("webauthn.get", challenge: challenge)))
        XCTAssertNil(Passkey(id: Data(), publicKey: phone.publicKey, authenticator: phone.authenticator(),
                             client: phone.client("webauthn.create", challenge: challenge), challenge: challenge))
    }

    func testChallengesDifferAndBase64URLGoesBothWays() {
        XCTAssertEqual(Passkey.challenge().count, 32)
        XCTAssertNotEqual(Passkey.challenge(), Passkey.challenge())
        let data = Data([251, 255, 190, 0, 1])
        XCTAssertEqual(data.base64URL, "-_--AAE")
        XCTAssertEqual(Data(base64URL: "-_--AAE"), data)
        XCTAssertNil(Data(base64URL: "not base64!"))
    }
}
