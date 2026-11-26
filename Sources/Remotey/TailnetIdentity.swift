import Foundation

/// Who a request comes from, as `tailscale serve` says it. Read in Tailscale's source (`ipn/ipnlocal/serve.go`,
/// main at f2c476c, see docs/decisions.md, round 19): before it forwards a request, `serve` deletes every
/// `Tailscale-User-Login`, `-Name`, `-Profile-Pic`, `Tailscale-Funnel-Request` and `Tailscale-Headers-Info` the
/// request brought, also spelled with `_`. Then it sets `Tailscale-User-Login` and `-Name` for a peer that has a
/// user, Q-encoded (RFC 2047) where they are not ASCII; nothing for a tagged device or for traffic from outside
/// the tailnet; and `Tailscale-Funnel-Request: ?1` for a request that came through Funnel from the internet.
///
/// So through `serve` the fields cannot be faked, and a request without them is local or from a tagged device. A
/// process on the Mac reaches the loopback ports directly and can send anything, which only ever lets it in as
/// the owner it could be anyway.
enum TailnetIdentity {
    /// What `tailscale status` names a tagged Mac's owner: no person, so no filter.
    static let tagged = "tagged-devices"

    /// A request through Funnel is refused: the agent is for the tailnet only. One through `serve` from a person
    /// other than the Mac's owner is refused. Everything else is let in: a request without the field, an owner
    /// that is not known, a login that cannot be read. Where a fact is not known, the rule lets the owner's own
    /// phone in rather than keep it out.
    static func allows(_ fields: HeaderFields, owner: String?) -> Bool {
        if fields["Tailscale-Funnel-Request"] != nil { return false }
        guard let owner, !owner.isEmpty, owner != tagged, let login = login(fields) else { return true }
        return login.caseInsensitiveCompare(owner) == .orderedSame
    }

    /// The login of the person behind the request, decoded. Nil without the field or when it cannot be read.
    static func login(_ fields: HeaderFields) -> String? {
        fields["Tailscale-User-Login"].flatMap(decode).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The person's display name, decoded.
    static func name(_ fields: HeaderFields) -> String? {
        fields["Tailscale-User-Name"].flatMap(decode).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A field as Go's `mime.QEncoding.Encode("utf-8", …)` writes it: ASCII as it is, else one or more words
    /// `=?utf-8?q?…?=` separated by a space, `_` for a space and `=XX` for a byte. Nil for a word it cannot read.
    static func decode(_ value: String) -> String? {
        guard value.hasPrefix("=?") else { return value }
        var bytes: [UInt8] = []
        for word in value.split(separator: " ") {
            let parts = word.split(separator: "?", omittingEmptySubsequences: false)
            guard parts.count == 5, parts[0] == "=", parts[1].lowercased() == "utf-8", parts[2].lowercased() == "q",
                  parts[4] == "=" else { return nil }
            var text = Array(parts[3].utf8)[...]
            while let byte = text.popFirst() {
                switch byte {
                case UInt8(ascii: "_"): bytes.append(UInt8(ascii: " "))
                case UInt8(ascii: "="):
                    guard text.count >= 2, let hex = UInt8(String(decoding: text.prefix(2), as: UTF8.self), radix: 16) else { return nil }
                    bytes.append(hex)
                    text = text.dropFirst(2)
                default: bytes.append(byte)
                }
            }
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}
