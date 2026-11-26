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

    func testHeaderFieldsByNameInAnyCase() {
        let request = Data("GET / HTTP/1.1\r\nhost: mac.tail1234.ts.net:8443\r\nOrigin:  https://x.ts.net \r\nHost: second\r\n\r\nHost: body".utf8)
        let fields = HeaderFields(request: request)
        XCTAssertEqual(fields["Host"], "mac.tail1234.ts.net:8443", "the first of two, and nothing of the body")
        XCTAssertEqual(fields["origin"], "https://x.ts.net")
        XCTAssertNil(fields["Cookie"])
        XCTAssertEqual(HeaderFields([(name: "ORIGIN", value: "null")])["Origin"], "null")
    }
}
