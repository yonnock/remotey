import CryptoKit
import Foundation

/// A phone that paired with this Mac. Its key lives in a cookie on the phone; the Mac keeps only its hash.
struct Device: Codable, Equatable, Identifiable {
    typealias ID = String
    let id: ID
    var name: String
    let paired: Date
    /// When it last asked for a session, connected or left.
    var seen: Date?
    /// The Tailscale login it paired from, as `tailscale serve` named it. Nil for a request that did not come
    /// through it, and for a tagged device, which has no login.
    var login: String?
    /// SHA-256 of the key, base64url.
    let keyHash: String

    static func hash(_ key: String) -> String { Data(SHA256.hash(data: Data(key.utf8))).base64URL }
}

/// Who may connect: the paired phones, and two switches that go with them. Whether the old shared token still
/// opens the socket (on for a Mac that has a token from before but no file yet, so a phone paired the old way
/// keeps working after the update; off on a Mac that never had one), and whether remote control is paused. One 0600 file beside the token, written whole, so the file
/// alone opens nothing: it has no key, only hashes.
final class Devices {
    private struct Saved: Codable {
        var devices: [Device] = []
        var token = true
        var paused = false
        /// A phone moved the pointer once: the setup's last step is done.
        var moved = false

        init(token: Bool = true) { self.token = token }

        /// A field a later version adds is missing in an older file.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            devices = try c.decode([Device].self, forKey: .devices)
            token = try c.decodeIfPresent(Bool.self, forKey: .token) ?? false
            paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
            moved = try c.decodeIfPresent(Bool.self, forKey: .moved) ?? false
        }
    }

    static func file(port: UInt16 = Server.port) -> URL {
        Token.fileURL.deletingLastPathComponent().appendingPathComponent(port == 47800 ? "devices" : "devices-\(port)")
    }

    private let file: URL
    private let now: () -> Date
    private var saved: Saved

    /// Oldest first.
    var all: [Device] { saved.devices }
    var acceptsToken: Bool { saved.token }
    var paused: Bool { saved.paused }
    var moved: Bool { saved.moved }

    /// A file that is there but cannot be read keeps the old token out: it may be one in which the user
    /// switched the token off. The phones pair again. `tokenFromBefore`: this Mac had the shared token before
    /// this start, so a phone may hold it. A Mac that never had one takes none: every process that runs as the
    /// user can read the token's file, and nothing is gained by a key that no phone has. That is saved at once,
    /// since the next start finds the token this one made.
    init(file: URL = Devices.file(), now: @escaping () -> Date = Date.init, tokenFromBefore: Bool = true) {
        self.file = file
        self.now = now
        if let data = try? Data(contentsOf: file) {
            saved = (try? JSONDecoder.devices.decode(Saved.self, from: data)) ?? Saved(token: false)
        } else {
            saved = Saved(token: tokenFromBefore)
            if !tokenFromBefore { try? save(saved) }
        }
    }

    // MARK: Pairing

    /// A new device and its key, which only the phone keeps. Throws if it could not be saved: then it does not exist.
    func add(name: String, login: String?) throws -> (device: Device, key: String) {
        let key = Token.random()
        let device = Device(id: Token.random(9), name: Self.unique(name, among: saved.devices.map(\.name)),
                            paired: now(), seen: now(), login: login, keyHash: Device.hash(key))
        var next = saved
        next.devices.append(device)
        try save(next)
        return (device, key)
    }

    /// The device this key belongs to. Every hash is compared in full, in constant time.
    func device(key: String) -> Device? {
        let hash = Device.hash(key)
        return saved.devices.reduce(nil) { found, device in Token.matches(device.keyHash, hash) ? device : found }
    }

    /// "iPhone", then "iPhone 2", and so on.
    private static func unique(_ name: String, among names: [String]) -> String {
        guard names.contains(name) else { return name }
        var number = 2
        while names.contains("\(name) \(number)") { number += 1 }
        return "\(name) \(number)"
    }

    // MARK: At the Mac

    func rename(_ id: Device.ID, to name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...64).contains(name.count) else { throw Token.WriteFailure(description: "Der Name braucht 1 bis 64 Zeichen.") }
        var next = saved
        guard let index = next.devices.firstIndex(where: { $0.id == id }) else { return }
        next.devices[index].name = name
        try save(next)
    }

    func revoke(_ id: Device.ID) throws {
        var next = saved
        next.devices.removeAll { $0.id == id }
        try save(next)
    }

    func revokeAll() throws {
        var next = saved
        next.devices = []
        try save(next)
    }

    func setAcceptsToken(_ on: Bool) throws {
        var next = saved
        next.token = on
        try save(next)
    }

    func setPaused(_ on: Bool) throws {
        var next = saved
        next.paused = on
        try save(next)
    }

    // MARK: What happened

    /// Best effort: a last-seen time that is not saved costs nothing.
    func saw(_ id: Device.ID) {
        var next = saved
        guard let index = next.devices.firstIndex(where: { $0.id == id }) else { return }
        next.devices[index].seen = now()
        try? save(next)
    }

    func noteMoved() {
        guard !saved.moved else { return }
        var next = saved
        next.moved = true
        try? save(next)
    }

    /// Saved first, then in effect: what the agent acts on is what the next start loads.
    private func save(_ next: Saved) throws {
        try Token.write(JSONEncoder.devices.encode(next), to: file)
        saved = next
    }
}

private extension JSONEncoder {
    static let devices: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

private extension JSONDecoder {
    static let devices: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
