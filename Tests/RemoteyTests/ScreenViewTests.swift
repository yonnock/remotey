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

    func testRequestedFrameRateIsBoundedAndJPEGStaysAt30FPS() throws {
        func request(_ fps: Int, h264: Bool = true) throws -> ScreenView.Request {
            try XCTUnwrap(ScreenView.Request(width: 390, height: 844, zoom: 0.5, pixelRatio: 2, h264: h264, fps: fps))
        }
        XCTAssertEqual(try request(60).framesPerSecond, 60)
        XCTAssertEqual(try request(120).framesPerSecond, 120)
        XCTAssertEqual(try request(1000).framesPerSecond, 120)
        XCTAssertEqual(try request(-1).framesPerSecond, 30)
        XCTAssertEqual(try request(120, h264: false).framesPerSecond, 30)
    }

    func testViewStaysOnOneDisplayAndPansSteadilyAcrossTheSeam() throws {
        let request = try XCTUnwrap(ScreenView.Request(width: 390, height: 844, zoom: 1, pixelRatio: 2, h264: true, fps: 60))
        // A large display with a smaller one to its right, bottom edges aligned.
        let large = CGRect(x: 0, y: 0, width: 2560, height: 1440), small = CGRect(x: 2560, y: 323, width: 1728, height: 1117)
        func view(_ x: Double, _ y: Double) -> CGRect {
            ScreenView.viewport(request, displays: [large, small], around: CGPoint(x: x, y: y))
        }
        XCTAssertEqual(view(3400, 900), CGRect(x: 3205, y: 478, width: 390, height: 844))
        // Away from the seam an edge shows no empty space, although the box around both displays reaches further.
        XCTAssertEqual(view(3400, 323).minY, 323)
        XCTAssertEqual(view(4287, 1439), CGRect(x: 4288 - 390, y: 1440 - 844, width: 390, height: 844))
        XCTAssertEqual(view(0, 0).origin, .zero)
        // Along a path over the seam the view never moves further than the cursor does.
        for y in [323.0, 400, 900, 1439] {
            var last = view(2300, y)
            for x in stride(from: 2301.0, through: 2900, by: 1) {
                let next = view(x, y)
                XCTAssertLessThanOrEqual(abs(next.minX - last.minX), 1.001, "x jump at \(x), \(y)")
                XCTAssertLessThanOrEqual(abs(next.minY - last.minY), 2, "y jump at \(x), \(y)")
                XCTAssertTrue(next.contains(CGPoint(x: x, y: y)))
                last = next
            }
            XCTAssertEqual(view(2560, y).midX, 2560, accuracy: 0.001, "the view is centred on the seam")
        }
        // The region never exceeds the smallest display, so away from a seam one display fills the view.
        let overview = try XCTUnwrap(ScreenView.Request(width: 390, height: 844, zoom: 0.25, pixelRatio: 2, h264: true, fps: 60))
        let whole = ScreenView.viewport(overview, displays: [large, small], around: CGPoint(x: 3400, y: 900))
        XCTAssertEqual(whole.minY, small.minY)
        XCTAssertEqual(whole.height, small.height)
        XCTAssertTrue(small.contains(whole))
        // Stacked displays of different widths.
        let half = try XCTUnwrap(ScreenView.Request(width: 390, height: 844, zoom: 0.5, pixelRatio: 2, h264: true, fps: 60))
        let upper = CGRect(x: -195, y: -1440, width: 2560, height: 1440), lower = CGRect(x: 0, y: 0, width: 2056, height: 1329)
        var last = ScreenView.viewport(half, displays: [upper, lower], around: CGPoint(x: 1000, y: -900))
        for y in stride(from: -899.0, through: 1328, by: 1) {
            let next = ScreenView.viewport(half, displays: [upper, lower], around: CGPoint(x: 1000, y: y))
            XCTAssertLessThanOrEqual(abs(next.minY - last.minY), 1.001, "y jump at \(y)")
            XCTAssertGreaterThanOrEqual(next.minY, -1440)
            XCTAssertLessThanOrEqual(next.maxY, 1329.001)
            last = next
        }
        XCTAssertEqual(last.maxY, 1329, accuracy: 0.001)
        // One display behaves as before.
        XCTAssertEqual(ScreenView.viewport(request, displays: [large], around: CGPoint(x: 2559, y: 5)),
                       CGRect(x: 2560 - 390, y: 0, width: 390, height: 844))
    }
}
