import AppKit
import CoreImage
import ImageIO
import ScreenCaptureKit

/// Live view for the phone: streams the screen region around the cursor as H.264, with a JPEG fallback.
/// Needs the Screen Recording permission. Captures only while a client has the view switched on.
///
/// One `SCStream` covers the display under the cursor; every frame is cropped around the cursor.
/// ScreenCaptureKit delivers frames only when the screen changes, so a static screen costs nothing.
///
/// `@unchecked Sendable`: state is confined to the main queue or the frame queue, as marked below.
final class ScreenView: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Request: Equatable {
        /// Size of the phone's display element in CSS pixels; the captured region gets the same aspect.
        let width: Double
        let height: Double
        /// 1 = one Mac point per CSS pixel, 2 = twice as large on the phone.
        let zoom: Double
        let pixelRatio: Double
        let h264: Bool

        /// Nil for a size no phone display has.
        init?(width: Double, height: Double, zoom: Double, pixelRatio: Double, h264: Bool = false) {
            guard (50...4000).contains(width), (50...4000).contains(height) else { return nil }
            self.width = width
            self.height = height
            self.zoom = min(max(zoom, 0.25), 4)
            self.pixelRatio = min(max(pixelRatio, 1), ScreenView.maxPixelRatio)
            self.h264 = h264
        }
    }

    private struct DisplayUnavailable: Error {}

    private let send: (Data) -> Void

    /// `send` delivers one frame on the main queue. The phone answers frames by number through `frameShown`.
    init(send: @escaping (Data) -> Void) {
        self.send = send
    }

    private static let framesPerSecond: Int32 = 60
    private static let maxOutputWidth = 1400.0
    /// Sharper than 2x costs bandwidth and frame rate for little gain at arm's length.
    private static let maxPixelRatio = 2.0
    /// Frames sent but not yet shown on the phone. Sockets and proxies on the way buffer megabytes,
    /// so only the phone can tell whether it keeps up. Two lets the next frame travel while one decodes.
    private static let maxFramesInFlight = 2

    // Main queue state.
    private var request: Request?
    private var revision: UInt64 = 0
    private var stream: SCStream?
    private var streamDisplay: CGDirectDisplayID = 0
    private var configuring = false
    private var dirty = false
    private var displayWatch: Timer?

    // Frame queue state.
    private let queue = DispatchQueue(label: "remotey.frames", qos: .userInteractive)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var geometry: (request: Request, bounds: CGRect, revision: UInt64)?
    private var generation = UUID()
    private var encoder: H264Encoder?
    private var encoding = false
    private var jpegFallback = false
    private var latest: CVPixelBuffer?
    private var framesSent: UInt32 = 0
    private var inFlight: Set<UInt32> = []

    func update(_ request: Request?) {
        guard request != self.request else { return }
        revision += 1
        let restarting = self.request == nil || self.request?.h264 != request?.h264
        queue.async {
            self.resetFrames()
            // A stopped or replaced viewer may never answer its old frames.
            if restarting { self.inFlight.removeAll() }
        }
        self.request = request
        if request == nil {
            displayWatch?.invalidate()
            displayWatch = nil
        } else if displayWatch == nil {
            // The stream covers one display; follow the cursor when it moves to another one.
            displayWatch = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self, self.stream != nil, Self.cursorDisplay() != self.streamDisplay else { return }
                self.configure()
            }
        }
        configure()
    }

    /// The phone has drawn (or discarded) the frame with this number.
    func frameShown(_ number: UInt32) {
        queue.async {
            guard self.inFlight.remove(number) != nil else { return }
            self.encodeLatest()
        }
    }

    /// Brings the stream in line with the newest request; calls arriving while a change is in flight are coalesced.
    private func configure() {
        dirty = true
        guard !configuring else { return }
        configuring = true
        Task { @MainActor in
            while dirty {
                dirty = false
                do {
                    try await apply()
                } catch {
                    await teardown()
                    if request != nil {
                        try? await Task.sleep(for: .seconds(1))
                        dirty = true
                    }
                }
            }
            configuring = false
        }
    }

    @MainActor
    private func apply() async throws {
        guard let request else { return await teardown() }
        let revision = self.revision
        let id = Self.cursorDisplay()
        let bounds = CGDisplayBounds(id)
        let regionWidth = Self.region(request, in: bounds).width
        let backingScale = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }?.backingScaleFactor ?? 2
        let outputWidth = min(regionWidth * backingScale, request.width * request.pixelRatio, Self.maxOutputWidth)
        // The whole display is captured at exactly the density the cropped region needs.
        let scale = outputWidth / regionWidth

        let config = SCStreamConfiguration()
        config.width = max(2, Int(bounds.width * scale))
        config.height = max(2, Int(bounds.height * scale))
        config.minimumFrameInterval = CMTime(value: 1, timescale: request.h264 ? Self.framesPerSecond : 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.queueDepth = 3

        if let stream, streamDisplay == id {
            try await stream.updateConfiguration(config)
        } else {
            await teardown()
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw DisplayUnavailable() }
            let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                                  configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            self.stream = stream
            streamDisplay = id
        }
        guard revision == self.revision else { return }
        queue.async { self.geometry = (request, bounds, revision) }
    }

    @MainActor
    private func teardown() async {
        let old = stream
        stream = nil
        streamDisplay = 0
        queue.async {
            self.resetFrames()
        }
        try? await old?.stopCapture()
    }

    /// Invalidates late encoder callbacks as well as queued captures. Frame numbers never reset.
    private func resetFrames() {
        generation = UUID()
        geometry = nil
        latest = nil
        encoder = nil
        encoding = false
        jpegFallback = false
    }

    private static func cursorDisplay() -> CGDirectDisplayID {
        Pointer.display(at: Pointer.location) ?? CGMainDisplayID()
    }

    /// Region size in points: the pad's aspect, shrunk if it would not fit on the display.
    private static func region(_ request: Request, in bounds: CGRect) -> CGSize {
        let width = request.width / request.zoom, height = request.height / request.zoom
        let fit = min(1, bounds.width / width, bounds.height / height)
        return CGSize(width: width * fit, height: height * fit)
    }

    // MARK: Frames (frame queue)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let buffer = sampleBuffer.imageBuffer,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              attachments.first?[.status] as? Int == SCFrameStatus.complete.rawValue else { return }
        // While the phone is busy only the newest frame is kept, so a slow link or phone lowers the
        // frame rate instead of building up delay, and the last frame of a movement always arrives.
        latest = buffer
        encodeLatest()
    }

    /// Frame layout, little endian: Float32 cursor x, Float32 cursor y (both 0...1 inside the image),
    /// UInt32 frame number, then JPEG or the H264Encoder payload.
    private func encodeLatest() {
        guard !encoding, inFlight.count < Self.maxFramesInFlight, let buffer = latest, let geometry else { return }
        latest = nil
        let bounds = geometry.bounds
        let size = Self.region(geometry.request, in: bounds)
        let cursor = Pointer.location
        let x = min(max(0, cursor.x - bounds.minX - size.width / 2), bounds.width - size.width)
        let y = min(max(0, cursor.y - bounds.minY - size.height / 2), bounds.height - size.height)

        let pixelHeight = Double(CVPixelBufferGetHeight(buffer))
        let scaleX = Double(CVPixelBufferGetWidth(buffer)) / bounds.width, scaleY = pixelHeight / bounds.height
        // Core Image has its origin at the bottom left.
        let crop = CGRect(x: x * scaleX, y: pixelHeight - (y + size.height) * scaleY,
                          width: size.width * scaleX, height: size.height * scaleY).integral
        let image = CIImage(cvPixelBuffer: buffer).cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        let cx = Float32((cursor.x - bounds.minX - x) / size.width)
        let cy = Float32((cursor.y - bounds.minY - y) / size.height)
        let generation = self.generation
        if geometry.request.h264 && !jpegFallback {
            do {
                // NV12 needs even dimensions. Keep them stable as the fractional crop follows the pointer.
                let width = max(2, Int(size.width * scaleX) / 2 * 2)
                let height = max(2, Int(size.height * scaleY) / 2 * 2)
                if encoder?.width != width || encoder?.height != height {
                    encoder = try H264Encoder(width: width, height: height)
                }
                encoding = true
                try encoder!.encode(image, context: ciContext) { payload in
                    self.queue.async {
                        guard generation == self.generation else { return }
                        self.encoding = false
                        if let payload {
                            self.deliver(payload, cx: cx, cy: cy, revision: geometry.revision)
                        } else {
                            self.jpegFallback = true
                            self.encoder = nil
                            self.sendJPEG(image, cx: cx, cy: cy, revision: geometry.revision)
                        }
                        self.encodeLatest()
                    }
                }
                return
            } catch {
                encoding = false
                jpegFallback = true
                encoder = nil
            }
        }
        sendJPEG(image, cx: cx, cy: cy, revision: geometry.revision)
    }

    private func sendJPEG(_ image: CIImage, cx: Float32, cy: Float32, revision: UInt64) {
        guard let jpeg = ciContext.jpegRepresentation(
            of: image, colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.5]) else { return }
        deliver(jpeg, cx: cx, cy: cy, revision: revision)
    }

    private func deliver(_ payload: Data, cx: Float32, cy: Float32, revision: UInt64) {
        var header = [cx, cy]
        var frame = Data(bytes: &header, count: MemoryLayout<Float32>.size * 2)
        framesSent &+= 1
        let number = framesSent
        inFlight.insert(number)
        withUnsafeBytes(of: framesSent.littleEndian) { frame.append(contentsOf: $0) }
        frame.append(payload)
        DispatchQueue.main.async {
            // Never send an old viewer's delta frame to a new viewer who has no reference picture.
            guard revision == self.revision else {
                self.frameShown(number)
                return
            }
            self.send(frame)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            guard stream === self.stream else { return }
            self.stream = nil
            self.streamDisplay = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.configure() }
        }
    }
}
