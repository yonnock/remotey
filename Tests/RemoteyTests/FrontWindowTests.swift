import XCTest
@testable import Remotey

final class FrontWindowTests: XCTestCase {
    private let frame = CGRect(x: 100, y: 80, width: 900, height: 600)

    func testAnotherWindowIsToldAtOnce() {
        var track = FrontWindow.Track<Int>()
        XCTAssertEqual(track.see(nil, frame: nil), .keep, "no window, as before the first look")
        XCTAssertEqual(track.see(1, frame: frame), .tell(frame))
        XCTAssertEqual(track.see(1, frame: frame), .keep)
        let other = CGRect(x: 0, y: 25, width: 1512, height: 957)
        XCTAssertEqual(track.see(2, frame: other), .tell(other))
        // The app closed its last window, or shows only its desktop.
        XCTAssertEqual(track.see(nil, frame: nil), .tell(nil))
        XCTAssertEqual(track.see(2, frame: other), .tell(other))
        // Another window at the very same place needs no word.
        XCTAssertEqual(track.see(3, frame: other), .keep)
    }

    func testAWindowOnItsWayIsToldOnceItHoldsStill() {
        var track = FrontWindow.Track<Int>()
        _ = track.see(1, frame: frame)
        // Dragged: every report differs from the one before.
        for step in 1...5 {
            XCTAssertEqual(track.see(1, frame: frame.offsetBy(dx: Double(step) * 10, dy: 0)), .wait)
        }
        // A look after the wait that finds it somewhere else again waits once more.
        XCTAssertEqual(track.see(1, frame: frame.offsetBy(dx: 60, dy: 0), settled: true), .wait)
        XCTAssertEqual(track.see(1, frame: frame.offsetBy(dx: 60, dy: 0), settled: true), .tell(frame.offsetBy(dx: 60, dy: 0)))
        XCTAssertEqual(track.see(1, frame: frame.offsetBy(dx: 60, dy: 0), settled: true), .keep)
    }

    func testAWindowPutBackWhereItWasNeedsNoWord() {
        var track = FrontWindow.Track<Int>()
        _ = track.see(1, frame: frame)
        XCTAssertEqual(track.see(1, frame: frame.insetBy(dx: 20, dy: 20)), .wait)
        XCTAssertEqual(track.see(1, frame: frame, settled: true), .keep)
    }

    // MARK: The phone's shape

    func testAWindowPutInPlaceFromHereIsToldAtOnce() {
        var track = FrontWindow.Track<Int>()
        _ = track.see(1, frame: frame)
        let shaped = CGRect(x: 100, y: 80, width: 740, height: 1120)
        XCTAssertEqual(track.put(1, at: shaped), .tell(shaped), "no wait for a window to hold still that was just placed")
        XCTAssertEqual(track.see(1, frame: shaped), .keep, "the app's own word of the new frame adds nothing")
        XCTAssertEqual(track.put(1, at: shaped), .keep)
        // The app took its time with the resize after all: then it is a window on its way.
        XCTAssertEqual(track.see(1, frame: shaped.insetBy(dx: 5, dy: 5)), .wait)
    }

    func testAWindowTakesThePhonesShapeAtTheSizeAskedForWhereItIs() {
        // The part of a laptop's display under the menu bar, and a pad of 370 x 560 at 0.5.
        let visible = CGRect(x: 0, y: 33, width: 2056, height: 1296), size = CGSize(width: 740, height: 1120)
        XCTAssertEqual(FrontWindow.shaped(CGRect(x: 100, y: 80, width: 1600, height: 900), to: size, inside: visible),
                       CGRect(x: 100, y: 80, width: 740, height: 1120))
        // Too low and too far right to hold the new size there: moved up and left, just as far as it takes.
        XCTAssertEqual(FrontWindow.shaped(CGRect(x: 1500, y: 700, width: 500, height: 400), to: size, inside: visible),
                       CGRect(x: 2056 - 740, y: 33 + 1296 - 1120, width: 740, height: 1120))
        // A window partly under the menu bar or off the left edge comes onto the display.
        XCTAssertEqual(FrontWindow.shaped(CGRect(x: -200, y: 0, width: 900, height: 600), to: size, inside: visible).origin,
                       CGPoint(x: 0, y: 33))
    }

    func testAShapeLargerThanTheDisplayKeepsItsAspect() {
        let visible = CGRect(x: -1939, y: -1667, width: 3008, height: 1667)
        // Upright at 0.3: 1233 x 1867 points, taller than the display has room for.
        let tall = FrontWindow.shaped(CGRect(x: -1900, y: -1600, width: 800, height: 600), to: CGSize(width: 1233, height: 1867), inside: visible)
        XCTAssertEqual(tall.height, 1667)
        XCTAssertEqual(tall.width / tall.height, 1233.0 / 1867, accuracy: 0.001)
        XCTAssertEqual(tall.minY, -1667)
        XCTAssertEqual(tall.minX, -1900)
        // Sideways at 0.2: wider than the display.
        let wide = FrontWindow.shaped(CGRect(x: -1900, y: -1600, width: 800, height: 600), to: CGSize(width: 3500, height: 1650), inside: visible)
        XCTAssertEqual(wide.width, 3008)
        XCTAssertEqual(wide.minX, -1939)
        XCTAssertEqual(wide.width / wide.height, 3500.0 / 1650, accuracy: 0.001)
    }
}
