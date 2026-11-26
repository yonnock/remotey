import AppKit
import XCTest
@testable import Remotey

@MainActor
final class InterfaceLookTests: XCTestCase {
    override func tearDown() {
        Accent.userChoseColor = { UserDefaults.standard.object(forKey: "AppleAccentColor") != nil }
    }

    func testTheAccentIsOrangeUntilTheUserPicksAColour() {
        Accent.userChoseColor = { false }
        XCTAssertEqual(Accent.nsColor, .systemOrange)
        Accent.userChoseColor = { true }
        XCTAssertEqual(Accent.nsColor, .controlAccentColor)
        XCTAssertEqual(Accent.selection, .selectedContentBackgroundColor)
    }

    func testWhiteOnTheOrangeSelectionIsReadable() throws {
        Accent.userChoseColor = { false }
        let color = try XCTUnwrap(Accent.selection.usingColorSpace(.sRGB))
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
        XCTAssertGreaterThanOrEqual(1.05 / (luminance + 0.05), 3.0, "large-text contrast for white on the highlight")
    }

    func testTheCodeIsSquareWithItsFinderPatterns() {
        let modules = QRCode.modules("https://macbook.example-tailnet.ts.net:8443/#pair=bWFkZS11cC1jb2Rl")
        XCTAssertGreaterThan(modules.count, 21)
        XCTAssertTrue(modules.allSatisfy { $0.count == modules.count })
        // Rows run from the top: finder patterns stand top left, top right and bottom left, inside the quiet zone.
        let quiet = modules.firstIndex { $0.contains(true) }!
        let far = modules.count - quiet - 7
        func finder(_ top: Int, _ left: Int) -> Bool {
            (0..<7).allSatisfy { y in
                (0..<7).allSatisfy { x in
                    let ring = min(x, y, 6 - x, 6 - y)
                    return modules[top + y][left + x] == (ring != 1)
                }
            }
        }
        XCTAssertTrue(finder(quiet, quiet))
        XCTAssertTrue(finder(quiet, far))
        XCTAssertTrue(finder(far, quiet))
        XCTAssertFalse(finder(far, far))
        XCTAssertEqual(QRCode.modules("x").count, QRCode.modules("y").count, "same size for same-length texts")
    }
}
