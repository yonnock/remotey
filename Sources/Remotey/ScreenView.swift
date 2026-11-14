import AppKit
import CoreImage
import ImageIO
import ScreenCaptureKit

/// What the live view tells the phone at once: where the pointer is, and a new picture if the view changed.
struct LiveUpdate {
    enum Picture {
        case jpeg(Data)
        /// The payload `H264Encoder` describes.
        case h264(Data)
    }

    /// The pointer's place, 0...1 inside the picture.
    var pointer: CGPoint
    /// Width of the picture in points, which gives the pointer's size on the phone.
    var width: Double
    /// The rate the view runs at: the phone's wish, bounded by the codec and the Mac's displays.
    var framesPerSecond: Int32
    /// Number of the last pointer move from the phone that this update includes.
    var sequence: UInt32
    /// The picture, and the number the phone answers it with. Nil: the pointer moved inside the picture sent last.
    var picture: (number: UInt32, content: Picture)?
}

/// Live view for the phone: streams the screen region around the cursor as H.264, with a JPEG fallback.
/// Needs the Screen Recording permission. Captures only while a client has the view switched on.
///
/// One `SCStream` runs per display. Every frame is composed from the displays the region around the
/// cursor touches, so the view pans across the seam between two displays instead of switching.
/// ScreenCaptureKit delivers frames only when the screen changes, so a static screen costs nothing.
///
/// The pointer is not captured. The phone gets its place with every message and its picture when the
/// shape changes, and draws it itself. So a move needs no capture: the view is cut anew from the frames
/// at hand the moment the move is posted, and pointer and marker cannot drift apart.
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
        init?(width: Double, height: Double, zoom: Double, pixelRatio: Double, h264: Bool, fps: Int) {
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

    /// What a picture is cut from, for one request and one arrangement of displays.
    private struct Geometry: Equatable {
        let request: Request
        let displays: [Display]
        /// Output pixels per point, the same for every display.
        let scale: Double
        let revision: UInt64
        let framesPerSecond: Int32

        func view(around cursor: CGPoint) -> CGRect {
            ScreenView.viewport(request, displays: displays.map(\.bounds), around: cursor)
        }
    }

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
                config.showsCursor = false
                config.queueDepth = 3
                return config
            }
        }

        var stream: SCStream?
        /// What the stream runs with.
        var settings: Settings?
        /// The second argument holds the changed areas in pixels of the buffer, or nil if all of it may have changed.
        private let frame: (CVPixelBuffer, [CGRect]?) -> Void

        init(frame: @escaping (CVPixelBuffer, [CGRect]?) -> Void) {
            self.frame = frame
        }

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen, let buffer = sampleBuffer.imageBuffer,
                  let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                  attachments.first?[.status] as? Int == SCFrameStatus.complete.rawValue else { return }
            // A stream's first frame comes with one empty area.
            let dirty = (attachments.first?[.dirtyRects] as? [NSDictionary])?
                .compactMap { CGRect(dictionaryRepresentation: $0) }.filter { !$0.isEmpty }
            frame(buffer, dirty?.isEmpty == false ? dirty : nil)
        }
    }

    private let send: (LiveUpdate) -> Void
    private let sendCursor: (Pointer.Picture) -> Bool

    /// Both closures run on the main queue and deliver to the phone. It answers the pictures among the
    /// updates by number through `frameShown`, and draws the pointer's picture at the place every update names.
    /// `cursor` returns false if the picture could not be sent.
    init(update: @escaping (LiveUpdate) -> Void, cursor: @escaping (Pointer.Picture) -> Bool) {
        self.send = update
        self.sendCursor = cursor
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
    /// The pointer's shape is looked at this often while the view changes, and once more after it has come to rest.
    private static let cursorInterval = 0.1
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
    /// Reports pointer moves the phone did not send: the Mac's own mouse or trackpad.
    private var mouseMonitor: Any?
    /// The pointer picture the phone has.
    private var cursorSent: Pointer.Picture?
    private var cursorCheck = (scheduled: false, again: false)

    // Frame queue state.
    private let queue = DispatchQueue(label: "remotey.frames", qos: .userInteractive)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var geometry: Geometry?
    /// Frames of an older set of captures are ignored.
    private var liveEpoch: UInt64 = 0
    /// The newest frame of every display. A static display keeps its last one for when the view pans onto it.
    private var frames: [CGDirectDisplayID: CVPixelBuffer] = [:]
    /// The picture inside the view changed since the last encode.
    private var stale = false
    /// What the phone was last told. A move that leaves the view where it is sends the pointer's place only.
    private var sent: (cursor: CGPoint, view: CGRect)?
    /// Number of the last pointer move the phone sent. It returns with the next message, so the phone can time the round trip.
    private var sequence: UInt32 = 0
    /// The displays in or near the view that the main queue was last told about.
    private var reported: Set<CGDirectDisplayID>?
    /// Earliest time of the next update. Two displays in view deliver up to twice the requested rate.
    private var nextSlot: TimeInterval = 0
    private var waiting = false
    private var generation = UUID()
    private var encoder: H264Encoder?
    /// The hardware encoder takes one picture at a time; composing the next one meanwhile gains nothing.
    private var encoding = false
    private var jpegFallback = false
    private var window = SendWindow()

    func update(_ request: Request?) {
        guard request != self.request else { return }
        revision += 1
        let restarting = self.request == nil || self.request?.h264 != request?.h264
        queue.async {
            self.resetFrames()
            if restarting {
                self.window.reset()
                self.sequence = 0
            }
        }
        self.request = request
        if restarting { cursorSent = nil }
        watchMouse(request != nil)
        sendCursorIfChanged()
        configure()
    }

    /// The phone has drawn (or discarded) the picture with this number.
    func frameShown(_ number: UInt32) {
        queue.async {
            guard self.window.answered(number, now: ProcessInfo.processInfo.systemUptime) else { return }
            self.encodeLatest()
        }
    }

    /// The pointer moved. `sequence` numbers a move the phone sent, which is posted by now.
    func pointerMoved(applied sequence: UInt32? = nil) {
        queue.async {
            if let sequence { self.sequence = sequence }
            self.encodeLatest()
        }
    }

    private func watchMouse(_ on: Bool) {
        if on, mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
            ) { [weak self] _ in self?.pointerMoved() }
        } else if !on, let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
    }

    // MARK: Pointer picture (main queue)

    private func sendCursorIfChanged() {
        guard request != nil, let picture = Pointer.picture(), picture != cursorSent, sendCursor(picture) else { return }
        cursorSent = picture
    }

    /// Call when the view changed. Apps set the pointer's shape a moment after a move, hence the extra look.
    private func checkCursorSoon() {
        guard !cursorCheck.scheduled else { return cursorCheck.again = true }
        cursorCheck.scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.cursorInterval) {
            self.cursorCheck.scheduled = false
            self.sendCursorIfChanged()
            if self.cursorCheck.again {
                self.cursorCheck.again = false
                self.checkCursorSoon()
            }
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
                let capture = Capture { [weak self] buffer, dirty in
                    self?.captured(buffer, dirty: dirty, from: id, epoch: epoch)
                }
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
        let geometry = Geometry(request: request, displays: displays, scale: scale, revision: revision, framesPerSecond: fps)
        queue.async {
            // A change of a capture's frame rate alone leaves the picture on the phone as it is.
            guard geometry != self.geometry else { return }
            self.geometry = geometry
            // A static screen sends no new frame for the new view; the kept ones show it.
            self.stale = true
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
        stale = false
        sent = nil
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

    /// Whether a capture changed the picture inside `view`. `dirty` is in pixels of the capture, `display` and `view` in global points.
    static func changes(_ dirty: [CGRect]?, pixelsPerPoint density: Double, on display: CGRect, touch view: CGRect) -> Bool {
        guard let dirty else { return true }
        return dirty.contains {
            CGRect(x: display.minX + $0.minX / density, y: display.minY + $0.minY / density,
                   width: $0.width / density, height: $0.height / density).intersects(view)
        }
    }

    private func captured(_ buffer: CVPixelBuffer, dirty: [CGRect]?, from id: CGDirectDisplayID, epoch: UInt64) {
        guard epoch == liveEpoch else { return }
        let width = CVPixelBufferGetWidth(buffer)
        // The first capture, or the first at a new density after a zoom.
        let fresh = frames.updateValue(buffer, forKey: id).map { CVPixelBufferGetWidth($0) != width } ?? true
        guard let geometry, let display = geometry.displays.first(where: { $0.id == id }) else { return }
        let cursor = Pointer.location
        let view = geometry.view(around: cursor)
        // Measured around the cursor, not the view: a view as tall as its display lies against the
        // neighbour all the time, but shows it only once the cursor is within half a view of the seam.
        let reach = CGRect(x: cursor.x - view.width / 2, y: cursor.y - view.height / 2, width: view.width, height: view.height)
            .insetBy(dx: -Self.leadIn, dy: -Self.leadIn)
        let near = Set(geometry.displays.filter { $0.bounds.intersects(reach) }.map(\.id))
        if near != reported {
            reported = near
            DispatchQueue.main.async { self.setActive(near) }
        }
        // A change outside the view is kept but not sent: on another display, or a clock in the menu bar
        // while the view shows the middle of the screen. The kept frame shows it once the view gets there.
        guard display.bounds.intersects(view),
              fresh || Self.changes(dirty, pixelsPerPoint: Double(width) / display.bounds.width, on: display.bounds, touch: view)
        else { return }
        // While the phone is busy only the newest frame is kept, so a slow link or phone lowers the
        // frame rate instead of building up delay, and the last frame of a movement always arrives.
        stale = true
        encodeLatest()
    }

    /// True if an update may leave now, which takes the slot. If not, `encodeLatest` runs again when it may.
    private func takeSlot(framesPerSecond: Int32) -> Bool {
        // The slack lets a single display's frames through despite jitter; the average stays at the rate.
        let interval = 1 / Double(framesPerSecond), slack = interval / 4
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= nextSlot - slack else {
            if !waiting {
                waiting = true
                queue.asyncAfter(deadline: .now() + (nextSlot - now)) {
                    self.waiting = false
                    self.encodeLatest()
                }
            }
            return false
        }
        nextSlot = max(nextSlot, now - slack) + interval
        return true
    }

    /// Sends what the phone does not show yet, if anything: a new picture, or the pointer's new place alone.
    private func encodeLatest() {
        // Also holds back the pointer's place alone: it must not overtake the picture being encoded, which shows an older one.
        guard !encoding, let geometry else { return }
        let cursor = Pointer.location, sequence = self.sequence
        let view = geometry.view(around: cursor)
        let picture = stale || view != sent?.view
        guard picture || cursor != sent?.cursor else { return }
        if picture, !window.isOpen(framesPerSecond: geometry.framesPerSecond) { return }
        guard takeSlot(framesPerSecond: geometry.framesPerSecond) else { return }
        func deliver(_ picture: LiveUpdate.Picture?) {
            sent = (cursor, view)
            let pointer = CGPoint(x: (cursor.x - view.minX) / view.width, y: (cursor.y - view.minY) / view.height)
            let numbered = picture.map { (number: window.send(now: ProcessInfo.processInfo.systemUptime), content: $0) }
            self.deliver(LiveUpdate(pointer: pointer, width: view.width, framesPerSecond: geometry.framesPerSecond,
                                    sequence: sequence, picture: numbered), revision: geometry.revision)
        }
        // The pointer moved inside a view held by its display's edges: the picture on the phone stays as it is.
        guard picture else { return deliver(nil) }
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
        // Without a capture yet the picture stays owed.
        guard var image = composed else { return }
        // Away from a seam one display fills the view. Otherwise space no display covers stays black.
        if !covered { image = image.composited(over: CIImage(color: .black)) }
        stale = false
        image = image.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let generation = self.generation
        func deliverJPEG() {
            // Without a JPEG the picture stays owed.
            if let data = jpeg(image) { deliver(.jpeg(data)) } else { stale = true }
        }
        if geometry.request.h264 && !jpegFallback {
            do {
                if encoder?.width != width || encoder?.height != height || encoder?.framesPerSecond != geometry.framesPerSecond {
                    encoder = try H264Encoder(width: width, height: height, framesPerSecond: geometry.framesPerSecond)
                }
                encoding = true
                try encoder!.encode(image, context: ciContext) { output in
                    self.queue.async {
                        guard generation == self.generation else { return }
                        self.encoding = false
                        switch output {
                        case .frame(let payload):
                            deliver(.h264(payload))
                        case .dropped:
                            // Keep the last changed image even if the screen becomes idle after a rate-control drop.
                            self.stale = true
                            self.queue.asyncAfter(deadline: .now() + 1 / Double(geometry.framesPerSecond)) {
                                guard generation == self.generation else { return }
                                self.encodeLatest()
                            }
                            return
                        case .failed:
                            self.jpegFallback = true
                            self.encoder = nil
                            deliverJPEG()
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
        deliverJPEG()
    }

    private func jpeg(_ image: CIImage) -> Data? {
        ciContext.jpegRepresentation(
            of: image, colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.5])
    }

    private func deliver(_ update: LiveUpdate, revision: UInt64) {
        DispatchQueue.main.async {
            // Never send an old viewer's delta frame to a new viewer who has no reference picture.
            guard revision == self.revision else {
                return self.queue.async {
                    guard let number = update.picture?.number, self.window.withdraw(number) else { return }
                    self.encodeLatest()
                }
            }
            self.send(update)
            self.checkCursorSoon()
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
