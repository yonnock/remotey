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
}
