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
