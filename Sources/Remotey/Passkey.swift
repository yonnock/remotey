import CryptoKit
import Foundation
import Security

/// A passkey on the phone, as far as the agent needs WebAuthn: what the phone says, checked against what
/// was asked.
///
/// The page makes the passkey and hands over its public key as the browser gives it (`getPublicKey()`).
/// From then on a signature over a fresh challenge proves that the phone holds the key and that iOS has
/// just verified its user: Face ID, Touch ID or the phone's code. Only ES256, the algorithm asked for.
struct Passkey: Codable, Equatable {
    /// The credential's id: the page names it when it asks the phone for the passkey.
    let id: Data
    /// The P-256 public key, DER (SubjectPublicKeyInfo).
    let publicKey: Data
    /// The page's origin when the passkey was made. A passkey belongs to the host of its page and works
    /// nowhere else, so a Mac that changes its name in the tailnet is enrolled again.
    let origin: String

    /// What the phone answers: the authenticator's data, the browser's (JSON) and the signature over both.
    struct Answer: Equatable {
        let authenticator: Data
        let client: Data
        let signature: Data
    }

    /// 32 random bytes that an answer has to sign. Each one counts once.
    static func challenge() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        return Data(bytes)
    }

    init(id: Data, publicKey: Data, origin: String) {
        self.id = id
        self.publicKey = publicKey
        self.origin = origin
    }

    /// A passkey the page has just made for `challenge`. Nil unless the browser made it for that challenge,
    /// for the host of its own page, with the user verified, and the key is one this can check with.
    /// The origin is taken as the browser names it: whoever enrols holds the token and sits at the Mac.
    init?(id: Data, publicKey: Data, authenticator: Data, client: Data, challenge: Data) {
        guard (1...1023).contains(id.count), (try? P256.Signing.PublicKey(derRepresentation: publicKey)) != nil,
              let origin = Self.origin(of: client, type: "webauthn.create", challenge: challenge),
              Self.isVerified(authenticator, origin: origin) else { return nil }
        self.init(id: id, publicKey: publicKey, origin: origin)
    }

    /// Whether `answer` is this passkey's signature for `challenge`, given on the page it was made for,
    /// with the user verified.
    func verifies(_ answer: Answer, challenge: Data) -> Bool {
        guard Self.origin(of: answer.client, type: "webauthn.get", challenge: challenge) == origin,
              Self.isVerified(answer.authenticator, origin: origin),
              let key = try? P256.Signing.PublicKey(derRepresentation: publicKey),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: answer.signature) else { return false }
        return key.isValidSignature(signature, for: answer.authenticator + Data(SHA256.hash(data: answer.client)))
    }

    private struct ClientData: Decodable {
        let type: String
        let challenge: String
        let origin: String
        var crossOrigin: Bool?
    }

    /// The origin the browser names, if its data is of this type, for this challenge and not from a frame
    /// of another site.
    private static func origin(of client: Data, type: String, challenge: Data) -> String? {
        guard let data = try? JSONDecoder().decode(ClientData.self, from: client), data.type == type,
              Data(base64URL: data.challenge) == challenge, data.crossOrigin != true else { return nil }
        return data.origin
    }

    /// The authenticator's data begins with the hash of the host it answered for, then its flags: bit 0
    /// says that the user was there, bit 2 that the phone verified who it is.
    private static func isVerified(_ authenticator: Data, origin: String) -> Bool {
        guard let host = URLComponents(string: origin)?.host, !host.isEmpty, authenticator.count >= 37 else { return false }
        let bytes = [UInt8](authenticator.prefix(33))
        return Data(bytes.prefix(32)) == Data(SHA256.hash(data: Data(host.utf8))) && bytes[32] & 0x05 == 0x05
    }
}

extension Data {
    /// Base64 as WebAuthn writes it: `-` and `_`, no padding.
    init?(base64URL text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }

    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
