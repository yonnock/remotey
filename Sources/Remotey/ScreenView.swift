import AppKit
import CoreImage
import ImageIO
import os
import ScreenCaptureKit

/// What the live view tells the phone at once: where the pointer is, and a new picture if the view changed.
struct LiveUpdate {
    enum Picture {
        case jpeg(Data)
        /// The payload `H264Encoder` describes.
        case h264(Data)

        var bytes: Int {
            switch self {
            case .jpeg(let data), .h264(let data): data.count
            }
        }
    }

    /// The pointer's place, 0...1 inside the picture.
    var pointer: CGPoint
    /// The place the view is cut around, 0...1 inside the picture: the pointer, or the text caret while the phone types.
    var focus: CGPoint
    /// The view follows the text caret instead of the pointer.
    var followsText: Bool
    /// The view is fitted to the window in front, so its zoom is the Mac's choice and not the request's.
    var fitted: Bool
    /// Number of the view request the picture was cut for.
    var request: UInt32
    /// What the picture shows, in global points. Its width gives the pointer's size on the phone, and with its
    /// place the phone knows where on the Mac the pointer is, and where its own moves take it meanwhile.
    var view: CGRect
    /// The rate the view runs at: the phone's wish, bounded by the codec and the Mac's displays.
    var framesPerSecond: Int32
    /// Number of the last pointer move from the phone that `pointer` includes: no earlier one is missing
    /// from it and no later one is in it, so the phone can add the moves it has sent since.
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
    /// The margins of the phone's display element that the page's controls cover, in CSS pixels.
    struct Inset: Equatable {
        var top = 0.0, right = 0.0, bottom = 0.0, left = 0.0
        static let zero = Inset()
    }

    struct Request: Equatable {
        /// Size of the phone's display element in CSS pixels; the captured region gets the same aspect.
        let width: Double
        let height: Double
        /// What the page's controls cover of it. The view is cut for the rest, as if that were the whole
        /// element, and then grown by these margins: what lies under the controls is picture as well, but
        /// nothing the view keeps in sight is only there.
        let inset: Inset
        /// 1 = one Mac point per CSS pixel, 2 = twice as large on the phone.
        let zoom: Double
        let pixelRatio: Double
        let h264: Bool
        let framesPerSecond: Int32
        /// The view shows the window in front whole, wherever the pointer is in it, instead of the region
        /// around the pointer at `zoom`. Without such a window `zoom` counts.
        let fit: Bool
        /// With `fit`: the window in front also takes the phone's shape, sized so that it shows at this zoom,
        /// as far as its app and its display allow. So it fills the phone's display instead of a band of it.
        /// Nil leaves the windows on the Mac as they are.
        let shape: Double?
        /// The page's number for this request. Every update names it, so the page knows which zoom a picture has.
        let number: UInt32

        /// Nil for a size no phone display has.
        init?(width: Double, height: Double, zoom: Double, pixelRatio: Double, h264: Bool, fps: Int, fit: Bool = false,
              shape: Double? = nil, number: UInt32 = 0, inset: Inset = .zero) {
            guard (50...4000).contains(width), (50...4000).contains(height) else { return nil }
            self.width = width
            self.height = height
            // The rest keeps at least the size of the smallest element; margins that leave less shrink alike.
            func sides(_ a: Double, _ b: Double, of length: Double) -> (Double, Double) {
                let a = a.isFinite ? max(a, 0) : 0, b = b.isFinite ? max(b, 0) : 0, room = length - 50
                guard a + b > room else { return (a, b) }
                return (a * room / (a + b), b * room / (a + b))
            }
            let (left, right) = sides(inset.left, inset.right, of: width), (top, bottom) = sides(inset.top, inset.bottom, of: height)
            self.inset = Inset(top: top, right: right, bottom: bottom, left: left)
            // How far out the view really goes is set by the displays (see `region`); this only bounds the arithmetic.
            self.zoom = min(max(zoom, 0.02), 4)
            self.pixelRatio = min(max(pixelRatio, 1), ScreenView.maxPixelRatio)
            self.h264 = h264
            self.framesPerSecond = h264 ? Int32(min(max(fps, 30), 120)) : 30
            self.fit = fit
            self.shape = fit ? shape.map { min(max($0, 0.05), ScreenView.maxFitZoom) } : nil
            self.number = number
        }

