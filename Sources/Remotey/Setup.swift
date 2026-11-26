import Foundation

/// The setup checklist as values: what was found goes in (`Facts`), rows come out. No system call in here,
/// so every state of every row is a test. `SetupAssistant` gathers the facts and runs the actions.
enum Setup {
    enum Item: String, CaseIterable, Equatable {
        case accessibility, screenRecording, tailscale, https, serve, pairing, firstMove, loginItem

        var title: String {
            switch self {
            case .accessibility: return "Bedienungshilfen"
            case .screenRecording: return "Bildschirmaufnahme"
            case .tailscale: return "Tailscale"
            case .https: return "HTTPS im Tailnet"
            case .serve: return "Freigabe im Tailnet"
            case .pairing: return "iPhone koppeln"
            case .firstMove: return "Erste Bewegung vom iPhone"
            case .loginItem: return "Beim Anmelden starten"
            }
        }

        /// Without these the phone reaches nothing or moves nothing. The live view, the pairing, the first move
        /// and the login item are not: the assistant does not come back by itself for them after the first start.
        var required: Bool {
            switch self {
            case .accessibility, .tailscale, .https, .serve: return true
            case .screenRecording, .pairing, .firstMove, .loginItem: return false
            }
        }
    }

    enum State: Equatable {
        case ok
        case actionNeeded
        case working
        case failed
    }

    /// What a key on a row does. `SetupAssistant.perform` runs it.
    enum Action: Equatable {
        case askForAccessibility
        case askForScreenRecording
        case openSettings(URL)
        /// A web page: the download, a consent link, a login link, the tailnet's admin console.
        case open(URL)
        case openTailscale(URL)
        /// A command the person types in Terminal, since it needs their password.
        case copy(String)
        case turnOnTailscale
        case logIn
        case applyServe
        case removeServe
        case selfTest
        case showPairing
        case setLoginItem(Bool)
        case openLoginItems

        var title: String {
            switch self {
            case .askForAccessibility, .askForScreenRecording: return "Erlauben …"
            case .openSettings: return "Einstellungen öffnen"
            case .open: return "Im Browser öffnen"
            case .openTailscale: return "Tailscale öffnen"
            case .copy: return "Befehl kopieren"
            case .turnOnTailscale: return "Einschalten"
            case .logIn: return "Anmelden …"
            case .applyServe: return "Freigeben"
            case .removeServe: return "Freigabe entfernen"
            case .selfTest: return "Erneut prüfen"
            case .showPairing: return "QR-Code zeigen …"
            case .setLoginItem(let on): return on ? "Einschalten" : "Ausschalten"
            case .openLoginItems: return "Anmeldeobjekte öffnen"
            }
        }
    }

    struct Row: Equatable {
        var item: Item
        var state: State
        /// One sentence for a person: what is fine, or what is missing and what the key does about it.
        var detail: String
        var action: Action?

        var title: String { item.title }
    }

    /// A command that changes Tailscale and runs for a while.
    enum Operation: Equatable {
        case applyServe, removeServe, logIn, turnOn
    }

    struct Running: Equatable {
        var operation: Operation
        /// The page the tool printed and waits on: a consent for Serve, or the login.
        var link: URL?
    }

    enum SelfTest: Equatable {
        case notRun
        case running
        case done(Tailscale.SelfTest)
    }

    /// Everything the rows are made of.
    struct Facts: Equatable {
        var accessibility = false
        var screenRecording = Permissions.ScreenRecording(granted: false, preflight: false)
        /// Each permission's dialog comes once; after it, the key opens System Settings instead.
        var askedForAccessibility = false
        var askedForScreenRecording = false
        /// Nil until the first look at Tailscale is back.
        var tailscale: Tailscale.Snapshot?
        var running: Running?
        /// How the last command of each kind failed, until it runs again.
        var failures: [Operation: String] = [:]
        var selfTest: SelfTest = .notRun
        var paired = false
        var moved = false
        var loginItem: LoginItem.State = .off
        var loginItemFailure: String?
    }

