import AppKit

/// Pictures of the Mac's windows and panel, drawn off screen: no window is ever ordered in, nothing shows on the
/// display and nothing is asked of the system. `scripts/mac-pictures.sh` runs the tests that use it.
///
/// What an off-screen drawing cannot show: a window that is not on screen is never key, so the traffic lights
/// and the switches draw in their inactive grey; a material (the menu's, the title bar's) has nothing behind it
/// to blur, so the panel's is painted in the colour it has over a plain background.
@MainActor
enum Pictures {
    /// Where the pictures go; nil skips them.
    static var folder: URL? {
        ProcessInfo.processInfo.environment["REMOTEY_PICTURES"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    enum Look: String, CaseIterable {
        case light, dark

        var appearance: NSAppearance { NSAppearance(named: self == .light ? .aqua : .darkAqua)! }
    }

    /// Lays out and draws whatever the run loop still owes: SwiftUI settles over a few turns.
    static func settle(_ window: NSWindow) {
        for _ in 0..<4 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    static func snapshot(_ view: NSView) -> NSBitmapImageRep {
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// The whole window with its title bar and toolbar, cut to its rounded corners.
    static func window(_ window: NSWindow, _ look: Look) -> NSImage {
        window.appearance = look.appearance
        settle(window)
        let frameView = window.contentView!.superview!
        let rep = snapshot(frameView)
        let size = frameView.bounds.size
        return NSImage(size: size, flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: radius(window), yRadius: radius(window)).addClip()
            rep.draw(in: rect)
            // The hairline every window has around it.
            NSColor(white: look == .light ? 0 : 1, alpha: look == .light ? 0.18 : 0.22).setStroke()
            let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: radius(window), yRadius: radius(window))
            edge.lineWidth = 0.5
            edge.stroke()
            return true
        }
    }

    /// Corners grew with macOS 26; earlier windows have 10 points.
    static func radius(_ window: NSWindow) -> CGFloat {
        if #available(macOS 26, *) { return window.toolbar == nil ? 16 : 26 }
        return 10
    }

    /// A view in an off-screen window of its own, at the size it asks for.
    static func view(_ view: NSView, _ look: Look, width: CGFloat? = nil) -> NSImage {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width ?? 100, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.appearance = look.appearance
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = view
        settle(window)
        let size = view.fittingSize
        window.setContentSize(NSSize(width: width ?? size.width, height: size.height))
        view.frame = NSRect(origin: .zero, size: window.contentRect(forFrameRect: window.frame).size)
        settle(window)
        let rep = snapshot(view)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// `image` with the shadow of a window around it, on a transparent ground, as a screenshot of a window is.
    static func shadowed(_ image: NSImage, margin: CGFloat = 40) -> NSImage {
        let size = NSSize(width: image.size.width + 2 * margin, height: image.size.height + 2 * margin)
        return NSImage(size: size, flipped: false) { _ in
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 0, alpha: 0.32)
            shadow.shadowBlurRadius = 24
            shadow.shadowOffset = NSSize(width: 0, height: -10)
            shadow.set()
            image.draw(in: NSRect(origin: NSPoint(x: margin, y: margin), size: image.size))
            return true
        }
    }

    /// The panel below a menu bar, over the gradient of the mockups. `symbol` is the status item's image.
    static func menu(_ content: NSImage, symbol: NSImage, _ look: Look, radius: CGFloat = 14) -> NSImage {
        let bar: CGFloat = 24, width = max(560, content.size.width + 140)
        let height = bar + 5 + content.size.height + 60
        return NSImage(size: NSSize(width: width, height: height), flipped: true) { rect in
            NSGradient(colors: [NSColor(srgbRed: 0.14, green: 0.21, blue: 0.35, alpha: 1),
                                NSColor(srgbRed: 0.42, green: 0.25, blue: 0.43, alpha: 1),
                                NSColor(srgbRed: 0.82, green: 0.48, blue: 0.24, alpha: 1)],
                       atLocations: [0, 0.52, 1], colorSpace: .sRGB)!.draw(in: rect, angle: -70)
            // The menu bar, and the status item lit as it is while its panel is open.
            NSColor(white: look == .light ? 1 : 0, alpha: look == .light ? 0.35 : 0.3).setFill()
            NSRect(x: 0, y: 0, width: rect.width, height: bar).fill()
            let panelX = rect.width - content.size.width - 70
            let item = NSRect(x: panelX, y: 3, width: 32, height: bar - 6)
            NSColor(white: look == .light ? 0 : 1, alpha: look == .light ? 0.12 : 0.22).setFill()
            NSBezierPath(roundedRect: item, xRadius: 5, yRadius: 5).fill()
            tinted(symbol, look).draw(in: NSRect(x: item.midX - symbol.size.width / 2, y: item.midY - symbol.size.height / 2,
                                   width: symbol.size.width, height: symbol.size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            // The panel: its material as it looks over a plain ground, its edge, its shadow, then what is in it.
            let panel = NSRect(x: panelX, y: bar + 5, width: content.size.width, height: content.size.height)
            let shape = NSBezierPath(roundedRect: panel, xRadius: radius, yRadius: radius)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
            shadow.shadowBlurRadius = 22
            shadow.shadowOffset = NSSize(width: 0, height: 10)
            shadow.set()
            (look == .light ? NSColor(srgbRed: 0.93, green: 0.92, blue: 0.94, alpha: 0.94)
                            : NSColor(srgbRed: 0.17, green: 0.16, blue: 0.19, alpha: 0.94)).setFill()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()
            (look == .light ? NSColor(white: 0, alpha: 0.12) : NSColor(white: 1, alpha: 0.16)).setStroke()
            shape.lineWidth = 0.5
            shape.stroke()
            content.draw(in: panel, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return true
        }
    }

    /// A template image in the colour the menu bar gives it.
    static func tinted(_ symbol: NSImage, _ look: Look) -> NSImage {
        NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            (look == .light ? NSColor.black : NSColor.white).set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    static func save(_ image: NSImage, _ name: String) throws {
        guard let folder else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let png = bitmap(image).representation(using: .png, properties: [:]) else { return }
        try png.write(to: folder.appendingPathComponent("\(name).png"))
    }

    /// At twice the size in points, as on a Retina display.
    static func bitmap(_ image: NSImage, scale: CGFloat = 2) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * scale),
                                   pixelsHigh: Int(image.size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}