        /// The request for the part of the element no control covers, which everything is worked out for.
        var inner: Request {
            guard inset != .zero else { return self }
            // `max`: margins shrunk to leave 50 may leave a hair less after rounding.
            return Request(width: max(50, width - inset.left - inset.right), height: max(50, height - inset.top - inset.bottom), zoom: zoom,
                           pixelRatio: pixelRatio, h264: h264, fps: Int(framesPerSecond), fit: fit, shape: shape, number: number)!
        }

        /// The view of the whole element, for `view`, the view of the part no control covers: grown by the
        /// covered margins, at its scale. Beyond the desktop that is black, as space no display covers is.
        func outer(_ view: CGRect) -> CGRect {
            guard inset != .zero else { return view }
            let inner = self.inner, x = view.width / inner.width, y = view.height / inner.height
            return CGRect(x: view.minX - inset.left * x, y: view.minY - inset.top * y,
                          width: view.width + (inset.left + inset.right) * x, height: view.height + (inset.top + inset.bottom) * y)
        }
    }

    private struct DisplayUnavailable: Error {}

    /// What a picture is cut from, for one request and one arrangement of displays.
    private struct Geometry: Equatable {
        let request: Request
        let displays: [Display]
        /// The window the view is fitted to. Nil: the view is cut around the pointer at the request's zoom.
        let window: CGRect?
        /// Output pixels per point, the same for every display.
        let scale: Double
        /// The share of its full width the picture has: less on a link that carries too little for all of it.
        let size: Double
        let revision: UInt64
        let framesPerSecond: Int32

