import CryptoKit
import Foundation

/// Unlocking with Face ID: the Mac's password, sealed so that only the phone's passkey opens it.
///
/// The passkey gives out a secret (WebAuthn's PRF extension) whenever iOS has verified the user, and only
/// then. The password is encrypted with a key made from that secret, so what lies on the Mac opens nothing
/// by itself: the file needs no secrecy and lies beside the token. To unlock, the phone signs a fresh
/// challenge, which proves that the secret was not recorded earlier, and sends the secret along.
/// Main thread only.
final class FaceUnlock {
    /// What is kept on the Mac.
    struct Key: Codable, Equatable {
        var passkey: Passkey
        /// What the passkey makes its secret from. Not secret itself.
        var salt: Data
        /// The password, encrypted (AES-GCM: nonce, ciphertext, tag).
        var sealed: Data
        /// How often in a row the Mac has refused the password since it last took it.
        var refusals = 0
    }

    /// An enrolment waiting for the phone: what its new passkey has to sign and make its secret from.
    struct Offer: Equatable {
        let challenge: Data
        let salt: Data
    }

    /// A password the Mac refuses this often in a row is no longer its password: the key is removed.
    static let maxRefusals = 2

    private(set) var key: Key?
    private(set) var offer: Offer?
    private var password: String? // while the offer stands
    private let file: URL

    /// Beside the token. An agent on another port is reached under another origin and keeps its own.
    static func file(port: UInt16 = Server.port) -> URL {
        Token.fileURL.deletingLastPathComponent().appendingPathComponent(port == 47800 ? "face-unlock" : "face-unlock-\(port)")
    }

    init(file: URL = FaceUnlock.file()) {
        self.file = file
        key = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Key.self, from: $0) }
    }

    // MARK: Enrolling

    /// Starts an enrolment with the Mac's password, which is held until the phone answers or `withdraw`.
    @discardableResult
    func offerEnrolment(password: String) -> Offer {
        let offer = Offer(challenge: Passkey.challenge(), salt: Passkey.challenge())
        self.offer = offer
        self.password = password
        return offer
    }

    func withdraw() {
        offer = nil
        password = nil
    }

    /// The phone made a passkey for the offer, and `secret` is what it gives out for the offer's salt.
    /// True: the password is sealed with it and kept, in place of what was there, and the offer is over.
    func enrol(id: Data, publicKey: Data, authenticator: Data, client: Data, secret: Data) -> Bool {
        guard let offer, let password,
              let passkey = Passkey(id: id, publicKey: publicKey, authenticator: authenticator, client: client,
                                    challenge: offer.challenge),
              let sealed = Self.seal(password, secret: secret, salt: offer.salt) else { return false }
        let enrolled = Key(passkey: passkey, salt: offer.salt, sealed: sealed)
        guard save(enrolled) else { return false }
        key = enrolled
        withdraw()
        return true
    }

    func remove() {
        key = nil
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: Unlocking

    /// The Mac's password, if `answer` is the passkey's signature for `challenge` and `secret` opens the seal.
    func password(for answer: Passkey.Answer, challenge: Data, secret: Data) -> String? {
        guard let key, key.passkey.verifies(answer, challenge: challenge) else { return nil }
        return Self.open(key.sealed, secret: secret, salt: key.salt)
    }

    /// The Mac did not take the password. True if that was once too often and the key is gone.
    @discardableResult
    func refused() -> Bool {
        guard var key else { return false }
        key.refusals += 1
        guard key.refusals < Self.maxRefusals else {
            remove()
            return true
        }
        self.key = key
        save(key)
        return false
    }

    /// The Mac took the password.
    func opened() {
        guard var key, key.refusals > 0 else { return }
        key.refusals = 0
        self.key = key
        save(key)
    }

    // MARK: The seal

    private static func cipherKey(secret: Data, salt: Data) -> SymmetricKey? {
        guard secret.count == 32 else { return nil } // what PRF gives out
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: salt,
                                      info: Data("Remotey face unlock 1".utf8), outputByteCount: 32)
    }

    static func seal(_ password: String, secret: Data, salt: Data) -> Data? {
        guard let cipherKey = cipherKey(secret: secret, salt: salt) else { return nil }
        return try? AES.GCM.seal(Data(password.utf8), using: cipherKey).combined
    }

    static func open(_ sealed: Data, secret: Data, salt: Data) -> String? {
        guard let cipherKey = cipherKey(secret: secret, salt: salt), let box = try? AES.GCM.SealedBox(combined: sealed),
              let password = try? AES.GCM.open(box, using: cipherKey) else { return nil }
        return String(data: password, encoding: .utf8)
    }

    @discardableResult
    private func save(_ key: Key) -> Bool {
        guard let data = try? JSONEncoder().encode(key) else { return false }
        let fm = FileManager.default
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        guard fm.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return false }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return true
    }
}
