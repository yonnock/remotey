import AppKit
import CoreImage
import ImageIO
import ScreenCaptureKit

/// Live view for the phone: streams the screen region around the cursor as H.264, with a JPEG fallback.
/// Needs the Screen Recording permission. Captures only while a client has the view switched on.
///
/// One `SCStream` runs per display. Every frame is composed from the displays the region around the
/// cursor touches, so the view pans across the seam between two displays instead of switching.
/// ScreenCaptureKit delivers frames only when the screen changes, so a static screen costs nothing.
///
/// `@unchecked Sendable`: state is confined to the main queue or the frame queue, as marked below.
final class ScreenView: NSObject, SCStreamDelegate, @unchecked Sendable {
    struct Request: Equatable {
        /// Size of the phone's display element in CSS pixels; the captured region gets the same aspect.
        let width: Double
        let height: Double
        /// 1 = one Mac point per CSS pixel, 2 = twice as large on the phone.
        let zoom: Double
        let pixelRatio: Double
        let h264: Bool
        let framesPerSecond: Int32

        /// Nil for a size no phone display has.
        init?(width: Double, height: Double, zoom: Double, pixelRatio: Double, h264: Bool = false, fps: Int = 60) {
            guard (50...4000).contains(width), (50...4000).contains(height) else { return nil }
            self.width = width
            self.height = height
            self.zoom = min(max(zoom, 0.25), 4)
            self.pixelRatio = min(max(pixelRatio, 1), ScreenView.maxPixelRatio)
            self.h264 = h264
            self.framesPerSecond = h264 ? Int32(min(max(fps, 30), 120)) : 30
        }
    }

    private struct DisplayUnavailable: Error {}

    /// A display in global coordinates (points, origin top left of the main display).
    private struct Display: Equatable {
        let id: CGDirectDisplayID
        let bounds: CGRect
        let backingScale: Double
        let framesPerSecond: Int32
    }

    /// One display's stream. Hands complete frames to `frame` on the frame queue.
    private final class Capture: NSObject, SCStreamOutput {
        struct Settings: Equatable {
            let width: Int
            let height: Int
            let framesPerSecond: Int32

            var configuration: SCStreamConfiguration {
                let config = SCStreamConfiguration()
                config.width = width
                config.height = height
                config.minimumFrameInterval = CMTime(value: 1, timescale: framesPerSecond)
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.showsCursor = true
                config.queueDepth = 3
                return config
            }
        }

        var stream: SCStream?
        /// What the stream runs with.
        var settings: Settings?
        private let frame: (CVPixelBuffer) -> Void

