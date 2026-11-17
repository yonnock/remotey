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
        // Stacked displays of different widths, and a view taller than either: it shows one whole and the
        // other's near part, and still pans steadily from one to the other.
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
        XCTAssertEqual(ScreenView.viewport(half, displays: [upper, lower], around: CGPoint(x: 1000, y: -900)).minY, -1440)
        // One display behaves as before.
        XCTAssertEqual(ScreenView.viewport(request, displays: [large], around: CGPoint(x: 2559, y: 5)),
                       CGRect(x: 2560 - 390, y: 0, width: 390, height: 844))
    }

    func testZoomedOutTheViewShowsTheWholeDisplayUprightAndSideways() throws {
        let display = CGRect(x: 0, y: 0, width: 3008, height: 1692)
        func view(_ width: Double, _ height: Double, zoom: Double, at cursor: CGPoint, displays: [CGRect] = [display]) throws -> CGRect {
            let request = try XCTUnwrap(ScreenView.Request(width: width, height: height, zoom: zoom, pixelRatio: 3, h264: true, fps: 60))
            return ScreenView.viewport(request, displays: displays, around: cursor)
        }
        // Upright, 0.25: 1480 points wide and taller than the display, which lies in the view's middle
        // with empty space above and below. Sideways the view still pans.
        let upright = try view(370, 560, zoom: 0.25, at: CGPoint(x: 1000, y: 200))
        XCTAssertEqual(upright, CGRect(x: 260, y: 846 - 1120, width: 1480, height: 2240))
        XCTAssertEqual(try view(370, 560, zoom: 0.25, at: CGPoint(x: 1000, y: 1600)), upright, "moving up and down leaves the picture as it is")
        XCTAssertEqual(try view(370, 560, zoom: 0.25, at: CGPoint(x: 3000, y: 200)).maxX, 3008)
        // Further out the view stops where the display is whole: its width fills the pad's.
        for zoom in [0.1, 0.05, 0.02, 0.001] {
            let whole = try view(370, 560, zoom: zoom, at: CGPoint(x: 5, y: 1600))
            XCTAssertEqual(whole.minX, 0, accuracy: 0.001)
            XCTAssertEqual(whole.width, 3008, accuracy: 0.001)
            XCTAssertEqual(whole.midY, 846, accuracy: 0.001)
            XCTAssertEqual(whole.width / whole.height, 370.0 / 560, accuracy: 0.0001, "the pad's aspect")
        }
        // Sideways the display's height is what stops it.
        let sideways = try view(700, 330, zoom: 0.02, at: CGPoint(x: 3000, y: 5))
        XCTAssertEqual(sideways.minY, 0, accuracy: 0.001)
        XCTAssertEqual(sideways.height, 1692, accuracy: 0.001)
        XCTAssertEqual(sideways.midX, 1504, accuracy: 0.001)
        XCTAssertTrue(sideways.insetBy(dx: -0.001, dy: -0.001).contains(display))
    }

    func testZoomedOutBeyondADisplayTheViewShowsItsNeighboursAndAtMostTheWholeDesktop() throws {
        // Two large displays side by side and a small one right of them, bottom edges aligned.
        let left = CGRect(x: 0, y: 0, width: 3008, height: 1692), middle = CGRect(x: 3008, y: 0, width: 3008, height: 1692)
        let small = CGRect(x: 6016, y: 575, width: 1728, height: 1117)
        let displays = [left, middle, small], all = CGRect(x: 0, y: 0, width: 7744, height: 1692)
        func view(_ width: Double, _ height: Double, zoom: Double, _ x: Double, _ y: Double) throws -> CGRect {
            let request = try XCTUnwrap(ScreenView.Request(width: width, height: height, zoom: zoom, pixelRatio: 3, h264: true, fps: 60))
            return ScreenView.viewport(request, displays: displays, around: CGPoint(x: x, y: y))
        }
        // Wider than the small display but not than the desktop: no empty space right of it, the neighbour instead.
        let beside = try view(700, 330, zoom: 0.25, 7000, 1000)
        XCTAssertEqual(beside.width, 2800)
        XCTAssertEqual(beside.maxX, 7744, accuracy: 0.001)
        XCTAssertTrue(beside.intersects(middle))
        // All the way out, upright and sideways: every display is in the picture, wherever the pointer is.
        for (width, height) in [(370.0, 560.0), (700, 330)] {
            let size = try view(width, height, zoom: 0.02, 100, 100).size
            XCTAssertEqual(size.width / size.height, width / height, accuracy: 0.0001)
            for (x, y) in [(100.0, 100.0), (3008, 800), (4000, 1691), (7743, 600), (7000, 1691)] {
                let whole = try view(width, height, zoom: 0.02, x, y)
                XCTAssertEqual(whole.size.width, size.width, accuracy: 0.001, "one size for every place of the pointer")
                XCTAssertTrue(whole.insetBy(dx: -0.001, dy: -0.001).contains(all), "\(whole) at \(x), \(y)")
                XCTAssertEqual(whole.midX, all.midX, accuracy: 0.001)
                XCTAssertEqual(whole.midY, all.midY, accuracy: 0.001)
            }
        }
        // At every zoom the view holds the pointer and never jumps while it crosses the desktop.
        for zoom in [0.02, 0.04, 0.06, 0.09, 0.12, 0.18, 0.25, 0.35, 0.5, 1] {
            for (width, height) in [(370.0, 560.0), (700, 330)] {
                for y in [600.0, 1000, 1691] {
                    var last = try view(width, height, zoom: zoom, 0, y)
                    for x in stride(from: 1.0, through: 7743, by: 1) {
                        let next = try view(width, height, zoom: zoom, x, y)
                        XCTAssertLessThanOrEqual(abs(next.minX - last.minX), 2, "x jump at \(x), \(y), zoom \(zoom)")
                        // Across the path the view takes up the small display's offset of 575 points while
                        // the pointer covers the half view before the seam.
                        XCTAssertLessThanOrEqual(abs(next.minY - last.minY), max(2, 575 / (next.width / 2) + 0.001),
                                                 "y jump at \(x), \(y), zoom \(zoom)")
                        XCTAssertTrue(next.insetBy(dx: -0.001, dy: -0.001).contains(CGPoint(x: x, y: y)), "pointer out of view at \(x), \(y), zoom \(zoom)")
                        last = next
                    }
                }
            }
        }
    }

    func testAViewLargerThanItsDisplayCrossesEverySeamOfThreeDisplaysWithoutAJump() throws {
        // A small display below two large ones, left-aligned with the first and centred under their seam.
        for small in [CGRect(x: 0, y: 0, width: 2056, height: 1329), CGRect(x: 1936, y: 0, width: 2056, height: 1329)] {
            let displays = [CGRect(x: 0, y: -1692, width: 3008, height: 1692), CGRect(x: 3008, y: -1692, width: 3008, height: 1692), small]
            let all = displays.reduce(CGRect.null) { $0.union($1) }
            for (width, height) in [(370.0, 560.0), (700, 330)] {
                for zoom in [0.02, 0.09, 0.18, 0.25, 0.35] {
                    let request = try XCTUnwrap(ScreenView.Request(width: width, height: height, zoom: zoom, pixelRatio: 3, h264: true, fps: 60))
                    func view(_ x: Double, _ y: Double) -> CGRect { ScreenView.viewport(request, displays: displays, around: CGPoint(x: x, y: y)) }
                    let size = view(small.midX, 5).size
                    // The limits take up at most the desktop while the pointer covers half a view, along either axis.
                    let half = min(size.width, size.height) / 2
                    let stepX = max(2, all.width / half), stepY = max(2, all.height / half)
                    func steady(_ next: CGRect, after last: CGRect, _ place: String) {
                        XCTAssertLessThanOrEqual(abs(next.minX - last.minX), stepX + 0.001, "x jump \(place), zoom \(zoom), pad \(width)")
                        XCTAssertLessThanOrEqual(abs(next.minY - last.minY), stepY + 0.001, "y jump \(place), zoom \(zoom), pad \(width)")
                    }
                    // Up and down across the seam between the small display and the large ones.
                    for x in stride(from: small.minX + 6, to: small.maxX, by: 291) {
                        var last = view(x, 1328)
                        for y in stride(from: 1327.0, through: -1692, by: -1) {
                            let next = view(x, y)
                            steady(next, after: last, "at \(x), \(y)")
                            last = next
                        }
                    }
                    // Sideways across the seam between the large ones.
                    for y in [-800.0, -1] {
                        var last = view(0, y)
                        for x in stride(from: 1.0, to: 6016, by: 1) {
                            let next = view(x, y)
                            steady(next, after: last, "at \(x), \(y)")
                            last = next
                        }
                    }
                }
            }
        }
    }

    func testTypedTextIsCentredAndTheViewWaitsUntilTheCaretNearsAnEdge() throws {
        let request = try XCTUnwrap(ScreenView.Request(width: 400, height: 200, zoom: 1, pixelRatio: 2, h264: true, fps: 60))
        let display = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let around = { ScreenView.viewport(request, displays: [display], around: $0) }
        func caret(_ x: Double, _ y: Double) -> TextFocus.Target { .init(rect: CGRect(x: x, y: y, width: 0, height: 16), exact: true) }

        let first = try XCTUnwrap(ScreenView.textView(for: caret(800, 500), held: nil, around: around))
        XCTAssertEqual(first, CGRect(x: 600, y: 408, width: 400, height: 200))
        // A few characters further the view stays where it is.
        XCTAssertEqual(ScreenView.textView(for: caret(900, 500), held: first, around: around), first)
        // Close to its right edge it centres the caret again.
        XCTAssertEqual(ScreenView.textView(for: caret(940, 500), held: first, around: around)?.midX, 940)
        // At the display's edge it stays on the display.
        XCTAssertEqual(ScreenView.textView(for: caret(5, 5), held: nil, around: around)?.origin, .zero)
    }

    func testAFocusedElementCountsOnlyIfItFitsTheView() throws {
        let request = try XCTUnwrap(ScreenView.Request(width: 400, height: 200, zoom: 1, pixelRatio: 2, h264: true, fps: 60))
        let around = { ScreenView.viewport(request, displays: [CGRect(x: 0, y: 0, width: 1728, height: 1117)], around: $0) }
        let field = TextFocus.Target(rect: CGRect(x: 100, y: 300, width: 240, height: 24), exact: false)
        XCTAssertEqual(ScreenView.textView(for: field, held: nil, around: around)?.midX, 220)
        let editor = TextFocus.Target(rect: CGRect(x: 0, y: 40, width: 1200, height: 900), exact: false)
        XCTAssertNil(ScreenView.textView(for: editor, held: nil, around: around), "the pointer's view instead")
    }
}
