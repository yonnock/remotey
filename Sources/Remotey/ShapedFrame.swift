import AppKit
import ApplicationServices

/// The frame a window had before it took the phone's shape, kept in a file for as long as it has that shape.
/// An agent that crashed or was killed without cleaning up gives the frame back at its next start.
struct ShapedFrame: Codable, Equatable {
    /// The app the window belongs to. A pid alone could name another app by then.
    let pid: Int32
    let bundle: String?
    let original: CGRect
    /// The frame the window took for the phone. It is put back only while it still has this one: what the user
    /// did with the window since stands.
    let shaped: CGRect

    /// One per agent, as with the token: a development build on other ports keeps its own.
    static func file(port: UInt16 = Server.port) -> URL {
        Token.fileURL.deletingLastPathComponent().appendingPathComponent(port == 47800 ? "shaped-window" : "shaped-window-\(port)")
    }

    static func load(from file: URL) -> ShapedFrame? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(ShapedFrame.self, from: $0) }
    }

    func save(to file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: file, options: .atomic)
    }

    static func remove(at file: URL) {
        try? FileManager.default.removeItem(at: file)
    }

    /// Which of `frames`, the app's windows, is the one that kept the phone's shape. Points are rounded by the
    /// window server, so a frame within a point counts.
    func window(among frames: [CGRect]) -> Int? {
        frames.firstIndex { frame in
            abs(frame.minX - shaped.minX) <= 1 && abs(frame.minY - shaped.minY) <= 1
                && abs(frame.width - shaped.width) <= 1 && abs(frame.height - shaped.height) <= 1
        }
    }

    /// At the start: a window the last run left in the phone's shape gets its frame back, and the file goes.
    /// Needs the Accessibility permission; without it the file stays for a start that has it.
    static func restore(from file: URL = ShapedFrame.file()) {
        guard let record = load(from: file) else { return }
        guard AXIsProcessTrusted() else { return }
        defer { remove(at: file) }
        guard let app = NSRunningApplication(processIdentifier: record.pid), app.bundleIdentifier == record.bundle else { return }
        let element = AXUIElementCreateApplication(record.pid)
        AXUIElementSetMessagingTimeout(element, 0.25)
        guard let windows = Accessibility.attribute(element, kAXWindowsAttribute) as? [AXUIElement] else { return }
        let frames = windows.map { Accessibility.frame(of: $0) ?? .null }
        guard let index = record.window(among: frames) else { return }
        FrontWindow.put(windows[index], at: record.original)
    }
}
