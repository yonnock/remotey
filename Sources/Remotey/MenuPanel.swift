import AppKit
import SwiftUI

/// The status item's panel, made to behave as a menu does: it opens on a click on the symbol, below it on that
/// display, closes on a click anywhere else, on Escape, when another app comes forward or the Space changes, and
/// takes the keyboard without making Remotey the active app.
///
/// A panel and not an NSMenu: a menu cannot hold a switch and a button in a row with its own highlight and
/// still act on Return, and a menu cannot be drawn off screen, so no picture of it could be checked.
final class MenuPanel: NSPanel {
    static let cornerRadius: CGFloat = 14

    var onClose: (() -> Void)?
    var onKeyEquivalent: ((String) -> Bool)?

    init(content: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: MenuView.width, height: 100),
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        // Over a full-screen app and on every Space, as a menu is.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        contentView = Self.backdrop(around: content)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onClose?() }

    override func resignKey() {
        super.resignKey()
        onClose?()
    }

    /// ⌘, and ⌘Q work while the panel is open, as their menu items say.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, let key = event.charactersIgnoringModifiers, onKeyEquivalent?(key) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// The menu's material with rounded corners and the hairline edge menus have.
    static func backdrop(around content: NSView) -> NSView {
        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.cgColor
        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        return effect
    }

    /// Where the panel's lower left corner goes: its left edge under the symbol's, its top just under the
    /// menu bar, and the whole of it on the symbol's display.
    static func origin(size: NSSize, below button: NSRect, on screen: NSRect) -> NSPoint {
        let margin: CGFloat = 6, gap: CGFloat = 5
        let x = min(max(button.minX, screen.minX + margin), screen.maxX - size.width - margin)
        let y = max(button.minY - gap - size.height, screen.minY + margin)
        return NSPoint(x: x, y: y)
    }
}

/// Opens and closes the panel for the status item.
final class MenuPresenter {
    private let model: MacModel
    private let host: NSHostingView<AnyView>
    private lazy var panel: MenuPanel = {
        let panel = MenuPanel(content: host)
        panel.onClose = { [weak self] in self?.close() }
        panel.onKeyEquivalent = { [weak self] key in self?.keyEquivalent(key) ?? false }
        return panel
    }()
    private var monitors: [Any] = []
    private var spaces: NSObjectProtocol?
    private var shown = false
    private weak var button: NSStatusBarButton?
    /// Called when it opens and closes: the assistant looks while the panel shows.
    var opened: (() -> Void)?
    var closed: (() -> Void)?

    var isOpen: Bool { shown }

    init(model: MacModel) {
        self.model = model
        host = NSHostingView(rootView: AnyView(MenuView(model: model)))
    }

    func toggle(below button: NSStatusBarButton) {
        isOpen ? close() : open(below: button)
    }

    func open(below button: NSStatusBarButton) {
        guard !shown, let buttonWindow = button.window, let screen = buttonWindow.screen ?? NSScreen.main else { return }
        shown = true
        self.button = button
        opened?()
        // A new identity each time: the panel opens with no row lit and the keyboard on it, as a menu does.
        host.rootView = AnyView(MenuView(model: model).id(UUID()))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let frame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        panel.setFrame(NSRect(origin: MenuPanel.origin(size: size, below: frame, on: screen.frame), size: size), display: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(host)
        panel.invalidateShadow()
        button.highlight(true)
        // Clicks in other apps; clicks in Remotey's own windows other than the panel and the symbol.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
                                                          handler: { [weak self] _ in self?.close() }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
                                                        handler: { [weak self] event in
            guard let self else { return event }
            if event.window !== self.panel, event.window !== self.button?.window { self.close() }
            return event
        }) {
            monitors.append(local)
        }
        spaces = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.close() }
    }

    /// Also called by the panel as it loses the keyboard while it goes: `shown` keeps that from counting twice.
    func close() {
        guard shown else { return }
        shown = false
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let spaces { NSWorkspace.shared.notificationCenter.removeObserver(spaces) }
        spaces = nil
        panel.orderOut(nil)
        button?.highlight(false)
        closed?()
    }

    private func keyEquivalent(_ key: String) -> Bool {
        switch key {
        case ",":
            close()
            model.actions.openSettings(nil)
        case "q":
            close()
            model.actions.quit()
        default:
            return false
        }
        return true
    }
}
