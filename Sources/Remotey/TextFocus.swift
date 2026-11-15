import AppKit
import ApplicationServices

/// Where text typed from the phone lands on the Mac, as Accessibility reports it. Main thread only.
///
/// Apps report this differently well. The best is the caret or selection (`AXBoundsForRange`); some apps
/// only give the focused element; some give nothing. Neither the pointer nor the keyboard focus is moved.
final class TextFocus {
    struct Target: Equatable {
        /// Global points, origin top left of the main display.
        let rect: CGRect
        /// The caret or selection itself. False: only the frame of the focused element.
        let exact: Bool
    }

    private let system = AXUIElementCreateSystemWide()
    private let changed: (Target?) -> Void
    private var locating = false
    private var observer: AXObserver?
    private var observed: pid_t = 0
    private var activation: NSObjectProtocol?

    /// `changed` gets the new target when the app in front reports that its focus, selection, text or
    /// window changed, or after `locateSoon`.
    init(changed: @escaping (Target?) -> Void) {
        self.changed = changed
        // A hanging app must not hold the main thread for the default six seconds.
        AXUIElementSetMessagingTimeout(system, 0.1)
    }

    var isWatching: Bool { activation != nil }

    func start() {
        guard activation == nil else { return }
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.observeFrontmost()
            self?.locateSoon()
        }
        observeFrontmost()
    }

    /// Locates once more shortly. Calls meanwhile are one: a log scrolling in a terminal sends value changes
    /// by the hundred, and every lookup is a round trip to the app on the main thread.
    func locateSoon() {
        guard !locating else { return }
        locating = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coalescing) { [weak self] in
            guard let self else { return }
            self.locating = false
            if self.isWatching { self.changed(self.locate()) }
        }
    }

    private static let coalescing = 0.03

    func stop() {
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
        unobserve()
    }

    /// The caret or selection of the focused element, else its frame. Nil if Accessibility knows neither.
    func locate() -> Target? {
        guard let focused = attribute(system, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = focused as! AXUIElement // swiftlint:disable:this force_cast
        if let caret = caret(of: element) { return Target(rect: caret, exact: true) }
        guard let position: CGPoint = value(attribute(element, kAXPositionAttribute), .cgPoint),
              let size: CGSize = value(attribute(element, kAXSizeAttribute), .cgSize) else { return nil }
        let frame = CGRect(origin: position, size: size)
        return Self.isOnScreen(frame) ? Target(rect: frame, exact: false) : nil
    }

    private func caret(of element: AXUIElement) -> CGRect? {
        guard let range: CFRange = value(attribute(element, kAXSelectedTextRangeAttribute), .cfRange) else { return nil }
        // An empty selection has no bounds in some apps. The character before the caret, or after it at the start, has.
        var candidates = [range]
        if range.length == 0 {
            if range.location > 0 { candidates.append(CFRange(location: range.location - 1, length: 1)) }
            candidates.append(CFRange(location: range.location, length: 1))
        }
        for (index, candidate) in candidates.enumerated() {
            var candidate = candidate
            guard let axRange = AXValueCreate(.cfRange, &candidate) else { continue }
            var result: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                             axRange, &result) == .success,
                  var rect: CGRect = value(result, .cgRect), Self.isOnScreen(rect) else { continue }
            // The character before an empty selection: the caret is at its right edge.
            if index > 0, candidate.location < range.location { rect = CGRect(x: rect.maxX, y: rect.minY, width: 0, height: rect.height) }
            else if index > 0 { rect = CGRect(x: rect.minX, y: rect.minY, width: 0, height: rect.height) }
            return rect
        }
        return nil
    }

    /// Some apps answer with an empty or made-up rectangle at the origin instead of an error.
    private static func isOnScreen(_ rect: CGRect) -> Bool {
        guard rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite, rect.height > 0,
              rect.origin != .zero else { return false }
        var count: UInt32 = 0
        return CGGetDisplaysWithRect(rect.insetBy(dx: -1, dy: -1), 0, nil, &count) == .success && count > 0
    }

    // MARK: Notifications of the app in front

    private func observeFrontmost() {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid != observed else { return }
        unobserve()
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<TextFocus>.fromOpaque(refcon).takeUnretainedValue().locateSoon()
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let names = [kAXFocusedUIElementChangedNotification, kAXSelectedTextChangedNotification, kAXValueChangedNotification,
                     kAXWindowMovedNotification, kAXWindowResizedNotification]
        // An app that is not ready for Accessibility yet is tried again when it next comes to the front or the phone types.
        guard names.map({ AXObserverAddNotification(created, app, $0 as CFString, refcon) }).contains(.success) else { return }
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

    // MARK: Accessibility values

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }

    private func value<T>(_ ref: CFTypeRef?, _ type: AXValueType) -> T? {
        guard let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        let axValue = ref as! AXValue // swiftlint:disable:this force_cast
        guard AXValueGetType(axValue) == type else { return nil }
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        return AXValueGetValue(axValue, type, pointer) ? pointer.pointee : nil
    }
}
