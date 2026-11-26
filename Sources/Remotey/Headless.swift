import AppKit

/// The agent for an end-to-end check on a Mac someone is working at: `REMOTEY_HEADLESS=1` with `REMOTEY_PORT`.
/// No status item, no window, no prompt for a permission, no live view; input is written to stdout instead of
/// posted, and so is everything the check waits for. Its token, devices and Face ID file live in a folder of its
/// own that goes when it ends, so it reads nothing of the installed agent and leaves nothing behind.
///
/// stdout, one line each: `listening <port>`, `pairing <link code> <digits>` once it listens, `paired <id> <name>`,
/// `session <count>` whenever who is connected changes, `posted <event type> <dx> <dy>` for every event that would
/// have been posted, `failed <reason>`.
final class Headless: NSObject, NSApplicationDelegate {
    static let on = ProcessInfo.processInfo.environment["REMOTEY_HEADLESS"] == "1"

    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("remotey-headless-\(UUID().uuidString)")
    private var server: Server?
    private var signals: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The installed agent's port, where this one would take the user's phone.
        guard Server.port != 47800 else { return quit("failed REMOTEY_PORT must name a port other than 47800") }
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signals.append(source)
        }
        let input = Input { event in
            Self.say("posted \(event.type.rawValue) \(event.getIntegerValueField(.mouseEventDeltaX)) \(event.getIntegerValueField(.mouseEventDeltaY))")
        }
        let token = Token.load(from: folder.appendingPathComponent("token")).token
        let server = Server(token: token, input: input, faceUnlock: FaceUnlock(file: folder.appendingPathComponent("face-unlock")),
                            devices: Devices(file: folder.appendingPathComponent("devices")),
                            // Accessibility is what input needs, and input goes nowhere: the page acts as if allowed.
                            permissions: { (true, false) }, activity: {})
        self.server = server
        var announced = false
        server.healthChanged = { [weak server] health in
            guard let server else { return }
            switch health {
            case .listening where !announced:
                announced = true
                Self.say("listening \(Server.port)")
                let offer = server.openPairing()
                Self.say("pairing \(offer.code) \(offer.digits)")
            case .failed(let reason): Self.say("failed \(reason)")
            default: break
            }
        }
        server.pairingChanged = { state in
            if case .paired(let device) = state { Self.say("paired \(device.id) \(device.name)") }
        }
        server.sessionsChanged = { Self.say("session \($0.count)") }
        do { try server.start() } catch { quit("failed \(error)") }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    private func quit(_ line: String) {
        Self.say(line)
        NSApp.terminate(nil)
    }

    private static func say(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}
