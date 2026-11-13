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

    private func encode(_ image: CIImage, encoder: H264Encoder, context: CIContext) throws -> Data {
        let ready = expectation(description: "hardware encoder output without flushing")
        var result: Data?
        try encoder.encode(image, context: context) { data in result = data; ready.fulfill() }
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
