import AppKit
import OpenDirectory

/// Enrols a phone for unlocking with Face ID, at the Mac: its user types the Mac's password here, then the
/// phone makes its passkey. The window says which step it is at and closes itself once the phone is
/// enrolled. Closing it ends the offer.
final class FaceUnlockWindow: NSObject, NSWindowDelegate {
    enum Step: Equatable {
        /// Asks for the Mac's password. `problem`: why the last try came to nothing.
        case password(problem: String? = nil)
        /// The offer stands and the phone has not answered.
        case waiting
        case done
    }

    /// What the directory says about a password.
    enum Verdict: Equatable {
        case right, wrong
        /// It could not be asked, or it gave another answer than yes or no.
        case unknown
    }

    /// What a password typed into the window leads to.
    enum Outcome: Equatable {
        case seal
        case refuse(String)
        /// Unchecked: typed once more, it is sealed if both are the same.
        case confirm
    }

    private let server: Server
    private let check: (String) -> Verdict
    /// The first entry of a password the directory could not check, until it is typed again.
    private var unconfirmed: String?
    private(set) var window: NSWindow?
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let text = NSTextField(wrappingLabelWithString: "")
    private let field = NSSecureTextField()
    private let problem = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let cancel = NSButton(title: Texts.FaceUnlock.cancel, target: nil, action: nil)
    private let proceed = NSButton(title: Texts.FaceUnlock.proceed, target: nil, action: nil)
    private lazy var buttons = NSStackView(views: [cancel, proceed])
    private lazy var content = NSStackView(views: [icon, title, text, field, problem, spinner, buttons])
    private var step = Step.password()
    private static let width: CGFloat = 300

    /// How long the window says that the phone is enrolled before it closes.
    static let farewell: TimeInterval = 2.5

    /// Hears when a phone was enrolled and when the window closed: the menu and the settings show the state.
    var changed: (() -> Void)?

    init(server: Server, check: @escaping (String) -> Verdict = FaceUnlockWindow.verdict) {
        self.server = server
        self.check = check
        super.init()
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.alignment = .center
        text.font = .systemFont(ofSize: 12)
        text.textColor = .secondaryLabelColor
        text.alignment = .center
        field.placeholderString = Texts.FaceUnlock.password
        field.controlSize = .large
        field.target = self
        field.action = #selector(offer)
        problem.font = .systemFont(ofSize: 12)
        problem.textColor = .systemRed
        problem.alignment = .center
        spinner.style = .spinning
        spinner.controlSize = .small
        for (button, action) in [(cancel, #selector(close)), (proceed, #selector(offer))] {
            button.target = self
            button.action = action
            button.controlSize = .large
            button.bezelStyle = .rounded
        }
        cancel.keyEquivalent = "\u{1b}"
        proceed.keyEquivalent = "\r"
        // The main action in Remotey's accent, as in the assistant.
        proceed.bezelColor = Accent.nsColor
        buttons.distribution = .fillEqually
        buttons.spacing = 10
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 10
        content.setCustomSpacing(14, after: icon)
        content.setCustomSpacing(16, after: text)
        // Under a title bar without a title, as an alert stands.
        content.edgeInsets = NSEdgeInsets(top: 44, left: 24, bottom: 22, right: 24)
        for view in [title, text, field, problem, buttons] { view.widthAnchor.constraint(equalToConstant: Self.width).isActive = true }
    }

    func show() {
        window?.close()
        let window = makeWindow()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// The window at its first step, not yet on screen.
    @discardableResult
    func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width + 48, height: 260),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = Texts.FaceUnlock.title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = content
        self.window = window
        field.stringValue = ""
        unconfirmed = nil
        set(.password())
        return window
    }

