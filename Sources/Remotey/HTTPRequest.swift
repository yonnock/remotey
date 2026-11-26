import Foundation

/// One HTTP/1.1 request, as far as the agent reads one: the request line, the head and a short body. Anything
/// larger or stranger is refused, not read on.
struct HTTPRequest {
    let method: String
    /// Without the query.
    let path: String
    let fields: HeaderFields
    let body: Data

    /// A browser's head is a few hundred bytes; cookies and `tailscale serve`'s fields add a few hundred more.
    static let maxHead = 8192
    /// `{"code":"…"}` or `{"token":"…"}`.
    static let maxBody = 4096

    enum Parse: Equatable {
        /// The head or the body is not all there yet.
        case incomplete
        case complete(HTTPRequest)
        /// A status line such as `431 Request Header Fields Too Large`.
        case refused(String)
    }

    static func parse(_ data: Data) -> Parse {
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxHead ? .refused("431 Request Header Fields Too Large") : .incomplete
        }
        guard end.lowerBound <= maxHead else { return .refused("431 Request Header Fields Too Large") }
        let lines = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1."), !parts[0].isEmpty, parts[1].hasPrefix("/") else {
            return .refused("400 Bad Request")
        }
        var pairs: [(name: String, value: String)] = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .refused("400 Bad Request") }
            pairs.append((String(line[..<colon]), String(line[line.index(after: colon)...])))
        }
        // The body is read by its length only. A second length could mean another body to a proxy in front.
        let lengths = pairs.filter { $0.name.lowercased() == "content-length" }
        if pairs.contains(where: { $0.name.lowercased() == "transfer-encoding" }) { return .refused("411 Length Required") }
        guard lengths.count <= 1 else { return .refused("400 Bad Request") }
        var length = 0
        if let text = lengths.first?.value.trimmingCharacters(in: .whitespaces) {
            guard !text.isEmpty, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber), let value = Int(text) else {
                return .refused("400 Bad Request")
            }
            guard value <= maxBody else { return .refused("413 Content Too Large") }
            length = value
        }
        let start = end.upperBound
        guard data.count - (start - data.startIndex) >= length else { return .incomplete }
        let target = parts[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return .complete(HTTPRequest(method: String(parts[0]), path: String(target), fields: HeaderFields(pairs),
                                     body: Data(data[start..<start + length])))
    }

    /// The values of the cookies with this name, in the order the request names them.
    func cookies(_ name: String) -> [String] {
        (fields["Cookie"] ?? "").split(separator: ";").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == name else { return nil }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
    }

    /// The body as a JSON object of strings; nil for anything else.
    var json: [String: String]? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return object.compactMapValues { $0 as? String }
    }

    static func == (a: HTTPRequest, b: HTTPRequest) -> Bool {
        a.method == b.method && a.path == b.path && a.body == b.body
    }
}

extension HTTPRequest: Equatable {}

/// What the agent answers, before the common fields are added.
struct HTTPResponse {
    var status: String
    var type = "text/plain; charset=utf-8"
    var body = Data()
    /// Such as `Set-Cookie`.
    var fields: [String] = []

    static func json(_ status: String, _ object: [String: Any], fields: [String] = []) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, type: "application/json", body: body, fields: ["Cache-Control: no-store"] + fields)
    }
}
