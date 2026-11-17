import XCTest
@testable import Remotey

final class AppsTests: XCTestCase {
    /// As Command-Tab lists them, as far as the screen tells: the app in front, then the others by their
    /// frontmost window, then those that show none in the order they were started.
    func testTheAppInFrontComesFirstThenTheOthersByTheirWindowsOnScreen() {
        // Started as 1...5. 4 is in front; a window of 2 lies above those of 5; 9 is no app of the Dock.
        XCTAssertEqual(Apps.order([1, 2, 3, 4, 5], front: 4, stacked: [4, 2, 9, 5, 2]), [4, 2, 5, 1, 3])
        XCTAssertEqual(Apps.order([1, 2, 3], front: 3, stacked: [2]), [3, 2, 1], "in front without a window on screen")
        XCTAssertEqual(Apps.order([1, 2], front: nil, stacked: []), [1, 2])
        XCTAssertEqual(Apps.order([1, 2], front: 7, stacked: [7, 2]), [2, 1], "the app in front is not one of the Dock")
    }

    func testOnlyWindowsAUserWouldNameAreOffered() {
        XCTAssertTrue(Apps.isChoice(role: "AXWindow", subrole: "AXStandardWindow"))
        XCTAssertTrue(Apps.isChoice(role: "AXWindow", subrole: "AXDialog"))
        XCTAssertFalse(Apps.isChoice(role: "AXScrollArea", subrole: nil), "Finder's desktop")
        XCTAssertFalse(Apps.isChoice(role: "AXWindow", subrole: "AXFloatingWindow"), "a palette")
        XCTAssertFalse(Apps.isChoice(role: "AXWindow", subrole: nil))
        XCTAssertFalse(Apps.isChoice(role: nil, subrole: nil), "the app did not answer")
    }
}
