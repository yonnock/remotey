import XCTest
@testable import Remotey

/// Tailscale as recorded outputs of its tool, in the shape version 1.104 prints them. Names, addresses and
/// logins are made up. Nothing here runs the tool.
final class TailscaleTests: XCTestCase {
    static let running = """
    {
      "Version": "1.104.7-t0000000000",
      "TUN": true,
      "BackendState": "Running",
      "HaveNodeKey": true,
      "AuthURL": "",
      "TailscaleIPs": ["100.64.0.7", "fd7a:115c:a1e0::7"],
      "Self": {
        "ID": "nExample1CNTRL",
        "HostName": "werkbank",
        "DNSName": "werkbank.tail0000.ts.net.",
        "OS": "macOS",
        "UserID": 1234567,
        "Online": true,
        "CapMap": {"https": null, "funnel": null}
      },
      "MagicDNSSuffix": "tail0000.ts.net",
      "CurrentTailnet": {"Name": "kim@example.com", "MagicDNSSuffix": "tail0000.ts.net", "MagicDNSEnabled": true},
      "CertDomains": ["werkbank.tail0000.ts.net"],
      "Peer": {},
      "User": {"1234567": {"ID": 1234567, "LoginName": "kim@example.com", "DisplayName": "Kim Beispiel"}}
    }
    """

    static let loggedOut = """
    {"Version": "1.104.7-t0000000000", "BackendState": "NeedsLogin",
     "AuthURL": "https://login.tailscale.com/a/0123abcd", "Self": {"DNSName": "", "UserID": 0}, "User": null}
    """

    static func serve(page: Int = 47800, socket: Int = 47801, funnel: Bool = false) -> String {
        """
        {
          "TCP": {"8443": {"HTTPS": true}},
          "Web": {"werkbank.tail0000.ts.net:8443": {"Handlers": {
            "/": {"Proxy": "http://127.0.0.1:\(page)"},
            "/ws": {"Proxy": "http://127.0.0.1:\(socket)"}
          }}}\(funnel ? #", "AllowFunnel": {"werkbank.tail0000.ts.net:8443": true}"# : "")
        }
        """
    }

    static let consent = """

    Serve is not enabled on your tailnet.
    To enable, visit:

             https://login.tailscale.com/f/serve?node=nExample1CNTRL

    Waiting...
    """

    // MARK: Values

    func testARunningMacGivesItsNameItsOwnerAndItsCertificates() throws {
        let status = try XCTUnwrap(Tailscale.status(from: Data(Self.running.utf8)))
        XCTAssertEqual(status.backend, .running)
        XCTAssertEqual(status.dnsName, "werkbank.tail0000.ts.net", "without the trailing dot")
        XCTAssertEqual(status.loginName, "kim@example.com")
        XCTAssertTrue(status.httpsEnabled)
        XCTAssertTrue(status.supported)
        XCTAssertNil(status.authURL)
    }

    func testALoggedOutMacHasNoNameButALoginLink() throws {
        let status = try XCTUnwrap(Tailscale.status(from: Data(Self.loggedOut.utf8)))
        XCTAssertEqual(status.backend, .needsLogin)
        XCTAssertNil(status.dnsName)
        XCTAssertNil(status.loginName)
        XCTAssertFalse(status.httpsEnabled)
        XCTAssertEqual(status.authURL, URL(string: "https://login.tailscale.com/a/0123abcd"))
    }

    func testEveryStateOfTheDaemonHasItsOwnCase() {
        XCTAssertEqual(Tailscale.Backend("Stopped"), .stopped)
        XCTAssertEqual(Tailscale.Backend("NeedsMachineAuth"), .needsMachineAuth)
        XCTAssertEqual(Tailscale.Backend("Starting"), .starting)
        XCTAssertEqual(Tailscale.Backend("NoState"), .needsLogin)
        XCTAssertEqual(Tailscale.Backend("Odd"), .other("Odd"))
        XCTAssertNil(Tailscale.status(from: Data("failed to connect to local tailscaled".utf8)))
    }

