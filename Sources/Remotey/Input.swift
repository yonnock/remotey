import AppKit
import Carbon.HIToolbox

/// The side buttons of a mouse, which browsers take as back and forward. CoreGraphics names only the first three.
extension CGMouseButton {
    static let back = CGMouseButton(rawValue: 3)!
    static let forward = CGMouseButton(rawValue: 4)!
}

/// Injects mouse, keyboard and media events. Needs the Accessibility permission. Main thread only.
final class Input {
    private let source = CGEventSource(stateID: .hidSystemState)
    private let post: (CGEvent) -> Void
    /// The buttons that are down, each with the modifiers of its press.
    private var held: [UInt32: CGEventFlags] = [:]
    private var lastClick: (time: TimeInterval, point: CGPoint, button: CGMouseButton, count: Int64)?
    private var moveRemainder = CGPoint.zero
    private var scrollRemainder = CGPoint.zero
    /// A two-finger scroll is under way: its first event said `began`, the last one will say `ended`.
    private var scrolling = false

    private static let namedKeys: [String: Int] = [
        "return": kVK_Return, "tab": kVK_Tab, "space": kVK_Space, "backspace": kVK_Delete, "escape": kVK_Escape,
        "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
    ]

    // NX_KEYTYPE_* values from IOKit/hidsystem/ev_keymap.h
    private static let mediaKeys: [String: Int] = [
        "volup": 0, "voldown": 1, "mute": 7, "play": 16, "next": 17, "prev": 18,
    ]

    /// `post` hands an event to the system; the tests collect the events instead.
    init(post: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) {
        self.post = post
    }

    // MARK: Mouse

