import XCTest
@testable import Remotey

final class DisplaysTests: XCTestCase {
    private let laptop = Displays.Display(id: 1, name: "Built-in", x: 0, y: 0, w: 2056, h: 1329, pointer: true)
    private let desk = Displays.Display(id: 2, name: "Studio Display", x: -1939, y: 1329, w: 3008, h: 1692, pointer: false)

    func testAJumpGoesToTheMiddleOfADisplayAndBackToWhereThePointerLeft() {
        var displays = Displays()
        let left = CGPoint(x: 300, y: 1000)
        XCTAssertEqual(displays.jump(to: 2, from: left, among: [laptop, desk]), CGPoint(x: -435, y: 2175), "the middle of a display not left before")
        let there = CGPoint(x: -1000, y: 2900)
        XCTAssertEqual(displays.jump(to: 1, from: there, among: [laptop, desk]), left)
        XCTAssertEqual(displays.jump(to: 2, from: left, among: [laptop, desk]), there)
    }

    func testThePointerStaysOnItsDisplayAndOffAnUnknownOne() {
        var displays = Displays()
        XCTAssertNil(displays.jump(to: 1, from: CGPoint(x: 300, y: 1000), among: [laptop, desk]), "it is there already")
        XCTAssertNil(displays.jump(to: 7, from: CGPoint(x: 300, y: 1000), among: [laptop, desk]), "unplugged meanwhile")
    }

    func testAPlaceIsKeptAsAShareOfItsDisplay() {
        var displays = Displays()
        _ = displays.jump(to: 2, from: CGPoint(x: 514, y: 1329 - 1), among: [laptop, desk])
        // The laptop's display was moved and set to another mode since.
        let moved = Displays.Display(id: 1, name: "Built-in", x: 3008, y: 0, w: 1028, h: 665, pointer: false)
        let back = displays.jump(to: 1, from: CGPoint(x: -435, y: 2175), among: [moved, desk])
        XCTAssertEqual(back, CGPoint(x: 3008 + 257, y: 664), "a quarter across, and inside its lower edge")
    }

    /// What the picker draws: every display of this Mac, one of them with the pointer.
    func testTheListNamesEveryDisplayOfThisMac() {
        let list = Displays.list()
        XCTAssertEqual(list.count, NSScreen.screens.count)
        XCTAssertEqual(list.filter(\.pointer).count, 1)
        for display in list {
            XCTAssertFalse(display.name.isEmpty)
            XCTAssertEqual(display.bounds, CGDisplayBounds(display.id))
        }
    }
}
