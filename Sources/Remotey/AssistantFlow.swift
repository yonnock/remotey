import Combine
import Foundation

/// Where the setup assistant is, and the pairing in it: the Mac's checklist first, then the code for the phone,
/// the first move from it and the step to the Home Screen. Each step moves on by itself when the server says
/// it is done. The offer is open only while its step shows; leaving the step or the window closes it.
final class AssistantFlow: ObservableObject {
    enum Phase: Int, CaseIterable, Comparable {
        case prepare, pair, move, homeScreen

        static func < (a: Phase, b: Phase) -> Bool { a.rawValue < b.rawValue }
    }

    /// The code on show.
    enum Code: Equatable {
        /// Tailscale or the ports are not ready: a link would lead nowhere.
        case unavailable
        case open(Pairing.Offer, link: String)
        case expired
        /// Too many wrong digits.
        case tries
    }

    /// The server's pairing, as far as the assistant uses it.
    struct Pairer {
        var open: () -> Pairing.Offer
        var close: () -> Void
    }

    @Published private(set) var phase = Phase.prepare
    @Published private(set) var code: Code?
    /// The phone paired in this run of the assistant.
    @Published private(set) var device: Device?
    @Published private(set) var moved = false
    @Published private(set) var onHomeScreen = false

    private let pairer: Pairer
    /// The Mac's state, read whenever the assistant decides.
    private let state: () -> MacState
    private let perform: (Setup.Action) -> Void
    /// The login item was offered once in this run; the box then shows what is.
    private var offeredLoginItem = false

    init(pairer: Pairer, state: @escaping () -> MacState, perform: @escaping (Setup.Action) -> Void) {
        self.pairer = pairer
        self.state = state
        self.perform = perform
    }

    /// Opens at `phase`, or at the checklist while something there keeps a phone from pairing. On the first
    /// start the login item is switched on, ticked, so a person who wants it does nothing.
    func start(at phase: Phase, firstStart: Bool = false) {
        device = nil
        moved = false
        onHomeScreen = false
        if firstStart, !offeredLoginItem {
            offeredLoginItem = true
            if state().facts.loginItem == .off { perform(.setLoginItem(true)) }
        }
        go(phase > .prepare && !state().readyToPair ? .prepare : phase)
    }

    /// The window closed: its code goes with it.
    func stop() {
        closeCode()
    }

    var canGoOn: Bool {
        switch phase {
        case .prepare: return state().readyToPair
        case .pair: return device != nil
        case .move, .homeScreen: return true
        }
    }

    /// Weiter. Nil once the last step is done: the window closes then.
    @discardableResult
    func next() -> Phase? {
        guard canGoOn else { return phase }
        guard let following = Phase(rawValue: phase.rawValue + 1) else {
            closeCode()
            return nil
        }
        // A phone that paired here goes on from where it is; one that did not, pairs first.
        go(following == .pair && device != nil ? .move : following)
        return phase
    }

    func back() {
        switch phase {
        case .prepare: return
        case .pair, .move: go(.prepare)
        case .homeScreen: go(.move)
        }
    }

    /// A new code in place of one that expired or was guessed at too often.
    func renewCode() {
        guard phase == .pair || phase == .homeScreen else { return }
        openCode()
    }

    private func go(_ phase: Phase) {
        self.phase = phase
        switch phase {
        case .prepare, .move:
            closeCode()
        case .pair:
            device = nil
            moved = false
            openCode()
        case .homeScreen:
            // A Home Screen app may not share Safari's cookie: then it asks for the digits.
            openCode()
        }
    }

    private func openCode() {
        let state = state()
        guard state.readyToPair, let host = state.hostname else {
            closeCode()
            code = .unavailable
            return
        }
        // Opening tells the Mac, which tells the assistant again: no code is waiting then, so none opens twice.
        code = nil
        let offer = pairer.open()
        code = .open(offer, link: Pairing.link(host: host, code: offer.code))
    }

    private func closeCode() {
        if case .open = code { pairer.close() }
        code = nil
    }

    // MARK: What the server says

    /// The checklist changed: a code that waited for Tailscale comes now.
    func stateChanged() {
        if code == .unavailable, state().readyToPair { openCode() }
    }

    func pairing(_ change: Server.PairingState) {
        switch change {
        case .open: return
        case .paired(let device):
            guard phase == .pair || phase == .homeScreen else { return }
            // The offer is spent.
            code = nil
            if phase == .pair {
                self.device = device
                go(.move)
            }
        case .expired: if case .open = code { code = .expired }
        case .tries: if case .open = code { code = .tries }
        case .closed: if case .open = code { code = nil }
        }
    }

    func firstMove(by device: Device.ID?) {
        guard phase >= .move, let device, device == self.device?.id else { return }
        moved = true
    }

    func sessions(_ sessions: [Server.Session]) {
        guard phase == .homeScreen else { return }
        if sessions.contains(where: { $0.standalone && $0.device != nil }) {
            onHomeScreen = true
            closeCode()
        }
    }
}
