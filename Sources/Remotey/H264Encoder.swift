import CoreImage
import VideoToolbox

/// One hardware encoder per view size. Call on the frame queue, with at most one encode pending.
/// Output includes SPS/PPS with its IDR, so a resized or restarted view needs no separate config message.
final class H264Encoder {
    struct Failure: Error { let status: OSStatus }
    enum Output {
        case frame(Data)
        case dropped
        case failed
    }

    let width: Int
    let height: Int
    let framesPerSecond: Int32
    /// An average the encoder aims at, not a cap. It may change while the stream runs, without a key frame:
    /// `LinkRate` fits it to what the link carries.
    var bitsPerSecond: Double {
        didSet {
            guard bitsPerSecond != oldValue else { return }
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: Int(bitsPerSecond) as CFNumber)
        }
    }
    private let session: VTCompressionSession

    init(width: Int, height: Int, framesPerSecond: Int32 = 60, bitsPerSecond: Double = LinkRate.most) throws {
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.bitsPerSecond = bitsPerSecond
        var created: VTCompressionSession?
        try Self.check(VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: [
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
                kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
            ] as CFDictionary,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferIOSurfacePropertiesKey: [:],
            ] as CFDictionary,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &created))
        guard let created else { throw Failure(status: kVTAllocationFailedErr) }
        session = created
        do {
            try Self.check(VTSessionSetProperties(session, propertyDictionary: [
                kVTCompressionPropertyKey_RealTime: true,
                kVTCompressionPropertyKey_AllowFrameReordering: false,
                kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Baseline_AutoLevel,
                kVTCompressionPropertyKey_ExpectedFrameRate: framesPerSecond,
                kVTCompressionPropertyKey_AverageBitRate: Int(bitsPerSecond),
                // The link is reliable and every size gets its own encoder, so one key frame starts the
                // stream and no later one interrupts it with a burst of data.
                kVTCompressionPropertyKey_MaxKeyFrameInterval: Int32.max,
            ] as CFDictionary))
            try Self.check(VTCompressionSessionPrepareToEncodeFrames(session))
        } catch {
            VTCompressionSessionInvalidate(session)
            throw error
        }
    }

    deinit { VTCompressionSessionInvalidate(session) }

    /// The callback may run on a VideoToolbox thread. A rate-control drop is not an encoder failure.
    func encode(_ image: CIImage, context: CIContext, completion: @escaping (Output) -> Void) throws {
        guard let pool = VTCompressionSessionGetPixelBufferPool(session) else {
            throw Failure(status: kVTAllocationFailedErr)
        }
        var buffer: CVPixelBuffer?
        try Self.check(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer))
        guard let buffer else { throw Failure(status: kVTAllocationFailedErr) }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.render(image, to: buffer, bounds: bounds, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let time = CMTime(seconds: ProcessInfo.processInfo.systemUptime, preferredTimescale: 1_000_000)
        try Self.check(VTCompressionSessionEncodeFrame(
            session, imageBuffer: buffer, presentationTimeStamp: time, duration: .invalid,
            frameProperties: nil, infoFlagsOut: nil
        ) { status, flags, sample in
            if status != noErr { completion(.failed) }
            else if flags.contains(.frameDropped) { completion(.dropped) }
            else if let frame = sample.flatMap(Self.packet) { completion(.frame(frame)) }
            else { completion(.failed) }
        })
    }

    /// Payload: profile/compatibility/level bytes, IDR flag, then Annex B H.264.
    /// JPEG keeps its existing FF D8 prefix, making the fallback distinguishable on the wire.
    private static func packet(_ sample: CMSampleBuffer) -> Data? {
        guard let format = sample.formatDescription, let block = sample.dataBuffer else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let key = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
        var count = 0, headerLength: Int32 = 0
        var sps: UnsafePointer<UInt8>?, spsSize = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: &sps, parameterSetSizeOut: &spsSize,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength) == noErr,
            let sps, spsSize >= 4, headerLength == 4 else { return nil }
        var packet = Data([sps[1], sps[2], sps[3], key ? 1 : 0])
        let start: [UInt8] = [0, 0, 0, 1]
        if key {
            for index in 0..<count {
                var bytes: UnsafePointer<UInt8>?, size = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &bytes, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let bytes else { return nil }
                packet.append(contentsOf: start)
                packet.append(bytes, count: size)
            }
        }
        let length = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes) == noErr else { return nil }
        var offset = 0
        while offset + 4 <= length {
            let size = bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            offset += 4
            guard size > 0, size <= length - offset else { return nil }
            packet.append(contentsOf: start)
            packet.append(contentsOf: bytes[offset..<offset + size])
            offset += size
        }
        return offset == length ? packet : nil
    }

    private static func check(_ status: OSStatus) throws {
        if status != noErr { throw Failure(status: status) }
    }
}