        /// The view that shows `point`, the pointer or the text caret while the phone types, in the part of
        /// the element no control covers.
        func view(around point: CGPoint) -> CGRect {
            ScreenView.inner(request, displays: displays.map(\.bounds), window: window, around: point)
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
        /// Runs instead of `stream` while `TestPattern.on`.
        var pattern: TestPattern?
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
        // A display that wakes has a capture again: one that waits to be rebuilt is rebuilt now.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.rebuildNow(always: true) }
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
    /// While typing, the view moves only once the caret comes this close to an edge, as a share of the view.
    private static let textMargin = 0.2
    /// A fitted window is never shown larger than this: a small dialog stays a small dialog.
    static let maxFitZoom = 2.0
    /// A fitted view keeps the pointer this far inside its edges, in CSS pixels of the phone: room for the
    /// pointer's picture, and near an edge the view shows what lies beyond it.
    private static let pointerMargin = 20.0
    /// A picture that no other followed for this long is encoded once more, at most `passes` times in a row,
    /// and no more once two passes in a row took fewer bits than this for a pixel: the encoder has nothing to
    /// add. One small pass says little, the encoder spends on every other one.
    private static let rest: TimeInterval = 0.15
    private static let passes = 30
    private static let sharpBitsPerPixel = 0.02

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
    /// The capture could not be set up, and the next try waits: longer with every failure in a row, since a
    /// display that sleeps has nothing to capture for minutes. Input from the phone or a display that wakes
    /// cut the wait short (`rebuildNow`).
    private var retry = Backoff(first: 1, longest: 30)
    private var retrying: Task<Void, Never>?
    /// Reports pointer moves the phone did not send: the Mac's own mouse or trackpad.
    private var mouseMonitor: Any?
    /// The pointer picture the phone has.
    private var cursorSent: Pointer.Picture?
    private var cursorCheck = (scheduled: false, again: false)
    private lazy var textFocus = TextFocus { [weak self] target in self?.setText(target) }
    private lazy var frontWindow = FrontWindow { [weak self] frame, another in
        self?.setWindow(frame)
        if another, let frame { self?.cameForward?(frame) }
    }
    /// Another window came to the front and the view is fitted to it now. Called on the main queue with its
    /// frame, so that the pointer can go there: left outside, it would push the view off the window.
    var cameForward: ((CGRect) -> Void)?
    /// The window in front, while the request asks to fit the view to it.
    private var fitTo: CGRect?
    /// The lock screen covers every window: the view shows the pointer there, and the password field.
    var locked = false { didSet { if locked != oldValue { watchWindow() } } }
    /// The share of its full width the picture is sent at, as the link's bit rate allows (`LinkRate.size`).
    private var size = 1.0

    /// The number of the last pointer move the phone sent. A move is posted and its number set as one, and
    /// place and number are read as one: an update never names a move its place lacks, nor has one it does
    /// not name. The phone adds the moves it has sent since to the place, so either would show as a jump.
    private let moves = OSAllocatedUnfairLock(initialState: UInt32(0))

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
    /// What the phone was last told. A move that leaves the view where it is sends the pointer's place only,
    /// and so does one that leaves the pointer where it is, against a display's edge: the phone counts a
    /// move as under way until an update names it.
    private var sent: (cursor: CGPoint, view: CGRect, focus: CGPoint, sequence: UInt32)?
    /// Where typed text lands, while the view follows it.
    private var text: TextFocus.Target?
    /// The view cut around the text, kept while the caret stays well inside it.
    private var textView: CGRect?
    /// The displays in or near the view that the main queue was last told about.
    private var reported: Set<CGDirectDisplayID>?
    /// Earliest time of the next update. Two displays in view deliver up to twice the requested rate.
    private var nextSlot: TimeInterval = 0
    private var waiting = false
    private var generation = UUID()
    private var encoder: H264Encoder?
    /// One picture at a time, composed and encoded. For a 756 × 1136 view on an M3 Max that takes 6 to 9 ms, of
    /// which composing is about 5 ms (`REMOTEY_STATS`): plenty for the 60 fps Safari draws at, short of 120 fps.
    private var encoding = false
    private var jpegFallback = false
    /// Pictures sent so far, which tells whether one followed another.
    private var pictures: UInt64 = 0
    /// The picture on the phone is to be encoded once more; how many such passes are left, and how many small
    /// ones came in a row. See `sharpenSoon`.
    private var sharpening = false
    private var passes = (left: 0, small: 0)
    private var window = SendWindow()
    private var link = LinkRate()
    private var stats = Stats()
    static var statsOn: Bool { Stats.on }

    /// What each stage of the live view did in the last second, written to standard error once a second
    /// while `REMOTEY_STATS` is set. For measuring the stream on the Mac's side; frame queue only.
    private struct Stats {
        static let on = ProcessInfo.processInfo.environment["REMOTEY_STATS"] != nil // HTTP requests are written too
        var captured = 0, inView = 0, encoded = 0, dropped = 0, encodeTime = 0.0, renderTime = 0.0, blocked = 0, pictures = 0, places = 0
        var sharpened = 0
        var bytes = 0, answered = 0
        var since = ProcessInfo.processInfo.systemUptime
        var active: Bool { captured + places + pictures + answered > 0 }

        mutating func report(_ extra: String) {
            let now = ProcessInfo.processInfo.systemUptime, seconds = now - since
            guard Self.on, seconds >= 1 else { return }
            if active {
                let line = String(format: "stats %.1fs captured %d in-view %d encoded %d (%.1f ms each, %.1f ms of it composing) dropped %d window-shut %d "
                    + "pictures %d sharpened %d pointer-only %d %.2f Mbit/s answered %d %@\n", seconds, captured, inView, encoded,
                    encoded > 0 ? encodeTime / Double(encoded) * 1000 : 0,
                    encoded > 0 ? renderTime / Double(encoded) * 1000 : 0, dropped, blocked, pictures, sharpened, places,
                    Double(bytes) * 8 / seconds / 1e6, answered, extra)
                FileHandle.standardError.write(Data(line.utf8))
            }
            self = Stats(since: now)
        }
    }

    func update(_ request: Request?) {
        guard request != self.request else { return }
        if Stats.on { FileHandle.standardError.write(Data("request \(request.map { "\($0)" } ?? "off")\n".utf8)) }
        revision += 1
        let fresh = self.request == nil, restarting = fresh || self.request?.h264 != request?.h264
        // Another viewer numbers its moves anew, and what the last one's link carried says nothing about
        // this one's. A viewer that only changes the codec goes on with its numbers and its link.
        if fresh {
            moves.withLock { $0 = 0 }
            size = 1
        }
        queue.async {
            self.resetFrames()
            if restarting { self.withdrawAll() }
            if fresh { self.link = LinkRate() }
        }
        self.request = request
        if restarting { cursorSent = nil }
        if request == nil { followText(false) }
        watchMouse(request != nil)
        watchWindow()
        sendCursorIfChanged()
        configure()
    }

    /// Input from the phone: the display it woke may have a capture again. A wait longer than the first is cut
    /// short; the first one stays, so input that comes a hundred times a second does not try as often.
    func wake() { rebuildNow(always: false) }

    private func rebuildNow(always: Bool) {
        guard let retrying, always || retry.failures > 1 else { return }
        retry.reset()
        retrying.cancel()
    }

    /// The phone's decoder lost its state. An H.264 stream goes on with a key frame, and the send window starts
    /// over as after a restart: the pictures under way were for a decoder that is gone.
    func keyFrame() {
        queue.async {
            guard self.geometry?.request.h264 == true, !self.jpegFallback, let encoder = self.encoder else { return }
            encoder.requestKeyFrame()
            self.withdrawAll()
            self.link.restarts()
            self.stale = true
            self.encodeLatest()
        }
    }

    /// The pictures under way will not be answered: the link no longer counts them either, else it would take
    /// itself to be busy from now on. Frame queue.
    private func withdrawAll() {
        let now = ProcessInfo.processInfo.systemUptime
        for _ in 0..<window.reset() { link.withdrawn(now: now) }
    }

    /// The phone has drawn (or discarded) the picture with this number.
    func frameShown(_ number: UInt32) {
        queue.async {
            let now = ProcessInfo.processInfo.systemUptime
            guard let answer = self.window.answered(number, now: now) else { return }
            self.stats.answered += 1
            if self.link.answered(after: answer.after, bytes: answer.bytes, now: now) { self.fitToLink() }
            self.encodeLatest()
        }
    }

    /// The pointer moved, by something other than a move from the phone: the Mac's own mouse, a jump to
    /// a window or a display.
    func pointerMoved() {
        queue.async { self.encodeLatest() }
    }

    /// Posts a pointer move the phone sent, which `post` does, and counts it as the move with the number
    /// `sequence`.
    func move(_ sequence: UInt32?, post: () -> Void) {
        moves.withLockUnchecked {
            post()
            if let sequence { $0 = sequence }
        }
        pointerMoved()
    }

    /// The link's bit rate changed: the encoder follows at once, the picture's size once the rate no longer
    /// suits it. `apply` picks the size, as it does for every new view.
    private func fitToLink() {
        encoder?.bitsPerSecond = link.bitsPerSecond
        guard let geometry, let encoder else { return }
        let pixels = Double(encoder.width * encoder.height) / (geometry.size * geometry.size)
        guard LinkRate.size(now: geometry.size, pixels: pixels, bitsPerSecond: link.bitsPerSecond) != geometry.size else { return }
        link.restarts()
        let revision = geometry.revision
        DispatchQueue.main.async {
            guard revision == self.revision else { return }
            self.configure()
        }
    }

    /// While on, the view is cut around the text caret instead of the pointer: the phone types.
    /// Off again with any use of the pointer, from the phone or the Mac's own mouse.
    func followText(_ on: Bool) {
        if on, request != nil {
            textFocus.start()
            locateText()
            // The app may take the key a moment after it was posted; its notifications may not come.
            textFocus.locateSoon()
        } else if !on, textFocus.isWatching {
            textFocus.stop()
            setText(nil)
        }
    }

    private func locateText() {
        setText(textFocus.locate())
    }


    private func setText(_ target: TextFocus.Target?) {
        queue.async {
            guard target != self.text else { return }
            self.text = target
            self.encodeLatest()
        }
    }

    /// Follows the window in front while the view is fitted to it, and forgets it otherwise. Asked to, the
    /// window takes the phone's shape meanwhile, and gets its frame back with the end of that.
    private func watchWindow() {
        if let request, request.fit, !locked {
            frontWindow.shape = Self.shape(for: request)
            if !frontWindow.isWatching { frontWindow.start() }
        } else {
            if frontWindow.isWatching {
                frontWindow.stop()
                setWindow(nil)
            }
            frontWindow.shape = nil
        }
    }

    /// The size in points a window in front takes for `request`: the part of the element no control covers,
    /// at the request's zoom. Nil: windows stay as they are.
    static func shape(for request: Request) -> CGSize? {
        let inner = request.inner
        return request.shape.map { CGSize(width: inner.width / $0, height: inner.height / $0) }
    }

    private func setWindow(_ frame: CGRect?) {
        guard frame != fitTo else { return }
        fitTo = frame
        if request != nil { configure() }
    }

    private func watchMouse(_ on: Bool) {
        if on, mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
            ) { [weak self] _ in
                self?.followText(false)
                self?.pointerMoved()
            }
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
                    retry.reset()
                } catch {
                    await teardown()
                    if request != nil {
                        let wait = retry.failed()
                        if Stats.on { FileHandle.standardError.write(Data("capture failed: \(error), next try in \(wait) s\n".utf8)) }
                        let pause = Task { _ = try? await Task.sleep(for: .seconds(wait)) }
                        retrying = pause
                        await pause.value
                        retrying = nil
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
        let window = fitTo
        let inner = Self.region(request.inner, fitting: displays.map(\.bounds), window: window)
        let regionWidth = request.outer(CGRect(origin: .zero, size: inner)).width
        let fullWidth = min(regionWidth * displays.map(\.backingScale).max()!,
                            request.width * request.pixelRatio, Self.maxOutputWidth)
        // The size for this view's pixels: a smaller view may be sent whole with the bit rate that was too
        // little for a larger one. The frame queue never waits for this one, so asking it cannot lock.
        let bitsPerSecond = queue.sync { link.bitsPerSecond }
        let size = !request.h264 ? 1 : LinkRate.size(now: self.size, pixels: fullWidth * fullWidth * request.height / request.width,
                                                     bitsPerSecond: bitsPerSecond)
        self.size = size
        let scale = fullWidth * size / regionWidth

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
                if let pattern = capture.pattern {
                    queue.async { pattern.size = (wanted.width, wanted.height, wanted.framesPerSecond) }
                }
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
            let content = TestPattern.on ? nil : try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            for display in displays {
                if TestPattern.on {
                    let wanted = settings(display), capture = Capture { _, _ in }
                    capture.pattern = TestPattern(width: wanted.width, height: wanted.height, framesPerSecond: wanted.framesPerSecond,
                                                  queue: queue) { [weak self] buffer in
                        self?.captured(buffer, dirty: nil, from: display.id, epoch: epoch)
                    }
                    capture.settings = wanted
                    captures.append(capture)
                    layout.append(display)
                    continue
                }
                guard let source = content?.displays.first(where: { $0.displayID == display.id }) else {
                    if Stats.on { FileHandle.standardError.write(Data("no capture of display \(display.id) among \(content?.displays.map(\.displayID) ?? [])\n".utf8)) }
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
        let geometry = Geometry(request: request, displays: displays, window: window, scale: scale, size: size, revision: revision,
                                framesPerSecond: fps)
        queue.async {
            // A change of a capture's frame rate alone leaves the picture on the phone as it is.
            guard geometry != self.geometry else { return }
            self.geometry = geometry
            self.textView = nil
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
            capture.pattern?.stop()
            try? await capture.stream?.stopCapture()
        }
    }

    /// Invalidates late encoder callbacks as well as queued captures. Frame numbers never reset.
    private func resetFrames() {
        generation = UUID()
        geometry = nil
        stale = false
        sent = nil
        textView = nil
        reported = nil
        encoder = nil
        encoding = false
        jpegFallback = false
        sharpening = false
        passes = (0, 0)
    }

    private static func displays() -> [Display] {
        NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            else { return nil }
            return Display(id: id, bounds: CGDisplayBounds(id), backingScale: screen.backingScaleFactor,
                           // The test pattern runs at any rate, so a measurement does not depend on the display the pointer is on.
                           framesPerSecond: TestPattern.on ? 120 : Int32(max(1, screen.maximumFramesPerSecond)))
        }
    }

    /// Called when the view comes near a display or leaves one behind.
    private func setActive(_ displays: Set<CGDirectDisplayID>) {
        guard request != nil, displays != active else { return }
        active = displays
        configure()
    }

    /// Region size in points: the pad's aspect at the requested zoom, or at the zoom that shows `window`
    /// whole, but no larger than it takes to show every display at once. So zooming out ends at the whole
    /// desktop, whichever way the phone is held. The size does not depend on where the pointer is.
    private static func region(_ request: Request, fitting displays: [CGRect], window: CGRect? = nil) -> CGSize {
        let zoom = window.map { min(request.width / max($0.width, 1), request.height / max($0.height, 1), maxFitZoom) } ?? request.zoom
        let width = request.width / zoom, height = request.height / zoom
        let all = displays.reduce(CGRect.null) { $0.union($1) }
        let fit = min(1, max(all.width / width, all.height / height))
        return CGSize(width: width * fit, height: height * fit)
    }

    /// Where a view of one length lies along one axis: `limits` is the cursor's display (grown towards a
    /// neighbour the cursor is near), `all` the box around every display.
    ///
    /// A view that fits its limits is centred on `centre` and held inside them. A longer one cannot follow
    /// the cursor: it holds still with its limits in the middle, and moves off that only to show a
    /// neighbouring display instead of empty space. One longer than the whole desktop has it in its middle.
    private static func origin(of length: Double, around centre: Double, limits: ClosedRange<Double>,
                               all: ClosedRange<Double>) -> Double {
        if length <= limits.upperBound - limits.lowerBound {
            return min(max(limits.lowerBound, centre - length / 2), limits.upperBound - length)
        }
        guard length < all.upperBound - all.lowerBound else { return (all.lowerBound + all.upperBound - length) / 2 }
        return min(max(all.lowerBound, (limits.lowerBound + limits.upperBound - length) / 2), all.upperBound - length)
    }

    /// The region shown for a cursor position, in global points.
    ///
    /// It is centred on the cursor and held inside the cursor's display, so a display edge shows no
    /// empty space beyond it. As the cursor nears another display, the limits grow towards the box
    /// around both and reach it at the seam: the view moves steadily across, with no jump on either side.
    /// Zoomed out beyond the cursor's display, the view shows that display whole, with its neighbours or
    /// empty space around it (see `origin`).
    static func viewport(_ request: Request, displays: [CGRect], around cursor: CGPoint) -> CGRect {
        let size = region(request, fitting: displays)
        let all = displays.reduce(CGRect.null) { $0.union($1) }
        let home = displays.first { $0.contains(cursor) } ?? all
        let near = displays.filter { $0 != home }.compactMap { other -> (bounds: CGRect, share: Double)? in
            // 1 at the other display, 0 where the centred region would only just touch it.
            let dx = max(other.minX - cursor.x, cursor.x - other.maxX, 0) / (size.width / 2)
            let dy = max(other.minY - cursor.y, cursor.y - other.maxY, 0) / (size.height / 2)
            let share = 1 - max(dx, dy)
            return share > 0 ? (other, share) : nil
        }
        // The limits for every set of the displays near, numbered by its bits: each display of a set grows what
        // the others allow, by its share. Grown from the home display alone, a third display would count from
        // another edge on either side of a seam, and a view larger than its display would jump there.
        var grown = [home]
        for set in 1..<(1 << near.count) {
            var limits = home
            for (index, other) in near.enumerated() where set & (1 << index) != 0 {
                let from = grown[set & ~(1 << index)], reach = from.union(other.bounds)
                let minX = from.minX + (reach.minX - from.minX) * other.share, maxX = from.maxX + (reach.maxX - from.maxX) * other.share
                let minY = from.minY + (reach.minY - from.minY) * other.share, maxY = from.maxY + (reach.maxY - from.maxY) * other.share
                limits = limits.union(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
            }
            grown.append(limits)
        }
        let limits = grown.last!
        return CGRect(x: origin(of: size.width, around: cursor.x, limits: limits.minX...limits.maxX, all: all.minX...all.maxX),
                      y: origin(of: size.height, around: cursor.y, limits: limits.minY...limits.maxY, all: all.minY...all.maxY),
                      width: size.width, height: size.height)
    }

    /// The view sent for `point`, in global points: worked out for the part of the element no control covers,
    /// then grown to the whole element.
    static func view(_ request: Request, displays: [CGRect], window: CGRect?, around point: CGPoint) -> CGRect {
        request.outer(inner(request, displays: displays, window: window, around: point))
    }

    /// The view for `point` in the part of the element no control covers: fitted to `window`, or around the point.
    static func inner(_ request: Request, displays: [CGRect], window: CGRect?, around point: CGPoint) -> CGRect {
        let inner = request.inner
        if let window { return fitted(inner, displays: displays, to: window, holding: point) }
        return viewport(inner, displays: displays, around: point)
    }

    /// The region that shows `window` whole, in global points: as large as the pad's aspect allows, so the
    /// window fills the pad's width or its height, whichever limits.
    ///
    /// It lies around the window and inside the displays the window is on, as the pointer's view lies inside
    /// the pointer's display; taller or wider than those, it has them in its middle (see `origin`). A point
    /// outside it pushes it: the view moves just far enough to hold `point`, the pointer or the text caret,
    /// and returns as the point does. So the menu bar and the other windows stay within reach, with no jump.
    static func fitted(_ request: Request, displays: [CGRect], to window: CGRect, holding point: CGPoint) -> CGRect {
        let size = region(request, fitting: displays, window: window)
        let all = displays.reduce(CGRect.null) { $0.union($1) }
        let home = displays.filter { $0.intersects(window) }.reduce(CGRect.null) { $0.union($1) }
        let limits = home.isNull ? all : home
        let margin = pointerMargin * size.width / request.width
        func place(_ length: Double, around centre: Double, limits: ClosedRange<Double>, all: ClosedRange<Double>, holding point: Double) -> Double {
            let rest = origin(of: length, around: centre, limits: limits, all: all)
            let margin = min(margin, length / 2)
            let pushed = min(max(rest, point + margin - length), point - margin)
            // Not beyond the desktop for the margin's sake: at its edge the pointer reaches the picture's edge.
            guard length <= all.upperBound - all.lowerBound else { return pushed }
            return min(max(all.lowerBound, pushed), all.upperBound - length)
        }
        return CGRect(x: place(size.width, around: window.midX, limits: limits.minX...limits.maxX, all: all.minX...all.maxX, holding: point.x),
                      y: place(size.height, around: window.midY, limits: limits.minY...limits.maxY, all: all.minY...all.maxY, holding: point.y),
                      width: size.width, height: size.height)
    }

    // MARK: Frames (frame queue)

    /// The view and the point it is cut around: the text caret while the phone types, else the pointer.
    /// Worked out for the part no control covers; what is sent is the whole element's.
    private func framing(_ geometry: Geometry, cursor: CGPoint) -> (view: CGRect, focus: CGPoint, text: Bool) {
        if let text, let view = Self.textView(for: text, held: textView, around: geometry.view(around:)) {
            textView = view
            return (geometry.request.outer(view), CGPoint(x: text.rect.midX, y: text.rect.midY), true)
        }
        textView = nil
        return (geometry.request.outer(geometry.view(around: cursor)), cursor, false)
    }

    /// The view for typed text, or nil if the text gives no place to show (then the pointer's view is shown).
    /// `held` is the view shown for the text so far; it stays while the caret is well inside it, so the text
    /// does not slide with every key. An element's frame only counts if it fits: a large text view says
    /// nothing about where the typing is.
    static func textView(for text: TextFocus.Target, held: CGRect?, around view: (CGPoint) -> CGRect) -> CGRect? {
        let focus = CGPoint(x: text.rect.midX, y: text.rect.midY)
        let fresh = view(focus)
        guard text.exact || (text.rect.width <= fresh.width && text.rect.height <= fresh.height) else { return nil }
        if let held, held.size == fresh.size,
           held.insetBy(dx: held.width * textMargin, dy: held.height * textMargin).contains(focus) {
            return held
        }
        return fresh
    }

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
        stats.captured += 1
        stats.report("\(window.description), bit rate \(Int(link.bitsPerSecond / 1000)) kbit/s, size \(geometry?.size ?? 1)")
        let width = CVPixelBufferGetWidth(buffer)
        // The first capture, or the first at a new density after a zoom.
        let fresh = frames.updateValue(buffer, forKey: id).map { CVPixelBufferGetWidth($0) != width } ?? true
        guard let geometry, let display = geometry.displays.first(where: { $0.id == id }) else { return }
        let (view, focus, _) = framing(geometry, cursor: Pointer.location)
        // Measured around the focus, not the view: a view as tall as its display lies against the
        // neighbour all the time, but shows it only once the focus is within half a view of the seam.
        // A view larger than its display shows neighbours wherever the focus is, so the view itself counts too.
        let reach = CGRect(x: focus.x - view.width / 2, y: focus.y - view.height / 2, width: view.width, height: view.height)
            .insetBy(dx: -Self.leadIn, dy: -Self.leadIn)
        let near = Set(geometry.displays.filter { $0.bounds.intersects(reach) || $0.bounds.intersects(view) }.map(\.id))
        if near != reported {
            reported = near
            DispatchQueue.main.async { self.setActive(near) }
        }
        // A change outside the view is kept but not sent: on another display, or a clock in the menu bar
        // while the view shows the middle of the screen. The kept frame shows it once the view gets there.
        guard display.bounds.intersects(view),
              fresh || Self.changes(dirty, pixelsPerPoint: Double(width) / display.bounds.width, on: display.bounds, touch: view)
        else { return }
        stats.inView += 1
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
        let (cursor, sequence) = moves.withLock { (Pointer.location, $0) }
        let (view, focus, followsText) = framing(geometry, cursor: cursor)
        // Nothing changed, and the encoder gets the picture once more: a pass that sharpens it.
        let pass = sharpening && !stale && view == sent?.view
        let picture = stale || view != sent?.view || pass
        guard picture || cursor != sent?.cursor || focus != sent?.focus || sequence != sent?.sequence else { return }
        if picture, !window.isOpen(now: ProcessInfo.processInfo.systemUptime) {
            stats.blocked += 1
            link.waits()
            return
        }
        guard takeSlot(framesPerSecond: geometry.framesPerSecond) else { return }
        func deliver(_ picture: LiveUpdate.Picture?) {
            sent = (cursor, view, focus, sequence)
            func inside(_ point: CGPoint) -> CGPoint {
                CGPoint(x: (point.x - view.minX) / view.width, y: (point.y - view.minY) / view.height)
            }
            let now = ProcessInfo.processInfo.systemUptime
            let numbered = picture.map { (number: window.send($0.bytes, now: now), content: $0) }
            if numbered != nil {
                link.sent(now: now)
                pictures += 1
            }
            if numbered == nil { stats.places += 1 } else { stats.pictures += 1 }
            self.deliver(LiveUpdate(pointer: inside(cursor), focus: inside(focus), followsText: followsText,
                                    fitted: geometry.window != nil, request: geometry.request.number, view: view,
                                    framesPerSecond: geometry.framesPerSecond, sequence: sequence, picture: numbered),
                         revision: geometry.revision)
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
        // A view inside one display is filled by it. Otherwise space no display covers stays black.
        if !covered { image = image.composited(over: CIImage(color: .black)) }
        stale = false
        sharpening = false
        image = image.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let generation = self.generation
        func deliverJPEG() {
            // Without a JPEG the picture stays owed.
            if let data = jpeg(image) { stats.bytes += data.count; deliver(.jpeg(data)) } else { stale = true }
        }
        if geometry.request.h264 && !jpegFallback {
            do {
                if encoder?.width != width || encoder?.height != height || encoder?.framesPerSecond != geometry.framesPerSecond {
                    encoder = try H264Encoder(width: width, height: height, framesPerSecond: geometry.framesPerSecond,
                                              bitsPerSecond: link.bitsPerSecond)
                }
                encoding = true
                let started = ProcessInfo.processInfo.systemUptime
                try encoder!.encode(image, context: ciContext) { output in
                    self.queue.async {
                        guard generation == self.generation else { return }
                        self.encoding = false
                        switch output {
                        case .frame(let payload):
                            self.stats.encoded += 1
                            self.stats.encodeTime += ProcessInfo.processInfo.systemUptime - started
                            self.stats.bytes += payload.count
                            if pass { self.stats.sharpened += 1 }
                            deliver(.h264(payload))
                            self.sharpenSoon(after: pass, bits: Double(payload.count * 8) / Double(width * height))
                        case .dropped:
                            self.stats.dropped += 1
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
                stats.renderTime += ProcessInfo.processInfo.systemUptime - started
                return
            } catch {
                encoding = false
                jpegFallback = true
                encoder = nil
            }
        }
        deliverJPEG()
    }

    /// A picture in motion gets the bits its bit rate has for a frame, and with little of it the last one
    /// before the screen came to rest stays soft: a capture sends nothing while nothing changes. So a picture
    /// that no other followed is encoded again after `rest`. The encoder then has the bits of that time for
    /// what the picture lacks, and once the passes add little none follows. Text is sharp a moment after a
    /// scroll ends, at any bit rate, and a picture that was sharp costs two small passes.
    private func sharpenSoon(after pass: Bool, bits bitsPerPixel: Double) {
        passes = pass ? (passes.left - 1, bitsPerPixel < Self.sharpBitsPerPixel ? passes.small + 1 : 0) : (Self.passes, 0)
        guard passes.left > 0, passes.small < 2 else { return }
        let generation = self.generation, picture = pictures
        queue.asyncAfter(deadline: .now() + Self.rest) {
            guard generation == self.generation, picture == self.pictures, !self.stale else { return }
            self.sharpening = true
            self.encodeLatest()
        }
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
                    self.link.withdrawn(now: ProcessInfo.processInfo.systemUptime)
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
