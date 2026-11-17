import AppKit
import ApplicationServices

/// The lock screen of the user's session: whether it is up, and typing the password into it.
///
/// A locked Mac takes posted input and shows in the live view like an unlocked one (measured on macOS 27),
/// and macOS has no call that unlocks a session. So unlocking is what a person does: the password goes
/// into the lock screen's field, key by key, then Return. Main thread only.
final class LockScreen {
    enum Failure: String {
        /// The lock screen's password field did not take the keyboard in time; nothing was typed.
        case field
        /// The password was typed and the Mac stayed locked.
        case password
    }

    /// The Mac was locked or unlocked.
    var changed: ((Bool) -> Void)?
    private(set) var isLocked: Bool
    private let session: () -> Bool
    private let field: () -> Int?
    private let wake: () -> Void
    private let patience: (field: TimeInterval, answer: TimeInterval)
    private var observers: [NSObjectProtocol] = []
    private var noted = -TimeInterval.infinity
    private var unlocking = false

    /// `session` says whether the session is locked, `field` how many characters the lock screen's password
    /// field holds (nil unless that field has the keyboard), `wake` powers the display on. `patience` is how
    /// long to wait for the field, and then for the Mac to unlock.
    init(session: @escaping () -> Bool = LockScreen.sessionIsLocked, field: @escaping () -> Int? = LockScreen.passwordField,
         wake: @escaping () -> Void = UserActivity.declare, patience: (field: TimeInterval, answer: TimeInterval) = (5, 6)) {
        self.session = session
        self.field = field
        self.wake = wake
        self.patience = patience
        isLocked = session()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            observers.append(DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in self?.note(locked) })
        }
    }

    deinit { observers.forEach(DistributedNotificationCenter.default().removeObserver) }

    private static let lag: TimeInterval = 1

    /// The system said so. Its word is taken at once and compared with the session's a moment later.
    func note(_ locked: Bool) {
        noted = ProcessInfo.processInfo.systemUptime
        set(locked)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lag + 0.1) { [weak self] in self?.refresh() }
    }

    /// Asks the session, in case a notification was lost. The session trails the notification of an unlock
    /// by a fraction of a second (it still said "locked" 0.2 s after one), so a recent notification stands.
    func refresh() {
        guard ProcessInfo.processInfo.systemUptime - noted >= Self.lag else { return }
        set(session())
    }

    private func set(_ locked: Bool) {
        guard locked != isLocked else { return }
        isLocked = locked
        changed?(locked)
    }

    /// Types `password` into the lock screen's field and presses Return. A Mac that unlocks says so through
    /// `changed`; `failed` is called if it stays locked. Nothing is typed unless the lock screen's password
    /// field has the keyboard, so a password never lands in an app: not on a Mac that is unlocked, and not on
    /// one that something else (Touch ID, an Apple Watch) unlocks while this waits.
    func unlock(with password: String, typing input: Input, failed: @escaping (Failure) -> Void) {
        guard isLocked else { return }
        // One password at a time. The page holds a second one back; another phone's is not typed.
        guard !unlocking else { return failed(.field) }
        unlocking = true
        Task { @MainActor in
            defer { unlocking = false }
            // A display that sleeps shows no field; awake, the lock screen needs a moment to take the keyboard.
            let characters = await poll(patience.field) { () -> Int? in
                self.wake()
                return self.field()
            }
            guard isLocked else { return }
            if ScreenView.statsOn { // never the password, only what the lock screen said
                FileHandle.standardError.write(Data("unlock: field \(characters.map { "holds \($0) characters" } ?? "not there")\n".utf8))
            }
            guard let characters else { return failed(.field) }
            // What an earlier try left in the field would go in front of the password.
            if characters > 0 { input.key("backspace", mods: [], count: characters) }
            input.type(password)
            input.key("return", mods: [], count: 1)
            // Nothing to ask for: this returns as soon as the Mac is open, or when the time is up.
            _ = await poll(patience.answer) { Bool?.none }
            guard isLocked else { return }
            // The notification may have been lost; the session knows by now.
            if session() { failed(.password) } else { set(false) }
        }
    }

    /// The first value `ready` gives within `seconds`, asked ten times a second. Nil: none, or the Mac unlocked.
    @MainActor
    private func poll<T>(_ seconds: TimeInterval, _ ready: () -> T?) async -> T? {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while isLocked {
            if let value = ready() { return value }
            guard ProcessInfo.processInfo.systemUptime < end else { return nil }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    // MARK: What the system says

    /// The key is there while the session is locked and gone otherwise.
    static func sessionIsLocked() -> Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// The number of characters in the lock screen's password field, as far as Accessibility tells. Nil unless
    /// that field has the keyboard and a display shows it.
    static func passwordField() -> Int? {
        guard CGDisplayIsAsleep(CGMainDisplayID()) == 0 else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        guard let focused = Accessibility.attribute(system, kAXFocusedUIElementAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement // swiftlint:disable:this force_cast
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.loginwindow",
              Accessibility.attribute(element, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole else { return nil }
        return Accessibility.attribute(element, kAXNumberOfCharactersAttribute) as? Int ?? 0
    }
}