    static func rows(_ facts: Facts) -> [Row] {
        Item.allCases.map { row($0, facts) }
    }

    static func row(_ item: Item, _ facts: Facts) -> Row {
        switch item {
        case .accessibility: return accessibility(facts)
        case .screenRecording: return screenRecording(facts)
        case .tailscale: return tailscale(facts)
        case .https: return https(facts)
        case .serve: return serve(facts)
        case .pairing: return pairing(facts)
        case .firstMove: return firstMove(facts)
        case .loginItem: return loginItem(facts)
        }
    }

    // MARK: Rows

    private static func accessibility(_ facts: Facts) -> Row {
        if facts.accessibility {
            return Row(item: .accessibility, state: .ok, detail: "Remotey darf Zeiger und Tasten bedienen.")
        }
        return Row(item: .accessibility, state: .actionNeeded,
                   detail: "Ohne diese Erlaubnis bewegt das iPhone nichts. In den Einstellungen Remotey einschalten.",
                   action: facts.askedForAccessibility ? .openSettings(Permissions.accessibilitySettings) : .askForAccessibility)
    }

    private static func screenRecording(_ facts: Facts) -> Row {
        // The server reads the grant the same way and starts the live view without a restart.
        if facts.screenRecording.granted {
            return Row(item: .screenRecording, state: .ok, detail: "Das iPhone kann den Bildschirm zeigen.")
        }
        return Row(item: .screenRecording, state: .actionNeeded,
                   detail: "Nur für das Live-Bild nötig. In den Einstellungen Remotey einschalten.",
                   action: facts.askedForScreenRecording ? .openSettings(Permissions.screenRecordingSettings) : .askForScreenRecording)
    }

    private static func tailscale(_ facts: Facts) -> Row {
        func row(_ state: State, _ detail: String, _ action: Action? = nil) -> Row {
            Row(item: .tailscale, state: state, detail: detail, action: action)
        }
        if let running = facts.running, running.operation == .logIn || running.operation == .turnOn {
            if let link = running.link {
                return row(.actionNeeded, "Die Anmeldung im Browser abschließen.", .open(link))
            }
            return row(.working, running.operation == .logIn ? "Anmeldung wird gestartet …" : "Tailscale wird eingeschaltet …")
        }
        guard let snapshot = facts.tailscale else { return row(.working, "Tailscale wird geprüft …") }
        switch snapshot {
        case .notInstalled:
            return row(.actionNeeded, "Tailscale ist nicht installiert. Es muss auf dem Mac und dem iPhone laufen.", .open(Tailscale.download))
        case .unreachable(let binary, _), .silent(let binary):
            let silent: Bool
            if case .silent = snapshot { silent = true } else { silent = false }
            if let app = binary.app {
                return row(silent ? .failed : .actionNeeded,
                           silent ? "Tailscale antwortet nicht." : "Tailscale läuft nicht.", .openTailscale(app))
            }
            if silent { return row(.failed, "Der Tailscale-Dienst antwortet nicht.", .copy("sudo brew services restart tailscale")) }
            return row(.actionNeeded, "Der Tailscale-Dienst läuft nicht. Im Terminal starten, er fragt nach dem Passwort.",
                       .copy("sudo brew services start tailscale"))
        case .connected(let binary, let status, _):
            if !status.supported {
                return row(.failed, "Tailscale \(status.version) ist zu alt, nötig ist 1.\(Tailscale.oldestSupported.minor) oder neuer.",
                           binary.app.map { .openTailscale($0) } ?? .copy("brew upgrade tailscale"))
            }
            switch status.backend {
            case .running:
                let who = status.loginName.map { " als \($0)" } ?? ""
                return row(.ok, "Angemeldet\(who).")
            case .starting:
                return row(.working, "Tailscale startet …")
            case .stopped:
                if let failure = facts.failures[.turnOn] { return row(.failed, failure, .turnOnTailscale) }
                return row(.actionNeeded, "Tailscale ist ausgeschaltet.", binary.app.map { .openTailscale($0) } ?? .turnOnTailscale)
            case .needsLogin:
                if let failure = facts.failures[.logIn] { return row(.failed, failure, .logIn) }
                if let link = status.authURL { return row(.actionNeeded, "Nicht bei Tailscale angemeldet.", .open(link)) }
                return row(.actionNeeded, "Nicht bei Tailscale angemeldet.", .logIn)
            case .needsMachineAuth:
                return row(.actionNeeded, "Der Mac wartet darauf, dass ihn die Verwaltung des Tailnets zulässt.", .open(Tailscale.machines))
            case .other(let state):
                return row(.failed, "Tailscale ist in einem unbekannten Zustand (\(state)).", binary.app.map { .openTailscale($0) })
            }
        }
    }

