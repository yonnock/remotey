import Foundation

/// What Tailscale says about this Mac, read through its command line tool: its only documented interface for
/// other apps. Everything here is a value; `TailscaleCLI` gets the values.
enum Tailscale {
    /// Port `tailscale serve` exposes inside the tailnet. Same as `AppDelegate.tailnetPort`.
    static let port = 8443
    /// `serve --bg` with `--set-path` came with this version.
    static let oldestSupported = (major: 1, minor: 52)
    static let download = URL(string: "https://tailscale.com/download/mac")!
    static let dnsSettings = URL(string: "https://login.tailscale.com/admin/dns")!
    static let machines = URL(string: "https://login.tailscale.com/admin/machines")!

    /// The tool and, if there is one, the app that runs the daemon.
    struct Binary: Equatable {
        var path: String
        /// Tailscale.app. Nil for a daemon from Homebrew, which only `brew services` starts.
        var app: URL?
    }

    /// Homebrew first, then the link the app installs, then the app's own binary, which also acts as the tool.
    static let candidates = ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale",
                             "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
    static let appPath = "/Applications/Tailscale.app"

    static func locate(isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:),
                       exists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> Binary? {
        guard let path = candidates.first(where: isExecutable) else { return nil }
        return Binary(path: path, app: exists(appPath) ? URL(fileURLWithPath: appPath) : nil)
    }

    enum Backend: Equatable {
        case running
        /// Switched off in the app or with `tailscale down`.
        case stopped
        case needsLogin
        /// Logged in, but the tailnet's admin has to approve this Mac.
        case needsMachineAuth
        case starting
        case other(String)

        init(_ state: String) {
            switch state {
            case "Running": self = .running
            case "Stopped": self = .stopped
            case "NeedsLogin", "NoState": self = .needsLogin
            case "NeedsMachineAuth": self = .needsMachineAuth
            case "Starting": self = .starting
            default: self = .other(state)
            }
        }
    }

    /// The parts of `tailscale status --json` the assistant needs.
    struct Status: Equatable {
        var backend: Backend
        var version: String
        /// MagicDNS name of this Mac without the trailing dot, e.g. `mac.example.ts.net`. Nil without MagicDNS.
        var dnsName: String?
        /// Who owns the node, e.g. `someone@example.com`.
        var loginName: String?
        /// Names Tailscale can get certificates for. Empty while HTTPS is off for the tailnet.
        var certDomains: [String]
        /// Where to log in, while Tailscale waits for it.
        var authURL: URL?

        var httpsEnabled: Bool { !certDomains.isEmpty }
        var supported: Bool { Tailscale.supports(version) }
    }

