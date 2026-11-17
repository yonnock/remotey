import AppKit
import ApplicationServices

/// The apps the Dock shows as open, with their windows, and bringing one of them to the front.
///
/// The windows come from Accessibility. It knows those of the current Space and the minimized ones; an app whose
/// windows lie on another Space is listed without any. Such an app comes to the front the way a click in the
/// Dock brings it, which switches to its Space.
final class Apps {
    struct App: Encodable, Equatable {
        let pid: Int32
        let name: String
        /// Names the app's icon. The page gets every icon once per connection, in a message of its own.
        let icon: String
        /// The app in front.
        let front: Bool
        let hidden: Bool
        /// Front to back. Empty without the Accessibility permission.
        let windows: [Window]
    }

    struct Window: Encodable, Equatable {
        /// Names the window in `focus`, for as long as the window exists.
        let id: Int
        let title: String
        let minimized: Bool
        /// The app's main window: the one in front, if the app is.
        let main: Bool

        enum CodingKeys: String, CodingKey { case id, title, minimized = "min", main }
    }

    /// A window of the last list: the id the page names it by, and what Accessibility raises.
    private struct Known {
        let id: Int
        let pid: pid_t
        let element: AXUIElement
    }

    /// What an app reports about one window.
    private struct Found {
        let element: AXUIElement
        let title: String
        let minimized: Bool
        let main: Bool
    }

    /// Every question to an app waits behind the app's own work, and the first one after its start takes tens
    /// of milliseconds. All of them are asked here, off the main thread, which carries the pointer.
    private let queue = DispatchQueue(label: "remotey.apps", qos: .userInitiated)
    /// The windows of the last list. An id stays with its window from list to list.
    private var known: [Known] = []
    private var lastID = 0
    /// Counts the calls of `focus`: what a call starts and finishes later only counts while it is the latest.
    private var requests = 0
    /// The apps of the last list, and the icons made so far by the names the list gives them.
    private var listed: [NSRunningApplication] = []
    private var icons: [String: Data] = [:]

    /// An app that hangs must not hold up the list for the six seconds Accessibility waits by default.
    private static let patience: Float = 0.25
    /// Icons are 40 points wide on the phone, which draws three pixels per point.
    private static let iconSide = 120
    private static let longestTitle = 200

