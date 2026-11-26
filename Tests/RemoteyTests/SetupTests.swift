import XCTest
@testable import Remotey

/// The checklist from facts alone: every row's state, sentence and key.
final class SetupTests: XCTestCase {
    static let brew = Tailscale.Binary(path: "/opt/homebrew/bin/tailscale", app: nil)
    static let app = Tailscale.Binary(path: "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
                                      app: URL(fileURLWithPath: "/Applications/Tailscale.app"))
    static let host = "werkbank.tail0000.ts.net"
    static let status = Tailscale.Status(backend: .running, version: "1.104.7", dnsName: host, loginName: "kim@example.com",
                                         certDomains: [host], authURL: nil)

    /// Everything green.
    static func ready() -> Setup.Facts {
        var facts = Setup.Facts()
        facts.accessibility = true
        facts.screenRecording = .init(granted: true, preflight: true)
        facts.tailscale = .connected(brew, status, .init(mapping: .ours, funnel: false))
        facts.selfTest = .done(.answered)
        facts.paired = true
        facts.moved = true
        facts.loginItem = .on
        return facts
    }

    private func row(_ item: Setup.Item, _ change: (inout Setup.Facts) -> Void) -> Setup.Row {
        var facts = Self.ready()
        change(&facts)
        return Setup.row(item, facts)
    }

    private func status(_ change: (inout Tailscale.Status) -> Void) -> Tailscale.Status {
        var status = Self.status
        change(&status)
        return status
    }

    func testAllGreenIsReadyAndStaysClosed() {
        let rows = Setup.rows(Self.ready())
        XCTAssertEqual(rows.map(\.item), Setup.Item.allCases)
        XCTAssertEqual(rows.filter { $0.state != .ok }, [])
        XCTAssertEqual(Setup.summary(rows), .init(state: .ok, text: "Bereit"))
        XCTAssertFalse(Setup.shouldOpen(rows, firstStart: false))
        XCTAssertTrue(Setup.shouldOpen(rows, firstStart: true), "the first start always opens it")
        XCTAssertEqual(Setup.row(.tailscale, Self.ready()).detail, "Angemeldet als kim@example.com.")
        XCTAssertEqual(Setup.row(.serve, Self.ready()).detail, "https://werkbank.tail0000.ts.net:8443 antwortet.")
    }

    // MARK: Permissions

    func testAccessibilityAsksOnceThenOpensSettings() {
        XCTAssertEqual(row(.accessibility) { $0.accessibility = false }.action, .askForAccessibility)
        let asked = row(.accessibility) {
            $0.accessibility = false
            $0.askedForAccessibility = true
        }
        XCTAssertEqual(asked.state, .actionNeeded)
        XCTAssertEqual(asked.action, .openSettings(Permissions.accessibilitySettings))
        XCTAssertNil(Setup.row(.accessibility, Self.ready()).action, "a green row has nothing to do")
    }

    func testScreenRecordingAsksOnceThenOpensSettingsAndSaysWhenARestartIsDue() {
        XCTAssertEqual(row(.screenRecording) { $0.screenRecording = .init(granted: false, preflight: false) }.action, .askForScreenRecording)
        XCTAssertEqual(row(.screenRecording) {
            $0.screenRecording = .init(granted: false, preflight: false)
            $0.askedForScreenRecording = true
        }.action, .openSettings(Permissions.screenRecordingSettings))
        let late = row(.screenRecording) { $0.screenRecording = .init(granted: true, preflight: false) }
        XCTAssertEqual(late.state, .actionNeeded)
        XCTAssertEqual(late.action, .restart)
    }

    func testOnlyRequiredRowsBringTheAssistantBack() {
        var facts = Self.ready()
        facts.screenRecording = .init(granted: false, preflight: false)
        facts.paired = false
        facts.moved = false
        facts.loginItem = .off
        XCTAssertFalse(Setup.shouldOpen(Setup.rows(facts), firstStart: false))
        XCTAssertEqual(Setup.summary(Setup.rows(facts)).state, .ok)

        facts.accessibility = false
        XCTAssertTrue(Setup.shouldOpen(Setup.rows(facts), firstStart: false))
        XCTAssertEqual(Setup.summary(Setup.rows(facts)), .init(state: .actionNeeded, text: "Einrichtung: 1 Schritt offen"))
    }

    // MARK: Tailscale