    /// Shows `step`: only what it needs, in a window that is as tall as that.
    func set(_ step: Step) {
        self.step = step
        let done = step == .done
        let symbol = NSImage(systemSymbolName: done ? "checkmark.circle.fill" : "faceid", accessibilityDescription: nil)
        icon.image = symbol?.withSymbolConfiguration(.init(pointSize: 42, weight: .regular))
        icon.contentTintColor = done ? .systemGreen : Accent.nsColor
        switch step {
        case .password(let why):
            title.stringValue = Texts.FaceUnlock.title
            text.stringValue = Texts.FaceUnlock.intro
            problem.stringValue = why ?? ""
        case .waiting:
            title.stringValue = Texts.FaceUnlock.waitingTitle
            text.stringValue = Texts.FaceUnlock.waiting
        case .done:
            title.stringValue = Texts.FaceUnlock.doneTitle
            text.stringValue = Texts.FaceUnlock.done
        }
        var asks = false, problemShown = false
        if case .password(let why) = step { (asks, problemShown) = (true, why != nil) }
        field.isHidden = !asks
        problem.isHidden = !problemShown
        proceed.isHidden = !asks
        buttons.isHidden = done
        spinner.isHidden = step != .waiting
        if step == .waiting { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        guard let window else { return }
        // The top edge stays where it is; the window grows and shrinks at its bottom.
        content.layoutSubtreeIfNeeded()
        let top = window.frame.maxY
        window.setContentSize(content.fittingSize)
        window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top))
        if asks { window.makeFirstResponder(field) }
    }

    @objc private func close() {
        window?.close()
    }

    @objc private func offer() {
        let password = field.stringValue
        guard case .password = step, !password.isEmpty else { return }
        field.stringValue = ""
        // A typo would be sealed and typed into the lock screen at every unlock.
        let earlier = unconfirmed
        unconfirmed = nil
        switch Self.judge(password, verdict: earlier == nil ? check(password) : .unknown, earlier: earlier) {
        case .refuse(let why): return set(.password(problem: why))
        case .confirm:
            unconfirmed = password
            field.placeholderString = Texts.FaceUnlock.passwordAgain
            return set(.password(problem: Self.unchecked))
        case .seal: break
        }
        field.placeholderString = Texts.FaceUnlock.password
        set(.waiting)
        server.offerFaceUnlock(password: password) { [weak self] enrolled in
            guard let self else { return }
            guard enrolled else { return self.set(.password(problem: Texts.FaceUnlock.timeUp)) }
            self.set(.done)
            self.changed?()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.farewell) { [weak self] in
                if self?.step == .done { self?.window?.close() }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        field.stringValue = ""
        unconfirmed = nil
        field.placeholderString = Texts.FaceUnlock.password
        server.withdrawFaceUnlock()
        changed?()
    }

    static let unchecked = Texts.FaceUnlock.unchecked

    /// What `password` leads to. `earlier` is its first entry, where the directory could not check it: a typo
    /// is then caught by comparing, as a new password is set. A password that is consistently wrong gets
    /// through that way; the lock screen refuses it, and twice refused it is deleted (`FaceUnlock`).
    static func judge(_ password: String, verdict: Verdict, earlier: String?) -> Outcome {
        if let earlier { return password == earlier ? .seal : .refuse(Texts.FaceUnlock.different) }
        return switch verdict {
        case .right: .seal
        case .wrong: .refuse(Texts.FaceUnlock.wrong)
        case .unknown: .confirm
        }
    }

    /// Asks the directory whether `password` is the password of the user this runs as.
    static func verdict(_ password: String) -> Verdict {
        guard let node = try? ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication)),
              let record = try? node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil) else {
            return .unknown
        }
        do {
            try record.verifyPassword(password)
            return .right
        } catch {
            return verdict(error)
        }
    }

    /// Only "credentials invalid" says that the password is wrong. Anything else (an account locked after
    /// too many tries, a directory that does not answer) says nothing about it.
    static func verdict(_ error: Error) -> Verdict {
        let error = error as NSError
        return error.domain == ODFrameworkErrorDomain && error.code == Int(kODErrorCredentialsInvalid.rawValue) ? .wrong : .unknown
    }
}
