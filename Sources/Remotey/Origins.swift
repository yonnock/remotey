import Foundation

/// The header fields of an HTTP request, looked up by name in any case.
struct HeaderFields {
    private var fields: [String: String] = [:]

    init(_ pairs: [(name: String, value: String)]) {
        // A field named twice keeps its first value: Host and Origin come once in any request a browser sends.
        for pair in pairs where fields[pair.name.lowercased()] == nil {
            fields[pair.name.lowercased()] = pair.value.trimmingCharacters(in: .whitespaces)
        }
    }

    /// The fields of the head of an HTTP/1.1 request: the lines after the request line, up to the empty one
    /// or as far as `data` reaches.
    init(request data: Data) {
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n").dropFirst()
        self.init(lines.prefix { !$0.isEmpty }.compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (String(line[..<colon]), String(line[line.index(after: colon)...]))
        })
    }

    subscript(name: String) -> String? { fields[name.lowercased()] }
}

/// Which requests come from the page's own places. The agent listens on loopback only, but a web page in the Mac's
/// browser reaches loopback too: by its own address (`Origin` names that page), or by a name of its own that it
/// points at 127.0.0.1 (DNS rebinding: then `Host` names it).
///
/// The page's own places: behind `tailscale serve` the phone asks for `https://<mac>.<tailnet>.ts.net:8443`, and
/// `serve` hands `Host` on as the phone sent it and `Origin` untouched (see docs/decisions.md, round 18). In
/// development the page is on 127.0.0.1 or localhost. A request without the field is let in: browsers always
/// send both on a WebSocket and `Host` on every request, so only a program sends none, and a program on the Mac
/// reaches the ports anyway.
enum Origins {
    /// Whether a host, as `Host` or an origin names it, is one the page is served from.
    static func isOwn(host: String) -> Bool {
        var name = host.lowercased()
        // Without its port: `[::1]:47800`, `127.0.0.1:47800`, `mac.example.ts.net:8443`.
        if name.hasPrefix("["), let end = name.firstIndex(of: "]") {
            name = String(name[name.index(after: name.startIndex)..<end])
        } else if let colon = name.lastIndex(of: ":"), name.firstIndex(of: ":") == colon {
            name = String(name[..<colon])
        }
        if name.hasSuffix(".") { name.removeLast() }
        return ["127.0.0.1", "localhost", "::1"].contains(name) || name.hasSuffix(".ts.net")
    }

    /// `Host` of a request to either port.
    static func allows(host: String?) -> Bool {
        host.map(isOwn(host:)) ?? true
    }

    /// `Origin` of a WebSocket handshake: the page that opens it. `null` is a sandboxed frame or a file, never the page.
    static func allows(origin: String?) -> Bool {
        guard let origin else { return true }
        guard let url = URL(string: origin), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host else { return false }
        return isOwn(host: host)
    }

    static func allows(_ fields: HeaderFields) -> Bool {
        allows(host: fields["Host"]) && allows(origin: fields["Origin"])
    }
}