    func testServeWithSetPathNeedsVersion152() {
        XCTAssertTrue(Tailscale.supports("1.104.7-t0000000000"))
        XCTAssertTrue(Tailscale.supports("1.52.0"))
        XCTAssertTrue(Tailscale.supports("2.0.1"))
        XCTAssertFalse(Tailscale.supports("1.50.1-tabc"))
        XCTAssertFalse(Tailscale.supports(""))
    }

    func testTheMappingOfTheScriptIsOurs() {
        XCTAssertEqual(Tailscale.serve(from: Data(Self.serve().utf8), pagePort: 47800), .init(mapping: .ours, funnel: false))
        let localhost = Self.serve().replacingOccurrences(of: "127.0.0.1", with: "localhost")
        XCTAssertEqual(Tailscale.serve(from: Data(localhost.utf8), pagePort: 47800)?.mapping, .ours)
    }

    func testAMappingToOtherPortsIsSomethingElse() {
        XCTAssertEqual(Tailscale.serve(from: Data(Self.serve(page: 3000, socket: 3001).utf8), pagePort: 47800)?.mapping,
                       .elsewhere("http://127.0.0.1:3000"))
        XCTAssertEqual(Tailscale.serve(from: Data(Self.serve(socket: 9999).utf8), pagePort: 47800)?.mapping,
                       .elsewhere("http://127.0.0.1:47800"), "the socket goes elsewhere")
        XCTAssertEqual(Tailscale.serve(from: Data(Self.serve().utf8), pagePort: 47820)?.mapping,
                       .elsewhere("http://127.0.0.1:47800"), "an agent moved by REMOTEY_PORT")
    }

    func testFunnelIsAStateOfItsOwn() {
        XCTAssertEqual(Tailscale.serve(from: Data(Self.serve(funnel: true).utf8), pagePort: 47800), .init(mapping: .ours, funnel: true))
    }

    func testAnEmptyConfigurationMapsNothing() {
        XCTAssertEqual(Tailscale.serve(from: Data("{}".utf8), pagePort: 47800), .init(mapping: .none, funnel: false))
        XCTAssertEqual(Tailscale.serve(from: Data("\n".utf8), pagePort: 47800), .init(mapping: .none, funnel: false))
        let otherPort = #"{"TCP": {"443": {"HTTPS": true}}, "Web": {"werkbank.tail0000.ts.net:443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:3000"}}}}}"#
        XCTAssertEqual(Tailscale.serve(from: Data(otherPort.utf8), pagePort: 47800)?.mapping, Tailscale.Serve.Mapping.none,
                       "port 443 is not ours to judge")
        XCTAssertNil(Tailscale.serve(from: Data("not json".utf8), pagePort: 47800))
    }

    func testTheConsentLinkIsFoundInWhatTheToolPrints() {
        XCTAssertEqual(Tailscale.link(in: Self.consent), URL(string: "https://login.tailscale.com/f/serve?node=nExample1CNTRL"))
        XCTAssertNil(Tailscale.link(in: "Available within your tailnet:\n"))
    }

    func testTheToolIsLookedForInHomebrewThenInTheApp() {
        let brew = Tailscale.locate(isExecutable: { $0.hasPrefix("/opt/homebrew") || $0.hasPrefix("/Applications") }, exists: { _ in false })
        XCTAssertEqual(brew, .init(path: "/opt/homebrew/bin/tailscale", app: nil))
        let app = Tailscale.locate(isExecutable: { $0.hasPrefix("/Applications") }, exists: { $0 == Tailscale.appPath })
        XCTAssertEqual(app, .init(path: "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
                                  app: URL(fileURLWithPath: "/Applications/Tailscale.app")))
        XCTAssertNil(Tailscale.locate(isExecutable: { _ in false }, exists: { _ in true }))
    }

    // MARK: The tool, recorded

    private var calls: [[String]] = []
    /// Answers by arguments; a missing entry is an error exit.
    private var answers: [[String]: (result: Command.Result, chunks: [String])] = [:]
    private var fetched: [URL] = []
    private var fetchAnswer: Result<(status: Int, body: Data), URLError> = .success((200, Data("page".utf8)))
    private let binary = Tailscale.Binary(path: "/opt/homebrew/bin/tailscale", app: nil)