    /// The open apps, the most recently used first as far as the screen tells. Answers on the main queue.
    func list(_ done: @escaping ([App]) -> Void) {
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier > 0 && !$0.isTerminated
        }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        queue.async {
            let apps = self.snapshot(running, front: front)
            DispatchQueue.main.async { done(apps) }
        }
    }

    /// The icons with these names as PNG, each handed over on the main queue. Names no listed app has are skipped.
    func pictures(of names: [String], each: @escaping (String, Data) -> Void) {
        queue.async {
            for name in names {
                guard let png = self.icons[name] ?? self.listed.first(where: { Self.iconName($0) == name }).flatMap(Self.picture(of:))
                else { continue }
                self.icons[name] = png
                DispatchQueue.main.async { each(name, png) }
            }
        }
    }

    /// Brings an app to the front: with the window `id` names in the last list, else as a click in the Dock does.
    /// `arrived` gets the frame of the window that is in front then, on the main queue, if the app reports one.
    func focus(pid: pid_t, window id: Int?, arrived: @escaping (CGRect) -> Void) {
        queue.async {
            // Only what the last list offered, if it still runs. Asking macOS for the process again can fail for an
            // app it started a moment ago, and would take any process, also one that is no app of the Dock.
            guard let app = self.listed.first(where: { $0.processIdentifier == pid }), !app.isTerminated else { return }
            self.requests += 1
            let request = self.requests
            let element = Self.application(pid)
            // By Accessibility as well: of an app in the background, macOS takes `activate` as a wish only.
            func activate() {
                AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                app.activate()
            }
            if app.isHidden { app.unhide() }
            if let window = id.flatMap({ id in self.known.first { $0.id == id && $0.pid == pid }?.element }) {
                // Out of the Dock first. A window on its way out takes no raise, and needs none: it arrives in front.
                if Accessibility.attribute(window, kAXMinimizedAttribute) as? Bool == true {
                    AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                }
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                activate()
                if let frame = Accessibility.frame(of: window) { DispatchQueue.main.async { arrived(frame) } }
            } else {
                // No window to raise: the app reported none, or the one named is gone.
                activate()
                // Opening a running app is what the Dock does: it has the app open a window if it has none. It
                // goes by the bundle, so of two copies of an app it may reach the other one, and it answers
                // late: it does not activate by itself, this app is activated once more after it, unless another
                // one was asked for meanwhile. A process without an app bundle (a script's window, a game's
                // binary) is left at that: opening its file would start a second copy in a terminal.
                if let bundle = app.bundleURL, bundle.pathExtension == "app" {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = false
                    NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, _ in
                        self.queue.async { if request == self.requests { activate() } }
                    }
                }
                // Which window that brings up shows once the app has come forward.
                self.queue.asyncAfter(deadline: .now() + Self.settling) {
                    guard request == self.requests,
                          let window = Accessibility.attribute(element, kAXFocusedWindowAttribute)
                            ?? Accessibility.attribute(element, kAXMainWindowAttribute),
                          CFGetTypeID(window) == AXUIElementGetTypeID(),
                          let frame = Accessibility.frame(of: window as! AXUIElement) // swiftlint:disable:this force_cast
                    else { return }
                    DispatchQueue.main.async { arrived(frame) }
                }
            }
        }
    }

    /// Coming forward, with a change of Space, takes about this long.
    private static let settling = 0.6

    // MARK: Order and choice

    /// The app in front, then the others by their frontmost window on screen (`stacked`, front to back, may
    /// name other processes and name one twice), then the rest in the order of `running`.
    static func order<ID: Hashable>(_ running: [ID], front: ID?, stacked: [ID]) -> [ID] {
        let listed = Set(running)
        var seen = Set<ID>()
        return ((front.map { [$0] } ?? []) + stacked + running).filter { listed.contains($0) && seen.insert($0).inserted }
    }

    /// Windows a user would name: a document or main window or a dialog. Not a palette, a popover or the desktop.
    static func isChoice(role: String?, subrole: String?) -> Bool {
        role == kAXWindowRole && (subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole)
    }

    // MARK: What the Mac reports (on `queue`)

    private func snapshot(_ running: [NSRunningApplication], front: pid_t?) -> [App] {
        var found = [[Found]](repeating: [], count: running.count)
        if AXIsProcessTrusted() {
            // Side by side: one after the other, fourteen apps took 50 to 800 ms here, together 20 to 60 ms.
            found.withUnsafeMutableBufferPointer { slots in
                let slots = slots.baseAddress!
                DispatchQueue.concurrentPerform(iterations: running.count) { index in
                    slots[index] = Self.windows(of: running[index].processIdentifier)
                }
            }
        }
        var seen: [Known] = []
        var apps: [pid_t: App] = [:]
        for (app, windows) in zip(running, found) {
            let pid = app.processIdentifier
            let listed = windows.map { window -> Window in
                let id = known.first { $0.pid == pid && CFEqual($0.element, window.element) }?.id ?? nextID()
                seen.append(Known(id: id, pid: pid, element: window.element))
                return Window(id: id, title: window.title, minimized: window.minimized, main: window.main)
            }
            apps[pid] = App(pid: pid, name: app.localizedName ?? app.bundleIdentifier ?? "App", icon: Self.iconName(app),
                            front: pid == front, hidden: app.isHidden, windows: listed)
        }
        known = seen
        listed = running
        // A process without a bundle has an icon of its own; it goes with the process.
        let names = Set(running.map(Self.iconName))
        icons = icons.filter { names.contains($0.key) }
        return Self.order(running.map(\.processIdentifier), front: front, stacked: Self.stacked()).compactMap { apps[$0] }
    }

    private func nextID() -> Int {
        lastID += 1
        return lastID
    }

    private static func application(_ pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, patience)
        return element
    }

    private static func windows(of pid: pid_t) -> [Found] {
        guard let windows = Accessibility.attribute(application(pid), kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        return windows.compactMap { window in
            AXUIElementSetMessagingTimeout(window, patience) // the app's own does not carry over to its windows
            guard isChoice(role: Accessibility.attribute(window, kAXRoleAttribute) as? String,
                           subrole: Accessibility.attribute(window, kAXSubroleAttribute) as? String) else { return nil }
            return Found(element: window,
                         title: String((Accessibility.attribute(window, kAXTitleAttribute) as? String ?? "").prefix(longestTitle)),
                         minimized: Accessibility.attribute(window, kAXMinimizedAttribute) as? Bool ?? false,
                         main: Accessibility.attribute(window, kAXMainAttribute) as? Bool ?? false)
        }
    }

    /// The apps that own the windows on screen, front to back. Reads no titles, so it needs no permission.
    private static func stacked() -> [pid_t] {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.filter { $0[kCGWindowLayer as String] as? Int == 0 }.compactMap { $0[kCGWindowOwnerPID as String] as? pid_t }
    }

    /// Two copies of one app share an icon; an app without a bundle has its own.
    private static func iconName(_ app: NSRunningApplication) -> String {
        app.bundleIdentifier ?? "pid-\(app.processIdentifier)"
    }

    private static func picture(of app: NSRunningApplication) -> Data? {
        var rect = CGRect(x: 0, y: 0, width: iconSide, height: iconSide)
        guard let image = app.icon?.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let context = CGContext(data: nil, width: iconSide, height: iconSide, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        return context.makeImage().flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
    }
}
