import XCTest
@testable import Remotey

final class ShapedFrameTests: XCTestCase {
    private let record = ShapedFrame(pid: 412, bundle: "com.example.editor", original: CGRect(x: 100, y: 80, width: 1600, height: 900),
                                     shaped: CGRect(x: 100, y: 80, width: 740, height: 1120))

    func testTheRecordOutlivesTheAgentUntilItIsRemoved() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("remotey-shaped-\(UUID().uuidString)")
        defer { ShapedFrame.remove(at: file) }
        record.save(to: file)
        XCTAssertEqual(ShapedFrame.load(from: file), record)
        ShapedFrame.remove(at: file)
        XCTAssertNil(ShapedFrame.load(from: file))
        XCTAssertNotEqual(ShapedFrame.file(port: 47820), ShapedFrame.file(port: 47800), "a development build keeps its own")
    }

    /// Only a window that still has the frame it took gets the old one back: what the user did since stands.
    func testTheWindowThatKeptThePhonesShape() {
        let other = CGRect(x: 0, y: 25, width: 800, height: 600)
        XCTAssertEqual(record.window(among: [other, CGRect(x: 100.4, y: 79.6, width: 740, height: 1120)]), 1)
        XCTAssertNil(record.window(among: [other, CGRect(x: 100, y: 80, width: 900, height: 1120)]), "resized since")
        XCTAssertNil(record.window(among: [.null]))
    }
}
