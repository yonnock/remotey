import XCTest
@testable import Remotey

final class HTTPRequestTests: XCTestCase {
    private func parse(_ text: String) -> HTTPRequest.Parse { HTTPRequest.parse(Data(text.utf8)) }

    func testARequestWithItsBody() throws {
        let head = "POST /pair?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 14\r\nCookie: a=1; remotey-device=k1;b=2\r\n\r\n"
        XCTAssertEqual(parse(head), .incomplete, "the body is still on its way")
        XCTAssertEqual(parse(head + #"{"code":"#), .incomplete)
        guard case .complete(let request) = parse(head + #"{"code":"123"}"#) else { return XCTFail() }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/pair")
        XCTAssertEqual(request.json, ["code": "123"])
        XCTAssertEqual(request.cookies("remotey-device"), ["k1"])
        XCTAssertEqual(request.fields["host"], "127.0.0.1")
        guard case .complete(let get) = parse("GET / HTTP/1.1\r\nHost: x\r\n\r\n") else { return XCTFail() }
        XCTAssertTrue(get.body.isEmpty)
    }

    func testAnythingLargerOrStrangerIsRefused() {
        XCTAssertEqual(parse("GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: HTTPRequest.maxHead)), .refused("431 Request Header Fields Too Large"))
        XCTAssertEqual(parse("GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: HTTPRequest.maxHead) + "\r\n\r\n"),
                       .refused("431 Request Header Fields Too Large"))
        XCTAssertEqual(parse("POST /pair HTTP/1.1\r\nContent-Length: 4097\r\n\r\n"), .refused("413 Content Too Large"))
        XCTAssertEqual(parse("POST /pair HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"), .refused("411 Length Required"))
        XCTAssertEqual(parse("POST /pair HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\n{}"), .refused("400 Bad Request"))
        XCTAssertEqual(parse("POST /pair HTTP/1.1\r\nContent-Length: -1\r\n\r\n"), .refused("400 Bad Request"))
        XCTAssertEqual(parse("POST /pair HTTP/1.1\r\nContent-Length: +2\r\n\r\n{}"), .refused("400 Bad Request"))
        XCTAssertEqual(parse("GARBAGE\r\n\r\n"), .refused("400 Bad Request"))
        XCTAssertEqual(parse("GET / HTTP/1.1\r\nno colon\r\n\r\n"), .refused("400 Bad Request"))
    }

    func testABodyThatIsNoObjectOfStringsHasNoFields() throws {
        guard case .complete(let request) = parse("POST /pair HTTP/1.1\r\nContent-Length: 2\r\n\r\n[]") else { return XCTFail() }
        XCTAssertNil(request.json)
    }
}

final class TailnetIdentityTests: XCTestCase {
    private func fields(_ pairs: [(String, String)]) -> HeaderFields { HeaderFields(pairs.map { (name: $0.0, value: $0.1) }) }

    func testAnotherPersonThroughServeIsRefused() {
        let owner = "owner@example.com"
        XCTAssertFalse(TailnetIdentity.allows(fields([("Tailscale-User-Login", "guest@example.com")]), owner: owner))
        XCTAssertTrue(TailnetIdentity.allows(fields([("Tailscale-User-Login", "Owner@Example.com")]), owner: owner))
    }

    /// Where a fact is not known, the owner's own phone gets in.
    func testWhatCannotBeKnownLetsIn() {
        XCTAssertTrue(TailnetIdentity.allows(fields([]), owner: "owner@example.com"), "local, or a tagged device")
        XCTAssertTrue(TailnetIdentity.allows(fields([("Tailscale-User-Login", "guest@example.com")]), owner: nil), "owner not known yet")
        XCTAssertTrue(TailnetIdentity.allows(fields([("Tailscale-User-Login", "guest@example.com")]), owner: TailnetIdentity.tagged),
                      "a tagged Mac has no person as its owner")
        XCTAssertTrue(TailnetIdentity.allows(fields([("Tailscale-User-Login", "=?utf-8?q?broken")]), owner: "owner@example.com"),
                      "a login that cannot be read")
    }

    func testFunnelIsRefused() {
        XCTAssertFalse(TailnetIdentity.allows(fields([("Tailscale-Funnel-Request", "?1")]), owner: nil))
    }

    /// As Go's `mime.QEncoding.Encode` writes a name that is not ASCII.
    func testQEncodedNamesAreRead() {
        XCTAssertEqual(TailnetIdentity.decode("plain@example.com"), "plain@example.com")
        XCTAssertEqual(TailnetIdentity.decode("=?utf-8?q?J=C3=BCrgen_M=C3=BCller?="), "Jürgen Müller")
        XCTAssertEqual(TailnetIdentity.decode("=?utf-8?q?J=C3=BCrgen?= =?utf-8?q?_M=C3=BCller?="), "Jürgen Müller", "two words")
        XCTAssertNil(TailnetIdentity.decode("=?utf-8?q?bad=Z?="))
        XCTAssertEqual(TailnetIdentity.name(fields([("Tailscale-User-Name", "=?utf-8?q?J=C3=BCrgen?=")])), "Jürgen")
    }
}