    func testATailscaleThatIsMissingOrDownSaysWhatToDo() {
        XCTAssertEqual(row(.tailscale) { $0.tailscale = .notInstalled }.action, .open(Tailscale.download))
        let app = row(.tailscale) { $0.tailscale = .unreachable(Self.app, reason: "") }
        XCTAssertEqual(app.state, .actionNeeded)
        XCTAssertEqual(app.action, .openTailscale(URL(fileURLWithPath: "/Applications/Tailscale.app")))
        XCTAssertEqual(row(.tailscale) { $0.tailscale = .unreachable(Self.brew, reason: "") }.action,
                       .copy("sudo brew services start tailscale"), "Homebrew's service needs the person's password")
        XCTAssertEqual(row(.tailscale) { $0.tailscale = .silent(Self.brew) }.state, .failed)
        XCTAssertEqual(row(.tailscale) { $0.tailscale = nil }.state, .working, "before the first look")
    }

    func testLoggedOutOpensTheLoginLinkOrStartsALogin() {
        let withLink = status {
            $0.backend = .needsLogin
            $0.authURL = URL(string: "https://login.tailscale.com/a/0123abcd")
        }
        XCTAssertEqual(row(.tailscale) { $0.tailscale = .connected(Self.brew, withLink, nil) }.action,
                       .open(URL(string: "https://login.tailscale.com/a/0123abcd")!))
        let without = status { $0.backend = .needsLogin }
        XCTAssertEqual(row(.tailscale) { $0.tailscale = .connected(Self.brew, without, nil) }.action, .logIn)
        let printed = row(.tailscale) {
            $0.tailscale = .connected(Self.brew, without, nil)
            $0.running = .init(operation: .logIn, link: URL(string: "https://login.tailscale.com/a/feed"))
        }
        XCTAssertEqual(printed.action, .open(URL(string: "https://login.tailscale.com/a/feed")!))
        let failed = row(.tailscale) {
            $0.tailscale = .connected(Self.brew, without, nil)
            $0.failures[.logIn] = "Tailscale meldet: nein"
        }
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.detail, "Tailscale meldet: nein")
    }

    func testSwitchedOffOldOrUnapprovedTailscale() {
        XCTAssertEqual(row(.tailscale) { $0.tailscale = .connected(Self.brew, status { $0.backend = .stopped }, nil) }.action,
                       .turnOnTailscale)
        XCTAssertEqual(row(.tailscale) { $0.tailscale = .connected(Self.app, status { $0.backend = .stopped }, nil) }.action,
                       .openTailscale(URL(fileURLWithPath: "/Applications/Tailscale.app")), "the app has its own switch")
        XCTAssertEqual(row(.tailscale) { $0.tailscale = .connected(Self.brew, status { $0.backend = .needsMachineAuth }, nil) }.action,
                       .open(Tailscale.machines))
        let old = row(.tailscale) { $0.tailscale = .connected(Self.brew, status { $0.version = "1.48.0" }, nil) }
        XCTAssertEqual(old.state, .failed)
        XCTAssertEqual(old.detail, "Tailscale 1.48.0 ist zu alt, nötig ist 1.52 oder neuer.")
        XCTAssertEqual(row(.serve) { $0.tailscale = .connected(Self.brew, status { $0.version = "1.48.0" }, nil) }.detail,
                       "Erst Tailscale einrichten.")
    }

    func testHTTPSNeedsMagicDNSAndCertificates() {
        let off = row(.https) { $0.tailscale = .connected(Self.brew, status { $0.certDomains = [] }, nil) }
        XCTAssertEqual(off.state, .actionNeeded)
        XCTAssertEqual(off.action, .open(Tailscale.dnsSettings))
        XCTAssertEqual(row(.https) { $0.tailscale = .connected(Self.brew, status { $0.dnsName = nil }, nil) }.detail,
                       "MagicDNS ist im Tailnet aus. In der Verwaltung einschalten.")
        XCTAssertEqual(row(.https) { $0.tailscale = nil }.state, .working)
        XCTAssertEqual(row(.https) { $0.tailscale = .notInstalled }, .init(item: .https, state: .actionNeeded, detail: "Erst Tailscale einrichten."))
    }

    // MARK: Serve

    private func serve(_ serve: Tailscale.Serve?) -> (inout Setup.Facts) -> Void {
        { $0.tailscale = .connected(Self.brew, Self.status, serve) }
    }

    func testServeOffersToMapWhatIsMissingOrPointsElsewhere() {
        XCTAssertEqual(row(.serve, serve(.init(mapping: .none, funnel: false))).action, .applyServe)
        let elsewhere = row(.serve, serve(.init(mapping: .elsewhere("http://127.0.0.1:3000"), funnel: false)))
        XCTAssertEqual(elsewhere.action, .applyServe)
        XCTAssertEqual(elsewhere.detail, "Port 8443 zeigt auf http://127.0.0.1:3000. Freigeben stellt ihn auf Remotey um.")
        XCTAssertEqual(row(.serve, serve(nil)).state, .failed)
    }

    func testFunnelIsAWarningWithItsOwnKey() {
        let funnel = row(.serve, serve(.init(mapping: .ours, funnel: true)))
        XCTAssertEqual(funnel.state, .failed)
        XCTAssertEqual(funnel.action, .removeServe)
        XCTAssertTrue(funnel.detail.contains("Internet"))
        var facts = Self.ready()
        serve(.init(mapping: .ours, funnel: true))(&facts)
        XCTAssertTrue(Setup.shouldOpen(Setup.rows(facts), firstStart: false))
        XCTAssertEqual(Setup.summary(Setup.rows(facts)).state, .failed)
    }

    func testApplyingShowsTheConsentLinkWhileTheToolWaits() {
        let working = row(.serve) { $0.running = .init(operation: .applyServe) }
        XCTAssertEqual(working.state, .working)
        XCTAssertNil(working.action)
        let consent = row(.serve) {
            $0.running = .init(operation: .applyServe, link: URL(string: "https://login.tailscale.com/f/serve?node=n1"))
        }
        XCTAssertEqual(consent.state, .actionNeeded)
        XCTAssertEqual(consent.action, .open(URL(string: "https://login.tailscale.com/f/serve?node=n1")!))
        let failed = row(.serve) { $0.failures[.applyServe] = "Tailscale meldet: nein" }
        XCTAssertEqual(failed, .init(item: .serve, state: .failed, detail: "Tailscale meldet: nein", action: .applyServe))
    }

    func testTheMappingIsGreenOnlyOnceTheSelfTestAnswered() {
        XCTAssertEqual(row(.serve) { $0.selfTest = .running }.state, .working)
        XCTAssertEqual(row(.serve) { $0.selfTest = .notRun }.state, .working)
        let failed = row(.serve) { $0.selfTest = .done(.failed("Keine Antwort.")) }
        XCTAssertEqual(failed, .init(item: .serve, state: .failed, detail: "Keine Antwort.", action: .selfTest))
        let untestable = row(.serve) { $0.selfTest = .done(.inconclusive("Von hier nicht prüfbar.")) }
        XCTAssertEqual(untestable, .init(item: .serve, state: .ok, detail: "Von hier nicht prüfbar.", action: .selfTest),
                       "a Mac that cannot reach its own name does not hold up the setup")
        var facts = Self.ready()
        facts.selfTest = .running
        XCTAssertFalse(Setup.shouldOpen(Setup.rows(facts), firstStart: false), "a row at work may turn green a moment later")
        XCTAssertEqual(Setup.summary(Setup.rows(facts)), .init(state: .working, text: "Wird geprüft …"))
    }

    // MARK: Phone and login item

    func testPairingWaitsForTheMappingAndTheMoveForThePairing() {
        XCTAssertEqual(row(.pairing) { $0.paired = false }.action, .showPairing)
        XCTAssertNil(row(.pairing) {
            $0.paired = false
            $0.selfTest = .done(.failed("x"))
        }.action, "a QR code that leads nowhere is no help")
        let move = row(.firstMove) { $0.moved = false }
        XCTAssertEqual(move.state, .actionNeeded)
        XCTAssertNil(move.action)
        XCTAssertEqual(move.detail, "Mit einem Finger über das iPhone streichen.")
        XCTAssertEqual(row(.firstMove) {
            $0.moved = false
            $0.paired = false
        }.detail, "Erst ein iPhone koppeln.")
    }

    func testTheLoginItemToggles() {
        XCTAssertEqual(Setup.row(.loginItem, Self.ready()).action, .setLoginItem(false))
        XCTAssertEqual(row(.loginItem) { $0.loginItem = .off }.action, .setLoginItem(true))
        XCTAssertEqual(row(.loginItem) { $0.loginItem = .needsApproval }.action, .openLoginItems)
        XCTAssertEqual(row(.loginItem) { $0.loginItem = .unavailable }.state, .failed)
        let failed = row(.loginItem) {
            $0.loginItem = .off
            $0.loginItemFailure = "Ließ sich nicht ändern: x"
        }
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.action, .setLoginItem(true))
    }

    func testEveryRowHasASentenceAndEveryKeyATitle() {
        var facts = Setup.Facts()
        facts.tailscale = .notInstalled
        for row in Setup.rows(facts) + Setup.rows(Self.ready()) {
            XCTAssertTrue(row.detail.hasSuffix(".") || row.detail.hasSuffix("…"), row.detail)
            if let action = row.action { XCTAssertFalse(action.title.isEmpty) }
        }
    }
}