    /// Running, logged in and new enough: what the later rows need.
    private static func readyStatus(_ facts: Facts) -> Tailscale.Status? {
        guard let status = facts.tailscale?.status, status.backend == .running, status.supported else { return nil }
        return status
    }

    private static func https(_ facts: Facts) -> Row {
        if facts.tailscale == nil { return Row(item: .https, state: .working, detail: "Wartet auf Tailscale …") }
        guard let status = readyStatus(facts) else {
            return Row(item: .https, state: .actionNeeded, detail: "Erst Tailscale einrichten.")
        }
        guard status.dnsName != nil else {
            return Row(item: .https, state: .actionNeeded, detail: "MagicDNS ist im Tailnet aus. In der Verwaltung einschalten.",
                       action: .open(Tailscale.dnsSettings))
        }
        guard status.httpsEnabled else {
            return Row(item: .https, state: .actionNeeded,
                       detail: "HTTPS-Zertifikate sind im Tailnet aus. In der Verwaltung unter DNS einschalten.",
                       action: .open(Tailscale.dnsSettings))
        }
        return Row(item: .https, state: .ok, detail: "Zertifikate für \(status.dnsName ?? "") sind an.")
    }

    private static func serve(_ facts: Facts) -> Row {
        func row(_ state: State, _ detail: String, _ action: Action? = nil) -> Row {
            Row(item: .serve, state: state, detail: detail, action: action)
        }
        if facts.tailscale == nil { return row(.working, "Wartet auf Tailscale …") }
        guard let status = readyStatus(facts) else { return row(.actionNeeded, "Erst Tailscale einrichten.") }
        if let running = facts.running, running.operation == .applyServe || running.operation == .removeServe {
            if let link = running.link {
                return row(.actionNeeded, "Serve ist im Tailnet noch nicht erlaubt. Im Browser zustimmen, dann geht es von selbst weiter.",
                           .open(link))
            }
            return row(.working, running.operation == .applyServe ? "Wird freigegeben …" : "Freigabe wird entfernt …")
        }
        if let failure = facts.failures[.applyServe] { return row(.failed, failure, .applyServe) }
        if let failure = facts.failures[.removeServe] { return row(.failed, failure, .removeServe) }
        guard let serve = facts.tailscale?.serve else {
            return row(.failed, "Tailscale sagt nicht, was es freigibt.", .applyServe)
        }
        if serve.funnel {
            return row(.failed, "Funnel ist an: die Fernbedienung ist aus dem Internet erreichbar. Freigabe entfernen, dann neu freigeben.",
                       .removeServe)
        }
        switch serve.mapping {
        case .none:
            return row(.actionNeeded, "Noch nicht im Tailnet freigegeben.", .applyServe)
        case .elsewhere(let target):
            return row(.actionNeeded, "Port \(Tailscale.port) zeigt auf \(target). Freigeben stellt ihn auf Remotey um.", .applyServe)
        case .ours:
            guard let host = status.dnsName else { return row(.actionNeeded, "Erst MagicDNS einschalten.") }
            switch facts.selfTest {
            case .notRun, .running:
                return row(.working, "Prüft https://\(host):\(Tailscale.port) …")
            case .done(.answered):
                return row(.ok, "https://\(host):\(Tailscale.port) antwortet.")
            case .done(.inconclusive(let reason)):
                return row(.ok, reason, .selfTest)
            case .done(.failed(let reason)):
                return row(.failed, reason, .selfTest)
            }
        }
    }

