import XCTest
@testable import Remotey

final class SendWindowTests: XCTestCase {
    /// How many pictures leave at `now` before the window closes, with nothing answered meanwhile.
    private func room(_ window: SendWindow, now: TimeInterval = 10) -> Int {
        var window = window, sent = 0
        while window.isOpen(now: now) {
            _ = window.send(now: now)
            sent += 1
        }
        return sent
    }

    /// A window whose only picture so far was answered after `answer` seconds.
    private func window(answeredAfter answer: TimeInterval) -> SendWindow {
        var window = SendWindow()
        let number = window.send(now: 1)
        XCTAssertTrue(window.answered(number, now: 1 + answer))
        return window
    }

    func testTwoPicturesMayBeUnderWayUntilThePhoneAnswers() {
        var window = SendWindow()
        XCTAssertEqual(room(window), 2)
        _ = window.send(now: 1)
        _ = window.send(now: 1)
        XCTAssertFalse(window.isOpen(now: 1.001), "no answer yet, however young the pictures")
    }

    func testPicturesLeaveWhileTheOldestIsYoungerThanTheFastestAnswerAllowsFor() {
        var window = window(answeredAfter: 0.030)
        _ = window.send(now: 10)
        _ = window.send(now: 10.05)
        let limit = 10 + 0.030 + SendWindow.slack
        XCTAssertTrue(window.isOpen(now: limit - 0.001), "a Wi-Fi hold of a few frames does not stop the stream")
        XCTAssertFalse(window.isOpen(now: limit + 0.001), "a link that holds longer lowers the frame rate instead of the delay rising")
    }

    func testTwoMayAlwaysBeUnderWay() {
        var window = window(answeredAfter: 0.030)
        _ = window.send(now: 10)
        XCTAssertTrue(window.isOpen(now: 20))
    }

    func testTheFastestAnswerCounts() {
        var window = window(answeredAfter: 0.5)
        let number = window.send(now: 2)
        XCTAssertTrue(window.answered(number, now: 2.004))
        _ = window.send(now: 10)
        _ = window.send(now: 10)
        XCTAssertFalse(window.isOpen(now: 10 + 0.004 + SendWindow.slack + 0.001))
    }

    func testNeverMoreThanMostUnderWay() {
        XCTAssertEqual(room(window(answeredAfter: 0.030)), SendWindow.most)
    }

    func testOnlyAnAnswerToAPictureUnderWayMakesRoom() {
        var window = SendWindow()
        let first = window.send(now: 1), second = window.send(now: 1)
        XCTAssertFalse(window.isOpen(now: 1))
        XCTAssertFalse(window.answered(second + 1000, now: 1.004), "a picture never sent")
        XCTAssertFalse(window.isOpen(now: 1.004))
        XCTAssertTrue(window.answered(second, now: 1.004))
        XCTAssertFalse(window.answered(second, now: 1.004), "a second answer")
        _ = window.send(now: 1.004)
        // The first picture is now older than the fastest answer allows: nothing more leaves until it is answered.
        XCTAssertFalse(window.isOpen(now: 1.3))
        XCTAssertTrue(window.withdraw(first))
        XCTAssertFalse(window.withdraw(first))
        XCTAssertTrue(window.isOpen(now: 1.3))
    }

    func testANewViewerStartsWithAnEmptyWindowAndNewNumbers() {
        var window = window(answeredAfter: 0.030)
        let old = window.send(now: 2)
        window.reset()
        XCTAssertEqual(room(window), 2)
        XCTAssertGreaterThan(window.send(now: 3), old)
        XCTAssertFalse(window.answered(old, now: 3), "the old viewer's late answer")
    }
}
