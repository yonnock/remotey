import XCTest
@testable import Remotey

/// The window server reports a posted move only after up to a display refresh.
final class PointerTests: XCTestCase {
    private let start = CGPoint(x: 100.5, y: 200)

    /// Posts `steps` moves the way `Input.move` does: each from the pointer's location at that moment.
    private func post(_ steps: [Double], on track: inout PointerTrack, reported: CGPoint, at time: TimeInterval) -> CGPoint {
        var target = reported
        for step in steps {
            let from = track.location(reported: reported, now: time)
            target = CGPoint(x: from.x + step, y: from.y)
            track.post(target, reported: reported, now: time)
        }
        return target
    }

    func testMovesPostedInABurstAddUpAlthoughTheWindowServerStillReportsTheOldPlace() {
        var track = PointerTrack()
        let target = post([4, 4, 4, -2], on: &track, reported: start, at: 1)
        XCTAssertEqual(target, CGPoint(x: 110.5, y: 200))
        XCTAssertEqual(track.location(reported: start, now: 1.004), target)
    }

    func testTheWindowServerCatchingUpStepByStepDoesNotCountAsAnotherMove() {
        var track = PointerTrack()
        let target = post([4, 4, 4], on: &track, reported: start, at: 1)
        // It reports the first two targets on its way; moves posted meanwhile continue from the last.
        XCTAssertEqual(track.location(reported: CGPoint(x: 104.5, y: 200), now: 1.004), target)
        let next = post([4], on: &track, reported: CGPoint(x: 108.5, y: 200), at: 1.008)
        XCTAssertEqual(next, CGPoint(x: 116.5, y: 200))
        XCTAssertEqual(track.location(reported: next, now: 1.016), next)
    }

    /// Seen on macOS 27: a burst of 50 moves ended up to 80 points short, because a report of the
    /// newest target was followed by one of a place several moves back.
    func testReportsOutOfOrderDoNotTakeMovesBack() {
        var track = PointerTrack()
        let target = post([4, 4, 4], on: &track, reported: start, at: 1)
        XCTAssertEqual(track.location(reported: target, now: 1.001), target)
        XCTAssertEqual(track.location(reported: CGPoint(x: 104.5, y: 200), now: 1.002), target)
        XCTAssertEqual(post([4], on: &track, reported: start, at: 1.003), CGPoint(x: 116.5, y: 200))
        // Once the moves are old, the report counts again wherever it is.
        XCTAssertEqual(track.location(reported: start, now: 1.003 + PointerTrack.patience), start)
    }

    /// Back and forth within one refresh: the place before the moves is also the last target.
    func testAMoveBackToTheStartIsNotMistakenForHavingCaughtUp() {
        var track = PointerTrack()
        XCTAssertEqual(post([24, -24], on: &track, reported: start, at: 1), start)
        // The window server is only now at the first target. The next move still starts from the second.
        XCTAssertEqual(post([8], on: &track, reported: CGPoint(x: 124.5, y: 200), at: 1.004), CGPoint(x: 108.5, y: 200))
    }

    func testTheMacsOwnMouseTakesOver() {
        var track = PointerTrack()
        _ = post([4, 4], on: &track, reported: start, at: 1)
        let mouse = CGPoint(x: 300, y: 50)
        XCTAssertEqual(track.location(reported: mouse, now: 1.004), mouse)
        XCTAssertEqual(post([4], on: &track, reported: mouse, at: 1.008), CGPoint(x: 304, y: 50))
    }

    func testAMoveTheWindowServerNeverReportsIsGivenUp() {
        var track = PointerTrack()
        let target = post([4], on: &track, reported: start, at: 1)
        XCTAssertEqual(track.location(reported: start, now: 1 + PointerTrack.patience / 2), target)
        XCTAssertEqual(track.location(reported: start, now: 1 + PointerTrack.patience), start)
    }
}
