import XCTest
@testable import Remotey

final class OriginsTests: XCTestCase {
    func testThePagesOwnPlacesAndNoOthers() {
        for host in ["127.0.0.1:47800", "localhost:47821", "LOCALHOST", "[::1]:47800", "mac.tail1234.ts.net:8443",
                     "Mac.Tail1234.TS.NET.:8443", "mac.tail1234.ts.net"] {
            XCTAssertTrue(Origins.allows(host: host), host)
        }
        for host in ["evil.example.com", "127.0.0.1.evil.example.com", "ts.net.evil.example", "evilts.net", "192.168.1.5:47800", ""] {
            XCTAssertFalse(Origins.allows(host: host), host)
        }
        XCTAssertTrue(Origins.allows(host: nil), "only programs send none")
    }

    func testOrigins() {
        for origin in ["https://mac.tail1234.ts.net:8443", "http://127.0.0.1:47820", "http://localhost:47820", "http://[::1]:47800"] {
            XCTAssertTrue(Origins.allows(origin: origin), origin)
        }
        for origin in ["https://evil.example.com", "null", "file://", "chrome-extension://abc", "https://mac.tail1234.ts.net.evil.com"] {
            XCTAssertFalse(Origins.allows(origin: origin), origin)
        }
        XCTAssertTrue(Origins.allows(origin: nil))
    }

    /// Anyone can publish a page under a `ts.net` name through Funnel. Opened in the Mac's browser it reaches
    /// the loopback ports, but it is not the page of the host it asks.
    func testAPageAsksTheHostItWasLoadedFrom() {
        func fields(_ host: String?, _ origin: String?) -> HeaderFields {
            HeaderFields([("Host", host), ("Origin", origin)].compactMap { name, value in value.map { (name: name, value: $0) } })
        }
        XCTAssertTrue(Origins.allows(fields("mac.tail1234.ts.net:8443", "https://mac.tail1234.ts.net:8443")), "behind serve")
        XCTAssertTrue(Origins.allows(fields("Mac.Tail1234.ts.net.:8443", "https://mac.tail1234.ts.net:8443")))
        XCTAssertTrue(Origins.allows(fields("127.0.0.1:47821", "http://127.0.0.1:47820")), "in development the socket is on the port after the page's")
        XCTAssertTrue(Origins.allows(fields("localhost:47821", "http://localhost:47820")))
        XCTAssertFalse(Origins.allows(fields("127.0.0.1:47801", "https://evil.tail9999.ts.net")), "a page published by somebody else")
        XCTAssertFalse(Origins.allows(fields("mac.tail1234.ts.net:8443", "https://evil.tail9999.ts.net")))
        XCTAssertFalse(Origins.allows(fields("127.0.0.1:47801", "http://localhost:47800")), "two names are two hosts")
        XCTAssertTrue(Origins.allows(fields("127.0.0.1:47801", nil)), "a program")
        XCTAssertTrue(Origins.allows(fields(nil, "http://127.0.0.1:47800")))
        // The pairing routes: the same, and `null` for a page whose referrer policy hides its origin.
        XCTAssertTrue(Origins.allowsPost(fields("mac.tail1234.ts.net:8443", "https://mac.tail1234.ts.net:8443")))
        XCTAssertTrue(Origins.allowsPost(fields("mac.tail1234.ts.net:8443", "null")))
        XCTAssertTrue(Origins.allowsPost(fields("127.0.0.1:47800", nil)))
        XCTAssertFalse(Origins.allowsPost(fields("127.0.0.1:47800", "https://evil.tail9999.ts.net")))
        XCTAssertFalse(Origins.allowsPost(fields("127.0.0.1:47800", "https://evil.example.com")))
    }

    func testHeaderFieldsByNameInAnyCase() {
        let request = Data("GET / HTTP/1.1\r\nhost: mac.tail1234.ts.net:8443\r\nOrigin:  https://x.ts.net \r\nHost: second\r\n\r\nHost: body".utf8)
        let fields = HeaderFields(request: request)
        XCTAssertEqual(fields["Host"], "mac.tail1234.ts.net:8443", "the first of two, and nothing of the body")
        XCTAssertEqual(fields["origin"], "https://x.ts.net")
        XCTAssertNil(fields["Cookie"])
        XCTAssertEqual(HeaderFields([(name: "ORIGIN", value: "null")])["Origin"], "null")
    }
}
