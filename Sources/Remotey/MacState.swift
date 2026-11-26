import Foundation

/// What the menu, the assistant and the settings show, as one value: the server's state and the setup
/// checklist's facts. The views read it and nothing else, so a picture of them needs no server and no Tailscale.
struct MacState: Equatable {
    var health: Server.Health = .starting
    var port: UInt16 = Server.port
    var paused = false
    var sessions: [Server.Session] = []
    var devices: [Device] = []
    var acceptsToken = false
    var faceUnlock = false
    var facts = Setup.Facts()
    /// The token in use is not the one in the file, or there is none.
    var tokenProblem: String?

    func row(_ item: Setup.Item) -> Setup.Row { Setup.row(item, facts) }
    var rows: [Setup.Row] { Setup.rows(facts) }
    /// This Mac's MagicDNS name, once Tailscale said it.
    var hostname: String? { facts.tailscale?.status?.dnsName }
    /// Whose phones `tailscale serve` lets through.
    var owner: String? { facts.tailscale?.status?.loginName }
    var address: String? {
        guard row(.serve).state == .ok, let hostname else { return nil }
        return "https://\(hostname):\(Tailscale.port)"
    }
    /// What the phone needs before it can pair: the page is reachable in the tailnet.
    var readyToPair: Bool { health == .listening && address != nil }

    func session(of device: Device.ID) -> Server.Session? { sessions.first { $0.device == device } }
}

// MARK: Menu bar symbol

extension MacState {
    /// The status item at a glance: a phone connected, remote control paused, something wrong.
    struct Look: Equatable {
        var connected = false
        var paused = false
        var problem = false
    }

    /// Wrong is what keeps a phone out or still: the ports, a required permission or Tailscale row. A row that is
    /// still checking is not, as the assistant does not open for it either.
    var look: Look {
        var problem = Setup.shouldOpen(rows, firstStart: false)
        if case .failed = health { problem = true }
        return Look(connected: !sessions.isEmpty, paused: paused, problem: problem)
    }
}

extension MacState.Look {
    var symbol: String { paused ? "cursorarrow.slash" : connected ? "cursorarrow.rays" : "cursorarrow" }

    var label: String {
        if problem { return Texts.Menu.symbolProblem }
        if paused { return Texts.Menu.symbolPaused }
        return connected ? Texts.Menu.symbolConnected : Texts.Menu.symbolIdle
    }
}

// MARK: Menu

/// A line of the menu's status section.
struct StatusLine: Equatable, Identifiable {
    enum Kind: String { case health, token, accessibility, screenRecording, tailscale }
    enum Fix: Equatable {
        case perform(Setup.Action)
        case assistant
    }

    var kind: Kind
    var title: String
    var subtitle: String?
    var state: Setup.State
    /// What a click does. Nil for a line that is fine, or that only waits.
    var fix: Fix?

    var id: Kind { kind }
    var symbol: String {
        switch kind {
        case .health: return "exclamationmark.triangle"
        case .token: return "key"
        case .accessibility: return "hand.raised"
        case .screenRecording: return "display"
        case .tailscale: return "network"
        }
    }
}

extension MacState {
    var statusLines: [StatusLine] {
        var lines: [StatusLine] = []
        if case .failed(let reason) = health {
            lines.append(StatusLine(kind: .health, title: Texts.Menu.unreachable, subtitle: reason, state: .failed))
        }
        if let tokenProblem {
            lines.append(StatusLine(kind: .token, title: Texts.Menu.tokenNotSaved, subtitle: tokenProblem, state: .failed))
        }
        let accessibility = row(.accessibility)
        lines.append(StatusLine(kind: .accessibility, title: Texts.Menu.accessibility,
                                subtitle: accessibility.state == .ok ? nil : Texts.Menu.notAllowed,
                                state: accessibility.state, fix: accessibility.action.map { .perform($0) }))
        let screen = row(.screenRecording)
        lines.append(StatusLine(kind: .screenRecording, title: Texts.Menu.screenRecording,
                                subtitle: screen.state == .ok ? nil : Texts.Menu.onlyLiveView,
                                state: screen.state, fix: screen.action.map { .perform($0) }))
        lines.append(tailscaleLine)
        return lines
    }

    /// Tailscale, HTTPS and the mapping as one line: the first that is not fine speaks for all three.
    private var tailscaleLine: StatusLine {
        let rows = [Setup.Item.tailscale, .https, .serve].map(row)
        let worst = rows.first { $0.state == .failed } ?? rows.first { $0.state == .actionNeeded } ?? rows.first { $0.state == .working }
        guard let worst else {
            return StatusLine(kind: .tailscale, title: Texts.Menu.tailscale, subtitle: hostname, state: .ok)
        }
        let subtitle: String
        if worst.state == .working {
            subtitle = Texts.Menu.checking
        } else {
            switch worst.item {
            case .https: subtitle = Texts.Menu.httpsOff
            case .serve: subtitle = facts.tailscale?.serve?.funnel == true ? Texts.Menu.funnel : Texts.Menu.notShared
            default: subtitle = Texts.Menu.tailscaleOff
            }
        }
        return StatusLine(kind: .tailscale, title: Texts.Menu.tailscale, subtitle: subtitle, state: worst.state,
                          fix: worst.state == .working ? nil : .assistant)
    }

    /// The name of a connected phone; the old token has none.
    static func name(of session: Server.Session) -> String { session.name ?? Texts.Menu.sharedKey }

    func subtitle(of session: Server.Session) -> String {
        if paused { return Texts.Menu.connectedPaused }
        return session.watches ? Texts.Menu.connectedLive : Texts.Menu.connected
    }

    /// The device's symbol by its name, which comes from the browser: "iPhone", "iPad", or what the user chose.
    static func symbol(forDevice name: String?) -> String {
        guard let name else { return "globe" }
        if name.localizedCaseInsensitiveContains("ipad") { return "ipad" }
        if name.localizedCaseInsensitiveContains("mac") || name.localizedCaseInsensitiveContains("browser") { return "desktopcomputer" }
        return "iphone"
    }
}

// MARK: Settings

extension MacState {
    /// The line under a paired device: connected since when, else when it was last seen.
    func subtitle(of device: Device, now: Date, calendar: Calendar = Calendar.current) -> String {
        if let session = session(of: device.id) {
            let since = Texts.Settings.connectedSince(Self.time(session.since, calendar: calendar))
            return session.watches ? "\(since) · \(Texts.Settings.liveView)" : since
        }
        if let seen = device.seen { return Texts.Settings.lastSeen(Self.day(seen, now: now, calendar: calendar)) }
        return Texts.Settings.pairedOn(Self.day(device.paired, now: now, calendar: calendar))
    }

    /// "14:31".
    static func time(_ date: Date, calendar: Calendar = .current) -> String {
        formatter("HH:mm", calendar).string(from: date)
    }

    /// "heute, 14:31", "gestern, 21:07", "3. Nov., 21:07", and with the year once it is another.
    static func day(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = time(date, calendar: calendar)
        if calendar.isDate(date, inSameDayAs: now) { return "\(Texts.Settings.today), \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "\(Texts.Settings.yesterday), \(time)"
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return formatter(sameYear ? "d. MMM, HH:mm" : "d. MMM yyyy, HH:mm", calendar).string(from: date)
    }

    private static func formatter(_ format: String, _ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Texts.locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter
    }

    var healthText: String {
        switch health {
        case .starting: return Texts.Settings.starting
        case .listening: return Texts.Settings.listening(port)
        case .failed(let reason): return Texts.Settings.failed(reason)
        }
    }
}