    static func status(from json: Data) -> Status? {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let state = root["BackendState"] as? String else { return nil }
        let me = root["Self"] as? [String: Any]
        let dnsName = (me?["DNSName"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        var loginName: String?
        if let id = me?["UserID"] as? NSNumber, let users = root["User"] as? [String: Any],
           let user = users[id.stringValue] as? [String: Any] {
            loginName = user["LoginName"] as? String
        }
        let auth = (root["AuthURL"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        return Status(backend: Backend(state), version: root["Version"] as? String ?? "",
                      dnsName: dnsName?.isEmpty == false ? dnsName : nil, loginName: loginName,
                      certDomains: root["CertDomains"] as? [String] ?? [], authURL: auth)
    }

    /// `1.104.7-tcbc74fe48` and the like.
    static func supports(_ version: String) -> Bool {
        let parts = version.split(whereSeparator: { !$0.isNumber }).prefix(2).compactMap { Int($0) }
        guard parts.count == 2 else { return false }
        return (parts[0], parts[1]) >= oldestSupported
    }

    /// What `tailscale serve` does with HTTPS on `Tailscale.port`.
    struct Serve: Equatable {
        enum Mapping: Equatable {
            case none
            /// `/` to the agent's page and `/ws` to its socket.
            case ours
            /// The port serves something else; the text says what `/` goes to.
            case elsewhere(String)
        }

        var mapping: Mapping
        /// Funnel puts the port on the public internet, with the token as the only barrier.
        var funnel: Bool
    }

    static func serve(from json: Data, pagePort: Int) -> Serve? {
        let text = String(decoding: json, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // Some versions print nothing at all for an empty configuration.
        if text.isEmpty { return Serve(mapping: .none, funnel: false) }
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        let suffix = ":\(port)"
        let web = (root["Web"] as? [String: Any] ?? [:]).first { $0.key.hasSuffix(suffix) }?.value as? [String: Any]
        let handlers = web?["Handlers"] as? [String: Any] ?? [:]
        let funnel = (root["AllowFunnel"] as? [String: Any] ?? [:]).contains {
            $0.key.hasSuffix(suffix) && ($0.value as? Bool) == true
        }

        func proxy(_ path: String) -> String? { (handlers[path] as? [String: Any])?["Proxy"] as? String }
        let mapping: Serve.Mapping
        if handlers.isEmpty {
            mapping = .none
        } else if isLoopback(proxy("/"), port: pagePort), isLoopback(proxy("/ws"), port: pagePort + 1) {
            mapping = .ours
        } else {
            mapping = .elsewhere(proxy("/") ?? handlers.keys.sorted().joined(separator: ", "))
        }
        return Serve(mapping: mapping, funnel: funnel)
    }

    private static func isLoopback(_ proxy: String?, port: Int) -> Bool {
        guard let proxy, let url = URL(string: proxy), url.scheme == "http", url.port == port,
              ["127.0.0.1", "localhost"].contains(url.host ?? ""), ["", "/"].contains(url.path) else { return false }
        return true
    }

    /// The first web link in what the tool printed: where to log in, or where the tailnet's admin allows Serve.
    static func link(in output: String) -> URL? {
        guard let range = output.range(of: #"https://[^\s"'<>]+"#, options: .regularExpression) else { return nil }
        return URL(string: String(output[range]))
    }

    /// Everything one look at Tailscale finds.
    enum Snapshot: Equatable {
        case notInstalled
        /// The tool is there, but no daemon answers it (the app is not running, or Homebrew's service is not started).
        case unreachable(Binary, reason: String)
        /// The tool did not answer within its time limit.
        case silent(Binary)
        /// Serve is nil while it could not be read, and before Tailscale runs.
        case connected(Binary, Status, Serve?)

        var binary: Binary? {
            switch self {
            case .notInstalled: return nil
            case .unreachable(let binary, _), .silent(let binary), .connected(let binary, _, _): return binary
            }
        }

        var status: Status? {
            if case .connected(_, let status, _) = self { return status }
            return nil
        }

        var serve: Serve? {
            if case .connected(_, _, let serve) = self { return serve }
            return nil
        }
    }

    /// How a command that changes Tailscale ended.
    enum Outcome: Equatable {
        case done
        /// A sentence for a person.
        case failed(String)
    }

    /// Whether this Mac's own page answers at its address in the tailnet.
    enum SelfTest: Equatable {
        case answered
        /// The Mac cannot reach its own address in the tailnet, so the test says nothing either way. The
        /// sentence says so.
        case inconclusive(String)
        /// A sentence for a person.
        case failed(String)
    }
}

/// The calls the assistant makes to Tailscale. All of them block, so they run off the main thread.
protocol TailscaleClient {
    func snapshot() -> Tailscale.Snapshot
    /// Maps `/` and `/ws` on HTTPS 8443. `link` gets the consent link when Serve is not yet allowed in the
    /// tailnet; the tool then waits until it is, and the mapping completes by itself.
    func applyServe(link: @escaping (URL) -> Void) -> Tailscale.Outcome
    func removeServe() -> Tailscale.Outcome
    /// Starts a login; `link` gets the page to log in on.
    func logIn(link: @escaping (URL) -> Void) -> Tailscale.Outcome
    /// `tailscale up`: for a Tailscale that is switched off.
    func turnOn() -> Tailscale.Outcome
    /// Fetches `https://host:8443/`. The first fetch also makes Tailscale get the certificate, before the phone comes.
    func selfTest(host: String) -> Tailscale.SelfTest
}

/// `TailscaleClient` through the command line tool.
struct TailscaleCLI: TailscaleClient {
    /// Time limits. A consent or a login waits for a person, the rest for a program.
    struct Limits {
        var read: TimeInterval = 5
        var change: TimeInterval = 20
        var person: TimeInterval = 600
        var fetch: TimeInterval = 30
    }

    var pagePort: Int
    /// The agent's own page, to tell it from anything else that answers.
    var page: () -> Data?
    var locate: () -> Tailscale.Binary? = { Tailscale.locate() }
    var run: Command.Run = Command.run(_:_:limit:output:)
    var fetch: Command.Fetch = Command.fetch(_:limit:)
    var limits = Limits()

    func snapshot() -> Tailscale.Snapshot {
        guard let binary = locate() else { return .notInstalled }
        let result = run(binary.path, ["status", "--json"], limits.read, nil)
        if result.timedOut { return .silent(binary) }
        // What it printed counts, whatever the exit status.
        guard let status = Tailscale.status(from: Data(result.stdout.utf8)) else {
            return .unreachable(binary, reason: Self.firstLine(result.stderr) ?? Self.firstLine(result.stdout) ?? "")
        }
        guard status.backend == .running else { return .connected(binary, status, nil) }
        return .connected(binary, status, readServe(binary))
    }

    private func readServe(_ binary: Tailscale.Binary) -> Tailscale.Serve? {
        let result = run(binary.path, ["serve", "status", "--json"], limits.read, nil)
        return result.succeeded ? Tailscale.serve(from: Data(result.stdout.utf8), pagePort: pagePort) : nil
    }

    /// The same two commands as scripts/tailscale-serve.sh.
    func applyServe(link: @escaping (URL) -> Void) -> Tailscale.Outcome {
        for (path, port) in [("/", pagePort), ("/ws", pagePort + 1)] {
            let outcome = change(["serve", "--bg", "--https=\(Tailscale.port)", "--set-path", path, "http://127.0.0.1:\(port)"],
                                 limit: limits.person, link: link)
            guard outcome == .done else { return outcome }
        }
        return .done
    }

    /// Only the agent's two paths, so anything else on the port stays. A port left without paths loses its
    /// Funnel with them. The tool's words for a path that is not there differ between versions, so what
    /// counts is the configuration read back afterwards.
    func removeServe() -> Tailscale.Outcome {
        var refusal = Tailscale.Outcome.done
        for path in ["/ws", "/"] {
            let outcome = change(["serve", "--https=\(Tailscale.port)", "--set-path", path, "off"], limit: limits.change, link: nil)
            if outcome != .done { refusal = outcome }
        }
        guard let binary = locate(), let serve = readServe(binary) else {
            return refusal == .done ? .failed("Tailscale sagt nicht, ob die Freigabe weg ist.") : refusal
        }
        guard serve.mapping == .ours || serve.funnel else { return .done }
        return refusal == .done ? .failed("Die Freigabe ist noch da.") : refusal
    }

    func logIn(link: @escaping (URL) -> Void) -> Tailscale.Outcome {
        change(["login"], limit: limits.person, link: link)
    }

    func turnOn() -> Tailscale.Outcome {
        change(["up"], limit: limits.change, link: nil)
    }

    func selfTest(host: String) -> Tailscale.SelfTest {
        guard let url = URL(string: "https://\(host):\(Tailscale.port)/") else {
            return .failed("„\(host)“ ist kein gültiger Name.")
        }
        switch fetch(url, limits.fetch) {
        case .success(let answer) where answer.status == 200 && answer.body == page():
            return .answered
        case .success(let answer) where answer.status == 502:
            return .failed("Tailscale erreicht Remotey auf Port \(pagePort) nicht. Läuft die App?")
        case .success(let answer):
            return .failed("Unter \(host):\(Tailscale.port) antwortet eine andere Seite (Status \(answer.status)).")
        case .failure(let error) where Self.closedInHandshake(error):
            return .inconclusive("Freigegeben. Von diesem Mac aus lässt sich die Adresse nicht prüfen, das iPhone zeigt, ob sie antwortet.")
        case .failure(let error):
            return .failed(Self.sentence(for: error, host: host))
        }
    }

    private func change(_ arguments: [String], limit: TimeInterval, link: ((URL) -> Void)?) -> Tailscale.Outcome {
        guard let binary = locate() else { return .failed("Tailscale ist nicht installiert.") }
        let lock = NSLock()
        var printed = "", announced = false
        let result = run(binary.path, arguments, limit) { chunk in
            guard let link else { return }
            lock.lock()
            printed += chunk
            // Only whole lines: a pipe may hand over half a link.
            let lines = printed.lastIndex(where: \.isNewline).map { printed[...$0] } ?? ""
            let url = announced ? nil : Tailscale.link(in: String(lines))
            if url != nil { announced = true }
            lock.unlock()
            if let url { link(url) }
        }
        if result.succeeded { return .done }
        if result.timedOut {
            return .failed(announced ? "Im Browser wurde nicht rechtzeitig zugestimmt. Bitte noch einmal versuchen."
                                     : "Tailscale hat nicht rechtzeitig geantwortet.")
        }
        let line = Self.lastLine(result.stderr) ?? Self.lastLine(result.stdout)
        return .failed(line.map { "Tailscale meldet: \($0)" } ?? "Tailscale hat den Befehl abgelehnt.")
    }

    /// Measured with Homebrew's tailscaled 1.104 on macOS 27: a connection from the Mac to its own name is
    /// accepted and closed before the TLS handshake (`errSSLClosedNoNotify`), although the phone gets through.
    /// A certificate Tailscale cannot get ends with an alert instead, a different code.
    static func closedInHandshake(_ error: URLError) -> Bool {
        error.code == .secureConnectionFailed && (error.userInfo["_kCFStreamErrorCodeKey"] as? Int) == -9816
    }

    static func sentence(for error: URLError, host: String) -> String {
        switch error.code {
        case .timedOut:
            return "Keine Antwort von \(host). Tailscale holt das Zertifikat vielleicht noch, bitte gleich noch einmal prüfen."
        case .cannotFindHost, .dnsLookupFailed:
            return "Der Name \(host) lässt sich nicht auflösen. Ist MagicDNS im Tailnet an?"
        case .cannotConnectToHost:
            return "Port \(Tailscale.port) auf \(host) nimmt keine Verbindung an."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            return "Das Zertifikat für \(host) ist noch nicht gültig. Ist HTTPS im Tailnet an?"
        case .notConnectedToInternet, .networkConnectionLost:
            return "Keine Verbindung zum Tailnet."
        default:
            return "Die Adresse \(host) antwortet nicht (Fehler \(error.code.rawValue))."
        }
    }

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func firstLine(_ text: String) -> String? { lines(text).first }
    static func lastLine(_ text: String) -> String? { lines(text).last }
}