    private func answer(_ arguments: [String], _ stdout: String = "", status: Int32? = 0, stderr: String = "", chunks: [String] = []) {
        answers[arguments] = (Command.Result(status: status, stdout: stdout, stderr: stderr), chunks)
    }

    private lazy var cli = TailscaleCLI(
        pagePort: 47800, page: { Data("page".utf8) }, locate: { [unowned self] in binary },
        run: { [unowned self] path, arguments, _, output in
            XCTAssertEqual(path, binary.path)
            calls.append(arguments)
            let answer = answers[arguments] ?? (Command.Result(status: 1, stdout: "", stderr: "unknown"), [])
            answer.chunks.forEach { output?($0) }
            return answer.result
        },
        fetch: { [unowned self] url, _ in
            fetched.append(url)
            return fetchAnswer
        })

    private static let apply = [["serve", "--bg", "--https=8443", "--set-path", "/", "http://127.0.0.1:47800"],
                                ["serve", "--bg", "--https=8443", "--set-path", "/ws", "http://127.0.0.1:47801"]]

    func testASnapshotReadsStatusThenServe() {
        answer(["status", "--json"], Self.running)
        answer(["serve", "status", "--json"], Self.serve())
        guard case .connected(let found, let status, let serve) = cli.snapshot() else { return XCTFail("not connected") }
        XCTAssertEqual(found, binary)
        XCTAssertEqual(status.dnsName, "werkbank.tail0000.ts.net")
        XCTAssertEqual(serve, .init(mapping: .ours, funnel: false))
    }

    func testServeIsNotReadBeforeTailscaleRuns() {
        answer(["status", "--json"], Self.loggedOut, status: 1)
        XCTAssertEqual(cli.snapshot().status?.backend, .needsLogin, "what it printed counts, not the exit status")
        XCTAssertEqual(calls, [["status", "--json"]])
    }

    func testNoDaemonAndNoAnswerAreTold() {
        answer(["status", "--json"], status: 1, stderr: "failed to connect to local tailscaled; it doesn't appear to be running\n")
        XCTAssertEqual(cli.snapshot(), .unreachable(binary, reason: "failed to connect to local tailscaled; it doesn't appear to be running"))
        answer(["status", "--json"], status: nil)
        XCTAssertEqual(cli.snapshot(), .silent(binary))
        XCTAssertEqual(TailscaleCLI(pagePort: 1, page: { nil }, locate: { nil }).snapshot(), .notInstalled)
    }

    func testAServeThatCannotBeReadIsNil() {
        answer(["status", "--json"], Self.running)
        answer(["serve", "status", "--json"], status: 1, stderr: "permission denied")
        XCTAssertEqual(cli.snapshot(), .connected(binary, Tailscale.status(from: Data(Self.running.utf8))!, nil))
    }

    func testApplyingRunsWhatTheScriptRuns() {
        Self.apply.forEach { answer($0, "Available within your tailnet:") }
        XCTAssertEqual(cli.applyServe(link: { _ in XCTFail("no consent needed") }), .done)
        XCTAssertEqual(calls, Self.apply)
    }

    func testTheConsentLinkComesWhileTheToolWaits() {
        answer(Self.apply[0], "done", chunks: ["\nServe is not enabled on your tailnet.\nTo enable, visit:\n\n   https://login.tailscale.com/f/se",
                                              "rve?node=nExample1CNTRL\n\nWaiting...\n", "Success.\n"])
        answer(Self.apply[1], "done")
        var links: [URL] = []
        XCTAssertEqual(cli.applyServe(link: { links.append($0) }), .done, "the mapping completes once allowed")
        XCTAssertEqual(links, [URL(string: "https://login.tailscale.com/f/serve?node=nExample1CNTRL")!], "whole, and once")
    }

    func testAConsentNotGivenInTimeFails() {
        answer(Self.apply[0], status: nil, chunks: [Self.consent])
        XCTAssertEqual(cli.applyServe(link: { _ in }),
                       .failed("Im Browser wurde nicht rechtzeitig zugestimmt. Bitte noch einmal versuchen."))
        XCTAssertEqual(calls.count, 1, "the second path is not tried")
    }

