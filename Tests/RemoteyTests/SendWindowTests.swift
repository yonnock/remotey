import XCTest
@testable import Remotey

final class SendWindowTests: XCTestCase {
    /// How many pictures leave at `now` before the window closes, with nothing answered meanwhile.
    private func room(_ window: SendWindow, now: TimeInterval = 10) -> Int {
        var window = window, sent = 0
        while window.isOpen(now: now) {
            _ = window.send(0, now: now)
            sent += 1
        }
        return sent
    }

    /// A window whose only picture so far was answered after `answer` seconds.
    private func window(answeredAfter answer: TimeInterval) -> SendWindow {
        var window = SendWindow()
        let number = window.send(0, now: 1)
        XCTAssertNotNil(window.answered(number, now: 1 + answer))
        return window
    }

    func testTwoPicturesMayBeUnderWayUntilThePhoneAnswers() {
        var window = SendWindow()
        XCTAssertEqual(room(window), 2)
        _ = window.send(0, now: 1)
        _ = window.send(0, now: 1)
        XCTAssertFalse(window.isOpen(now: 1.001), "no answer yet, however young the pictures")
    }

    func testPicturesLeaveWhileTheOldestIsYoungerThanTheFastestAnswerAllowsFor() {
        var window = window(answeredAfter: 0.030)
        _ = window.send(0, now: 10)
        _ = window.send(0, now: 10.05)
        let limit = 10 + 0.030 + SendWindow.slack
        XCTAssertTrue(window.isOpen(now: limit - 0.001), "a Wi-Fi hold of a few frames does not stop the stream")
        XCTAssertFalse(window.isOpen(now: limit + 0.001), "a link that holds longer lowers the frame rate instead of the delay rising")
    }

    func testTwoMayAlwaysBeUnderWay() {
        var window = window(answeredAfter: 0.030)
        _ = window.send(0, now: 10)
        XCTAssertTrue(window.isOpen(now: 20))
    }

    func testTheFastestAnswerCounts() {
        var window = window(answeredAfter: 0.5)
        let number = window.send(0, now: 2)
        XCTAssertNotNil(window.answered(number, now: 2.004))
        _ = window.send(0, now: 10)
        _ = window.send(0, now: 10)
        XCTAssertFalse(window.isOpen(now: 10 + 0.004 + SendWindow.slack + 0.001))
    }

    func testNeverMoreThanMostUnderWay() {
        XCTAssertEqual(room(window(answeredAfter: 0.030)), SendWindow.most)
    }

    func testOnlyAnAnswerToAPictureUnderWayMakesRoom() {
        var window = SendWindow()
        let first = window.send(0, now: 1), second = window.send(0, now: 1)
        XCTAssertFalse(window.isOpen(now: 1))
        XCTAssertNil(window.answered(second + 1000, now: 1.004), "a picture never sent")
        XCTAssertFalse(window.isOpen(now: 1.004))
        XCTAssertNotNil(window.answered(second, now: 1.004))
        XCTAssertNil(window.answered(second, now: 1.004), "a second answer")
        _ = window.send(0, now: 1.004)
        // The first picture is now older than the fastest answer allows: nothing more leaves until it is answered.
        XCTAssertFalse(window.isOpen(now: 1.3))
        XCTAssertTrue(window.withdraw(first))
        XCTAssertFalse(window.withdraw(first))
        XCTAssertTrue(window.isOpen(now: 1.3))
    }

    func testANewViewerStartsWithAnEmptyWindowAndNewNumbers() {
        var window = window(answeredAfter: 0.030)
        let old = window.send(0, now: 2)
        window.reset()
        XCTAssertEqual(room(window), 2)
        XCTAssertGreaterThan(window.send(0, now: 3), old)
        XCTAssertNil(window.answered(old, now: 3), "the old viewer's late answer")
    }

    func testAfterASlowFirstAnswerTheLinkRunsEmptyAndTheNextAnswerCounts() {
        // The key frame took two seconds on a slow link. Measured by that, seconds of pictures could queue.
        var window = SendWindow()
        let key = window.send(250_000, now: 1), second = window.send(4000, now: 1.016)
        XCTAssertNotNil(window.answered(key, now: 3))
        XCTAssertFalse(window.isOpen(now: 3), "one picture is under way: the link is not empty yet")
        XCTAssertNotNil(window.answered(second, now: 3.03))
        XCTAssertEqual(room(window, now: 3.03), 2, "empty: two may leave, as before the first answer")
        let third = window.send(4000, now: 3.03), fourth = window.send(4000, now: 3.046)
        XCTAssertNotNil(window.answered(third, now: 3.08))
        _ = fourth
        _ = window.send(4000, now: 3.1)
        XCTAssertTrue(window.isOpen(now: 3.046 + 0.05 + SendWindow.slack - 0.001))
        XCTAssertFalse(window.isOpen(now: 3.046 + 0.05 + SendWindow.slack + 0.001), "the answer on the empty link is the measure: 50 ms")
    }

    func testTheLinkRunsEmptyOnlyOnce() {
        // A phone far away answers every picture after half a second. That is its fastest answer then.
        var window = SendWindow()
        let first = window.send(250_000, now: 1)
        XCTAssertNotNil(window.answered(first, now: 1.5))
        let second = window.send(4000, now: 1.5)
        XCTAssertNotNil(window.answered(second, now: 2))
        _ = window.send(4000, now: 2)
        _ = window.send(4000, now: 2.1)
        XCTAssertTrue(window.isOpen(now: 2.3), "more than two under way: the window is a time again")
        XCTAssertFalse(window.isOpen(now: 2 + 0.5 + SendWindow.slack + 0.001))
    }

    func testAPromptFirstAnswerNeedsNoEmptyLink() {
        var window = SendWindow()
        let first = window.send(250_000, now: 1)
        _ = window.send(4000, now: 1.016)
        XCTAssertNotNil(window.answered(first, now: 1.05))
        XCTAssertTrue(window.isOpen(now: 1.06))
    }
}
