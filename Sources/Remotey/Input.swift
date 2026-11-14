import AppKit
import Carbon.HIToolbox

/// Injects mouse, keyboard and media events. Needs the Accessibility permission. Main thread only.
final class Input {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var held: Set<UInt32> = []
    private var lastClick: (time: TimeInterval, point: CGPoint, button: CGMouseButton, count: Int64)?
    private var moveRemainder = CGPoint.zero
    private var scrollRemainder = CGPoint.zero

    private static let namedKeys: [String: Int] = [
        "return": kVK_Return, "tab": kVK_Tab, "space": kVK_Space, "backspace": kVK_Delete, "escape": kVK_Escape,
        "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
    ]

    // NX_KEYTYPE_* values from IOKit/hidsystem/ev_keymap.h
    private static let mediaKeys: [String: Int] = [
        "volup": 0, "voldown": 1, "mute": 7, "play": 16, "next": 17, "prev": 18,
    ]

    // MARK: Mouse

    func move(dx: Double, dy: Double) {
        moveRemainder.x += dx
        moveRemainder.y += dy
        let step = CGPoint(x: moveRemainder.x.rounded(.towardZero), y: moveRemainder.y.rounded(.towardZero))
        guard step != .zero else { return }
        moveRemainder.x -= step.x
        moveRemainder.y -= step.y

        let from = Pointer.location
        let to = clamp(CGPoint(x: from.x + step.x, y: from.y + step.y), from: from)
        let left = held.contains(CGMouseButton.left.rawValue)
        let right = held.contains(CGMouseButton.right.rawValue)
        let type: CGEventType = left ? .leftMouseDragged : right ? .rightMouseDragged : .mouseMoved
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: to,
                              mouseButton: right && !left ? .right : .left) else { return }
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64(step.x))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64(step.y))
        e.flags = []
        e.post(tap: .cghidEventTap)
        Pointer.posted(to)
    }

    /// Keeps the cursor on a display: a target off every screen is clamped to the current one.
    private func clamp(_ target: CGPoint, from: CGPoint) -> CGPoint {
        guard Pointer.display(at: target) == nil else { return target }
        let bounds = CGDisplayBounds(Pointer.display(at: from) ?? CGMainDisplayID())
        return CGPoint(x: min(max(target.x, bounds.minX), bounds.maxX - 1),
                       y: min(max(target.y, bounds.minY), bounds.maxY - 1))
    }

    func button(_ button: CGMouseButton, down: Bool) {
        guard held.contains(button.rawValue) != down else { return }
        let point = Pointer.location
        if down {
            let now = ProcessInfo.processInfo.systemUptime
            var count: Int64 = 1
            if let last = lastClick, last.button == button, now - last.time < NSEvent.doubleClickInterval,
               hypot(last.point.x - point.x, last.point.y - point.y) < 5 {
                count = last.count + 1
            }
            lastClick = (now, point, button, count)
            held.insert(button.rawValue)
        } else {
            held.remove(button.rawValue)
        }
        let type: CGEventType = button == .left
            ? (down ? .leftMouseDown : .leftMouseUp)
            : (down ? .rightMouseDown : .rightMouseUp)
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                              mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: lastClick?.count ?? 1)
        e.flags = []
        e.post(tap: .cghidEventTap)
    }

    func click(_ b: CGMouseButton) {
        button(b, down: true)
        button(b, down: false)
    }

    /// Called when a client disconnects so a drag never stays stuck.
    func releaseAll() {
        for raw in held { if let b = CGMouseButton(rawValue: raw) { button(b, down: false) } }
    }

    func scroll(dx: Double, dy: Double) {
        scrollRemainder.x += dx
        scrollRemainder.y += dy
        let step = CGPoint(x: scrollRemainder.x.rounded(.towardZero), y: scrollRemainder.y.rounded(.towardZero))
        guard step != .zero else { return }
        scrollRemainder.x -= step.x
        scrollRemainder.y -= step.y
        CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                wheel1: Int32(step.y), wheel2: Int32(step.x), wheel3: 0)?.post(tap: .cghidEventTap)
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
                e.post(tap: .cghidEventTap)
            }
        }
    }

    private func press(_ code: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            e.flags = flags
            e.post(tap: .cghidEventTap)
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
            NSEvent.otherEvent(with: .systemDefined, location: .zero,
                               modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                               timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                               data1: (key << 16) | (state << 8), data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