    private static func pairing(_ facts: Facts) -> Row {
        if facts.paired { return Row(item: .pairing, state: .ok, detail: "Ein iPhone ist gekoppelt.") }
        guard row(.serve, facts).state == .ok else {
            return Row(item: .pairing, state: .actionNeeded, detail: "Erst die Freigabe im Tailnet einrichten.")
        }
        return Row(item: .pairing, state: .actionNeeded,
                   detail: "Den QR-Code mit der iPhone-Kamera scannen, Tailscale muss dort verbunden sein.", action: .showPairing)
    }

    private static func firstMove(_ facts: Facts) -> Row {
        if facts.moved { return Row(item: .firstMove, state: .ok, detail: "Das iPhone hat den Zeiger bewegt.") }
        guard facts.paired else { return Row(item: .firstMove, state: .actionNeeded, detail: "Erst ein iPhone koppeln.") }
        guard facts.accessibility else {
            return Row(item: .firstMove, state: .actionNeeded, detail: "Erst die Bedienungshilfen erlauben.")
        }
        return Row(item: .firstMove, state: .actionNeeded, detail: "Mit einem Finger über das iPhone streichen.")
    }

    private static func loginItem(_ facts: Facts) -> Row {
        if let failure = facts.loginItemFailure {
            return Row(item: .loginItem, state: .failed, detail: failure, action: .setLoginItem(facts.loginItem != .on))
        }
        switch facts.loginItem {
        case .on:
            return Row(item: .loginItem, state: .ok, detail: "Remotey startet mit der Anmeldung am Mac.", action: .setLoginItem(false))
        case .off:
            return Row(item: .loginItem, state: .actionNeeded, detail: "Remotey startet nicht von selbst.", action: .setLoginItem(true))
        case .needsApproval:
            return Row(item: .loginItem, state: .actionNeeded,
                       detail: "In den Einstellungen unter Anmeldeobjekte erlauben.", action: .openLoginItems)
        case .unavailable:
            return Row(item: .loginItem, state: .failed, detail: "Geht nur mit der installierten App.")
        }
    }

    // MARK: Summary

    /// One line for the menu.
    struct Summary: Equatable {
        var state: State
        var text: String
    }

    static func summary(_ rows: [Row]) -> Summary {
        let required = rows.filter(\.item.required)
        if let failed = required.first(where: { $0.state == .failed }) {
            return Summary(state: .failed, text: "\(failed.title): \(failed.detail)")
        }
        let open = required.filter { $0.state == .actionNeeded }
        if !open.isEmpty {
            return Summary(state: .actionNeeded, text: open.count == 1 ? "Einrichtung: 1 Schritt offen" : "Einrichtung: \(open.count) Schritte offen")
        }
        if required.contains(where: { $0.state == .working }) {
            return Summary(state: .working, text: "Wird geprüft …")
        }
        return Summary(state: .ok, text: "Bereit")
    }

    /// The assistant opens by itself on the first start, and whenever a row that must be green is not.
    /// A row still at work does not count: it may turn green a moment later.
    static func shouldOpen(_ rows: [Row], firstStart: Bool) -> Bool {
        firstStart || rows.contains { $0.item.required && ($0.state == .actionNeeded || $0.state == .failed) }
    }
}
