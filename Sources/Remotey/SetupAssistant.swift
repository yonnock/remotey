import AppKit

/// Gathers the facts for the setup checklist and runs its actions. Main thread only; whatever can hang
/// (Tailscale's tool, the self-test) runs on `background` and comes back through `main`.
///
/// It looks about once a second while something watches it (the checklist, a settings pane, an open
/// menu) and not at all otherwise.
final class SetupAssistant {
    /// Reads that are cheap and safe on the main thread. Pairing and the first move come from the server.
    struct Probes {
        var accessibility: () -> Bool = { Permissions.accessibility }
        var screenRecording: () -> Permissions.ScreenRecording = { Permissions.screenRecording }
        var loginItem: () -> LoginItem.State = { LoginItem.current }
        var paired: () -> Bool
        var moved: () -> Bool
    }

    /// What the actions do outside the model. The windows supply pairing.
    struct Effects {
        var open: (URL) -> Void = { NSWorkspace.shared.open($0) }
        var copy: (String) -> Void = {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString($0, forType: .string)
        }
        var showPairing: () -> Void
        var askForAccessibility: () -> Void = Permissions.askForAccessibility
        var askForScreenRecording: () -> Void = Permissions.askForScreenRecording
        var setLoginItem: (Bool) throws -> Void = LoginItem.set
        var openLoginItems: () -> Void = LoginItem.openSettings
    }

    static let interval: TimeInterval = 1

    private let probes: Probes
    private let effects: Effects
    private let tailscaleClient: TailscaleClient
    private let background: (@escaping () -> Void) -> Void
    private let main: (@escaping () -> Void) -> Void
    private let every: (TimeInterval, @escaping () -> Void) -> () -> Void

    private(set) var facts = Setup.Facts() {
        didSet { if facts != oldValue { changed?() } }
    }

    /// Called on the main thread whenever a row, the summary or what Tailscale says changes.
    var changed: (() -> Void)?

    private var watchers = 0
    private var stopTimer: (() -> Void)?
    private var looking = false
    /// Something changed while a look was out: that look may have seen the state before it.
    private var lookAgain = false
    /// Waits for the next look at Tailscale.
    private var launchChecks: [() -> Void] = []
    /// The name the last self-test was for: a new name tests again.
    private var testedHost: String?