    func testARefusalSaysWhatTailscaleSaid() {
        answer(Self.apply[0], status: 1, stderr: "Warning: client version differs\nerror: serve config denied\n")
        XCTAssertEqual(cli.applyServe(link: { _ in }), .failed("Tailscale meldet: error: serve config denied"))
    }

    func testRemovingTakesOffBothPathsAndChecks() {
        answer(["serve", "--https=8443", "--set-path", "/ws", "off"])
        answer(["serve", "--https=8443", "--set-path", "/", "off"])
        answer(["serve", "status", "--json"], "{}")
        XCTAssertEqual(cli.removeServe(), .done)
        XCTAssertEqual(calls.count, 3)

        answer(["serve", "--https=8443", "--set-path", "/ws", "off"], status: 1, stderr: "error: handler does not exist")
        XCTAssertEqual(cli.removeServe(), .done, "a path that is not there is what removing wants")

        answer(["serve", "status", "--json"], Self.serve())
        XCTAssertEqual(cli.removeServe(), .failed("Tailscale meldet: error: handler does not exist"))
        answer(["serve", "--https=8443", "--set-path", "/ws", "off"])
        XCTAssertEqual(cli.removeServe(), .failed("Die Freigabe ist noch da."))
    }

    func testLoginHandsOnTheLinkItPrints() {
        answer(["login"], chunks: ["\nTo authenticate, visit:\n\n\thttps://login.tailscale.com/a/0123abcd\n\n"])
        var link: URL?
        XCTAssertEqual(cli.logIn(link: { link = $0 }), .done)
        XCTAssertEqual(link, URL(string: "https://login.tailscale.com/a/0123abcd"))
    }

    func testTheSelfTestWantsTheAgentsOwnPage() {
        XCTAssertEqual(cli.selfTest(host: "werkbank.tail0000.ts.net"), .answered)
        XCTAssertEqual(fetched, [URL(string: "https://werkbank.tail0000.ts.net:8443/")!])

        fetchAnswer = .success((200, Data("another page".utf8)))
        XCTAssertEqual(cli.selfTest(host: "werkbank.tail0000.ts.net"),
                       .failed("Unter werkbank.tail0000.ts.net:8443 antwortet eine andere Seite (Status 200)."))
        fetchAnswer = .success((502, Data()))
        XCTAssertEqual(cli.selfTest(host: "werkbank.tail0000.ts.net"),
                       .failed("Tailscale erreicht Remotey auf Port 47800 nicht. Läuft die App?"))
        fetchAnswer = .failure(URLError(.timedOut))
        XCTAssertEqual(cli.selfTest(host: "werkbank.tail0000.ts.net"),
                       .failed("Keine Antwort von werkbank.tail0000.ts.net. Tailscale holt das Zertifikat vielleicht noch, bitte gleich noch einmal prüfen."))
        fetchAnswer = .failure(URLError(.secureConnectionFailed, userInfo: ["_kCFStreamErrorCodeKey": -9816]))
        XCTAssertEqual(cli.selfTest(host: "werkbank.tail0000.ts.net"),
                       .inconclusive("Freigegeben. Von diesem Mac aus lässt sich die Adresse nicht prüfen, das iPhone zeigt, ob sie antwortet."),
                       "closed before the handshake, as the Mac's own name does with Homebrew's tailscaled")
        fetchAnswer = .failure(URLError(.secureConnectionFailed, userInfo: ["_kCFStreamErrorCodeKey": -9806]))
        XCTAssertEqual(cli.selfTest(host: "werkbank.tail0000.ts.net"),
                       .failed("Das Zertifikat für werkbank.tail0000.ts.net ist noch nicht gültig. Ist HTTPS im Tailnet an?"),
                       "an alert in the handshake is a real failure")
        fetchAnswer = .failure(URLError(.serverCertificateUntrusted))
        XCTAssertEqual(cli.selfTest(host: "werkbank.tail0000.ts.net"),
                       .failed("Das Zertifikat für werkbank.tail0000.ts.net ist noch nicht gültig. Ist HTTPS im Tailnet an?"))
    }
}
