import XCTest
@testable import Remotey

/// The layout Web/live-view.js reads. scripts/live-view.test.mjs builds the same bytes for the page's half.
final class WireTests: XCTestCase {
    func testLayoutOfAnUpdateWithAPicture() {
        let update = LiveUpdate(pointer: CGPoint(x: 0.5, y: 0.25), focus: CGPoint(x: 0.75, y: 1.5), followsText: true,
                                request: 9, width: 614, framesPerSecond: 120, sequence: 0x0102_0304,
                                picture: (number: 7, content: .h264(Data([66, 192, 31, 1]))))
        let data = update.data
        func float(_ offset: Int) -> Float32 {
            Float32(bitPattern: data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        }
        XCTAssertEqual(Array(data[0..<3]), [2, 120, 1])
        XCTAssertEqual([float(3), float(7), float(11), float(15), float(19)], [0.5, 0.25, 0.75, 1.5, 614])
        XCTAssertEqual(Array(data[23..<35]), [4, 3, 2, 1, 9, 0, 0, 0, 7, 0, 0, 0])
        XCTAssertEqual(Array(data[LiveUpdate.headerSize...]), [66, 192, 31, 1])
    }

    func testKinds() {
        var update = LiveUpdate(pointer: .zero, focus: .zero, followsText: false, request: 0, width: 614,
                                framesPerSecond: 60, sequence: 1, picture: nil)
        XCTAssertEqual(Array(update.data), [0, 60, 0] + [UInt8](repeating: 0, count: 16) + [0, 0x80, 0x19, 0x44]
                       + [1, 0, 0, 0] + [UInt8](repeating: 0, count: 8),
                       "only the pointer moved: a header and nothing else")
        update.picture = (number: 1, content: .jpeg(Data([0xff, 0xd8])))
        XCTAssertEqual(update.data[0], 1)
        XCTAssertEqual(update.data.count, LiveUpdate.headerSize + 2)
    }

    func testTextMessagesAreJSON() throws {
        func object(_ text: String) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }
        let accepted = try object(Wire.accepted(accessibility: true, page: "abc"))
        XCTAssertEqual(accepted["t"] as? String, "ok")
        XCTAssertEqual(accepted["ax"] as? Bool, true)
        XCTAssertEqual(accepted["page"] as? String, "abc")
        XCTAssertEqual(try object(Wire.denied)["t"] as? String, "denied")
        XCTAssertEqual(try object(Wire.viewRefused)["ok"] as? Bool, false)
        let picture = Pointer.Picture(pixels: Data(repeating: 255, count: 4 * 6 * 9), width: 6, height: 9,
                                      size: CGSize(width: 2, height: 3), hotSpot: CGPoint(x: 1, y: 0.5))
        let cursor = try object(try XCTUnwrap(Wire.cursor(picture)))
        XCTAssertEqual(cursor["t"] as? String, "cursor")
        XCTAssertEqual([cursor["w"], cursor["h"], cursor["x"], cursor["y"]].map { $0 as? Double }, [2, 3, 1, 0.5])
        let png = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(cursor["png"] as? String)))
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4e, 0x47])
    }

    private func command(_ json: String) throws -> Wire.Command {
        try Wire.command(from: Data(json.utf8))
    }

    func testCommandsOfThePage() throws {
        guard case .auth(token: "abc") = try command(#"{"t":"auth","token":"abc"}"#) else { return XCTFail("auth") }
        guard case .move(dx: 3.5, dy: -2, sequence: 7) = try command(#"{"t":"m","dx":3.5,"dy":-2,"q":7}"#) else { return XCTFail("move") }
        guard case .move(dx: 1, dy: 1, sequence: nil) = try command(#"{"t":"m","dx":1,"dy":1}"#) else { return XCTFail("move without a number") }
        guard case .scroll(dx: 0, dy: 12) = try command(#"{"t":"s","dx":0,"dy":12}"#) else { return XCTFail("scroll") }
        guard case .scrollEnded = try command(#"{"t":"se"}"#) else { return XCTFail("end of a scroll") }
        guard case .click(.right, mods: []) = try command(#"{"t":"c","b":"right"}"#) else { return XCTFail("click") }
        guard case .click(.left, mods: ["alt"]) = try command(#"{"t":"c","b":"left","mods":["alt"]}"#) else { return XCTFail("click with a modifier") }
        guard case .button(.left, down: true, mods: ["cmd", "shift"]) = try command(#"{"t":"b","b":"left","d":true,"mods":["cmd","shift"]}"#) else { return XCTFail("button") }
        guard case .button(.left, down: false, mods: []) = try command(#"{"t":"b","b":"left","d":false}"#) else { return XCTFail("release") }
        guard case .text("hä") = try command(#"{"t":"text","s":"hä"}"#) else { return XCTFail("text") }
        guard case .key("w", mods: ["cmd"], count: 2) = try command(#"{"t":"key","k":"w","mods":["cmd"],"n":2}"#) else { return XCTFail("key") }
        guard case .media("play") = try command(#"{"t":"media","k":"play"}"#) else { return XCTFail("media") }
        guard case .shown(41) = try command(#"{"t":"shown","n":41}"#) else { return XCTFail("shown") }
    }

    func testViewRequest() throws {
        let on = #"{"t":"view","on":true,"w":390,"h":844,"zoom":0.5,"dpr":3,"codec":"h264","fps":120,"v":4}"#
        guard case .view(let request?) = try command(on) else { return XCTFail("view on") }
        XCTAssertEqual(request, ScreenView.Request(width: 390, height: 844, zoom: 0.5, pixelRatio: 3, h264: true, fps: 120, number: 4))
        guard case .view(let jpeg?) = try command(on.replacingOccurrences(of: "h264", with: "jpeg")) else { return XCTFail("jpeg") }
        XCTAssertFalse(jpeg.h264)
        for off in [#"{"t":"view","on":false}"#, #"{"t":"view","on":true,"w":390,"h":844}"#,
                    on.replacingOccurrences(of: "390", with: "5")] {
            guard case .view(nil) = try command(off) else { return XCTFail(off) }
        }
    }

    func testWhatTheAgentDoesNotActOn() throws {
        for json in [#"{"t":"noop"}"#, #"{"t":"m","dx":6000,"dy":0}"#, #"{"t":"m","dx":1}"#, #"{"t":"auth"}"#,
                     #"{"t":"shown","n":-1}"#, #"{"t":"key","k":"w"}"#,
                     #"{"t":"text","s":"\#(String(repeating: "x", count: 2001))"}"#] {
            guard case .ignored = try command(json) else { return XCTFail(json) }
        }
        XCTAssertThrowsError(try command("not json"))
        XCTAssertThrowsError(try command(#"{"dx":1}"#), "a message names its kind")
    }
}