    init(probes: Probes, effects: Effects, tailscale: TailscaleClient,
         background: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .userInitiated).async(execute: $0) },
         main: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
         every: @escaping (TimeInterval, @escaping () -> Void) -> () -> Void = SetupAssistant.timer) {
        self.probes = probes
        self.effects = effects
        tailscaleClient = tailscale
        self.background = background
        self.main = main
        self.every = every
    }

    var rows: [Setup.Row] { Setup.rows(facts) }
    var summary: Setup.Summary { Setup.summary(rows) }
    func row(_ item: Setup.Item) -> Setup.Row { Setup.row(item, facts) }

    /// This Mac's MagicDNS name, for the pairing link. Nil until Tailscale runs.
    var hostname: String? { facts.tailscale?.status?.dnsName }

    // MARK: Watching

    /// Starts looking once a second. Every `watch` needs its `unwatch`; the last one stops the looking.
    func watch() {
        watchers += 1
        guard watchers == 1 else { return }
        refresh()
        stopTimer = every(Self.interval) { [weak self] in self?.refresh() }
    }

    func unwatch() {
        guard watchers > 0 else { return }
        watchers -= 1
        guard watchers == 0 else { return }
        stopTimer?()
        stopTimer = nil
    }

    /// One look now. A look at Tailscale that is still out is not started twice.
    func refresh() {
        refreshLocal()
        lookAtTailscale()
    }

    /// Only the reads that are cheap on the main thread, not Tailscale: for the menu bar symbol, which follows
    /// the permissions while nothing watches.
    func refreshLocal() {
        var next = facts
        next.accessibility = probes.accessibility()
        next.screenRecording = probes.screenRecording()
        next.loginItem = probes.loginItem()
        next.paired = probes.paired()
        next.moved = probes.moved()
        facts = next
    }

    /// Looks once and says whether the assistant should open by itself.
    func launchCheck(firstStart: Bool, _ done: @escaping (Bool) -> Void) {
        launchChecks.append { [weak self] in done(Setup.shouldOpen(self?.rows ?? [], firstStart: firstStart)) }
        refresh()
    }

    private func lookAtTailscale() {
        guard !looking else {
            lookAgain = true
            return
        }
        looking = true
        lookAgain = false
        let client = tailscaleClient
        background { [weak self] in
            let snapshot = client.snapshot()
            self?.main { [weak self] in
                guard let self else { return }
                looking = false
                facts.tailscale = snapshot
                forgetFailuresThatAreOver()
                testIfDue()
                let checks = launchChecks
                launchChecks = []
                checks.forEach { $0() }
                if lookAgain { lookAtTailscale() }
            }
        }
    }

    /// A failure stays on its row until the state it failed to reach is there, by the assistant or otherwise.
    private func forgetFailuresThatAreOver() {
        if facts.tailscale?.status?.backend == .running {
            facts.failures[.logIn] = nil
            facts.failures[.turnOn] = nil
        }
        switch facts.tailscale?.serve?.mapping {
        case .ours?: facts.failures[.applyServe] = nil
        case .none?: facts.failures[.removeServe] = nil
        default: break
        }
    }

    // MARK: Self-test

    /// Once for every name the mapping is in place for, again after it was applied, and when asked.
    private func testIfDue() {
        guard let status = facts.tailscale?.status, status.backend == .running, let host = status.dnsName,
              facts.tailscale?.serve?.mapping == .ours, facts.funnelOff else {
            if facts.selfTest != .running { facts.selfTest = .notRun }
            testedHost = nil
            return
        }
        guard host != testedHost || facts.selfTest == .notRun else { return }
        selfTest(host)
    }

    private func selfTest(_ host: String) {
        guard facts.selfTest != .running else { return }
        testedHost = host
        facts.selfTest = .running
        let client = tailscaleClient
        background { [weak self] in
            let result = client.selfTest(host: host)
            self?.main { self?.facts.selfTest = .done(result) }
        }
    }

    // MARK: Actions

    func perform(_ action: Setup.Action) {
        switch action {
        case .askForAccessibility:
            facts.askedForAccessibility = true
            effects.askForAccessibility()
        case .askForScreenRecording:
            facts.askedForScreenRecording = true
            effects.askForScreenRecording()
        case .openSettings(let url), .open(let url), .openTailscale(let url):
            effects.open(url)
        case .copy(let command):
            effects.copy(command)
        case .turnOnTailscale:
            start(.turnOn) { client, _ in client.turnOn() }
        case .logIn:
            start(.logIn) { client, link in client.logIn(link: link) }
        case .applyServe:
            start(.applyServe) { client, link in client.applyServe(link: link) }
        case .removeServe:
            start(.removeServe) { client, _ in client.removeServe() }
        case .selfTest:
            if let host = hostname { selfTest(host) }
        case .showPairing:
            effects.showPairing()
        case .setLoginItem(let on):
            do {
                try effects.setLoginItem(on)
                facts.loginItemFailure = nil
            } catch {
                facts.loginItemFailure = "Ließ sich nicht ändern: \(error.localizedDescription)"
            }
            facts.loginItem = probes.loginItem()
        case .openLoginItems:
            effects.openLoginItems()
        }
    }

    /// One command that changes Tailscale at a time. The look afterwards shows what it did.
    private func start(_ operation: Setup.Operation,
                       _ command: @escaping (TailscaleClient, @escaping (URL) -> Void) -> Tailscale.Outcome) {
        guard facts.running == nil else { return }
        facts.failures[operation] = nil
        facts.running = Setup.Running(operation: operation)
        let client = tailscaleClient
        background { [weak self] in
            let link: (URL) -> Void = { url in
                self?.main { [weak self] in
                    guard let self, facts.running?.operation == operation else { return }
                    facts.running?.link = url
                }
            }
            let outcome = command(client, link)
            self?.main { [weak self] in
                guard let self else { return }
                facts.running = nil
                if case .failed(let reason) = outcome { facts.failures[operation] = reason }
                if operation == .applyServe || operation == .removeServe {
                    facts.selfTest = .notRun
                    testedHost = nil
                }
                lookAtTailscale()
            }
        }
    }

    static func timer(_ interval: TimeInterval, _ tick: @escaping () -> Void) -> () -> Void {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in tick() }
        // Also while a menu is open, which runs the loop in its own mode.
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
}

private extension Setup.Facts {
    var funnelOff: Bool { tailscale?.serve?.funnel == false }
}
