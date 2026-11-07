import CoreGraphics
import Foundation
import Synchronization

// Timeline thumbnails: a headless second libmpv instance opens the playing
// file, seeks to keyframes and hands back small frames for the scrubber's
// hover bubble. It never touches the playback engine, its render context or
// its event queue, so a slow preview cannot stall playback.

/// What the preview decoder opens: the playing file and its request inputs.
struct ScrubPreviewSource: Equatable, Sendable {
    /// The player's load-request id; frames from an older load are dropped.
    let id: Int
    let resource: PlaybackResource
    let headers: [String: String]
    var decryption: ClearKeyDto? = nil
}

/// One decoded preview frame.
struct ScrubPreviewFrame: @unchecked Sendable {
    // CGImage is immutable and thread-safe; Swift does not mark it Sendable.
    let image: CGImage
}

/// Owns the headless engine. Requests are coalesced: only the latest target
/// waits while a frame decodes, so a fast sweep across the timeline never
/// queues a backlog of seeks.
///
/// `@unchecked Sendable`: the native handle and load state are confined to
/// `queue`; the request mailbox is behind a `Mutex`.
final class ScrubPreviewDecoder: @unchecked Sendable {
    /// Output width in pixels (2× the bubble's point width, rounded).
    nonisolated static let frameWidth = 320
    nonisolated static let loadTimeout: Duration = .seconds(20)
    nonisolated static let seekTimeout: Duration = .seconds(8)
    /// With no request for this long the engine is released: an idle preview
    /// instance otherwise keeps its stream connection, demuxer and hardware
    /// decoder open for the rest of the file. The next hover reopens it.
    nonisolated static let idleRelease: TimeInterval = 30

    private struct Mailbox {
        var source: ScrubPreviewSource?
        var target: (key: Int, seconds: Double)?
        var isRunning = false
        var isClosed = false
        /// Bumped by every request; an idle release only acts when unchanged.
        var activity = 0
    }

    private let mailbox = Mutex(Mailbox())
    private let queue: DispatchQueue
    private let idleRelease: TimeInterval
    private let onFrame: @Sendable (_ sourceID: Int, _ key: Int, ScrubPreviewFrame) -> Void

    // Confined to `queue`.
    private var handle: OpaquePointer?
    private var defaultUserAgent: String?
    private var loadedSourceID: Int?
    private var failedSourceID: Int?

    /// - Parameter onFrame: called on the decoder queue.
    init(idleRelease: TimeInterval = ScrubPreviewDecoder.idleRelease,
         onFrame: @escaping @Sendable (_ sourceID: Int, _ key: Int, ScrubPreviewFrame) -> Void) {
        self.idleRelease = idleRelease
        self.queue = DispatchQueue(label: "com.lagradost.cloudstream.scrub-preview", qos: .utility)
        self.onFrame = onFrame
    }

    deinit {
        // The last reference can go on any thread, including the main one;
        // mpv_terminate_destroy joins the native network threads.
        if let handle {
            nonisolated(unsafe) let owned = handle
            DispatchQueue.global(qos: .utility).async { mpv_terminate_destroy(owned) }
        }
    }

    /// Whether the native engine currently exists (tests and diagnostics).
    var hasEngine: Bool { queue.sync { handle != nil } }

    /// Switches to another file (or none). Pending work for the old one is
    /// dropped; with no source the native engine is released.
    func setSource(_ source: ScrubPreviewSource?) {
        let releases = mailbox.withLock { box -> Bool in
            guard box.source != source else { return false }
            box.source = source
            box.target = nil
            return source == nil
        }
        if releases {
            queue.async { [self] in releaseHandle() }
        }
    }

    /// Asks for the frame nearest `seconds`; replaces any request still waiting.
    func request(key: Int, seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        let starts = mailbox.withLock { box -> Bool in
            guard !box.isClosed, box.source != nil else { return false }
            box.target = (key, seconds)
            box.activity &+= 1
            guard !box.isRunning else { return false }
            box.isRunning = true
            return true
        }
        if starts {
            queue.async { [self] in drain() }
        }
    }

    func close() {
        mailbox.withLock { box in
            box.isClosed = true
            box.source = nil
            box.target = nil
        }
        queue.async { [self] in releaseHandle() }
    }

    // MARK: - Decoder queue

    private struct Job {
        let source: ScrubPreviewSource
        let key: Int
        let seconds: Double
    }

