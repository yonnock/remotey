import AppKit
import ApplicationServices

/// The window in front, as Accessibility reports it: what the live view fits itself to. Main thread only.
///
/// It is the focused window of the app in front if a user would name it a window (a document, a main window,
/// a dialog), else the app's main window. An app without one, such as the Finder showing only the desktop,
/// has none; neither has any app without the Accessibility permission.
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
    }

    /// Two references to one window are equal as Accessibility compares them.
    private struct Element: Equatable {
        let ref: AXUIElement
        static func == (a: Element, b: Element) -> Bool { CFEqual(a.ref, b.ref) }
    }

    private let changed: (CGRect?) -> Void
    private var track = Track<Element>()
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
    /// the main display, whenever it is another one: at `start`, and when the app in front says so.
    init(changed: @escaping (CGRect?) -> Void) {
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
        let found = Self.find()
        switch track.see(found.map { Element(ref: $0.window) }, frame: found?.frame, settled: settled) {
        case .keep: break
        case .tell(let frame): changed(frame)
        case .wait:
            let item = DispatchWorkItem { [weak self] in self?.look(settled: true) }
            settling = item
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.stillness, execute: item)
        }
    }

    private static func find() -> (window: AXUIElement, frame: CGRect)? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        // A hanging app must not hold the main thread, which carries the pointer, for the default six seconds.
        AXUIElementSetMessagingTimeout(app, 0.1)
        for name in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            guard let value = Accessibility.attribute(app, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { continue }
            let window = value as! AXUIElement // swiftlint:disable:this force_cast
            AXUIElementSetMessagingTimeout(window, 0.1)
            guard Apps.isChoice(role: Accessibility.attribute(window, kAXRoleAttribute) as? String,
                                subrole: Accessibility.attribute(window, kAXSubroleAttribute) as? String),
                  Accessibility.attribute(window, kAXMinimizedAttribute) as? Bool != true,
                  let frame = Accessibility.frame(of: window), frame.width >= 1, frame.height >= 1 else { continue }
            return (window, frame)
        }
        return nil
    }
}