        init(frame: @escaping (CVPixelBuffer) -> Void) {
            self.frame = frame
        }

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen, let buffer = sampleBuffer.imageBuffer,
                  let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                  attachments.first?[.status] as? Int == SCFrameStatus.complete.rawValue else { return }
            frame(buffer)
        }
    }

    private let send: (Data) -> Void

    /// `send` delivers one frame on the main queue. The phone answers frames by number through `frameShown`.
    init(send: @escaping (Data) -> Void) {
        self.send = send
        super.init()
        // Displays were connected, removed, rearranged or changed their mode.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.request != nil else { return }
            self.configure()
        }
    }

    private static let maxOutputWidth = 1400.0
    /// Sharper than 2x costs bandwidth and frame rate for little gain at arm's length.
    private static let maxPixelRatio = 2.0
    /// Frames sent but not yet shown on the phone. Sockets and proxies on the way buffer megabytes,
    /// so only the phone can tell whether it keeps up. Two lets the next frame travel while one decodes.
    private static let maxFramesInFlight = 2
    /// Capture rate of a display out of view. Its last frame is what shows first when the view reaches it.
    private static let idleFramesPerSecond: Int32 = 5
    /// A display runs at the full rate this many points before the view reaches it.
    private static let leadIn = 200.0

    // Main queue state.
    private var request: Request?
    private var revision: UInt64 = 0
    private var captures: [Capture] = []
    /// The displays the running captures were set up for.
    private var layout: [Display] = []
    private var epoch: UInt64 = 0
    private var broken = false
    /// Displays in or near the view, as the frame queue last reported them. Nil: not known yet, all run at the full rate.
    private var active: Set<CGDirectDisplayID>?
    private var configuring = false
    private var dirty = false

    // Frame queue state.
    private let queue = DispatchQueue(label: "remotey.frames", qos: .userInteractive)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    /// `scale` is output pixels per point, the same for every display.
    private var geometry: (request: Request, displays: [Display], scale: Double, revision: UInt64, fps: Int32)?
    /// Frames of an older set of captures are ignored.
    private var liveEpoch: UInt64 = 0
    /// The newest frame of every display. A static display keeps its last one for when the view pans onto it.
    private var frames: [CGDirectDisplayID: CVPixelBuffer] = [:]
    /// The visible region changed since the last encode.
    private var pending = false
    /// The displays in or near the view that the main queue was last told about.
    private var reported: Set<CGDirectDisplayID>?
    /// Earliest time of the next encode. Two displays in view deliver up to twice the requested rate.
    private var nextEncode: TimeInterval = 0
    private var waiting = false
    private var generation = UUID()
    private var encoder: H264Encoder?
    private var encoding = false
    private var jpegFallback = false
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
        let displays = Self.displays()
        guard !displays.isEmpty else { throw DisplayUnavailable() }
        let regionWidth = Self.region(request, fitting: displays.map(\.bounds)).width
        let outputWidth = min(regionWidth * displays.map(\.backingScale).max()!,
                              request.width * request.pixelRatio, Self.maxOutputWidth)
        let scale = outputWidth / regionWidth

        // Each display is captured whole at the density the region needs, but never above its own:
        // a 1x display beside a Retina one is enlarged while composing instead.
        // Rounded up, so that neighbours overlap by a fraction of a pixel rather than leave a gap.
        func settings(_ display: Display) -> Capture.Settings {
            let density = min(scale, display.backingScale)
            let fps = min(request.framesPerSecond, display.framesPerSecond)
            return Capture.Settings(
                width: max(2, Int((display.bounds.width * density).rounded(.up))),
                height: max(2, Int((display.bounds.height * density).rounded(.up))),
                // A display out of view costs next to nothing.
                framesPerSecond: active?.contains(display.id) == false ? min(fps, Self.idleFramesPerSecond) : fps)
        }

        if !broken, !captures.isEmpty, layout == displays {
            for (capture, display) in zip(captures, layout) {
                let wanted = settings(display)
                guard capture.settings != wanted else { continue }
                try await capture.stream?.updateConfiguration(wanted.configuration)
                capture.settings = wanted
            }
        } else {
            await teardown()
            broken = false
            epoch += 1
            let epoch = self.epoch
            // Queued before any capture starts, so the first frame of a static display is not lost.
            queue.async { self.liveEpoch = epoch }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            for display in displays {
                guard let source = content.displays.first(where: { $0.displayID == display.id }) else {
                    throw DisplayUnavailable()
                }
                let id = display.id
                let capture = Capture { [weak self] buffer in self?.captured(buffer, from: id, epoch: epoch) }
                let wanted = settings(display)
                let stream = SCStream(filter: SCContentFilter(display: source, excludingWindows: []),
                                      configuration: wanted.configuration, delegate: self)
                try stream.addStreamOutput(capture, type: .screen, sampleHandlerQueue: queue)
                capture.stream = stream
                capture.settings = wanted
                captures.append(capture)
                layout.append(display)
                try await stream.startCapture()
            }
        }
        guard revision == self.revision else { return }
        let fps = displays.map { min(request.framesPerSecond, $0.framesPerSecond) }.max()!
        queue.async {
            self.geometry = (request, displays, scale, revision, fps)
            // A static screen sends no new frame for the new view; the kept ones show it.
            self.pending = true
            self.encodeLatest()
        }
    }

    @MainActor
    private func teardown() async {
        let old = captures
        captures = []
        layout = []
        active = nil
        queue.async {
            self.liveEpoch = 0
            self.frames.removeAll()
            self.resetFrames()
        }
        for capture in old {
            try? await capture.stream?.stopCapture()
        }
    }

    /// Invalidates late encoder callbacks as well as queued captures. Frame numbers never reset.
    private func resetFrames() {
        generation = UUID()
        geometry = nil
        pending = false
        reported = nil
        encoder = nil
        encoding = false
        jpegFallback = false
    }

    private static func displays() -> [Display] {
        NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            else { return nil }
            return Display(id: id, bounds: CGDisplayBounds(id), backingScale: screen.backingScaleFactor,
                           framesPerSecond: Int32(max(1, screen.maximumFramesPerSecond)))
        }
    }

    /// Called when the view comes near a display or leaves one behind.
    private func setActive(_ displays: Set<CGDirectDisplayID>) {
        guard request != nil, displays != active else { return }
        active = displays
        configure()
    }

    /// Region size in points: the pad's aspect, shrunk until it fits on every display.
    /// So the view never exceeds a display, and away from a seam it shows one display only.
    private static func region(_ request: Request, fitting displays: [CGRect]) -> CGSize {
        let width = request.width / request.zoom, height = request.height / request.zoom
        let fit = min(1, displays.map(\.width).min()! / width, displays.map(\.height).min()! / height)
        return CGSize(width: width * fit, height: height * fit)
    }

    /// The region shown for a cursor position, in global points.
    ///
    /// It is centred on the cursor and held inside the cursor's display, so a display edge shows no
    /// empty space beyond it. As the cursor nears another display, the limits grow towards the box
    /// around both and reach it at the seam: the view moves steadily across, with no jump on either side.
    static func viewport(_ request: Request, displays: [CGRect], around cursor: CGPoint) -> CGRect {
        let size = region(request, fitting: displays)
        let home = displays.first { $0.contains(cursor) } ?? displays.reduce(CGRect.null) { $0.union($1) }
        var limits = home
        for other in displays where other != home {
            // 1 at the other display, 0 where the centred region would only just touch it.
            let dx = max(other.minX - cursor.x, cursor.x - other.maxX, 0) / (size.width / 2)
            let dy = max(other.minY - cursor.y, cursor.y - other.maxY, 0) / (size.height / 2)
            let near = 1 - max(dx, dy)
            guard near > 0 else { continue }
            let reach = home.union(other)
            let minX = home.minX + (reach.minX - home.minX) * near, maxX = home.maxX + (reach.maxX - home.maxX) * near
            let minY = home.minY + (reach.minY - home.minY) * near, maxY = home.maxY + (reach.maxY - home.maxY) * near
            limits = limits.union(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
        }
        return CGRect(x: min(max(limits.minX, cursor.x - size.width / 2), limits.maxX - size.width),
                      y: min(max(limits.minY, cursor.y - size.height / 2), limits.maxY - size.height),
                      width: size.width, height: size.height)
    }

    // MARK: Frames (frame queue)

    private func captured(_ buffer: CVPixelBuffer, from id: CGDirectDisplayID, epoch: UInt64) {
        guard epoch == liveEpoch else { return }
        frames[id] = buffer
        guard let geometry else { return }
        let cursor = Pointer.location
        let view = Self.viewport(geometry.request, displays: geometry.displays.map(\.bounds), around: cursor)
        // Measured around the cursor, not the view: a view as tall as its display lies against the
        // neighbour all the time, but shows it only once the cursor is within half a view of the seam.
        let reach = CGRect(x: cursor.x - view.width / 2, y: cursor.y - view.height / 2, width: view.width, height: view.height)
            .insetBy(dx: -Self.leadIn, dy: -Self.leadIn)
        let near = Set(geometry.displays.filter { $0.bounds.intersects(reach) }.map(\.id))
        if near != reported {
            reported = near
            DispatchQueue.main.async { self.setActive(near) }
        }
        // A change on a display outside the view is kept but not sent.
        guard geometry.displays.contains(where: { $0.id == id && $0.bounds.intersects(view) }) else { return }
        // While the phone is busy only the newest frame is kept, so a slow link or phone lowers the
        // frame rate instead of building up delay, and the last frame of a movement always arrives.
        pending = true
        encodeLatest()
    }

    /// Frame layout, little endian: Float32 cursor x, Float32 cursor y (both 0...1 inside the image),
    /// UInt32 frame number, then JPEG or the H264Encoder payload.
    private func encodeLatest() {
        guard !encoding, pending, inFlight.count < Self.maxFramesInFlight, let geometry else { return }
        // The slack lets a single display's frames through despite jitter; the average stays at the rate.
        let interval = 1 / Double(geometry.fps), slack = interval / 4
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= nextEncode - slack else {
            if !waiting {
                waiting = true
                queue.asyncAfter(deadline: .now() + (nextEncode - now)) {
                    self.waiting = false
                    self.encodeLatest()
                }
            }
            return
        }
        let cursor = Pointer.location
        let view = Self.viewport(geometry.request, displays: geometry.displays.map(\.bounds), around: cursor)
        let scale = geometry.scale
        // NV12 needs even dimensions. They depend on the region's size only, not on where it is.
        let width = max(2, Int(view.width * scale) / 2 * 2), height = max(2, Int(view.height * scale) / 2 * 2)

        var composed: CIImage?
        var covered = false
        for display in geometry.displays where display.bounds.intersects(view) {
            guard let buffer = frames[display.id] else { continue }
            let bufferHeight = Double(CVPixelBufferGetHeight(buffer))
            // A capture at the output density is placed pixel for pixel, which keeps text sharp.
            func factor(_ value: Double) -> Double { abs(value - 1) < 0.01 ? 1 : value }
            let scaleX = factor(display.bounds.width * scale / Double(CVPixelBufferGetWidth(buffer)))
            let scaleY = factor(display.bounds.height * scale / bufferHeight)
            let left = ((display.bounds.minX - view.minX) * scale).rounded()
            let top = ((display.bounds.minY - view.minY) * scale).rounded()
            // Core Image has its origin at the bottom left.
            let position = CGAffineTransform(translationX: left, y: Double(height) - top - (bufferHeight * scaleY).rounded())
            let layer = CIImage(cvPixelBuffer: buffer).transformed(by: position.scaledBy(x: scaleX, y: scaleY))
            composed = composed.map { layer.composited(over: $0) } ?? layer
            covered = covered || display.bounds.contains(view)
        }
        guard var image = composed else { return }
        // Away from a seam one display fills the view. Otherwise space no display covers stays black.
        if !covered { image = image.composited(over: CIImage(color: .black)) }
        pending = false
        nextEncode = max(nextEncode, now - slack) + interval
        image = image.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let cx = Float32((cursor.x - view.minX) / view.width)
        let cy = Float32((cursor.y - view.minY) / view.height)
        let generation = self.generation
        if geometry.request.h264 && !jpegFallback {
            do {
                if encoder?.width != width || encoder?.height != height || encoder?.framesPerSecond != geometry.fps {
                    encoder = try H264Encoder(width: width, height: height, framesPerSecond: geometry.fps)
                }
                encoding = true
                try encoder!.encode(image, context: ciContext) { output in
                    self.queue.async {
                        guard generation == self.generation else { return }
                        self.encoding = false
                        switch output {
                        case .frame(let payload):
                            self.deliver(payload, cx: cx, cy: cy, revision: geometry.revision)
                        case .dropped:
                            // Keep the last changed image even if the screen becomes idle after a rate-control drop.
                            self.pending = true
                            self.queue.asyncAfter(deadline: .now() + 1 / Double(geometry.fps)) {
                                guard generation == self.generation else { return }
                                self.encodeLatest()
                            }
                            return
                        case .failed:
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
            guard self.captures.contains(where: { $0.stream === stream }) else { return }
            // One lost capture rebuilds them all.
            self.broken = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.configure() }
        }
    }
}
