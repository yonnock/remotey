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
        let name = bare(host)
        return isLoopback(host: name) || name.hasSuffix(".ts.net")
    }

    /// The development page's places: plain HTTP on this Mac.
    static func isLoopback(host: String) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(bare(host))
    }

    /// The name alone, in lower case.
    private static func bare(_ host: String) -> String {
        var name = host.lowercased()
        // Without its port: `[::1]:47800`, `127.0.0.1:47800`, `mac.example.ts.net:8443`.
        if name.hasPrefix("["), let end = name.firstIndex(of: "]") {
            name = String(name[name.index(after: name.startIndex)..<end])
        } else if let colon = name.lastIndex(of: ":"), name.firstIndex(of: ":") == colon {
            name = String(name[..<colon])
        }
        if name.hasSuffix(".") { name.removeLast() }
        return name
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

    /// `Origin` of a `POST` to the pairing routes. `null` passes here: by the Fetch standard a browser may send it
    /// for its own page's request where a referrer policy hides the origin, and the routes take only
    /// `application/json`, which no other page can send without a CORS preflight that the agent never answers.
    static func allowsPost(_ fields: HeaderFields) -> Bool {
        fields["Origin"] == "null" || (allows(origin: fields["Origin"]) && sameHost(fields))
    }

    /// A WebSocket handshake, or a request to the page's port.
    static func allows(_ fields: HeaderFields) -> Bool {
        allows(host: fields["Host"]) && allows(origin: fields["Origin"]) && sameHost(fields)
    }

    /// The page asks the host it was loaded from: its socket and its routes are on its own name. So `Origin` and
    /// `Host` name one host, whatever the ports. Without this any page under a `ts.net` name passed, and anyone
    /// can publish one through Funnel: opened in the Mac's browser it could fill the places for connections that
    /// have not authenticated and keep the phone out. A request that lacks one of the two is a program's.
    static func sameHost(_ fields: HeaderFields) -> Bool {
        guard let origin = fields["Origin"], let host = fields["Host"] else { return true }
        guard let asked = URL(string: origin)?.host else { return false }
        return bare(asked) == bare(host)
    }
}
