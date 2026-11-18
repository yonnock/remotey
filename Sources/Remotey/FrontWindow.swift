import AppKit
import ApplicationServices

/// The window in front, as Accessibility reports it: what the live view fits itself to. Main thread only.
///
/// It is the focused window of the app in front if a user would name it a window (a document, a main window,
/// a dialog), else the app's main window. An app without one, such as the Finder showing only the desktop,
/// has none; neither has any app without the Accessibility permission.
///
/// Asked to (`shape`), it also gives that window the phone's shape, so the window fills the phone's display.
/// One window at a time: it gets the frame it had back when another one comes to the front, when `shape` is
/// taken away and with `stop`. An agent that crashes leaves the window as it is.
final class FrontWindow {
    /// Which window is in front and where, and when to say so. Another window is told at once. One that
    /// moves or changes size is told once it holds still: a window dragged across the screen would
    /// otherwise drag the view along, and one being resized would set up the stream anew with every step.
    struct Track<Window: Equatable> {
        private var window: Window?
        private var told: CGRect?
        /// Where the window was at the last look, while that differs from what was told.
        private var moving: CGRect?

        enum Step: Equatable {
            /// Nothing new to tell.
            case keep
            case tell(CGRect?)
            /// The window is on its way: look again after `FrontWindow.stillness`, with `settled`.
            case wait
        }

        /// `settled`: this look comes `stillness` after the last one, with nothing reported in between.
        mutating func see(_ window: Window?, frame: CGRect?, settled: Bool = false) -> Step {
            let frame = window == nil ? nil : frame
            if window != self.window || frame == nil || told == nil || (settled && frame == moving) {
                self.window = window
                moving = nil
                guard frame != told else { return .keep }
                told = frame
                return .tell(frame)
            }
            guard frame != told else {
                moving = nil
                return .keep
            }
            moving = frame
            return .wait
        }

        /// The window was put at `frame` from here: there is nothing to wait for.
        mutating func put(_ window: Window, at frame: CGRect) -> Step {
            self.window = window
            moving = nil
            guard frame != told else { return .keep }
            told = frame
            return .tell(frame)
        }
    }

    /// The window that has the phone's shape: where it was before, and the frame asked of it. It is asked
    /// once for a frame. What the app makes of that, or the user after it, stands.
    private struct Shaped {
        let window: Element
        let original: CGRect
        let asked: CGRect
    }

    /// Two references to one window are equal as Accessibility compares them.
    private struct Element: Equatable {
        let ref: AXUIElement
        static func == (a: Element, b: Element) -> Bool { CFEqual(a.ref, b.ref) }
    }

    private let changed: (CGRect?, Bool) -> Void
    private var track = Track<Element>()
    /// The window `changed` was last called for.
    private var told: Element?
    private var shaped: Shaped?
    /// The size the window in front is to take, in points: the phone's display at the zoom the page asks for.
    /// Nil leaves every window as it is, and gives the one that was shaped its frame back.
    var shape: CGSize? { didSet { if shape != oldValue, isWatching { look() } } }
    private var looking = false
    private var settling: DispatchWorkItem?
    private lazy var app = FrontApp(notifications: [
        kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXWindowCreatedNotification,
        kAXWindowMovedNotification, kAXWindowResizedNotification, kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
    ]) { [weak self] in self?.lookSoon() }

    /// A window that has not moved for this long holds still.
    static let stillness = 0.15
    private static let coalescing = 0.03

    /// `changed` gets the frame of the window in front, in global points with the origin at the top left of
    /// the main display, whenever it is another one: at `start`, and when the app in front says so. Its second
    /// argument is false for the same window as last time, which was moved or changed its size.
    init(changed: @escaping (CGRect?, _ another: Bool) -> Void) {
        self.changed = changed
    }

    var isWatching: Bool { app.isWatching }

    func start() {
        app.start()
        look()
    }

    func stop() {
        app.stop()
        settling?.cancel()
        if let shaped { Self.put(shaped.window.ref, at: shaped.original) }
        shaped = nil
        told = nil
        track = Track()
    }

