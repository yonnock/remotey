import AppKit

/// The menu bar symbol: a pointer, with rays while a phone is connected, struck through while remote control is
/// paused, and with a small exclamation mark while something keeps a phone out. A template image, so the menu
/// bar draws it in its own colour, on every background and with increased contrast.
enum StatusSymbol {
    static let size = NSSize(width: 22, height: 18)

    static func image(_ look: MacState.Look) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let base = NSImage(systemSymbolName: look.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
            ?? NSImage(systemSymbolName: "cursorarrow", accessibilityDescription: nil)!
        guard look.problem else {
            base.isTemplate = true
            base.accessibilityDescription = look.label
            return base
        }
        let mark = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8.5, weight: .bold))
        let image = NSImage(size: size, flipped: false) { rect in
            let baseSize = base.size
            base.draw(in: NSRect(x: (rect.width - baseSize.width) / 2 - 2, y: (rect.height - baseSize.height) / 2,
                                 width: baseSize.width, height: baseSize.height))
            guard let mark else { return true }
            let markRect = NSRect(x: rect.maxX - mark.size.width, y: 0, width: mark.size.width, height: mark.size.height)
            // A gap around the mark, so it reads apart from the pointer.
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: markRect.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            mark.draw(in: markRect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = look.label
        return image
    }
}
