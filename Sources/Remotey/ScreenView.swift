import AppKit
import CoreImage
import ImageIO
import ScreenCaptureKit

/// Live view for the phone: streams the screen region around the cursor as JPEG frames.
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

        /// Nil for a size no phone display has.
        init?(width: Double, height: Double, zoom: Double, pixelRatio: Double) {
            guard (50...4000).contains(width), (50...4000).contains(height) else { return nil }
            self.width = width
            self.height = height
            self.zoom = min(max(zoom, 0.25), 4)
            self.pixelRatio = min(max(pixelRatio, 1), ScreenView.maxPixelRatio)
        }
    }

    private struct DisplayUnavailable: Error {}

    private let send: (Data) -> Void

    /// `send` delivers one frame on the main queue. The phone answers frames by number through `frameShown`.
    init(send: @escaping (Data) -> Void) {
        self.send = send
    }

    private static let framesPerSecond: Int32 = 30
    private static let maxOutputWidth = 1400.0
    /// Sharper than 2x costs bandwidth and frame rate for little gain at arm's length.
    private static let maxPixelRatio = 2.0
    /// Frames sent but not yet shown on the phone. Sockets and proxies on the way buffer megabytes,
    /// so only the phone can tell whether it keeps up. Two lets the next frame travel while one decodes.
    private static let maxFramesInFlight = 2

    // Main queue state.
    private var request: Request?
    private var stream: SCStream?
    private var streamDisplay: CGDirectDisplayID = 0
    private var configuring = false
    private var dirty = false
    private var displayWatch: Timer?

    // Frame queue state.
    private let queue = DispatchQueue(label: "remotey.frames", qos: .userInteractive)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var geometry: (request: Request, bounds: CGRect)?
    private var latest: CVPixelBuffer?
    private var framesSent: UInt32 = 0
    private var framesShown: UInt32 = 0

    func update(_ request: Request?) {
        guard request != self.request else { return }
        // Frames of a stopped view may never be answered, so a new view counts none of them as in flight.
        if self.request == nil { queue.async { self.framesShown = self.framesSent } }
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
            guard number > self.framesShown, number <= self.framesSent else { return }
            self.framesShown = number
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
        config.minimumFrameInterval = CMTime(value: 1, timescale: Self.framesPerSecond)
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
        queue.async { self.geometry = (request, bounds) }
    }

    @MainActor
    private func teardown() async {
        let old = stream
        stream = nil
        streamDisplay = 0
        queue.async {
            self.geometry = nil
            self.latest = nil
        }
        try? await old?.stopCapture()
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
        guard type == .screen, let buffer = sampleBuffer.imageBuffer else { return }
        // While the phone is busy only the newest frame is kept, so a slow link or phone lowers the
        // frame rate instead of building up delay, and the last frame of a movement always arrives.
        latest = buffer
        encodeLatest()
    }

    /// Frame layout, little endian: Float32 cursor x, Float32 cursor y (both 0...1 inside the image),
    /// UInt32 frame number, then JPEG.
    private func encodeLatest() {
        guard framesSent - framesShown < Self.maxFramesInFlight, let buffer = latest, let geometry else { return }
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
        guard let jpeg = ciContext.jpegRepresentation(
            of: image, colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.5]) else { return }

        var header = [Float32((cursor.x - bounds.minX - x) / size.width),
                      Float32((cursor.y - bounds.minY - y) / size.height)]
        var frame = Data(bytes: &header, count: MemoryLayout<Float32>.size * 2)
        framesSent += 1
        withUnsafeBytes(of: framesSent.littleEndian) { frame.append(contentsOf: $0) }
        frame.append(jpeg)
        DispatchQueue.main.async { self.send(frame) }
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
