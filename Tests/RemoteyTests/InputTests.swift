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
}