    private func drain() {
        while true {
            let next = mailbox.withLock { box -> (job: Job?, activity: Int) in
                guard !box.isClosed, let source = box.source, let target = box.target else {
                    box.isRunning = false
                    return (nil, box.activity)
                }
                box.target = nil
                return (Job(source: source, key: target.key, seconds: target.seconds), box.activity)
            }
            guard let job = next.job else {
                scheduleIdleRelease(after: next.activity)
                return
            }
            if let image = render(job) {
                onFrame(job.source.id, job.key, ScrubPreviewFrame(image: image))
            }
        }
    }

    /// Decoder queue: releases the engine once no request arrived for
    /// `idleRelease`. A request in the meantime bumps `activity` and keeps it.
    private func scheduleIdleRelease(after activity: Int) {
        queue.asyncAfter(deadline: .now() + idleRelease) { [weak self] in
            guard let self, self.handle != nil else { return }
            let idle = self.mailbox.withLock { !$0.isRunning && $0.target == nil && $0.activity == activity }
            if idle { self.releaseHandle() }
        }
    }

    private func isCurrent(_ sourceID: Int) -> Bool {
        mailbox.withLock { !$0.isClosed && $0.source?.id == sourceID }
    }

    private func render(_ job: Job) -> CGImage? {
        guard failedSourceID != job.source.id else { return nil }
        guard let mpv = handle ?? makeHandle() else { return nil }
        if loadedSourceID != job.source.id {
            loadedSourceID = nil
            guard load(job.source, on: mpv) else {
                failedSourceID = job.source.id
                return nil
            }
            loadedSourceID = job.source.id
        }
        let seek = Self.command(mpv, ["seek", String(format: "%.3f", job.seconds), "absolute+keyframes"])
        guard seek >= 0, wait(for: MPV_EVENT_PLAYBACK_RESTART, on: mpv, sourceID: job.source.id,
                               timeout: Self.seekTimeout) else { return nil }
        return Self.screenshot(mpv)
    }

    private func load(_ source: ScrubPreviewSource, on mpv: OpaquePointer) -> Bool {
        drainEvents(mpv)
        let split = MetalVideoView.splitHeaders(source.headers)
        Self.setStringList(mpv, "http-header-fields", split.fields)
        _ = mpv_set_property_string(mpv, "user-agent", split.userAgent ?? defaultUserAgent ?? "")
        let demuxer = MetalVideoView.demuxerOptions(headers: split, defaultUserAgent: defaultUserAgent,
                                                    decryption: source.decryption)
        var args = ["loadfile", source.resource.url, "replace"]
        if demuxer != MetalVideoView.demuxerOptions {
            args += ["-1", MetalVideoView.lengthPrefixed("demuxer-lavf-o", demuxer)]
        }
        guard Self.command(mpv, args) >= 0 else { return false }
        return wait(for: MPV_EVENT_FILE_LOADED, on: mpv, sourceID: source.id, timeout: Self.loadTimeout)
    }

