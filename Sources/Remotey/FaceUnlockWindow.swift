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

    private let server: Server
    private(set) var window: NSWindow?
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let text = NSTextField(wrappingLabelWithString: "")
    private let field = NSSecureTextField()
    private let problem = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let cancel = NSButton(title: "Abbrechen", target: nil, action: nil)
    private let proceed = NSButton(title: "Weiter", target: nil, action: nil)
    private lazy var buttons = NSStackView(views: [cancel, proceed])
    private lazy var content = NSStackView(views: [icon, title, text, field, problem, spinner, buttons])
    private var step = Step.password()
    private static let width: CGFloat = 300

    /// How long the window says that the phone is enrolled before it closes.
    static let farewell: TimeInterval = 2.5

    init(server: Server) {
        self.server = server
        super.init()
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.alignment = .center
        text.font = .systemFont(ofSize: 12)
        text.textColor = .secondaryLabelColor
        text.alignment = .center
        field.placeholderString = "Passwort dieses Macs"
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width + 48, height: 260),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Entsperren mit Face ID"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = content
        self.window = window
        field.stringValue = ""
        set(.password())
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Shows `step`: only what it needs, in a window that is as tall as that.
    func set(_ step: Step) {
        self.step = step
        let done = step == .done
        let symbol = NSImage(systemSymbolName: done ? "checkmark.circle.fill" : "faceid", accessibilityDescription: nil)
        icon.image = symbol?.withSymbolConfiguration(.init(pointSize: 42, weight: .regular))
        icon.contentTintColor = done ? .systemGreen : .controlAccentColor
        switch step {
        case .password(let why):
            title.stringValue = "Entsperren mit Face ID"
            text.stringValue = "Das iPhone bekommt einen Passkey, und das Passwort dieses Macs wird damit verschlüsselt abgelegt: "
                + "ohne Face ID am iPhone ist es nicht zu lesen. Den Mac entsperrt dann, wer das iPhone entsperren kann."
            problem.stringValue = why ?? ""
        case .waiting:
            title.stringValue = "Warte auf das iPhone"
            text.stringValue = "Öffne Remotey am iPhone und tippe dort auf „Einrichten“. Das Angebot gilt zwei Minuten."
        case .done:
            title.stringValue = "Eingerichtet"
            text.stringValue = "Ist der Mac gesperrt, entsperrt ihn „Entsperren…“ am iPhone mit Face ID."
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
        guard Self.isPassword(password) else { return set(.password(problem: "Das ist nicht das Passwort dieses Macs.")) }
        set(.waiting)
        server.offerFaceUnlock(password: password) { [weak self] enrolled in
            guard let self else { return }
            guard enrolled else { return self.set(.password(problem: "Die Zeit ist um, nichts wurde eingerichtet.")) }
            self.set(.done)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.farewell) { [weak self] in
                if self?.step == .done { self?.window?.close() }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        field.stringValue = ""
        server.withdrawFaceUnlock()
    }

    /// Whether `password` is the password of the user this runs as. True as well where the directory
    /// cannot be asked: the lock screen will tell.
    static func isPassword(_ password: String) -> Bool {
        guard let node = try? ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication)),
              let record = try? node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil) else {
            return true
        }
        return (try? record.verifyPassword(password)) != nil
    }
}