    /// The page sends whole points and keeps the rest itself: it draws the pointer ahead of the answer, so
    /// it has to know where a move ends. Such a move is made as it is, whatever rest an earlier sender left.
    /// For one that sends fractions, as the scripts do, the rest is carried over here.
    func move(dx: Double, dy: Double) {
        var step = CGPoint(x: dx, y: dy)
        if dx != dx.rounded() || dy != dy.rounded() {
            moveRemainder.x += dx
            moveRemainder.y += dy
            step = CGPoint(x: moveRemainder.x.rounded(.towardZero), y: moveRemainder.y.rounded(.towardZero))
            moveRemainder.x -= step.x
            moveRemainder.y -= step.y
        }
        guard step != .zero else { return }

        let from = Pointer.location
        let to = clamp(CGPoint(x: from.x + step.x, y: from.y + step.y), from: from)
        let left = held[CGMouseButton.left.rawValue] != nil
        let right = held[CGMouseButton.right.rawValue] != nil
        let type: CGEventType = left ? .leftMouseDragged : right ? .rightMouseDragged : .mouseMoved
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: to,
                              mouseButton: right && !left ? .right : .left) else { return }
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64(step.x))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64(step.y))
        e.flags = held.values.reduce([]) { $0.union($1) } // a drag keeps the modifiers of its press
        Pointer.post(e, movingTo: to, with: post)
    }

    /// Puts the pointer in the middle of `frame`, unless it is inside already or holds a button: a window that
    /// came to the front from the phone, where the live view is cut around the pointer. False if the pointer stays.
    func move(into frame: CGRect) -> Bool {
        !frame.contains(Pointer.location) && move(to: CGPoint(x: frame.midX.rounded(), y: frame.midY.rounded()))
    }

    /// Puts the pointer at `target`: on another display, for one. False if it stays: it holds a button (the
    /// drag goes on where it is), or no display is there.
    func move(to target: CGPoint) -> Bool {
        guard held.isEmpty, display(at: target) != nil,
              let e = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: target,
                              mouseButton: .left) else { return false }
        moveRemainder = .zero
        Pointer.post(e, movingTo: target, with: post)
        return true
    }

    private func display(at point: CGPoint) -> CGDirectDisplayID? {
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        return CGGetDisplaysWithPoint(point, 1, &id, &count) == .success && count > 0 ? id : nil
    }

    /// Keeps the cursor on a display: a target off every screen is clamped to the current one.
    private func clamp(_ target: CGPoint, from: CGPoint) -> CGPoint {
        guard display(at: target) == nil else { return target }
        let bounds = CGDisplayBounds(display(at: from) ?? CGMainDisplayID())
        return CGPoint(x: min(max(target.x, bounds.minX), bounds.maxX - 1),
                       y: min(max(target.y, bounds.minY), bounds.maxY - 1))
    }

    /// `mods` count for a press. The release and the moves in between carry the same ones, as with a real
    /// keyboard, where the modifier stays down for the whole click or drag.
    func button(_ button: CGMouseButton, down: Bool, mods: [String] = []) {
        guard (held[button.rawValue] != nil) != down else { return }
        let point = Pointer.location
        let flags = down ? Self.flags(mods) : held[button.rawValue] ?? []
        if down {
            let now = ProcessInfo.processInfo.systemUptime
            var count: Int64 = 1
            if let last = lastClick, last.button == button, now - last.time < NSEvent.doubleClickInterval,
               hypot(last.point.x - point.x, last.point.y - point.y) < 5 {
                count = last.count + 1
            }
            lastClick = (now, point, button, count)
            held[button.rawValue] = flags
        } else {
            held[button.rawValue] = nil
        }
        let type: CGEventType = switch button {
        case .left: down ? .leftMouseDown : .leftMouseUp
        case .right: down ? .rightMouseDown : .rightMouseUp
        default: down ? .otherMouseDown : .otherMouseUp // the event names its button by number
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                              mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: lastClick?.count ?? 1)
        e.flags = flags
        post(e)
    }

    func click(_ b: CGMouseButton, mods: [String] = []) {
        button(b, down: true, mods: mods)
        button(b, down: false)
    }

    /// Called when a client disconnects so a drag or a scroll never stays stuck.
    func releaseAll() {
        for raw in held.keys { if let b = CGMouseButton(rawValue: raw) { button(b, down: false) } }
        endScroll()
    }

    /// Part of a two-finger scroll, in pixels. Like a trackpad's, the events carry a phase, so apps
    /// see one gesture: they lock it to an axis and know when it ends.
    func scroll(dx: Double, dy: Double) {
        scrollRemainder.x += dx
        scrollRemainder.y += dy
        let step = CGPoint(x: scrollRemainder.x.rounded(.towardZero), y: scrollRemainder.y.rounded(.towardZero))
        guard step != .zero else { return }
        scrollRemainder.x -= step.x
        scrollRemainder.y -= step.y
        postScroll(step, phase: scrolling ? .changed : .began)
        scrolling = true
    }

    /// The fingers left the glass or the gesture was cancelled. Nothing scrolls after this.
    func endScroll() {
        scrollRemainder = .zero
        guard scrolling else { return }
        scrolling = false
        postScroll(.zero, phase: .ended)
    }

    private func postScroll(_ step: CGPoint, phase: CGScrollPhase) {
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: Int32(step.y), wheel2: Int32(step.x), wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        post(e)
    }

    // MARK: Keyboard

    private static func flags(_ mods: [String]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for mod in mods {
            switch mod {
            case "cmd": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt": flags.insert(.maskAlternate)
            case "ctrl": flags.insert(.maskControl)
            default: break
            }
        }
        return flags
    }

    /// `key` is a name from `namedKeys` or a single character (for shortcuts like cmd+c).
    func key(_ key: String, mods: [String], count: Int) {
        let flags = Self.flags(mods)
        let keymap = Self.keymap()
        for _ in 0..<max(1, min(count, 100)) {
            if let code = Self.namedKeys[key] {
                press(CGKeyCode(code), flags: flags)
            } else if key.count == 1, let ch = key.first {
                typeCharacter(ch, flags: flags, keymap: keymap)
            }
        }
    }

    func type(_ text: String) {
        let keymap = Self.keymap()
        for ch in text {
            if ch == "\n" || ch == "\r\n" {
                press(CGKeyCode(kVK_Return), flags: [])
            } else {
                typeCharacter(ch, flags: [], keymap: keymap)
            }
        }
    }

    /// Prefers the real key of the active layout so apps that read key codes (shortcuts, players) work;
    /// everything else (umlauts on a US layout, emoji) goes in as a Unicode string.
    private func typeCharacter(_ ch: Character, flags: CGEventFlags, keymap: [Character: CGKeyCode]) {
        if let code = keymap[ch] {
            press(code, flags: flags)
        } else if ch.isUppercase, let code = keymap[Character(ch.lowercased())] {
            press(code, flags: flags.union(.maskShift))
        } else {
            let utf16 = Array(String(ch).utf16)
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                e.flags = flags
                e.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                post(e)
            }
        }
    }

    private func press(_ code: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            e.flags = flags
            post(e)
        }
    }

    /// Character -> key code for the unshifted main block of the active keyboard layout.
    /// Rebuilt per message so layout switches need no invalidation.
    private static func keymap() -> [Character: CGKeyCode] {
        guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var map: [Character: CGKeyCode] = [:]
        data.withUnsafeBytes { buffer in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
            for code in UInt16(0)...UInt16(50) {
                var deadKeyState: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                            0, &deadKeyState, chars.count, &length, &chars)
                // Dead keys (deadKeyState != 0) are skipped: pressing them would start a composition.
                guard status == noErr, deadKeyState == 0, length == 1, chars[0] > 0x20, chars[0] != 0x7F,
                      !(0xF700...0xF8FF).contains(chars[0]),
                      let ch = String(utf16CodeUnits: chars, count: 1).first, map[ch] == nil else { continue }
                map[ch] = code
            }
        }
        return map
    }

    // MARK: Media

    func media(_ name: String) {
        guard let key = Self.mediaKeys[name] else { return }
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            guard let e = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                             modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                                             timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                             data1: (key << 16) | (state << 8), data2: -1)?.cgEvent else { continue }
            post(e)
        }
    }
}