    /// Blocks this queue until `event` arrives. False on timeout, a file
    /// error, shutdown, or when the source changed meanwhile.
    private func wait(for event: mpv_event_id, on mpv: OpaquePointer, sourceID: Int, timeout: Duration) -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            guard isCurrent(sourceID) else { return false }
            guard let next = mpv_wait_event(mpv, 0.25) else { return false }
            switch next.pointee.event_id {
            case event:
                return true
            case MPV_EVENT_END_FILE, MPV_EVENT_SHUTDOWN:
                return false
            default:
                continue
            }
        }
        return false
    }

    private func drainEvents(_ mpv: OpaquePointer) {
        while let event = mpv_wait_event(mpv, 0), event.pointee.event_id != MPV_EVENT_NONE {}
    }

    private func makeHandle() -> OpaquePointer? {
        guard let mpv = mpv_create() else { return nil }
        for (name, value) in Self.options {
            guard mpv_set_option_string(mpv, name, value) >= 0 else {
                // The resource boundary is not best effort: no previews
                // rather than an unconfined decoder.
                DaemonLog.client("player.scrub_preview_option_rejected", fields: ["option": name])
                mpv_destroy(mpv)
                return nil
            }
        }
        guard mpv_initialize(mpv) >= 0 else {
            mpv_terminate_destroy(mpv)
            return nil
        }
        if let raw = mpv_get_property_string(mpv, "user-agent") {
            defaultUserAgent = String(cString: raw)
            mpv_free(raw)
        }
        handle = mpv
        return mpv
    }

    private func releaseHandle() {
        loadedSourceID = nil
        failedSourceID = nil
        guard let mpv = handle else { return }
        handle = nil
        // Joins the native network threads; never on the main thread.
        mpv_terminate_destroy(mpv)
    }

    // MARK: - Native helpers

    /// The playback engine's resource confinement, plus a decoder tuned to
    /// open fast, read little and hand back one small frame per seek.
    nonisolated static let options: [(String, String)] = [
        ("config", "no"), ("load-scripts", "no"), ("autoload-files", "no"),
        ("load-unsafe-playlists", "no"), ("demuxer-lavf-o", MetalVideoView.demuxerOptions),
        ("stream-lavf-o", MetalVideoView.httpStreamOptions),
        ("vo", "null"), ("ao", "null"), ("audio", "no"), ("sid", "no"),
        ("pause", "yes"), ("idle", "yes"), ("keep-open", "always"),
        // Keyframe seeks: no decoding forward to the exact frame.
        ("hr-seek", "no"),
        ("hwdec", "videotoolbox-copy"), ("vd-lavc-fast", "yes"),
        ("vf", "scale=w=\(frameWidth):h=-2"),
        ("cache", "no"), ("demuxer-max-bytes", "8MiB"), ("demuxer-max-back-bytes", "0"),
        ("demuxer-readahead-secs", "0"), ("network-timeout", "10"),
        ("input-default-bindings", "no"), ("media-controls", "no"),
    ]

    /// A NULL-terminated C argument vector, valid for the closure only.
    private static func withArgv<T>(_ args: [String], _ body: (inout [UnsafePointer<CChar>?]) -> T) -> T {
        let cStrings: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var argv: [UnsafePointer<CChar>?] = cStrings.map { $0.map { UnsafePointer($0) } } + [nil]
        return body(&argv)
    }

    @discardableResult
    private static func command(_ mpv: OpaquePointer, _ args: [String]) -> Int32 {
        withArgv(args) { mpv_command(mpv, &$0) }
    }

    private static func setStringList(_ mpv: OpaquePointer, _ name: String, _ values: [String]) {
        let cStrings = values.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        let nodes = UnsafeMutablePointer<mpv_node>.allocate(capacity: max(1, cStrings.count))
        defer { nodes.deallocate() }
        for (index, cString) in cStrings.enumerated() {
            var node = mpv_node()
            node.format = MPV_FORMAT_STRING
            node.u.string = cString
            (nodes + index).initialize(to: node)
        }
        var list = mpv_node_list()
        list.num = Int32(cStrings.count)
        list.values = nodes
        list.keys = nil
        withUnsafeMutablePointer(to: &list) { listPointer in
            var node = mpv_node()
            node.format = MPV_FORMAT_NODE_ARRAY
            node.u.list = listPointer
            _ = mpv_set_property(mpv, name, MPV_FORMAT_NODE, &node)
        }
    }

    /// `screenshot-raw video`: the decoded frame after the scale filter,
    /// without subtitles or OSD, as `bgr0`.
    private static func screenshot(_ mpv: OpaquePointer) -> CGImage? {
        var result = mpv_node()
        guard withArgv(["screenshot-raw", "video"], { mpv_command_ret(mpv, &$0, &result) }) >= 0 else { return nil }
        defer { mpv_free_node_contents(&result) }
        guard result.format == MPV_FORMAT_NODE_MAP, let list = result.u.list,
              let keys = list.pointee.keys, let values = list.pointee.values else { return nil }
        var width = 0, height = 0, stride = 0
        var format: String?
        var bytes: UnsafeRawBufferPointer?
        for index in 0..<max(0, Int(list.pointee.num)) {
            guard let key = keys[index] else { continue }
            let value = values[index]
            switch String(cString: key) {
            case "w" where value.format == MPV_FORMAT_INT64: width = Int(clamping: value.u.int64)
            case "h" where value.format == MPV_FORMAT_INT64: height = Int(clamping: value.u.int64)
            case "stride" where value.format == MPV_FORMAT_INT64: stride = Int(clamping: value.u.int64)
            case "format" where value.format == MPV_FORMAT_STRING:
                format = value.u.string.map { String(cString: $0) }
            case "data" where value.format == MPV_FORMAT_BYTE_ARRAY:
                if let array = value.u.ba, let data = array.pointee.data {
                    bytes = UnsafeRawBufferPointer(start: data, count: array.pointee.size)
                }
            default:
                continue
            }
        }
        guard format == "bgr0", let bytes else { return nil }
        return image(bgr0: bytes, width: width, height: height, stride: stride)
    }

    /// Copies a native `bgr0` buffer into a CGImage. Dimensions are native
    /// output and are checked against the buffer before any read.
    nonisolated static func image(bgr0 bytes: UnsafeRawBufferPointer, width: Int, height: Int, stride: Int) -> CGImage? {
        guard (1...4096).contains(width), (1...4096).contains(height), stride >= width * 4,
              stride <= width * 4 + 256, bytes.count >= stride * height else { return nil }
        let data = Data(bytes.prefix(stride * height))
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                       space: space, bitmapInfo: info, provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Main-actor face of the decoder for the scrubber: buckets hover positions,
/// caches frames, and publishes the one to show. Only the preview bubble
/// observes `image`, so arriving frames re-render nothing else.
@MainActor
@Observable
final class ScrubPreviewStore {
    /// The frame to show for the hovered position, or the nearest one already
    /// decoded while the exact one is on its way.
    private(set) var image: CGImage?
    /// True when the current file can produce previews.
    private(set) var isAvailable = false

    nonisolated static let cacheLimit = 96

    @ObservationIgnored private var source: ScrubPreviewSource?
    @ObservationIgnored private var cache: [Int: CGImage] = [:]
    @ObservationIgnored private var cacheOrder: [Int] = []
    @ObservationIgnored private var interval: Double = 0
    @ObservationIgnored private var hoveredKey: Int?
    @ObservationIgnored private var lastRequestedKey: Int?
    @ObservationIgnored private lazy var decoder = ScrubPreviewDecoder { [weak self] sourceID, key, frame in
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self?.receive(sourceID: sourceID, key: key, image: frame.image) }
        }
    }

    init() {}

    /// Called for every load (nil for live streams and when playback ends).
    func configure(source: ScrubPreviewSource?) {
        guard source != self.source else { return }
        self.source = source
        cache = [:]
        cacheOrder = []
        interval = 0
        hoveredKey = nil
        lastRequestedKey = nil
        image = nil
        isAvailable = source != nil
        decoder.setSource(source)
    }

    /// The pointer is over (or dragging) the timeline at `seconds`.
    func preview(at seconds: Double, duration: Double) {
        guard source != nil, duration.isFinite, duration > 0, seconds.isFinite else { return }
        let bucket = Self.bucketInterval(forDuration: duration)
        if bucket != interval {
            interval = bucket
            cache = [:]
            cacheOrder = []
            lastRequestedKey = nil
        }
        // Stay clear of the end: a seek there reaches EOF, not a frame.
        let key = Self.key(for: min(max(0, seconds), max(0, duration - bucket)), interval: bucket)
        hoveredKey = key
        if let exact = cache[key] {
            if image !== exact { image = exact }
            return
        }
        if let nearest = Self.nearestKey(to: key, in: cache.keys), let fallback = cache[nearest], image !== fallback {
            image = fallback
        }
        guard lastRequestedKey != key else { return }
        lastRequestedKey = key
        decoder.request(key: key, seconds: Double(key) * bucket)
    }

    /// The pointer left the timeline. The cache stays for the next hover.
    func endPreview() {
        hoveredKey = nil
        lastRequestedKey = nil
    }

    func shutdown() {
        configure(source: nil)
        decoder.close()
    }

    private func receive(sourceID: Int, key: Int, image frame: CGImage) {
        guard sourceID == source?.id else { return }
        if cache[key] == nil {
            cacheOrder.append(key)
            if cacheOrder.count > Self.cacheLimit {
                cache[cacheOrder.removeFirst()] = nil
            }
        }
        cache[key] = frame
        // The decoder always works towards the latest hover, so a frame for
        // another position only becomes the stand-in when it is closer.
        guard let hoveredKey else { return }
        if key == hoveredKey || cache[hoveredKey] == nil && Self.nearestKey(to: hoveredKey, in: cache.keys) == key {
            image = frame
        }
    }

    // MARK: - Bucketing

    /// About 300 previews per file, never closer than 2 s apart: a 24-minute
    /// episode gets one every ~5 s, a two-hour film one every 24 s.
    nonisolated static func bucketInterval(forDuration duration: Double) -> Double {
        guard duration.isFinite, duration > 0 else { return 2 }
        return max(2, (duration / 300).rounded())
    }

    nonisolated static func key(for seconds: Double, interval: Double) -> Int {
        guard seconds.isFinite, interval > 0 else { return 0 }
        return Int(min(Double(Int32.max), max(0, seconds / interval).rounded(.down)))
    }

    nonisolated static func nearestKey(to key: Int, in keys: some Collection<Int>) -> Int? {
        keys.min { abs($0 - key) < abs($1 - key) }
    }
}
