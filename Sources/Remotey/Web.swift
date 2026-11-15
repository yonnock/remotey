import CryptoKit
import Foundation

/// The page and its modules: every file in the `Web` folder, bundled with the app.
enum Web {
    private static let directory: URL = {
        #if DEBUG
        // `swift run` and the tests have no bundle and read the source tree, so an edit shows after a reload of the page.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Web")
        #else
        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Web")
        #endif
    }()

    private static let types = [
        "html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8", "css": "text/css; charset=utf-8",
        "png": "image/png",
    ]

    /// A file of the folder by its name. Nil for anything else, such as a path that leads out of the folder.
    static func file(_ name: String) -> (type: String, body: Data)? {
        guard !name.contains("/"), !name.hasPrefix("."),
              let type = types[(name as NSString).pathExtension],
              let body = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return (type, body)
    }

    /// Everything in the folder, hidden files aside. Each one needs its extension in `types` to be served.
    static var names: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    /// Differs whenever a file of the page differs.
    static var version: String {
        var hash = SHA256()
        for name in names {
            guard let file = file(name) else { continue }
            hash.update(data: Data(name.utf8))
            hash.update(data: file.body)
        }
        return hash.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
