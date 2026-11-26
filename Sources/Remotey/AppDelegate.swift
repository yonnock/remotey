import AppKit
import Combine

/// Wires the server and the setup assistant to the Mac's interface: the status item with its panel, the setup
/// assistant and the settings. All of them show `MacModel.state`, which this keeps current.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let input = Input()
    private lazy var server: Server = {
        let loaded = Token.load()
        tokenProblem = loaded.failure.map { Texts.Problem.tokenNotSaved("\($0)") }
        return Server(token: loaded.token, input: input)
    }()
    /// The token in use is not the one in the file, or there is none: the menu says so.
    private var tokenProblem: String?
    /// `pkill` and Control-C end the agent with a signal, on which AppKit does not call `applicationWillTerminate`.
    private var signals: [DispatchSourceSignal] = []
    private var statusItem: NSStatusItem!
    private var look: MacState.Look?
    private var timers: [Timer] = []
    private var problems: AnyCancellable?

    private lazy var assistant = SetupAssistant(
        probes: .init(paired: { [unowned self] in server.isPaired }, moved: { [unowned self] in server.hasMoved }),
        effects: .init(showPairing: { [unowned self] in showAssistant(at: .pair) }),
        tailscale: TailscaleCLI(pagePort: Int(Server.port), page: { Web.file("index.html")?.body }))
    private lazy var model = MacModel(state: currentState(), actions: actions())
    private lazy var flow = AssistantFlow(
        pairer: .init(open: { [unowned self] in server.openPairing() }, close: { [unowned self] in server.closePairing() }),
        state: { [unowned self] in model.state }, perform: { [unowned self] in assistant.perform($0) })
    private lazy var menu = MenuPresenter(model: model)
    private lazy var assistantWindow = AssistantWindow(model: model, flow: flow)
    private lazy var settingsWindow = SettingsWindow(model: model)
    private lazy var faceUnlockWindow = FaceUnlockWindow(server: server)

    /// Set once the assistant has opened on a first start.
    private static let setUpKey = "assistantShown"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        NSApp.applicationIconImage = Logo.icon()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggleMenu(_:))
        // On the press, as a menu opens, not on the release.
        statusItem.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])

        endOnSignals()
        // A window the last run left in the phone's shape, when it crashed or was killed.
        ShapedFrame.restore()
        wire()
        update()
        do {
            try server.start()
        } catch {
            let alert = NSAlert()
            alert.messageText = Texts.Problem.couldNotStart
            alert.informativeText = Texts.Problem.ports(Server.port, error.localizedDescription)
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            NSApp.terminate(nil)
        }
        let firstStart = !UserDefaults.standard.bool(forKey: Self.setUpKey)
        assistant.launchCheck(firstStart: firstStart) { [weak self] open in
            guard let self, open else { return }
            UserDefaults.standard.set(true, forKey: Self.setUpKey)
            showAssistant(at: .prepare, firstStart: firstStart)
        }
        // While nothing watches, the symbol still follows the permissions, and Tailscale now and then.
        timers = [
            Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.assistant.refreshLocal() },
            Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.assistant.refresh() },
        ]
    }

    /// Leaves the Mac as it was: a window that took the phone's shape for the live view gets its frame back.
    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
    }

    /// Ends the agent in order on SIGTERM and SIGINT, so the window in the phone's shape gets its frame back.
    private func endOnSignals() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN) // else the default action ends the process before the source hears it
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signals.append(source)
        }
    }

    // MARK: State

    private func wire() {
        server.healthChanged = { [weak self] _ in self?.update() }
        server.devicesChanged = { [weak self] in self?.update() }
        server.sessionsChanged = { [weak self] sessions in
            self?.update()
            self?.flow.sessions(sessions)
        }
        server.pairingChanged = { [weak self] change in
            self?.update()
            self?.flow.pairing(change)
        }
        server.firstMove = { [weak self] device in self?.flow.firstMove(by: device) }
        assistant.changed = { [weak self] in
            guard let self else { return }
            // Whose phones may connect through `tailscale serve`: unknown until Tailscale answers.
            if let status = assistant.facts.tailscale?.status { server.owner = status.loginName }
            update()
        }
        faceUnlockWindow.changed = { [weak self] in self?.update() }
        // The assistant looks once a second while any of these shows.
        menu.opened = { [weak self] in
            self?.update()
            self?.assistant.watch()
        }
        menu.closed = { [weak self] in self?.assistant.unwatch() }
        assistantWindow.opened = { [weak self] in self?.assistant.watch() }
        assistantWindow.closed = { [weak self] in self?.assistant.unwatch() }
        settingsWindow.opened = { [weak self] in self?.assistant.watch() }
        settingsWindow.closed = { [weak self] in self?.assistant.unwatch() }
        problems = model.$problem.compactMap { $0 }.sink { [weak self] problem in
            // After the value is set: `sink` hears it before.
            DispatchQueue.main.async { self?.show(problem) }
        }
    }

    private func currentState() -> MacState {
        MacState(health: server.health, paused: server.paused, sessions: server.sessions, devices: server.devices,
                 acceptsToken: server.acceptsToken, faceUnlock: server.unlocksWithFaceID, facts: assistant.facts,
                 tokenProblem: tokenProblem)
    }

    private func update() {
        let state = currentState()
        if state != model.state { model.state = state }
        model.now = Date()
        flow.stateChanged()
        let look = state.look
        guard look != self.look else { return }
        self.look = look
        statusItem?.button?.image = StatusSymbol.image(look)
        statusItem?.button?.setAccessibilityLabel(look.label)
        statusItem?.button?.toolTip = look.label
    }

    // MARK: Actions

    private func actions() -> MacModel.Actions {
        MacModel.Actions(
            setPaused: { [unowned self] in try server.setPaused($0) },
            end: { [unowned self] in server.end($0) },
            perform: { [unowned self] in assistant.perform($0) },
            addPhone: { [unowned self] in showAssistant(at: .pair) },
            openAssistant: { [unowned self] in showAssistant(at: .prepare) },
            setUpFaceUnlock: { [unowned self] in faceUnlockWindow.show() },
            removeFaceUnlock: { [unowned self] in
                server.removeFaceUnlock()
                update()
            },
            openSettings: { [unowned self] in settingsWindow.show($0) },
            quit: { NSApp.terminate(nil) },
            rename: { [unowned self] in try server.rename($0, to: $1) },
            revoke: { [unowned self] in try server.revoke($0) },
            disconnectAll: { [unowned self] in try disconnectAll() },
            setAcceptsToken: { [unowned self] in try server.setAcceptsToken($0) },
            closeMenu: { [unowned self] in menu.close() })
    }

    /// A new shared token and no paired device: every phone is out until it pairs again.
    private func disconnectAll() throws {
        do {
            server.token = try Token.rotate()
            tokenProblem = nil
        } catch {
            // The old token is still in the file, so it stays: a new one would be lost with the next start.
            throw Token.WriteFailure(description: "\(error). \(Texts.Problem.tokenNotRenewed)")
        }
        try server.revokeAllDevices()
        update()
    }

    @objc private func toggleMenu(_ sender: NSStatusBarButton) {
        menu.toggle(below: sender)
    }

    @objc func showSettings(_ sender: Any?) {
        menu.close()
        settingsWindow.show()
    }

    private func showAssistant(at phase: AssistantFlow.Phase, firstStart: Bool = false) {
        menu.close()
        assistantWindow.show(at: phase, firstStart: firstStart)
    }

    /// A key that did not do what it said: on the window it came from, else on its own.
    private func show(_ problem: MacModel.Problem) {
        guard model.problem == problem else { return }
        model.problem = nil
        let alert = NSAlert()
        alert.messageText = problem.title
        alert.informativeText = problem.text
        if let window = [settingsWindow.window, assistantWindow.window].compactMap({ $0 }).first(where: \.isKeyWindow) {
            alert.beginSheetModal(for: window)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
