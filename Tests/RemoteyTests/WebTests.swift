import XCTest
@testable import Remotey

final class WebTests: XCTestCase {
    func testServesTheFilesOfThePageWithTheirTypes() throws {
        let page = try XCTUnwrap(Web.file("index.html"))
        XCTAssertEqual(page.type, "text/html; charset=utf-8")
        XCTAssertTrue(String(decoding: page.body, as: UTF8.self).contains("<title>Remotey</title>"))
        XCTAssertEqual(Web.file("live-view.js")?.type, "text/javascript; charset=utf-8")
        XCTAssertEqual(Web.file("remote.js")?.type, "text/javascript; charset=utf-8")
        XCTAssertEqual(Web.file("remote.css")?.type, "text/css; charset=utf-8")
        XCTAssertEqual(Web.file("icon.png")?.type, "image/png")
    }

    /// A new kind of file in Web/ needs its type in `Web`, or it is neither served nor part of the version.
    func testEveryFileInTheFolderIsServed() {
        XCTAssertGreaterThanOrEqual(Web.names.count, 3)
        for name in Web.names {
            XCTAssertNotNil(Web.file(name), name)
        }
    }

    func testServesNothingElse() {
        for name in ["", "missing.js", "../Package.swift", "../Web/index.html", "/etc/passwd", ".hidden.js", "index", "index.html/"] {
            XCTAssertNil(Web.file(name), name)
        }
    }
}
