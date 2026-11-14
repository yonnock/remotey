import CoreImage
import XCTest
@testable import Remotey

final class H264EncoderTests: XCTestCase {
    func testStreamStartsWithParameterSetsAndIDRThenUsesDeltaFrames() throws {
        let encoder = try H264Encoder(width: 640, height: 360)
        let context = CIContext()
        let image = CIImage(color: CIColor(red: 0.2, green: 0.5, blue: 0.8))
            .cropped(to: CGRect(x: 0, y: 0, width: 640, height: 360))
        let first = try encode(image, encoder: encoder, context: context)
        XCTAssertEqual(first[3], 1)
        XCTAssertTrue(nalTypes(first).isSuperset(of: [7, 8, 5]), "First frame must be independently decodable")
        let second = try encode(image, encoder: encoder, context: context)
        XCTAssertEqual(second[3], 0)
        XCTAssertTrue(nalTypes(second).contains(1))
        XCTAssertLessThan(second.count, first.count, "An unchanged image should use interframe compression")
    }

    func testOneKeyFrameStartsTheStreamAndNoLaterOneInterruptsIt() throws {
        let encoder = try H264Encoder(width: 640, height: 360, framesPerSecond: 120)
        let context = CIContext()
        // Five seconds of video at 120 fps.
        let keys = try (0..<600).filter { index in
            let image = CIImage(color: CIColor(red: Double(index % 7) / 7, green: 0.5, blue: 0.5))
                .cropped(to: CGRect(x: 0, y: 0, width: 640, height: 360))
            if case .frame(let data) = try output(image, encoder: encoder, context: context) { return data[3] == 1 }
            return false
        }
        XCTAssertEqual(keys, [0])
    }

    func testNewSizeStartsAnIndependentStream() throws {
        let context = CIContext()
        for (width, height) in [(640, 360), (360, 640)] {
            let encoder = try H264Encoder(width: width, height: height)
            let image = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
            let frame = try encode(image, encoder: encoder, context: context)
            XCTAssertEqual(frame[3], 1)
            XCTAssertTrue(nalTypes(frame).isSuperset(of: [7, 8, 5]))
        }
    }

    func test120FPSHardwareStreamStartsWithoutBuffering() throws {
        for (width, height) in [(780, 442), (780, 1688)] {
            let encoder = try H264Encoder(width: width, height: height, framesPerSecond: 120)
            let image = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
            let frame = try encode(image, encoder: encoder, context: CIContext())
            XCTAssertEqual(encoder.framesPerSecond, 120)
            XCTAssertEqual(frame[3], 1)
            XCTAssertTrue(nalTypes(frame).isSuperset(of: [7, 8, 5]))
        }
    }

    func testRequestedFrameRateIsBoundedAndOlderClientsStayAt60FPS() throws {
        func request(_ fps: Int = 60, h264: Bool = true) throws -> ScreenView.Request {
            try XCTUnwrap(ScreenView.Request(width: 390, height: 844, zoom: 0.5, pixelRatio: 2, h264: h264, fps: fps))
        }
        XCTAssertEqual(try request().framesPerSecond, 60)
        XCTAssertEqual(try request(120).framesPerSecond, 120)
        XCTAssertEqual(try request(1000).framesPerSecond, 120)
        XCTAssertEqual(try request(-1).framesPerSecond, 30)
        XCTAssertEqual(try request(120, h264: false).framesPerSecond, 30)
    }

    func testViewStaysOnOneDisplayAndPansSteadilyAcrossTheSeam() throws {
        let request = try XCTUnwrap(ScreenView.Request(width: 390, height: 844, zoom: 1, pixelRatio: 2))
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
        let overview = try XCTUnwrap(ScreenView.Request(width: 390, height: 844, zoom: 0.25, pixelRatio: 2))
        let whole = ScreenView.viewport(overview, displays: [large, small], around: CGPoint(x: 3400, y: 900))
        XCTAssertEqual(whole.minY, small.minY)
        XCTAssertEqual(whole.height, small.height)
        XCTAssertTrue(small.contains(whole))
        // Stacked displays of different widths.
        let half = try XCTUnwrap(ScreenView.Request(width: 390, height: 844, zoom: 0.5, pixelRatio: 2))
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

    func testRateControlDropsAreNotFailuresAndTheLastImageCanBeRetried() throws {
        let encoder = try H264Encoder(width: 780, height: 1688, framesPerSecond: 120)
        let context = CIContext()
        let bounds = CGRect(x: 0, y: 0, width: 780, height: 1688)
        var encoded = 0
        // High-entropy inputs exhaust the bitrate budget and can trigger intentional frame drops.
        for _ in 0..<30 {
            let noise = try XCTUnwrap(CIFilter(name: "CIRandomGenerator")?.outputImage).cropped(to: bounds)
            switch try output(noise, encoder: encoder, context: context) {
            case .frame: encoded += 1
            case .dropped: break
            case .failed: return XCTFail("Rate-control pressure must not force a JPEG fallback")
            }
        }
        XCTAssertGreaterThan(encoded, 0)
        let lastImage = CIImage(color: .white).cropped(to: bounds)
        for _ in 0..<120 {
            switch try output(lastImage, encoder: encoder, context: context) {
            case .frame: return
            case .dropped: Thread.sleep(forTimeInterval: 1 / 120)
            case .failed: return XCTFail("Encoder did not recover after bitrate pressure")
            }
        }
        XCTFail("Last image remained dropped after retries")
    }

    private func encode(_ image: CIImage, encoder: H264Encoder, context: CIContext) throws -> Data {
        let output = try output(image, encoder: encoder, context: context)
        if case .frame(let data) = output { return data }
        XCTFail("Expected a frame, got \(output)")
        throw H264Encoder.Failure(status: -1)
    }

    private func output(_ image: CIImage, encoder: H264Encoder, context: CIContext) throws -> H264Encoder.Output {
        let ready = expectation(description: "hardware encoder output without flushing")
        var result: H264Encoder.Output?
        try encoder.encode(image, context: context) { output in
            result = output
            ready.fulfill()
        }
        wait(for: [ready], timeout: 3)
        return try XCTUnwrap(result)
    }

    private func nalTypes(_ packet: Data) -> Set<UInt8> {
        let bytes = Array(packet)
        return Set((4..<bytes.count - 4).compactMap { i in
            bytes[i..<i + 4].elementsEqual([0, 0, 0, 1]) ? bytes[i + 4] & 31 : nil
        })
    }
}
