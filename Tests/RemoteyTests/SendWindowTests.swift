import XCTest
@testable import Remotey

final class SendWindowTests: XCTestCase {
    /// How many pictures leave before the window closes, with nothing answered meanwhile.
    private func room(_ window: SendWindow, framesPerSecond: Int32) -> Int {
        var window = window, sent = 0
        while window.isOpen(framesPerSecond: framesPerSecond) {
            _ = window.send(now: 10)
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
        XCTAssertEqual(room(SendWindow(), framesPerSecond: 120), 2)
        XCTAssertEqual(room(window(answeredAfter: 0.004), framesPerSecond: 120), 2)
        XCTAssertEqual(room(window(answeredAfter: 0.004), framesPerSecond: 60), 2)
    }

    func testAPhoneWithSlowAnswersGetsMorePicturesUnderWayButNeverManyMore() {
        // 30 ms span three and a half frame intervals at 120 fps, not even two at 60 fps.
        XCTAssertEqual(room(window(answeredAfter: 0.030), framesPerSecond: 120), 5)
        XCTAssertEqual(room(window(answeredAfter: 0.030), framesPerSecond: 60), 3)
        XCTAssertEqual(room(window(answeredAfter: 0.5), framesPerSecond: 120), SendWindow.most)
        XCTAssertEqual(room(window(answeredAfter: 0.5), framesPerSecond: 30), SendWindow.most)
    }

    func testTheFastestAnswerCounts() {
        var window = window(answeredAfter: 0.5)
        let number = window.send(now: 2)
        XCTAssertTrue(window.answered(number, now: 2.004))
        XCTAssertEqual(room(window, framesPerSecond: 120), 2)
    }

    func testOnlyAnAnswerToAPictureUnderWayMakesRoom() {
        var window = SendWindow()
        let first = window.send(now: 1), second = window.send(now: 1)
        XCTAssertFalse(window.isOpen(framesPerSecond: 60))
        XCTAssertFalse(window.answered(second + 1000, now: 1.004), "a picture never sent")
        XCTAssertFalse(window.isOpen(framesPerSecond: 60))
        XCTAssertTrue(window.answered(second, now: 1.004))
        XCTAssertFalse(window.answered(second, now: 1.004), "a second answer")
        XCTAssertEqual(room(window, framesPerSecond: 60), 1)
        XCTAssertTrue(window.withdraw(first))
        XCTAssertFalse(window.withdraw(first))
        XCTAssertEqual(room(window, framesPerSecond: 60), 2)
    }

    func testANewViewerStartsWithAnEmptyWindowAndNewNumbers() {
        var window = window(answeredAfter: 0.5)
        let old = window.send(now: 2)
        window.reset()
        XCTAssertEqual(room(window, framesPerSecond: 120), 2)
        XCTAssertGreaterThan(window.send(now: 3), old)
        XCTAssertFalse(window.answered(old, now: 3), "the old viewer's late answer")
    }
}
