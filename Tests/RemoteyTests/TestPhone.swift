import CryptoKit
import Foundation
@testable import Remotey

/// A phone's passkey that exists only in the tests: it signs as an authenticator does, on the page of
/// `origin`, and gives out a secret for a salt as PRF does: the same for the same salt, another for another.
struct TestPhone {
    var key = P256.Signing.PrivateKey()
    let id = Data([1, 2, 3, 4])
    var origin = "https://mac.example.ts.net:8443"
    /// What the passkey makes its secrets from. Two phones with the same one give the same secrets.
    var seed = Data(repeating: 7, count: 32)

    func secret(for salt: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: salt, using: SymmetricKey(data: seed)))
    }

    var publicKey: Data { key.publicKey.derRepresentation }

    /// The hash of the host, the flags (user present and verified, by default) and a counter.
    func authenticator(flags: UInt8 = 0x05, host: String = "mac.example.ts.net") -> Data {
        Data(SHA256.hash(data: Data(host.utf8))) + [flags, 0, 0, 0, 0]
    }

    func client(_ type: String, challenge: Data, origin: String? = nil, crossOrigin: Bool = false) -> Data {
        Data(#"{"type":"\#(type)","challenge":"\#(challenge.base64URL)","origin":"\#(origin ?? self.origin)","crossOrigin":\#(crossOrigin)}"#.utf8)
    }

    func answer(_ challenge: Data, authenticator: Data? = nil, client: Data? = nil) -> Passkey.Answer {
        let authenticator = authenticator ?? self.authenticator(), client = client ?? self.client("webauthn.get", challenge: challenge)
        let signature = try! key.signature(for: authenticator + Data(SHA256.hash(data: client))) // swiftlint:disable:this force_try
        return Passkey.Answer(authenticator: authenticator, client: client, signature: signature.derRepresentation)
    }

    /// Enrols this phone for `offer`.
    func enrol(in faceUnlock: FaceUnlock, for offer: FaceUnlock.Offer) -> Bool {
        faceUnlock.enrol(id: id, publicKey: publicKey, authenticator: authenticator(),
                         client: client("webauthn.create", challenge: offer.challenge), secret: secret(for: offer.salt))
    }

    /// The page's `unlock` message for `answer`, with the secrets for `salt` and, if named, for `next`.
    func message(_ answer: Passkey.Answer, salt: Data, next: Data? = nil) -> String {
        #"{"t":"unlock","auth":"\#(answer.authenticator.base64URL)","client":"\#(answer.client.base64URL)","#
            + #""sig":"\#(answer.signature.base64URL)","prf":"\#(secret(for: salt).base64URL)""#
            + (next.map { #","next":"\#(secret(for: $0).base64URL)""# } ?? "") + "}"
    }
}
