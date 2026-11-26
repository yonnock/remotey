import XCTest
@testable import Remotey

/// The events are collected instead of posted, so nothing here clicks.
final class InputTests: XCTestCase {
    private var events: [CGEvent] = []
    private lazy var input = Input { [unowned self] in events.append($0) }
    private static let modifiers: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]

    private var posted: [String] {
        events.map { event in
            let names: [(CGEventFlags, String)] = [(.maskCommand, "cmd"), (.maskShift, "shift"), (.maskAlternate, "alt"), (.maskControl, "ctrl")]
            let mods = names.filter { event.flags.intersection(Self.modifiers).contains($0.0) }.map(\.1)
            return (["\(event.type.rawValue)"] + mods).joined(separator: " ")
        }
    }
    private func name(_ type: CGEventType, _ mods: String...) -> String { (["\(type.rawValue)"] + mods).joined(separator: " ") }

    func testAClickCarriesItsModifiersOnThePressAndTheRelease() {
        input.click(.left, mods: ["alt"])
        XCTAssertEqual(posted, [name(.leftMouseDown, "alt"), name(.leftMouseUp, "alt")])
    }

    func testTheNextClickIsPlainAgain() {
        input.click(.right, mods: ["cmd", "shift"])
        input.click(.right)
        XCTAssertEqual(posted, [name(.rightMouseDown, "cmd", "shift"), name(.rightMouseUp, "cmd", "shift"),
                                name(.rightMouseDown), name(.rightMouseUp)])
    }

    /// Browsers go back and forward on a mouse's fourth and fifth button. An armed modifier goes with them as with any click.
    func testTheSideButtonsClickAsButtonsFourAndFive() {
        input.click(.back)
        input.click(.forward, mods: ["cmd"])
        XCTAssertEqual(posted, [name(.otherMouseDown), name(.otherMouseUp), name(.otherMouseDown, "cmd"), name(.otherMouseUp, "cmd")])
        XCTAssertEqual(events.map { $0.getIntegerValueField(.mouseEventButtonNumber) }, [3, 3, 4, 4])
    }

    func testADragKeepsTheModifiersOfItsPressUntilTheRelease() {
        input.button(.left, down: true, mods: ["alt"])
        input.move(dx: 3, dy: 0)
        input.button(.left, down: false)
        input.move(dx: -3, dy: 0)
        XCTAssertEqual(posted, [name(.leftMouseDown, "alt"), name(.leftMouseDragged, "alt"), name(.leftMouseUp, "alt"),
                                name(.mouseMoved)])
    }

    func testAButtonLeftDownIsReleasedWithItsModifiers() {
        input.button(.left, down: true, mods: ["ctrl"])
        input.releaseAll()
        XCTAssertEqual(posted, [name(.leftMouseDown, "ctrl"), name(.leftMouseUp, "ctrl")])
    }

    /// A half of the main display: the one the pointer is in, or the other one.
    private func half(holdingThePointer holding: Bool) -> CGRect {
        let display = CGDisplayBounds(CGMainDisplayID())
        let left = CGRect(x: display.minX, y: display.minY, width: (display.width / 2).rounded(.down), height: display.height)
        return left.contains(Pointer.location) == holding ? left : left.offsetBy(dx: left.width, dy: 0)
    }

    /// A window brought to the front from the phone: the view is cut around the pointer, so the pointer goes there.
    func testThePointerGoesToTheMiddleOfAWindowItIsNotIn() {
        let window = half(holdingThePointer: false)
        XCTAssertTrue(input.move(into: window))
        XCTAssertEqual(events.map(\.type), [.mouseMoved])
        XCTAssertEqual(events.first?.location, CGPoint(x: window.midX.rounded(), y: window.midY.rounded()))
    }

    func testThePointerStaysInAWindowItIsInAndDuringADrag() {
        XCTAssertFalse(input.move(into: half(holdingThePointer: true)))
        XCTAssertEqual(events.count, 0)
        input.button(.left, down: true)
        XCTAssertFalse(input.move(into: half(holdingThePointer: false)), "the drag goes on where it is")
        XCTAssertFalse(input.move(into: CGRect(x: -90_000, y: -90_000, width: 100, height: 100)), "no display there")
        XCTAssertEqual(events.map(\.type), [.leftMouseDown])
    }

    /// A display chosen on the phone: the pointer goes to the place named, also inside the window it is in.
    func testThePointerGoesToAPlaceOnADisplayUnlessItHoldsAButton() {
        let display = CGDisplayBounds(CGMainDisplayID())
        let target = CGPoint(x: display.midX.rounded(), y: display.midY.rounded())
        XCTAssertTrue(input.move(to: target))
        XCTAssertEqual(events.map(\.type), [.mouseMoved])
        XCTAssertEqual(events.first?.location, target)
        XCTAssertFalse(input.move(to: CGPoint(x: -90_000, y: -90_000)), "no display there")
        input.button(.left, down: true)
        XCTAssertFalse(input.move(to: target), "the drag goes on where it is")
        XCTAssertEqual(events.map(\.type), [.mouseMoved, .leftMouseDown])
    }

    private var scrolls: [String] {
        events.filter { $0.type == .scrollWheel }.map { event in
            let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
            return "\(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)) \(phase)"
        }
    }

    /// The page sends fractions of a pixel; none is lost, and the gesture has a beginning and an end.
    func testAScrollIsOneGestureFromItsFirstWholePixelToItsEnd() {
        input.scroll(dx: 0, dy: 0.6)
        input.scroll(dx: 0, dy: 0.6)
        input.scroll(dx: 0, dy: 2.9)
        input.endScroll()
        XCTAssertEqual(scrolls, ["1 1", "3 2", "0 4"])
    }

    func testARestOfAPixelDoesNotCarryIntoTheNextScroll() {
        input.scroll(dx: 0, dy: 1.9)
        input.endScroll()
        input.scroll(dx: 0, dy: -1.2)
        input.endScroll()
        input.endScroll()
        XCTAssertEqual(scrolls, ["1 1", "0 4", "-1 1", "0 4"])
    }

    func testADisconnectEndsAScroll() {
        input.scroll(dx: 0, dy: 5)
        input.releaseAll()
        XCTAssertEqual(scrolls, ["5 1", "0 4"])
    }

    /// Fractional moves add up, so a sender of fractions reaches the Mac in full.
    func testFractionsOfAPointAddUp() {
        for _ in 0..<10 { input.move(dx: 0.25, dy: 0) }
        let steps = events.filter { $0.type == .mouseMoved }.map { $0.getIntegerValueField(.mouseEventDeltaX) }
        XCTAssertEqual(steps.reduce(0, +), 2)
    }

    /// The page sends whole points and draws the pointer where they take it, before the Mac answers.
    func testAMoveOfWholePointsIsMadeAsItIsWhateverRestAnEarlierSenderLeft() {
        input.move(dx: 0.7, dy: 0.7)
        input.move(dx: -3, dy: 2)
        input.move(dx: 3, dy: -2)
        let steps = events.filter { $0.type == .mouseMoved }
            .map { [$0.getIntegerValueField(.mouseEventDeltaX), $0.getIntegerValueField(.mouseEventDeltaY)] }
        XCTAssertEqual(steps, [[-3, 2], [3, -2]], "with the rest of 0.7 counted in, these were -2 and 2")
        input.move(dx: 0.3, dy: 0.3)
        XCTAssertEqual(events.filter { $0.type == .mouseMoved }.count, 3, "the rest is kept for the sender of fractions")
    }
}
