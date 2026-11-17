import Carbon.HIToolbox
import XCTest
@testable import Remotey

/// A lock screen that exists only here: the session, the password field and the display are stand-ins, and
/// the keys are collected instead of posted. Nothing is typed on this Mac.
final class LockScreenTests: XCTestCase {
    private var events: [CGEvent] = []
    private var sessionLocked = true
    /// What the lock screen's field answers, one per question; the last one stays.
    private var answers: [Int?] = [0]
    /// Runs when the field is asked for the second time, and when Return is pressed.
    private var whileAwaitingTheField: (() -> Void)?
    private var onReturn: (() -> Void)?
    private var asked = 0
    private var wakes = 0
    private var changes: [Bool] = []

    private lazy var input = Input { [unowned self] event in
        events.append(event)
        if event.type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == kVK_Return { onReturn?() }
    }
    private lazy var lock: LockScreen = {
        let lock = LockScreen(session: { [unowned self] in sessionLocked }, field: { [unowned self] in
            asked += 1
            if asked == 2 { whileAwaitingTheField?() }
            return answers.count > 1 ? answers.removeFirst() : answers[0]
        }, wake: { [unowned self] in wakes += 1 }, patience: (field: 0.4, answer: 0.2))
        lock.changed = { [unowned self] in changes.append($0) }
        return lock
    }()

    private var pressed: [Int] {
        events.filter { $0.type == .keyDown }.map { Int($0.getIntegerValueField(.keyboardEventKeycode)) }
    }

    /// Unlocks and waits until it is over. Nil: the Mac did not stay locked, or nothing was tried.
    private func unlock(_ password: String, staysLocked: Bool) -> LockScreen.Failure? {
        var failure: LockScreen.Failure?
        let failed = expectation(description: "stayed locked")
        failed.isInverted = !staysLocked
        lock.unlock(with: password, typing: input) {
            failure = $0
            failed.fulfill()
        }
        wait(for: [failed], timeout: 1)
        return failure
    }

    func testThePasswordGoesInOnceTheFieldHasTheKeyboardAndReturnFollows() {
        answers = [nil, nil, 0]
        XCTAssertEqual(unlock("ab", staysLocked: true), .password, "this lock screen never opens")
        XCTAssertEqual(pressed.count, 3)
        XCTAssertEqual(pressed.last, kVK_Return)
        XCTAssertEqual(events.filter { $0.type == .keyUp }.count, 3)
        XCTAssertGreaterThanOrEqual(wakes, 3, "the display is woken for as long as the field is not there")
    }

    func testWhatAnEarlierTryLeftInTheFieldIsDeletedFirst() {
        answers = [2]
        _ = unlock("a", staysLocked: true)
        XCTAssertEqual(Array(pressed.prefix(2)), [kVK_Delete, kVK_Delete])
        XCTAssertEqual(pressed.count, 4)
    }

    func testNothingIsTypedWhileTheFieldLacksTheKeyboard() {
        answers = [nil]
        XCTAssertEqual(unlock("secret", staysLocked: true), .field)
        XCTAssertEqual(events.count, 0)
    }

    func testNothingIsTypedOnAnUnlockedMac() {
        sessionLocked = false
        XCTAssertNil(unlock("secret", staysLocked: false))
        XCTAssertEqual(events.count, 0)
        XCTAssertEqual(wakes, 0)
    }

    /// Touch ID or a watch can open the Mac while the field is awaited. The password must not reach an app.
    func testNothingIsTypedOnAMacThatUnlocksWhileTheFieldIsAwaited() {
        answers = [nil]
        whileAwaitingTheField = { [unowned self] in lock.note(false) }
        XCTAssertNil(unlock("secret", staysLocked: false))
        XCTAssertEqual(events.count, 0)
        XCTAssertEqual(changes, [false])
    }

    func testAMacThatOpensReportsNoFailure() {
        onReturn = { [unowned self] in lock.note(false) }
        XCTAssertNil(unlock("a", staysLocked: false))
        XCTAssertEqual(pressed.last, kVK_Return)
        XCTAssertEqual(changes, [false])
    }

    /// The notification of an unlock was lost, the session knows: no failure, and the page hears of it.
    func testTheSessionSettlesWhatNoNotificationSaid() {
        onReturn = { [unowned self] in sessionLocked = false }
        XCTAssertNil(unlock("a", staysLocked: false))
        XCTAssertEqual(changes, [false])
    }

    func testAnUnlockUnderWayIsNotJoinedByASecond() {
        lock.unlock(with: "a", typing: input) { _ in }
        XCTAssertEqual(unlock("b", staysLocked: true), .field, "told at once, so that the page can offer it again")
        XCTAssertEqual(pressed.count, 0, "nothing of the second, and the first still waits for the field")
    }

    /// The session still says "locked" for a moment after the notification of an unlock.
    func testARecentNotificationStandsAgainstTheSession() {
        XCTAssertTrue(lock.isLocked)
        lock.note(false)
        lock.refresh()
        XCTAssertFalse(lock.isLocked)
        XCTAssertEqual(changes, [false])
    }

    func testWithoutANotificationTheSessionCounts() {
        XCTAssertTrue(lock.isLocked)
        sessionLocked = false
        lock.refresh()
        XCTAssertFalse(lock.isLocked)
        lock.refresh()
        XCTAssertEqual(changes, [false], "told once")
    }
}