    /// Looks once more shortly. Calls meanwhile are one: a window being dragged reports every step.
    private func lookSoon() {
        guard !looking else { return }
        looking = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coalescing) { [weak self] in
            guard let self else { return }
            self.looking = false
            if self.isWatching { self.look() }
        }
    }

    private func look(settled: Bool = false) {
        settling?.cancel()
        let found = Self.find(), window = found.map { Element(ref: $0.window) }
        var put: CGRect?
        // The window that had the phone's shape left the front, or shapes are no longer asked for.
        if let held = shaped, shape == nil || window != held.window {
            let frame = Self.put(held.window.ref, at: held.original)
            if window == held.window { put = frame }
            shaped = nil
        }
        if let shape, let found, let window, found.resizable {
            let original = shaped?.original ?? found.frame
            let asked = Self.shaped(original, to: shape, inside: Self.visibleFrame(around: original))
            if shaped?.asked != asked {
                shaped = Shaped(window: window, original: original, asked: asked)
                put = Self.put(found.window, at: asked)
            }
        }
        let step = if let window, let put { track.put(window, at: put) }
                   else { track.see(window, frame: found?.frame, settled: settled) }
        switch step {
        case .keep: break
        case .tell(let frame):
            let another = window != told
            told = window
            changed(frame, another)
        case .wait:
            let item = DispatchWorkItem { [weak self] in self?.look(settled: true) }
            settling = item
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.stillness, execute: item)
        }
    }

    /// The frame a window takes for the phone's shape: `size`, or as much of it as `visible` holds at the same
    /// aspect. It stays where the window is, and moves only as far as it takes to lie inside `visible`.
    static func shaped(_ frame: CGRect, to size: CGSize, inside visible: CGRect) -> CGRect {
        let fit = min(1, visible.width / size.width, visible.height / size.height)
        let width = (size.width * fit).rounded(.down), height = (size.height * fit).rounded(.down)
        return CGRect(x: min(max(frame.minX, visible.minX), visible.maxX - width).rounded(),
                      y: min(max(frame.minY, visible.minY), visible.maxY - height).rounded(), width: width, height: height)
    }

    /// The part of the display `frame` mostly lies on that windows may take: without the menu bar and the Dock.
    /// In global points with the origin at the top left of the main display, as `frame` is.
    private static func visibleFrame(around frame: CGRect) -> CGRect {
        // AppKit counts from the bottom left of the main display, upwards.
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        func flipped(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height) }
        func share(_ screen: NSScreen) -> Double {
            let common = flipped(screen.frame).intersection(frame)
            return common.isNull ? 0 : common.width * common.height
        }
        return (NSScreen.screens.max { share($0) < share($1) }).map { flipped($0.visibleFrame) } ?? frame
    }

    /// Asks a window to take `frame`, and returns the one it has then: an app may hold a window to a
    /// smallest size, a largest one, or steps of its own.
    @discardableResult
    private static func put(_ window: AXUIElement, at frame: CGRect) -> CGRect? {
        var size = frame.size, origin = frame.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size), let originValue = AXValueCreate(.cgPoint, &origin) else { return nil }
        // The size first and again after the move: a window may not grow past the edge of the display it is on.
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, originValue)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        return Accessibility.frame(of: window)
    }

    /// `resizable`: a document or main window that takes a size, not a dialog and not one in full screen.
    private static func find() -> (window: AXUIElement, frame: CGRect, resizable: Bool)? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        // A hanging app must not hold the main thread, which carries the pointer, for the default six seconds.
        AXUIElementSetMessagingTimeout(app, 0.1)
        for name in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            guard let value = Accessibility.attribute(app, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { continue }
            let window = value as! AXUIElement // swiftlint:disable:this force_cast
            AXUIElementSetMessagingTimeout(window, 0.1)
            let subrole = Accessibility.attribute(window, kAXSubroleAttribute) as? String
            guard Apps.isChoice(role: Accessibility.attribute(window, kAXRoleAttribute) as? String, subrole: subrole),
                  Accessibility.attribute(window, kAXMinimizedAttribute) as? Bool != true,
                  let frame = Accessibility.frame(of: window), frame.width >= 1, frame.height >= 1 else { continue }
            var settable: DarwinBoolean = false
            let resizable = subrole == kAXStandardWindowSubrole
                && Accessibility.attribute(window, "AXFullScreen") as? Bool != true
                && AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &settable) == .success && settable.boolValue
            return (window, frame, resizable)
        }
        return nil
    }
}
