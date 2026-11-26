import Foundation
import Security

/// Pairing token. Lives in a 0600 file so the app and dev builds share it without Keychain prompts.
enum Token {
    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Remotey/token")
    }

    struct WriteFailure: Error, CustomStringConvertible {
        let description: String
    }

    /// The saved token, or a new one if there is none. A new one that could not be saved works until the agent
    /// quits; `failure` says why it was not saved.
    /// `fresh`: there was none, so no phone was ever paired with it.
    static func load(from file: URL = fileURL) -> (token: String, failure: WriteFailure?, fresh: Bool) {
        if let existing = try? String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), existing.count >= 32 {
            return (existing, nil, false)
        }
        let token = make()
        do {
            try save(token, to: file)
            return (token, nil, true)
        } catch {
            return (token, error as? WriteFailure ?? WriteFailure(description: "\(error)"), true)
        }
    }

    /// A new token, saved. Throws if it could not be saved: then the file still holds the old one, which stays
    /// valid, so the caller keeps it too. Else the old one would come back with the next start.
    static func rotate(at file: URL = fileURL) throws -> String {
        let token = make()
        try save(token, to: file)
        return token
    }

    private static func make() -> String { random() }

    /// `count` random bytes, base64url without padding: tokens, device keys, codes and tickets.
    static func random(_ count: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        return Data(bytes).base64URL
    }

    private static func save(_ token: String, to file: URL) throws {
        try write(Data(token.utf8), to: file)
    }

    /// Written beside the file and renamed over it, so the file holds the old content or the new one, never a part.
    /// The new file is 0600 from the start.
    static func write(_ data: Data, to file: URL) throws {
        let fm = FileManager.default
        let directory = file.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw WriteFailure(description: "\(directory.path): \(error.localizedDescription)")
        }
        let temporary = directory.appendingPathComponent(".\(file.lastPathComponent)-\(UUID().uuidString)")
        guard fm.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw WriteFailure(description: "\(directory.path) ist nicht beschreibbar")
        }
        guard rename(temporary.path, file.path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? fm.removeItem(at: temporary)
            throw WriteFailure(description: "\(file.path): \(reason)")
        }
    }

    /// Constant-time comparison.
    static func matches(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
