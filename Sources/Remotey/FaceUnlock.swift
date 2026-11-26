import CryptoKit
import Foundation

/// Unlocking with Face ID: the Mac's password, sealed so that only the phone's passkey opens it.
///
/// The passkey gives out a secret (WebAuthn's PRF extension) whenever iOS has verified the user, and only
/// then. The password is encrypted with a key made from that secret, so what lies on the Mac opens nothing
/// by itself: the file needs no secrecy and lies beside the token. To unlock, the phone signs a fresh
/// challenge, which proves that the secret was not recorded earlier, and sends the secret along.
///
/// The secret is the same for the same salt, so a secret recorded once would open the file for good. So
/// every unlock asks the passkey for a second secret too, for a fresh salt, and once the Mac has taken the
/// password it is sealed anew under that one: a recorded secret opens the file only until the next unlock.
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

    /// What a locked Mac gives a phone for one try: the challenge its passkey signs, and the salt for the
    /// secret the password is sealed under after that try.
    struct Ask: Equatable {
        let challenge: Data
        let next: Data
    }

    /// The password sealed under the passkey's secret for a new salt, kept once the Mac has taken it.
    struct Rotation: Equatable {
        /// The salt it replaces. A key that changed meanwhile (enrolled anew, removed) is not touched.
        let from: Data
        let salt: Data
        let sealed: Data
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

    func ask() -> Ask { Ask(challenge: Passkey.challenge(), next: Passkey.challenge()) }

    /// `password`, as `password(for:challenge:secret:)` opened it with `secret`, sealed under `next`, the
    /// passkey's secret for `salt`. Nil if there is nothing to seal it under: the phone gave no second secret
    /// (an older page, a browser without it), or one that cannot be the passkey's for another salt. Then the
    /// key stays as it is, which unlocks as before, instead of a seal that no passkey can open again.
    func rotation(of password: String, secret: Data, to salt: Data, next: Data?) -> Rotation? {
        guard let key, let next, next != secret, salt != key.salt,
              let sealed = Self.seal(password, secret: next, salt: salt) else { return nil }
        return Rotation(from: key.salt, salt: salt, sealed: sealed)
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

    /// The Mac took the password. With `rotation` from that try, the password is kept under its salt from now
    /// on. Kept only once it is on disk: until then the file and the salt the Mac names are the old ones,
    /// which the passkey still opens.
    func opened(rotating rotation: Rotation? = nil) {
        guard var key else { return }
        let refused = key.refusals > 0
        key.refusals = 0
        if let rotation, rotation.from == key.salt {
            key.salt = rotation.salt
            key.sealed = rotation.sealed
        } else if !refused {
            return
        }
        if save(key) { self.key = key }
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
        // Written whole beside the file and then moved over it: a crash halfway leaves the old key, not none.
        do { try data.write(to: file, options: .atomic) } catch { return false }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return true
    }
}
