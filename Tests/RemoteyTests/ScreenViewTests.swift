import XCTest
@testable import Remotey

final class ScreenViewTests: XCTestCase {
    func testOnlyChangesInsideTheViewCount() {
        // A display above and left of the main one, captured at half its density.
        let display = CGRect(x: -195, y: -1440, width: 2560, height: 1440)
        let view = CGRect(x: 800, y: -900, width: 614, height: 800)
        func changes(_ dirty: [CGRect]?) -> Bool {
            ScreenView.changes(dirty, pixelsPerPoint: 0.5, on: display, touch: view)
        }
        XCTAssertTrue(changes(nil), "a capture without areas may have changed anywhere")
        // A clock at the right end of the menu bar: pixels 1268...1280 are points 2341...2365.
        XCTAssertFalse(changes([CGRect(x: 1268, y: 0.5, width: 12, height: 11)]))
        // Pixel 600, 300 is the point 1005, -840.
        XCTAssertTrue(changes([CGRect(x: 1268, y: 0.5, width: 12, height: 11), CGRect(x: 600, y: 300, width: 4, height: 4)]))
        // Just left of the view, and touching it.
        XCTAssertFalse(changes([CGRect(x: 480, y: 300, width: 17, height: 10)]))
        XCTAssertTrue(changes([CGRect(x: 480, y: 300, width: 18, height: 10)]))
    }

    func testAPhoneWithSlowAnswersGetsMorePicturesUnderWayButNeverManyMore() {
        func window(_ answer: TimeInterval, _ fps: Int32) -> Int {
            ScreenView.framesInFlight(fastestAnswer: answer, framesPerSecond: fps)
        }
        XCTAssertEqual(window(.infinity, 120), 2, "nothing answered yet")
        XCTAssertEqual(window(0.004, 120), 2)
        XCTAssertEqual(window(0.004, 60), 2)
        // 30 ms span three and a half frame intervals at 120 fps, not even two at 60 fps.
        XCTAssertEqual(window(0.030, 120), 5)
        XCTAssertEqual(window(0.030, 60), 3)
        XCTAssertEqual(window(0.5, 120), 6)
        XCTAssertEqual(window(0.5, 30), 6)
    }

    func testMessageLayout() {
        let picture = ScreenView.message(pointer: CGPoint(x: 0.5, y: 0.25), number: 7, sequence: 0x0102_0304,
                                         width: 614, payload: Data([0xff, 0xd8]))
        XCTAssertEqual(picture.count, ScreenView.headerSize + 2)
        func float(_ offset: Int) -> Float32 {
            Float32(bitPattern: picture.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        }
        XCTAssertEqual([float(0), float(4), float(16)], [0.5, 0.25, 614])
        XCTAssertEqual(Array(picture[8..<16]), [7, 0, 0, 0, 4, 3, 2, 1])
        XCTAssertEqual(Array(picture[20...]), [0xff, 0xd8])
        let pointerOnly = ScreenView.message(pointer: .zero, number: 0, sequence: 1, width: 614, payload: Data())
        XCTAssertEqual(pointerOnly.count, ScreenView.headerSize)
    }
}
