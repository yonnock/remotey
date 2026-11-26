import AppKit
import ApplicationServices
import CoreGraphics
import ServiceManagement

/// The two permissions Remotey needs, read without a prompt, and asked for only when someone presses a key.
enum Permissions {
    static let accessibilitySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let screenRecordingSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    /// Follows the switch in System Settings while the app runs.
    static var accessibility: Bool { AXIsProcessTrusted() }

    /// Shows the system's dialog and puts Remotey into the list in System Settings, switched off.
    static func askForAccessibility() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    struct ScreenRecording: Equatable {
        /// What the switch in System Settings says now.
        var granted: Bool
        /// What `CGPreflightScreenCaptureAccess` says in this process. It keeps its first answer until the app
        /// restarts, so it only counts where no window tells.
        var preflight: Bool
    }

    /// Without the permission, the window server leaves out the titles of other apps' windows; with it, every
    /// window has one, if only an empty one. That answer follows the switch at once and asks nothing.
    static var screenRecording: ScreenRecording {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let preflight = CGPreflightScreenCaptureAccess()
        let seen = titlesVisible(in: windows, ownPID: getpid()) {
            NSRunningApplication(processIdentifier: $0)?.activationPolicy == .regular
        }
        return ScreenRecording(granted: seen ?? preflight, preflight: preflight)
    }

    /// Nil when no window of another app is on screen to tell. Only windows of regular apps count: system
    /// processes such as WindowManager keep their titles without the permission (measured on macOS 27).
    static func titlesVisible(in windows: [[String: Any]], ownPID: pid_t, isApp: (pid_t) -> Bool) -> Bool? {
        var apps: [pid_t: Bool] = [:]
        var witnesses = 0
        for window in windows {
            guard let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != ownPID else { continue }
            if apps[pid] == nil { apps[pid] = isApp(pid) }
            guard apps[pid] == true else { continue }
            if window[kCGWindowName as String] != nil { return true }
            witnesses += 1
        }
        return witnesses > 0 ? false : nil
    }

    /// The system's dialog, once in the life of the app on this Mac; it also puts Remotey into the list in
    /// System Settings. Every later call returns without showing anything.
    static func askForScreenRecording() {
        CGRequestScreenCaptureAccess()
    }
}

/// "Beim Anmelden starten" through SMAppService.
enum LoginItem {
    enum State: Equatable {
        case on
        case off
        /// Registered, but switched off under System Settings → General → Login Items.
        case needsApproval
        /// Only an app in a bundle can be a login item, not `swift run`.
        case unavailable
    }

    static func state(_ status: SMAppService.Status) -> State {
        switch status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        case .notRegistered: return .off
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    static var current: State { state(SMAppService.mainApp.status) }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
