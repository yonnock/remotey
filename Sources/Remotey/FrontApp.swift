import AppKit
import ApplicationServices

/// Tells when the app in front reports something about its interface, and when another app comes to the
/// front. Main thread only.
final class FrontApp {
    private let notifications: [String]
    private let changed: () -> Void
    private var observer: AXObserver?
    private var observed: pid_t = 0
    private var activation: NSObjectProtocol?

    /// `changed` runs for every one of `notifications` the app in front posts, and when another app takes
    /// its place. Apps post them by the hundred, so the receiver looks once for many.
    init(notifications: [String], changed: @escaping () -> Void) {
        self.notifications = notifications
        self.changed = changed
    }

    var isWatching: Bool { activation != nil }

    /// Also tries again for an app that was not ready for Accessibility when it came to the front.
    func start() {
        if activation == nil {
            activation = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.observeFrontmost()
                self?.changed()
            }
        }
        observeFrontmost()
    }

    func stop() {
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
        unobserve()
    }

    private func observeFrontmost() {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid != observed else { return }
        unobserve()
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<FrontApp>.fromOpaque(refcon).takeUnretainedValue().changed()
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // An app that is not ready for Accessibility yet is tried again when it next comes to the front or with `start`.
        guard notifications.map({ AXObserverAddNotification(created, app, $0 as CFString, refcon) }).contains(.success) else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        observed = pid
    }

    private func unobserve() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        observer = nil
        observed = 0
    }

    deinit { stop() }
}
