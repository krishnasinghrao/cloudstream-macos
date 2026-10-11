import AppKit
import CoreVideo
import Metal
import QuartzCore
import Synchronization

// Top-level C callbacks to satisfy Swift 6 C function pointer rules
private func onMpvWakeupCallback(_ rawCore: UnsafeMutableRawPointer?) {
    guard let rawCore else { return }
    let core = Unmanaged<MpvCore>.fromOpaque(rawCore).takeUnretainedValue()
    core.queue.async {
        core.drainEvents()
    }
}

private func onMpvRenderUpdateCallback(_ rawContext: UnsafeMutableRawPointer?) {
    guard let rawContext else { return }
    let updateContext = Unmanaged<RenderUpdateContext>.fromOpaque(rawContext).takeUnretainedValue()
    updateContext.view?.markFrameAvailable()
}

/// libmpv viewport backed by `CAMetalLayer` + `mpv_render_context`
/// (Architecture.md §4.1). No `wid` pointers — mpv renders through the render
/// API into our own Metal layer, keeping HUD/window chrome fully native SwiftUI.
///
/// Pipeline (Player-Remediation-Plan A1, R1–R5, T1):
/// * GPU path (default): mpv's OpenGL render API on a private CGL context
///   draws into pooled IOSurface-backed `CVPixelBuffer`s that Metal samples
///   directly. Decoding is zero-copy `hwdec=videotoolbox`; scaling, colour
///   conversion and HDR tone mapping run on the GPU, targeting SDR sRGB.
/// * Software fallback (no OpenGL context, or `CS_PLAYER_RENDERER=sw`):
///   `hwdec=videotoolbox-copy` and mpv's `sw` render API into the same pool,
///   sized to the *video* (never above native resolution). This path does
///   not tone-map HDR.
/// * Either way the `CAMetalLayer` (sRGB) presents the buffer. Up to three
///   frames are in flight; a buffer is only reused after the GPU finished
///   sampling it.
/// * Pacing: a display link drives presentation; mpv's update callback only
///   marks a frame as available, and `mpv_render_context_report_swap` feeds
///   mpv's timing. Occluded windows consume frames without rendering them.
/// * Control: every mpv command/property write is asynchronous — the main
///   thread never waits on the playback core. Teardown runs off the main thread.
@MainActor
final class MetalVideoView: NSView {
    // `nonisolated(unsafe)`: C handles shared with the render/event queues.
    // Writes happen on the main actor before those queues can observe them, or
    // under `renderLock`.
    nonisolated(unsafe) private var mpvHandle: OpaquePointer?
    nonisolated(unsafe) private var renderContext: OpaquePointer?
    nonisolated(unsafe) private var core: MpvCore?
    nonisolated(unsafe) private var coreRetainedPtr: UnsafeMutableRawPointer?
    nonisolated(unsafe) private var renderUpdateContextPtr: UnsafeMutableRawPointer?
    /// The GPU path's OpenGL context (`cs_gl_context`); nil on the software path.
    /// Used only on `renderQueue`.
    nonisolated(unsafe) private var glContext: OpaquePointer?
    /// Which renderer this view uses, for diagnostics and the stream info line.
    nonisolated(unsafe) private(set) var rendererName = "none"
    /// Tests only: receives each rendered frame on the render queue. Set before `setup`.
    nonisolated(unsafe) var renderedFrameObserverForTesting: (@Sendable (CVPixelBuffer) -> Void)?

    // Metal blit pipeline (render queue)
    nonisolated(unsafe) private var commandQueue: MTLCommandQueue?
    nonisolated(unsafe) private var pipelineState: MTLRenderPipelineState?
    // The reference is guarded by renderLock. Each generation owns a box;
    // its mutable pool/cache are only accessed on renderQueue.
    nonisolated(unsafe) private var renderBuffers: RenderBufferState?
    nonisolated(unsafe) private var metalLayerRef: CAMetalLayer?

    nonisolated private let renderQueue = DispatchQueue(label: "com.cloudstream.macos.render", qos: .userInteractive)
    /// Bounds frames in flight on the GPU (R2).
    nonisolated private let inFlightFrames = DispatchSemaphore(value: MetalVideoView.maxFramesInFlight)
    /// The GPU frame rendered by GL but not yet known finished. Render queue only.
    nonisolated private let pendingGPU = PendingGPUFrame()
    /// A frame whose GL work is still unfinished after this long is dropped.
    nonisolated static let maxFencePending: Duration = .milliseconds(100)
    nonisolated static let maxFramesInFlight = 3

    // Guarded by `renderLock`.
    nonisolated private let renderLock = NSLock()
    nonisolated(unsafe) private var isRenderPending = false
    nonisolated(unsafe) private var isTornDownState = false
    nonisolated(unsafe) private var frameAvailable = false
    nonisolated(unsafe) private var forceRedraw = true
    nonisolated(unsafe) private var isOccluded = false
    /// An update callback was processed off the display link and mpv reported
    /// a new frame: the next tick renders it (Remediation 2.1).
    nonisolated(unsafe) private var updatedFrame = false
    nonisolated(unsafe) private var isUpdatePending = false
    /// The display link exists and runs: it alone drives rendering then.
    nonisolated(unsafe) private var displayLinkRunning = false
    /// A GPU frame waits for its fence before it can be presented (Remediation 2.2).
    nonisolated(unsafe) private var hasPendingPresentation = false
    nonisolated(unsafe) private var lastDrawableSize = CGSize(width: 1280, height: 720)
    nonisolated(unsafe) private var videoSize = CGSize.zero
    nonisolated(unsafe) private var presentedFrames = 0

    /// Frames presented to the drawable since setup — diagnostics and the
    /// live pipeline tests (R1/R2).
    nonisolated var presentedFrameCount: Int {
        renderLock.lock()
        defer { renderLock.unlock() }
        return presentedFrames
    }

    private var displayLink: CADisplayLink?
    private var displayLinkProxy: DisplayLinkProxy?
    private var observedWindow: NSWindow?

    private var pendingAudioTracks: [PlaybackAudio] = []
    private var pendingSubtitles: [PlaybackSubtitle] = []
    private var addedSubtitleURLs: Set<String> = []
    private var fileLoaded = false
    private var eofReported = false
    private var defaultUserAgent: String?

    nonisolated(unsafe) private(set) var isInitialized = false

    /// Options mpv rejected during setup (unknown name or invalid value).
    /// mpv fails these silently otherwise — a misspelled option once stripped
    /// Referer from every request. Surfaced for logs and tests.
    private(set) var rejectedOptions: [String] = []

    /// - Parameter optional: the option only exists in some libmpv builds and
    ///   its absence already gives the wanted behaviour (e.g. `osc` needs Lua,
    ///   which the bundled build omits — no Lua means no on-screen controller).
    @discardableResult
    private func setOption(_ mpv: OpaquePointer, _ name: String, _ value: String, optional: Bool = false) -> Bool {
        let status = mpv_set_option_string(mpv, name, value)
        if optional, status == MPV_ERROR_OPTION_NOT_FOUND.rawValue { return true }
        if status < 0 {
            rejectedOptions.append(name)
            let reason = mpv_error_string(status).map { String(cString: $0) } ?? "\(status)"
            NSLog("MetalVideoView: mpv rejected option %@ (%@)", name, reason)
            return false
        }
        return true
    }

    /// Playback clock, maintained on the main actor from property changes.
    var currentElapsed: Double = 0
    var currentDuration: Double = 0

    /// time-pos forwarding cadence (4 Hz) — mpv ticks far faster, and every
    /// forwarded tick is a main-actor hop plus a SwiftUI invalidation.
    nonisolated static let timePosForwardInterval: Double = 0.25
    private var lastForwardedTimePos: Double = -1

    /// Upper bound for the CPU-rendered frame's longest side. The GPU scales
    /// the result to the Retina drawable.
    nonisolated static let maxRenderDimension: CGFloat = 1920

    /// External subtitles attached per file (mpv handles more, but each is a
    /// network fetch at load time).
    static let maxExternalSubtitles = 16

    /// True when this time-pos should reach SwiftUI: on the ~4 Hz cadence, or
    /// immediately for a discontinuity (seek) — a negative delta or a jump.
    func shouldForwardTimePos(now: Double) -> Bool {
        let last = lastForwardedTimePos
        lastForwardedTimePos = now
        guard last >= 0 else { return true }
        let delta = now - last
        return delta < 0 || delta >= Self.timePosForwardInterval
    }

    /// Bridges playback property changes to the SwiftUI layer (main-actor only).
    var onPropertyChange: ((String, MpvValue) -> Void)?
    /// Fired once per file when playback reaches the end (`eof-reached` under
    /// `keep-open`, or END_FILE with reason EOF).
    var onEndOfFile: (() -> Void)?
    /// Fired on MPV_END_FILE_REASON_ERROR for the current file — drives
    /// automatic mirror failover.
    var onPlaybackFailed: (() -> Void)?
    /// The engine itself could not start (create, initialize, render
    /// context, shader). Another mirror cannot fix that, so it is reported
    /// separately from a failed file.
    var onEngineFailed: ((String) -> Void)?
    /// Outcome of a seek or screenshot command, and failures of any other.
    var onCommandReply: ((MpvCommandReply) -> Void)?
    private var commandSequence: UInt64 = 0
    private var pendingScreenshots: [UInt64: URL] = [:]

    private func reportEngineFailure(_ stage: String) {
        NSLog("%@", "[mpv:error] engine setup failed: \(stage)")
        if let onEngineFailed { onEngineFailed(stage) } else { onPlaybackFailed?() }
    }

    private func nextCommandTag(_ kind: MpvCommandReply.Kind) -> UInt64 {
        commandSequence &+= 1
        return MpvCommandReply.tag(kind, sequence: commandSequence)
    }

    private func handleCommandReply(userdata: UInt64, error: String?) {
        let kind = MpvCommandReply.Kind(rawValue: userdata & 0xff) ?? .other
        let url = kind == .screenshot ? pendingScreenshots.removeValue(forKey: userdata) : nil
        // Untagged commands only matter when they fail.
        guard kind != .other || error != nil else { return }
        onCommandReply?(MpvCommandReply(kind: kind, error: error, url: url))
    }
    /// Fired when the observed `track-list` changes (audio/sub/video tracks).
    var onTracksChanged: (([MpvTrack]) -> Void)?
    /// Fired when the file's `chapter-list` changes (skip intro/credits).
    var onChaptersChanged: (([MpvChapter]) -> Void)?
    /// Fired when playback actually (re)starts — after the initial load and
    /// after every seek (MPV_EVENT_PLAYBACK_RESTART).
    var onPlaybackRestart: (() -> Void)?
    /// Trackpad/mouse wheel gestures (D11): relative seek seconds / volume delta.
    var onScrollSeek: ((Double) -> Void)?
    var onScrollVolume: ((Double) -> Void)?

    private var metalLayer: CAMetalLayer {
        if let layer = self.layer as? CAMetalLayer {
            return layer
        }
        wantsLayer = true
        let created = makeBackingLayer() as! CAMetalLayer
        self.layer = created
        return created
    }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = MTLCreateSystemDefaultDevice()
        layer.pixelFormat = .bgra8Unorm
        // Both renderers produce SDR in sRGB encoding; say so explicitly
        // instead of leaving the interpretation to the system default.
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.maximumDrawableCount = 3
        layer.allowsNextDrawableTimeout = true
        layer.backgroundColor = NSColor.black.cgColor
        return layer
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        // Between a bounds change and the next frame rendered at the new
        // drawable size, the last frame is scaled to the view. AppKit owns
        // the backing layer's contentsGravity and derives it from this
        // property, whose default (.scaleAxesIndependently) stretches it.
        layerContentsPlacement = .scaleProportionallyToFit
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MetalVideoView is created programmatically")
    }

    deinit {
        performShutdown()
    }

    // MARK: - Engine setup

    func setup(
        streamURL: String,
        headers: [String: String],
        subtitles: [SubtitleDto],
        audioTracks: [AudioTrackDto] = [],
        startAt seconds: Double?,
    ) {
        do {
            setup(resource: try .remote(streamURL), headers: headers,
                subtitles: try subtitles.map(PlaybackSubtitle.remote), audioTracks: try audioTracks.map(PlaybackAudio.remote), startAt: seconds)
        } catch { onPlaybackFailed?() }
    }

    func setup(
        resource: PlaybackResource,
        headers: [String: String],
        subtitles: [PlaybackSubtitle],
        audioTracks: [PlaybackAudio] = [],
        startAt seconds: Double?,
        decryption: ClearKeyDto? = nil,
    ) {
        do { try Self.validateInputs(headers: headers, audioTracks: audioTracks) }
        catch { onPlaybackFailed?(); return }
        guard !isInitialized else { return }
        guard let mpv = mpv_create() else { reportEngineFailure("could not create the player core"); return }
        renderLock.lock()
        isTornDownState = false
        metalLayerRef = metalLayer
        lastDrawableSize = metalLayer.drawableSize
        renderLock.unlock()

        mpvHandle = mpv
        lastForwardedTimePos = -1

        // Log dispatch: every message crosses into NSLog, so keep the volume
        // low even in DEBUG (P2-17, U6).
        #if DEBUG
        _ = mpv_request_log_messages(mpv, "info")
        #else
        _ = mpv_request_log_messages(mpv, "warn")
        #endif

        // Render pipeline: libmpv + our CAMetalLayer, no embedded window.
        setOption(mpv, "vo", "libmpv")
        // Renders never block for a frame's display time (the display link
        // paces them, Remediation 2.2); with no timing offset mpv hands each
        // frame over at its display time instead of ahead of it, so A/V sync
        // holds without a wait inside mpv_render_context_render.
        setOption(mpv, "video-timing-offset", "0")
        // The sw render API cannot consume VideoToolbox surfaces directly;
        // `-copy` keeps decoding on the media engine and hands back system
        // memory frames (A1). Plain `videotoolbox` fell back to CPU decode.
        setOption(mpv, "hwdec", "videotoolbox-copy")
        setOption(mpv, "hwdec-codecs", "all")
        // `always`: never advance into a queued next episode by itself
        // (queueNext); the player decides when the next episode starts.
        setOption(mpv, "keep-open", "always")
        // Opens a queued next entry once the current file is fully read.
        setOption(mpv, "prefetch-playlist", "yes")
        setOption(mpv, "input-cursor", "no")
        setOption(mpv, "input-default-bindings", "no")
        setOption(mpv, "osc", "no", optional: true)
        setOption(mpv, "media-controls", "no")
        // Refuse playback if the bundled native engine cannot enforce the
        // resource boundary. Unknown security options cannot be best effort.
        let requiredResourceOptions = [
            ("config", "no"), ("load-scripts", "no"), ("autoload-files", "no"),
            ("load-unsafe-playlists", "no"), ("demuxer-lavf-o", Self.demuxerOptions),
            ("stream-lavf-o", Self.httpStreamOptions),
        ]
        for (name, value) in requiredResourceOptions {
            guard setOption(mpv, name, value) else {
                mpv_destroy(mpv)
                mpvHandle = nil
                onPlaybackFailed?()
                return
            }
        }

        // Network / cache tuning for scraped HTTP(S) and HLS sources.
        setOption(mpv, "cache", "yes")
        setOption(mpv, "demuxer-max-bytes", "128MiB")
        setOption(mpv, "demuxer-max-back-bytes", "32MiB")
        setOption(mpv, "demuxer-readahead-secs", "30")
        setOption(mpv, "cache-pause-wait", "1")
        setOption(mpv, "network-timeout", "20")
        // Bounded range requests (`request_size`) instead of one open-ended
        // GET: CDNs such as googlevideo throttle open-ended downloads to
        // ~2 Mbit/s (measured 248 KB/s vs. 1.5+ MB/s for bounded ranges),
        // which starved the video track mid-playback and desynced it from
        // audio. Keep-alive + reconnect make transient network errors
        // invisible instead of fatal.

        // Native macOS audio output: AVFoundation (AVSampleBufferAudioRenderer) with CoreAudio fallback.
        setOption(mpv, "ao", "avfoundation,coreaudio")
        setOption(mpv, "audio-client-name", "CloudStream")
        setOption(mpv, "volume", "100")
        setOption(mpv, "mute", "no")

        // Benchmarks/tests only: override or add options (empty in production).
        for (name, value) in Self.optionOverridesForTesting {
            setOption(mpv, name, value)
        }

        // A core this build cannot start (the tests' injected fault, or a real
        // failure) ends as an engine failure, never as a failed mirror.
        let initialized = Self.initializationFaultForTesting ?? mpv_initialize(mpv)
        guard initialized == 0 else {
            mpv_destroy(mpv)
            mpvHandle = nil
            reportEngineFailure("the player core did not initialize")
            return
        }

        guard createRenderContext(mpv: mpv) else {
            mpv_terminate_destroy(mpv)
            mpvHandle = nil
            reportEngineFailure("the video renderer could not be created")
            return
        }

        observeProperties(mpv: mpv)

        let core = MpvCore(
            handle: mpv,
            queue: DispatchQueue(label: "com.cloudstream.macos.mpv-events", qos: .userInteractive),
            sink: MpvEventSink(
                onProperty: { [weak self] name, value in
                    self?.handleProperty(name, value)
                },
                onEndFile: { [weak self] reason in
                    switch reason {
                    case .eof:
                        self?.reportEndOfFile()
                    case .error:
                        self?.onPlaybackFailed?()
                    case .stop, .quit, .redirect, .other:
                        break
                    }
                },
                onTracks: { [weak self] tracks in
                    self?.onTracksChanged?(tracks)
                },
                onFileLoaded: { [weak self] in
                    self?.handleFileLoaded()
                },
                onPlaybackRestart: { [weak self] in
                    self?.onPlaybackRestart?()
                },
                onChapters: { [weak self] chapters in
                    self?.onChaptersChanged?(chapters)
                },
                onCommandReply: { [weak self] userdata, error in
                    self?.handleCommandReply(userdata: userdata, error: error)
                },
            ),
        )
        self.core = core

        let coreRaw = Unmanaged.passRetained(core).toOpaque()
        self.coreRetainedPtr = coreRaw
        mpv_set_wakeup_callback(mpv, onMpvWakeupCallback, coreRaw)

        // Captured once: headers without a User-Agent restore mpv's default
        // instead of inheriting the previous mirror's (T7).
        if let raw = mpv_get_property_string(mpv, "user-agent") {
            defaultUserAgent = String(cString: raw)
            mpv_free(raw)
        }

        isInitialized = true
        startDisplayLinkIfNeeded()
        loadStream(resource: resource, headers: headers, subtitles: subtitles, audioTracks: audioTracks, startAt: seconds,
                   decryption: decryption)
    }

    /// Loads a stream into the running engine. Every per-file input — headers,
    /// referer, user agent, start position — is set on every load, so nothing
    /// leaks from the previous mirror or episode (T7, T8, T9).
    func loadStream(
        url: String,
        headers: [String: String],
        subtitles: [SubtitleDto] = [],
        audioTracks: [AudioTrackDto] = [],
        startAt: Double?,
    ) {
        do {
            loadStream(resource: try .remote(url), headers: headers,
                subtitles: try subtitles.map(PlaybackSubtitle.remote), audioTracks: try audioTracks.map(PlaybackAudio.remote), startAt: startAt)
        } catch { onPlaybackFailed?() }
    }

    func loadStream(
        resource: PlaybackResource,
        headers: [String: String],
        subtitles: [PlaybackSubtitle] = [],
        audioTracks: [PlaybackAudio] = [],
        startAt: Double?,
        usesQueuedNext: Bool = false,
        decryption: ClearKeyDto? = nil,
    ) {
        do { try Self.validateInputs(headers: headers, audioTracks: audioTracks) }
        catch { onPlaybackFailed?(); return }
        if let decryption, !MediaResourcePolicy.isHexKey(decryption.key) || !(decryption.kid.map(MediaResourcePolicy.isHexKey) ?? true) {
            onPlaybackFailed?(); return
        }
        guard let mpv = mpvHandle else { return }
        pendingAudioTracks = audioTracks
        pendingSubtitles = subtitles
        addedSubtitleURLs = []
        fileLoaded = false
        eofReported = false
        lastForwardedTimePos = -1
        currentElapsed = max(0, startAt ?? 0)

        let split = Self.splitHeaders(headers)
        // Credential headers never get here: such streams play through the
        // engine relay (security audit M2). The rest go both to mpv's own HTTP
        // stream and, per file below, to FFmpeg's demuxer (Remediation 3.3).
        Self.setStringListAsync(mpv, "http-header-fields", split.fields)
        Self.setStringAsync(mpv, "user-agent", split.userAgent ?? defaultUserAgent ?? "")
        // A preload is capped (queueNext); the playing file gets the full buffer.
        Self.setStringAsync(mpv, "demuxer-max-bytes", Self.playbackBufferBytes)

        if usesQueuedNext {
            // The queued entry was opened (and buffered) ahead of time with
            // these same headers; switching to it keeps that work.
            Self.commandAsync(mpv, ["playlist-next", "force"])
            requestRedraw()
            return
        }
        var args = ["loadfile", resource.url, "replace"]
        var fileOptions: [String] = []
        if let startAt, startAt > 1 {
            // Per-file `start=` opens directly at the resume point instead of
            // loading from 0:00 and seeking afterwards (T9). mpv ≥ 0.38 syntax:
            // loadfile <url> <flags> <index> <options>.
            fileOptions.append(String(format: "start=%.3f", startAt))
        }
        // Remediation 3.3: the request headers as FFmpeg's `headers` demuxer
        // option, so the nested HTTP contexts the HLS and DASH demuxers open for
        // segments, keys and initialization data carry them too. Per file, so
        // they apply to this stream only; a decryption key rides along the same
        // way. The per-file value replaces the global option, so it repeats the
        // protocol confinement. FFmpeg sets each header once (the option
        // replaces the one mpv derives from `http-header-fields`).
        let demuxer = Self.demuxerOptions(headers: split, defaultUserAgent: defaultUserAgent, decryption: decryption)
        if demuxer != Self.demuxerOptions {
            fileOptions.append(Self.lengthPrefixed("demuxer-lavf-o", demuxer))
        }
        if !fileOptions.isEmpty { args += ["-1", fileOptions.joined(separator: ",")] }
        Self.commandAsync(mpv, args)
        requestRedraw()
    }

    /// The full forward buffer of the playing file, and the cap for a preload.
    nonisolated static let playbackBufferBytes = "128MiB"
    nonisolated static let preloadBufferBytes = "32MiB"

    /// Section 7 preload: appends the next episode so mpv opens it and buffers
    /// its first seconds once the current file is fully read. The buffer cap
    /// drops to `preloadBufferBytes` meanwhile (the current file is nearly
    /// done); `loadStream` restores it. Headers are the current file's, so
    /// callers queue only a link with the same headers.
    func queueNext(url: String) {
        guard let mpv = mpvHandle else { return }
        Self.commandAsync(mpv, ["playlist-clear"])
        Self.setStringAsync(mpv, "demuxer-max-bytes", Self.preloadBufferBytes)
        Self.commandAsync(mpv, ["loadfile", url, "append"])
    }

    /// Drops a queued next episode (seek back, a different episode, close).
    func cancelQueuedNext() {
        guard let mpv = mpvHandle else { return }
        Self.commandAsync(mpv, ["playlist-clear"])
        Self.setStringAsync(mpv, "demuxer-max-bytes", Self.playbackBufferBytes)
    }

    /// Subtitles discovered after playback started (progressive link
    /// resolution). Added immediately when the file is loaded, otherwise
    /// queued for FILE_LOADED.
    func addSubtitles(_ subtitles: [PlaybackSubtitle]) {
        guard !subtitles.isEmpty else { return }
        if fileLoaded {
            attachSubtitles(subtitles)
        } else {
            pendingSubtitles += subtitles
        }
    }

    private func handleFileLoaded() {
        guard let mpv = mpvHandle else { return }
        fileLoaded = true

        // 1. External audio stream(s) (e.g. YouTube DASH / split streams).
        //    Headers are the global per-load `http-header-fields` (the daemon
        //    defaults audio headers to the link's own).
        if !pendingAudioTracks.isEmpty {
            let tracks = pendingAudioTracks
            pendingAudioTracks = []
            for (index, track) in tracks.enumerated() {
                let flag = (index == 0) ? "select" : "auto"
                let title = track.dto.label ?? "Audio Track \(index + 1)"
                Self.commandAsync(mpv, ["audio-add", track.resource.url, flag, title, track.dto.language ?? ""])
            }
        }

        // 2. External subtitles
        if !pendingSubtitles.isEmpty {
            let subs = pendingSubtitles
            pendingSubtitles = []
            attachSubtitles(subs)
        }
    }

    private func attachSubtitles(_ subtitles: [PlaybackSubtitle]) {
        guard let mpv = mpvHandle else { return }
        for sub in subtitles {
            guard addedSubtitleURLs.count < Self.maxExternalSubtitles else { break }
            guard addedSubtitleURLs.insert(sub.resource.url).inserted else { continue }
            let title = sub.dto.label ?? sub.dto.language
            Self.commandAsync(mpv, ["sub-add", sub.resource.url, "auto", title, sub.dto.language])
        }
    }

    private func handleProperty(_ name: String, _ value: MpvValue) {
        switch name {
        case "eof-reached":
            if value.boolValue == true {
                reportEndOfFile()
            }
        case "dwidth", "dheight":
            if let dimension = value.int64Value {
                renderLock.lock()
                if name == "dwidth" {
                    videoSize.width = CGFloat(dimension)
                } else {
                    videoSize.height = CGFloat(dimension)
                }
                forceRedraw = true
                renderLock.unlock()
            }
        default:
            break
        }
        onPropertyChange?(name, value)
    }

    /// `keep-open=yes` suppresses END_FILE(eof) — `eof-reached` is the signal
    /// (T4). Deduplicated per file so both paths can never double-advance.
    private func reportEndOfFile() {
        guard !eofReported else { return }
        eofReported = true
        onEndOfFile?()
    }

    private func createRenderContext(mpv: OpaquePointer) -> Bool {
        let layer = metalLayer
        guard let device = layer.device ?? MTLCreateSystemDefaultDevice() else { return false }
        commandQueue = device.makeCommandQueue()
        if commandQueue == nil { return false }
        guard buildBlitPipeline(device: device) else { return false }

        var textureCache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache) == kCVReturnSuccess,
              let textureCache else { return false }
        let buffers = RenderBufferState(queue: renderQueue, textureCache: textureCache)
        renderLock.lock()
        renderBuffers = buffers
        renderLock.unlock()

        if !Self.forcesSoftwareRenderer, let context = createGPURenderContext(mpv: mpv) {
            renderContext = context
            rendererName = "gpu"
            // Zero-copy decode, and an SDR target the GPU renderer tone-maps
            // HDR (BT.2020 PQ/HLG) into, matching the layer's sRGB colour space.
            for (name, value) in [("hwdec", "videotoolbox"), ("target-prim", "bt.709"), ("target-trc", "srgb"),
                                  ("tone-mapping", "auto"), ("hdr-compute-peak", "auto")] {
                _ = mpv_set_property_string(mpv, name, value)
            }
        } else {
            // MPV_RENDER_PARAM_API_TYPE = "sw": upstream mpv's render context
            // without an OpenGL context. See the type doc for the pipeline.
            guard let context = createSoftwareRenderContext(mpv: mpv) else { return false }
            renderContext = context
            rendererName = "software"
        }
        NSLog("%@", "[mpv:info] renderer: \(rendererName)")

        let updateContext = RenderUpdateContext(view: self)
        let updateContextRaw = Unmanaged.passRetained(updateContext).toOpaque()
        self.renderUpdateContextPtr = updateContextRaw
        mpv_render_context_set_update_callback(renderContext, onMpvRenderUpdateCallback, updateContextRaw)

        return true
    }

    /// `CS_PLAYER_RENDERER=sw` keeps the software renderer (diagnosis, tests).
    nonisolated static var forcesSoftwareRenderer: Bool {
        ProcessInfo.processInfo.environment["CS_PLAYER_RENDERER"] == "sw"
    }

    /// The GPU path: an OpenGL render context on a private CGL context, made
    /// on the render queue that will use it. Nil when OpenGL or mpv's GL
    /// renderer is unavailable; the caller then uses the software path.
    private func createGPURenderContext(mpv: OpaquePointer) -> OpaquePointer? {
        renderQueue.sync { () -> OpaquePointer? in
            guard let gl = cs_gl_create() else { return nil }
            cs_gl_make_current(gl)
            var initParams = mpv_opengl_init_params(get_proc_address: cs_gl_get_proc_address, get_proc_address_ctx: nil)
            // Advanced control lets the renderer answer screenshot requests
            // (decoded frames are GPU surfaces). Its contract holds here: the
            // render queue calls only mpv_render_* functions, and every
            // update callback schedules a render, which calls
            // mpv_render_context_update promptly (markFrameAvailable).
            var advancedControl: Int32 = 1
            var context: OpaquePointer?
            let status = MPV_RENDER_API_TYPE_OPENGL.withCString { apiType in
                withUnsafeMutablePointer(to: &initParams) { initPointer in
                    withUnsafeMutablePointer(to: &advancedControl) { advancedPointer in
                        var renderParams: [mpv_render_param] = [
                            mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: apiType)),
                            mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: initPointer),
                            mpv_render_param(type: MPV_RENDER_PARAM_ADVANCED_CONTROL, data: advancedPointer),
                            mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                        ]
                        return mpv_render_context_create(&context, mpv, &renderParams)
                    }
                }
            }
            guard status == 0, let context else {
                NSLog("%@", "[mpv:warn] GPU renderer unavailable (\(status)); using the software renderer")
                cs_gl_destroy(gl)
                return nil
            }
            glContext = gl
            return context
        }
    }

    private func createSoftwareRenderContext(mpv: OpaquePointer) -> OpaquePointer? {
        var context: OpaquePointer?
        let status = "sw".withCString { apiType in
            var renderParams: [mpv_render_param] = [
                mpv_render_param(
                    type: MPV_RENDER_PARAM_API_TYPE,
                    data: UnsafeMutableRawPointer(mutating: apiType),
                ),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
            ]
            return mpv_render_context_create(&context, mpv, &renderParams)
        }
        guard status == 0, let context else { return nil }
        // The software path decodes to system memory (see the type doc).
        _ = mpv_set_property_string(mpv, "hwdec", "videotoolbox-copy")
        return context
    }

    private func buildBlitPipeline(device: MTLDevice) -> Bool {
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        constant float2 quad_vertices[4] = {
            float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0)
        };
        constant float2 quad_uvs[4] = {
            float2(0.0, 1.0), float2(1.0, 1.0), float2(0.0, 0.0), float2(1.0, 0.0)
        };

        struct RasterizerData {
            float4 position [[position]];
            float2 uv;
        };

        vertex RasterizerData fullscreen_vertex(uint vid [[vertex_id]]) {
            RasterizerData out;
            out.position = float4(quad_vertices[vid], 0.0, 1.0);
            out.uv = quad_uvs[vid];
            return out;
        }

        fragment float4 sample_texture(RasterizerData in [[stage_in]],
                                       texture2d<float> tex [[texture(0)]]) {
            constexpr sampler s(address::clamp_to_edge, filter::linear);
            return float4(tex.sample(s, in.uv).rgb, 1.0);
        }
        """

        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "fullscreen_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "sample_texture")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
            return pipelineState != nil
        } catch {
            NSLog("MetalVideoView: blit pipeline failed: \(error)")
            return false
        }
    }

    private func observeProperties(mpv: OpaquePointer) {
        let properties: [(String, mpv_format)] = [
            ("time-pos", MPV_FORMAT_DOUBLE),
            ("duration", MPV_FORMAT_DOUBLE),
            ("pause", MPV_FORMAT_FLAG),
            ("paused-for-cache", MPV_FORMAT_FLAG),
            ("cache-buffering-state", MPV_FORMAT_INT64),
            ("seeking", MPV_FORMAT_FLAG),
            ("speed", MPV_FORMAT_DOUBLE),
            ("volume", MPV_FORMAT_DOUBLE),
            ("mute", MPV_FORMAT_FLAG),
            ("aid", MPV_FORMAT_INT64),
            ("sid", MPV_FORMAT_INT64),
            ("dwidth", MPV_FORMAT_INT64),
            ("dheight", MPV_FORMAT_INT64),
            ("eof-reached", MPV_FORMAT_FLAG),
            ("seekable", MPV_FORMAT_FLAG),
            ("track-list", MPV_FORMAT_NODE),
            ("chapter-list", MPV_FORMAT_NODE),
        ]
        for (name, format) in properties {
            mpv_observe_property(mpv, 0, name, format)
        }
        // The stream info line (StreamInfo).
        for name in StreamInfo.observedStringProperties { mpv_observe_property(mpv, 0, name, MPV_FORMAT_STRING) }
        for name in StreamInfo.observedIntegerProperties { mpv_observe_property(mpv, 0, name, MPV_FORMAT_INT64) }
    }

    // MARK: - Display link & occlusion (R1, R4)

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observedWindow {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didChangeOcclusionStateNotification,
                object: observedWindow,
            )
            self.observedWindow = nil
        }
        guard let window else {
            stopDisplayLink()
            return
        }
        observedWindow = window
        // Retina: size the drawable in device pixels from the first layout.
        metalLayer.contentsScale = window.backingScaleFactor
        needsLayout = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowOcclusionChanged(_:)),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window,
        )
        updateOcclusion()
        startDisplayLinkIfNeeded()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor {
            metalLayer.contentsScale = scale
        }
        needsLayout = true
    }

    @objc private func windowOcclusionChanged(_ notification: Notification) {
        updateOcclusion()
    }

    private func updateOcclusion() {
        let occluded = !(window?.occlusionState.contains(.visible) ?? false)
        renderLock.lock()
        let changed = occluded != isOccluded
        isOccluded = occluded
        if !occluded { forceRedraw = true }
        renderLock.unlock()
        displayLink?.isPaused = occluded
        if changed, !occluded { scheduleRender() }
    }

    private func startDisplayLinkIfNeeded() {
        guard isInitialized, displayLink == nil, window != nil else { return }
        let proxy = DisplayLinkProxy(view: self)
        let link = displayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        link.add(to: .main, forMode: .common)
        link.isPaused = isOccludedSnapshot
        displayLinkProxy = proxy
        displayLink = link
        renderLock.lock()
        displayLinkRunning = true
        renderLock.unlock()
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkProxy = nil
        renderLock.lock()
        displayLinkRunning = false
        renderLock.unlock()
    }

    private var isOccludedSnapshot: Bool {
        renderLock.lock()
        defer { renderLock.unlock() }
        return isOccluded
    }

    /// Display-link tick (main run loop): the single source of render ticks
    /// while it runs (Remediation 2.1). A tick with nothing new — no frame from
    /// mpv, no repaint, no frame waiting for its fence — does no work at all.
    fileprivate func displayLinkFired() {
        renderLock.lock()
        let needed = frameAvailable || forceRedraw || updatedFrame || hasPendingPresentation
        renderLock.unlock()
        if needed { scheduleRender() }
    }

    /// mpv render-update callback (any thread). Only records that a frame is
    /// due; the display link renders it. Without a running display link (no
    /// window yet, tests) or while occluded (the link is paused; frames are
    /// consumed cheaply to keep mpv's queue flowing) it renders at once.
    nonisolated func markFrameAvailable() {
        renderLock.lock()
        frameAvailable = true
        let occluded = isOccluded
        let driven = displayLinkRunning
        let advancedControl = glContext != nil
        renderLock.unlock()
        if occluded || !driven {
            scheduleRender()
        } else if advancedControl {
            // Advanced control: mpv may wait for this update to be processed
            // (a screenshot, say), so the update runs now; the frame it
            // reports is rendered on the next tick.
            scheduleUpdate()
        }
    }

    /// `mpv_render_context_update` on the render queue, coalesced.
    nonisolated private func scheduleUpdate() {
        renderLock.lock()
        guard !isTornDownState, !isUpdatePending else {
            renderLock.unlock()
            return
        }
        isUpdatePending = true
        renderLock.unlock()
        renderQueue.async { [weak self] in
            guard let self else { return }
            self.renderLock.lock()
            self.isUpdatePending = false
            let ctx = self.isTornDownState ? nil : self.renderContext
            self.renderLock.unlock()
            guard let ctx else { return }
            if let gl = self.glContext { cs_gl_make_current(gl) }
            let flags = mpv_render_context_update(ctx)
            guard flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 else { return }
            self.renderLock.lock()
            self.updatedFrame = true
            self.renderLock.unlock()
        }
    }

    private func requestRedraw() {
        renderLock.lock()
        forceRedraw = true
        renderLock.unlock()
    }

    // MARK: - Rendering

    override func layout() {
        super.layout()
        let layer = metalLayer
        let scale = layer.contentsScale
        let size = CGSize(width: max(2, bounds.width * scale), height: max(2, bounds.height * scale))
        if layer.drawableSize != size {
            layer.drawableSize = size
        }
        renderLock.lock()
        lastDrawableSize = size
        forceRedraw = true
        renderLock.unlock()
        // Re-render now rather than waiting for mpv's next frame: a paused
        // video would otherwise keep showing the frame sized for the old
        // bounds until playback resumes.
        scheduleRender()
    }

    nonisolated func scheduleRender() {
        renderLock.lock()
        guard !isTornDownState, !isRenderPending else {
            renderLock.unlock()
            return
        }
        isRenderPending = true
        renderLock.unlock()

        renderQueue.async { [weak self] in
            guard let self else { return }
            self.renderLock.lock()
            self.isRenderPending = false
            let tornDown = self.isTornDownState
            self.renderLock.unlock()
            if !tornDown {
                self.renderFrame()
            }
        }
    }

    /// Size of the CPU-rendered frame: the drawable's aspect ratio (mpv
    /// letterboxes inside it), scaled so the video area never exceeds the
    /// video's native resolution, capped at `maxRenderDimension` (A1).
    nonisolated static func renderSize(drawable: CGSize, video: CGSize) -> CGSize {
        let drawableWidth = max(2, drawable.width)
        let drawableHeight = max(2, drawable.height)
        var scale: CGFloat = 1
        if video.width > 0, video.height > 0 {
            let fit = min(drawableWidth / video.width, drawableHeight / video.height)
            if fit > 1 { scale = 1 / fit }
        }
        scale = min(scale, maxRenderDimension / max(drawableWidth, drawableHeight))
        func even(_ value: CGFloat) -> CGFloat { max(2, (value / 2).rounded() * 2) }
        return CGSize(width: even(drawableWidth * scale), height: even(drawableHeight * scale))
    }

    nonisolated func renderFrame() {
        renderLock.lock()
        let tornDown = isTornDownState
        let ctx = renderContext
        let queue = commandQueue
        let pipeline = pipelineState
        let layer = metalLayerRef
        let buffers = renderBuffers
        let drawableSize = lastDrawableSize
        let video = videoSize
        let occluded = isOccluded
        let force = forceRedraw
        let updated = updatedFrame
        forceRedraw = false
        frameAvailable = false
        updatedFrame = false
        renderLock.unlock()

        guard !tornDown, let ctx, let queue, let pipeline, let layer, let buffers else { return }
        // mpv's GL renderer may touch the context even when skipping a frame.
        let gl = glContext
        if let gl { cs_gl_make_current(gl) }

        // R3: only render when mpv has a new frame (or the surface changed).
        let flags = mpv_render_context_update(ctx)
        let hasFrame = flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 || updated
        let target = Presentation(ctx: ctx, queue: queue, pipeline: pipeline, layer: layer, buffers: buffers)

        // Remediation 2.2: a GPU frame whose GL work may still be running is
        // presented only once its fence has passed; the queue never waits.
        if let gl, let pending = pendingGPU.frame {
            switch cs_gl_fence_poll(gl, pending.fence) {
            case 1:
                takePendingGPUFrame(gl: gl)
                present(pending.buffer, width: pending.width, height: pending.height, to: target)
            case 0 where pending.issued.duration(to: .now) < Self.maxFencePending:
                // Still on the GPU: try again next tick, and keep any new frame
                // for then rather than queueing it behind this one.
                renderLock.lock()
                if hasFrame { updatedFrame = true }
                if force { forceRedraw = true }
                renderLock.unlock()
                return
            default:
                dropPendingGPUFrame(gl: gl, ctx: ctx)
            }
        }
        guard hasFrame || force else { return }

        // R4: hidden window — consume the frame without rasterizing it.
        if occluded {
            Self.skipRender(ctx)
            return
        }

        // R2: bound frames in flight without ever waiting for the GPU here.
        guard inFlightFrames.wait(timeout: .now()) == .success else {
            Self.skipRender(ctx)
            return
        }

        // The GPU path scales on the GPU, so it renders at the drawable's
        // size; the software path keeps the CPU work at the video's size.
        let renderSize = gl != nil ? Self.gpuRenderSize(drawable: drawableSize) : Self.renderSize(drawable: drawableSize, video: video)
        let width = Int(renderSize.width)
        let height = Int(renderSize.height)
        guard let buffer = buffers.makePixelBuffer(width: width, height: height) else {
            inFlightFrames.signal()
            Self.skipRender(ctx)
            return
        }

        if let gl {
            guard Self.renderGPU(ctx, gl: gl, buffer: buffer, poolChanged: buffers.takePoolChanged(), width: width, height: height),
                  let fence = cs_gl_fence(gl) else {
                inFlightFrames.signal()
                mpv_render_context_report_swap(ctx)
                return
            }
            if cs_gl_fence_poll(gl, fence) == 1 {
                cs_gl_fence_release(gl, fence)
                present(buffer, width: width, height: height, to: target)
            } else {
                // Presented on a later tick; the in-flight slot stays held until then.
                pendingGPU.frame = .init(buffer: buffer, fence: fence, width: width, height: height, issued: .now)
                setPendingPresentation(true)
            }
            return
        }
        guard Self.renderSoftware(ctx, buffer: buffer, width: width, height: height) else {
            inFlightFrames.signal()
            mpv_render_context_report_swap(ctx)
            return
        }
        present(buffer, width: width, height: height, to: target)
    }

    /// What presenting a frame needs; captured once per render pass.
    private struct Presentation {
        let ctx: OpaquePointer
        let queue: MTLCommandQueue
        let pipeline: MTLRenderPipelineState
        let layer: CAMetalLayer
        let buffers: RenderBufferState
    }

    /// Samples a finished frame into the next drawable and reports the swap.
    /// Owns one `inFlightFrames` slot: released when the GPU completes, or at
    /// once if the frame cannot be presented.
    nonisolated private func present(_ buffer: CVPixelBuffer, width: Int, height: Int, to target: Presentation) {
        var frameSubmitted = false
        defer {
            if !frameSubmitted {
                inFlightFrames.signal()
                mpv_render_context_report_swap(target.ctx)
            }
        }
        renderedFrameObserverForTesting?(buffer)
        guard let textureCache = target.buffers.textureCache else { return }
        CVMetalTextureCacheFlush(textureCache, 0)

        var cvTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, nil, .bgra8Unorm, width, height, 0, &cvTexture,
        ) == kCVReturnSuccess,
            let cvTexture,
            let texture = CVMetalTextureGetTexture(cvTexture),
            let drawable = target.layer.nextDrawable(),
            let commandBuffer = target.queue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: Self.renderPassDescriptor(for: drawable))
        else { return }

        encoder.setRenderPipelineState(target.pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        // The pixel buffer returns to the pool only once the GPU finished
        // sampling it — the texture keeps it alive until then (R2).
        let retained = FrameResources(texture: cvTexture, buffer: buffer)
        let semaphore = inFlightFrames
        commandBuffer.addCompletedHandler { _ in
            retained.release()
            semaphore.signal()
        }
        frameSubmitted = true
        commandBuffer.present(drawable)
        commandBuffer.commit()
        mpv_render_context_report_swap(target.ctx)
        renderLock.lock()
        presentedFrames += 1
        renderLock.unlock()
    }

    nonisolated private func setPendingPresentation(_ pending: Bool) {
        renderLock.lock()
        hasPendingPresentation = pending
        renderLock.unlock()
    }

    /// Render queue: hands over the pending frame's fence (released here).
    nonisolated private func takePendingGPUFrame(gl: OpaquePointer) {
        guard let pending = pendingGPU.frame else { return }
        pendingGPU.frame = nil
        cs_gl_fence_release(gl, pending.fence)
        setPendingPresentation(false)
    }

    /// Render queue: a frame that failed or took too long is not shown.
    nonisolated private func dropPendingGPUFrame(gl: OpaquePointer, ctx: OpaquePointer?) {
        guard pendingGPU.frame != nil else { return }
        takePendingGPUFrame(gl: gl)
        inFlightFrames.signal()
        if let ctx { mpv_render_context_report_swap(ctx) }
    }

    /// The GPU path's frame size: the drawable's, capped at `maxRenderDimension`.
    nonisolated static func gpuRenderSize(drawable: CGSize) -> CGSize {
        let width = max(2, drawable.width), height = max(2, drawable.height)
        let scale = min(1, maxRenderDimension / max(width, height))
        func even(_ value: CGFloat) -> CGFloat { max(2, (value / 2).rounded() * 2) }
        return CGSize(width: even(width * scale), height: even(height * scale))
    }

    /// mpv's GPU renderer draws into the buffer's IOSurface through a cached
    /// framebuffer; the GL work is finished before Metal samples the surface.
    nonisolated private static func renderGPU(_ ctx: OpaquePointer, gl: OpaquePointer, buffer: CVPixelBuffer,
                                              poolChanged: Bool, width: Int, height: Int) -> Bool {
        guard let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return false }
        if poolChanged { cs_gl_forget_framebuffers(gl) }
        let framebuffer = cs_gl_framebuffer(gl, surface, false)
        guard framebuffer != 0 else { return false }
        var target = mpv_opengl_fbo(fbo: Int32(framebuffer), w: Int32(width), h: Int32(height), internal_format: 0)
        // An IOSurface bound to GL keeps Metal's row order: no flip needed.
        var flip: Int32 = 0
        // Never wait inside mpv for the frame's target time (Remediation 2.2):
        // with `video-timing-offset=0` frames arrive when they are due, and
        // the display link (or, without one, the update callback) presents them.
        var block: Int32 = 0
        let result = withUnsafeMutablePointer(to: &target) { targetPointer in
            withUnsafeMutablePointer(to: &flip) { flipPointer in
                withUnsafeMutablePointer(to: &block) { blockPointer in
                    var renderParams: [mpv_render_param] = [
                        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: targetPointer),
                        mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flipPointer),
                        mpv_render_param(type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: blockPointer),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                    ]
                    return mpv_render_context_render(ctx, &renderParams)
                }
            }
        }
        // Completion is checked with a fence by the caller; nothing waits here.
        return result >= 0
    }

    /// mpv's software renderer writes BGRX pixels into the locked buffer.
    nonisolated private static func renderSoftware(_ ctx: OpaquePointer, buffer: CVPixelBuffer, width: Int, height: Int) -> Bool {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let rendered: Bool
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            var stride = CVPixelBufferGetBytesPerRow(buffer)
            var dims: [Int32] = [Int32(width), Int32(height)]
            // As on the GPU path: frames arrive when due (`video-timing-offset=0`),
            // so the render never blocks for the display time (R1, Remediation 2.2).
            var block: Int32 = 0
            let result = dims.withUnsafeMutableBufferPointer { dimsBuf in
                withUnsafeMutablePointer(to: &stride) { stridePtr in
                    withUnsafeMutablePointer(to: &block) { blockPtr in
                        "bgr0".withCString { format in
                            var renderParams: [mpv_render_param] = [
                                mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: dimsBuf.baseAddress),
                                mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(mutating: format)),
                                mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: stridePtr),
                                mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: base),
                                mpv_render_param(type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: blockPtr),
                                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                            ]
                            return mpv_render_context_render(ctx, &renderParams)
                        }
                    }
                }
            }
            rendered = result >= 0
        } else {
            rendered = false
        }
        return rendered
    }

    nonisolated private static func skipRender(_ ctx: OpaquePointer) {
        var skip: Int32 = 1
        withUnsafeMutablePointer(to: &skip) { skipPtr in
            var params: [mpv_render_param] = [
                mpv_render_param(type: MPV_RENDER_PARAM_SKIP_RENDERING, data: skipPtr),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
            ]
            _ = mpv_render_context_render(ctx, &params)
        }
        mpv_render_context_report_swap(ctx)
    }

    nonisolated private static func renderPassDescriptor(for drawable: CAMetalDrawable) -> MTLRenderPassDescriptor {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store
        return descriptor
    }

    // MARK: - Trackpad / wheel (D11)

    private var horizontalScrollAccumulator: CGFloat = 0
    /// Points of horizontal travel per 5 s seek step.
    private static let scrollSeekStep: CGFloat = 40

    override func scrollWheel(with event: NSEvent) {
        let rawX = event.scrollingDeltaX
        let rawY = event.scrollingDeltaY
        if event.phase == .began || event.phase == .mayBegin {
            horizontalScrollAccumulator = 0
        }
        // Normalize so "physically up / right" is positive regardless of the
        // natural-scrolling setting.
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
        let deltaX = rawX * sign
        let deltaY = rawY * sign

        if abs(deltaX) > abs(deltaY) {
            horizontalScrollAccumulator += deltaX
            while abs(horizontalScrollAccumulator) >= Self.scrollSeekStep {
                let direction: Double = horizontalScrollAccumulator > 0 ? -1 : 1
                horizontalScrollAccumulator -= Self.scrollSeekStep * (horizontalScrollAccumulator > 0 ? 1 : -1)
                onScrollSeek?(5 * direction)
            }
        } else if deltaY != 0 {
            let volumeDelta = event.hasPreciseScrollingDeltas ? Double(deltaY) * 0.25 : Double(deltaY) * 2
            onScrollVolume?(volumeDelta)
        }
    }

    // MARK: - Transport (asynchronous — T1)

    func setPlaying(_ play: Bool) {
        guard let mpv = mpvHandle else { return }
        Self.setFlagAsync(mpv, "pause", !play)
    }

    func togglePlayPause() {
        guard let mpv = mpvHandle else { return }
        Self.commandAsync(mpv, ["cycle", "pause"])
    }

    func seek(by seconds: Double) {
        guard let mpv = mpvHandle else { return }
        Self.commandAsync(mpv, ["seek", String(format: "%.3f", seconds), "relative"])
    }

    func seek(to seconds: Double) {
        guard let mpv = mpvHandle else { return }
        Self.commandAsync(mpv, ["seek", String(format: "%.3f", seconds), "absolute"], tag: nextCommandTag(.seek))
    }

    func setSubtitleDelay(_ seconds: Double) {
        guard let mpv = mpvHandle else { return }
        Self.setDoubleAsync(mpv, "sub-delay", seconds)
    }

    func setSpeed(_ speed: Double) {
        guard let mpv = mpvHandle else { return }
        Self.setDoubleAsync(mpv, "speed", speed)
    }

    func toggleMute() {
        guard let mpv = mpvHandle else { return }
        Self.commandAsync(mpv, ["cycle", "mute"])
    }

    func setMuted(_ muted: Bool) {
        guard let mpv = mpvHandle else { return }
        Self.setFlagAsync(mpv, "mute", muted)
    }

    func setVolume(_ volume: Double) {
        guard let mpv = mpvHandle else { return }
        Self.setDoubleAsync(mpv, "volume", max(0, min(100, volume)))
    }

    func selectAudioTrack(_ id: Int64) {
        guard let mpv = mpvHandle else { return }
        if id <= 0 {
            Self.setStringAsync(mpv, "aid", "no")
        } else {
            Self.setInt64Async(mpv, "aid", id)
        }
    }

    func selectSubtitleTrack(_ id: Int64) {
        guard let mpv = mpvHandle else { return }
        if id <= 0 {
            Self.setStringAsync(mpv, "sid", "no")
        } else {
            Self.setInt64Async(mpv, "sid", id)
        }
    }

    /// Applies persisted subtitle styling (plan WS-3.3). mpv color strings use
    /// "#RRGGBB" (or "#RRGGBBAA"); passing nil leaves a property untouched.
    func setSubtitleStyle(fontSize: Double?, outlineWidth: Double?, textColor: String?, backgroundColor: String?) {
        guard let mpv = mpvHandle else { return }
        if let fontSize {
            Self.setStringAsync(mpv, "sub-font-size", String(format: "%.0f", fontSize))
        }
        if let outlineWidth {
            Self.setStringAsync(mpv, "sub-border-size", String(format: "%.1f", outlineWidth))
        }
        if let textColor {
            Self.setStringAsync(mpv, "sub-color", textColor)
        }
        if let backgroundColor {
            Self.setStringAsync(mpv, "sub-back-color", backgroundColor)
        }
    }

    /// Extended subtitle styling (Offline-Features-Plan Phase 5). nil leaves
    /// the property untouched.
    func setSubtitleLayout(font: String?, bold: Bool?, shadowOffset: Double?, position: Int?) {
        guard let mpv = mpvHandle else { return }
        if let font { Self.setStringAsync(mpv, "sub-font", font) }
        if let bold { Self.setFlagAsync(mpv, "sub-bold", bold) }
        if let shadowOffset { Self.setStringAsync(mpv, "sub-shadow-offset", String(format: "%.1f", shadowOffset)) }
        if let position { Self.setInt64Async(mpv, "sub-pos", Int64(max(0, min(150, position)))) }
    }

    /// Writes the current frame (with subtitles) to `url`.
    func takeScreenshot(to url: URL) {
        guard let mpv = mpvHandle else {
            onCommandReply?(MpvCommandReply(kind: .screenshot, error: "the player is not running", url: url))
            return
        }
        let tag = nextCommandTag(.screenshot)
        pendingScreenshots[tag] = url
        Self.commandAsync(mpv, ["screenshot-to-file", url.path, "subtitles"], tag: tag)
    }

    /// Single-frame step; pauses playback like mpv's `.` / `,`.
    func frameStep(forward: Bool) {
        guard let mpv = mpvHandle else { return }
        Self.commandAsync(mpv, [forward ? "frame-step" : "frame-back-step"])
    }

    func setAspectRatio(_ ratio: String) {
        guard let mpv = mpvHandle else { return }
        Self.setStringAsync(mpv, "video-aspect-override", ratio)
    }

    /// mpv `panscan`: 1 zooms to fill the output (cropping), 0 fits it.
    func setFillsScreen(_ fills: Bool) {
        guard let mpv = mpvHandle else { return }
        Self.setDoubleAsync(mpv, "panscan", fills ? 1 : 0)
    }

    /// ffmpeg HTTP protocol options for network streams (see setup).
    nonisolated static let httpStreamOptions = [
        remoteProtocolOptions,
        "request_size=4194304",
        "multiple_requests=1",
        "reconnect=1",
        "reconnect_streamed=1",
        "reconnect_on_network_error=1",
        "reconnect_delay_max=4",
    ].joined(separator: ",")

    nonisolated static let remoteProtocolOptions = "protocol_whitelist=%\(DownloadPolicy.ffmpegProtocolWhitelist.utf8.count)%\(DownloadPolicy.ffmpegProtocolWhitelist)"

    /// `demuxer-lavf-o`: the protocol confinement plus the HLS options
    /// (``DownloadPolicy/hlsDemuxerOptions``). Demuxers other than HLS ignore
    /// the HLS keys; mpv only logs that they were unused.
    nonisolated static let demuxerOptions = ([remoteProtocolOptions]
        + DownloadPolicy.hlsDemuxerOptions.map { "\($0.0)=\($0.1)" }).joined(separator: ",")

    /// ``demuxerOptions`` plus a ClearKey content key for FFmpeg's CENC
    /// decryption: `cenc_decryption_key(s)` for DASH (passed on to each
    /// segment's MP4 demuxer) and `decryption_key(s)` for MP4 directly. Keys
    /// are validated hex, so they cannot carry option separators.
    nonisolated static func demuxerOptions(decryption: ClearKeyDto) -> String {
        let (single, keyed) = ("cenc_decryption_key", "cenc_decryption_keys")
        let options: [String]
        if let kid = decryption.kid {
            let pair = "\(kid)=\(decryption.key)"
            options = [lengthPrefixed(keyed, pair), lengthPrefixed("decryption_keys", pair)]
        } else {
            options = ["\(single)=\(decryption.key)", "decryption_key=\(decryption.key)"]
        }
        return ([demuxerOptions] + options).joined(separator: ",")
    }

    /// ``demuxerOptions`` for one file: its request headers as FFmpeg's
    /// `headers` option (CRLF-terminated lines, length-prefixed so `,` `=` and
    /// `:` in values cannot break mpv's option parser) and an optional ClearKey.
    /// Header names and values were validated by ``MediaResourcePolicy`` and
    /// cannot contain CR or LF.
    nonisolated static func demuxerOptions(headers split: (fields: [String], userAgent: String?),
                                           defaultUserAgent: String?, decryption: ClearKeyDto?) -> String {
        var options = [decryption.map(demuxerOptions(decryption:)) ?? demuxerOptions]
        var lines = split.fields
        if let userAgent = split.userAgent ?? defaultUserAgent, !userAgent.isEmpty, !split.fields.isEmpty {
            lines.append("User-Agent: \(userAgent)")
        }
        if !split.fields.isEmpty {
            options.append(lengthPrefixed("headers", lines.map { $0 + "\r\n" }.joined()))
        }
        return options.joined(separator: ",")
    }

    /// `name=%N%value`: mpv's length-prefixed form for a value containing `,` or `=`.
    nonisolated static func lengthPrefixed(_ name: String, _ value: String) -> String {
        "\(name)=%\(value.utf8.count)%\(value)"
    }

    nonisolated private static func validateInputs(headers: [String: String], audioTracks: [PlaybackAudio]) throws {
        _ = try MediaResourcePolicy.headers(headers)
        for track in audioTracks {
            _ = try MediaResourcePolicy.headers(track.dto.headers)
        }
    }

    // MARK: - Diagnostics (tests / benchmarks only)

    /// Applied after the production options at setup; empty in production.
    nonisolated(unsafe) static var optionOverridesForTesting: [(String, String)] = []
    /// Tests only: the status `mpv_initialize` is treated as returning. This
    /// libmpv build validates every option when it is set, so no option value
    /// can make a real initialization fail on demand.
    nonisolated(unsafe) static var initializationFaultForTesting: Int32?

    /// Synchronous property read for diagnostics. Never call from UI paths —
    /// it waits on the playback core.
    func diagnosticProperty(_ name: String) -> String? {
        guard let mpv = mpvHandle, let raw = mpv_get_property_string(mpv, name) else { return nil }
        defer { mpv_free(raw) }
        return String(cString: raw)
    }

    func shutdown() {
        stopDisplayLink()
        if let observedWindow {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didChangeOcclusionStateNotification,
                object: observedWindow,
            )
            self.observedWindow = nil
        }
        performShutdown()
    }

    /// Idempotent teardown. Callbacks are detached synchronously (cheap); the
    /// expensive part — draining the event and render queues, freeing the
    /// render context, and `mpv_terminate_destroy` (which joins mpv's network
    /// threads) — runs as an ordered chain off the main thread (T1).
    nonisolated func performShutdown() {
        renderLock.lock()
        guard !isTornDownState else {
            renderLock.unlock()
            return
        }
        isTornDownState = true
        let mpv = mpvHandle
        let ctx = renderContext
        let core = core
        let coreRetainedPtr = coreRetainedPtr
        let renderUpdateContextPtr = renderUpdateContextPtr
        let gl = glContext
        mpvHandle = nil
        renderContext = nil
        glContext = nil
        self.core = nil
        self.coreRetainedPtr = nil
        self.renderUpdateContextPtr = nil
        let buffers = renderBuffers
        renderBuffers = nil
        isInitialized = false
        renderLock.unlock()

        // Invalidate immediately even if deinit runs off-main: queued events
        // from this generation cannot update a replacement session/view.
        core?.sink.invalidate()

        // 1. No new events or render requests from mpv's threads.
        if let mpv {
            mpv_set_wakeup_callback(mpv, nil, nil)
        }
        if let ctx {
            mpv_render_context_set_update_callback(ctx, nil, nil)
        }

        let handles = TeardownHandles(
            mpv: mpv,
            renderContext: ctx,
            glContext: gl,
            coreRetainedPtr: coreRetainedPtr,
            renderUpdateContextPtr: renderUpdateContextPtr,
        )
        let renderQueue = renderQueue
        let pending = pendingGPU
        let slots = inFlightFrames
        let finish: @Sendable () -> Void = {
            // 3. After any in-flight render: free the render context (must
            //    precede core destruction), then destroy the core off-queue.
            renderQueue.async {
                // A frame still waiting for its fence is never shown; its fence
                // goes before the GL context that owns it.
                if let frame = pending.frame {
                    if let gl = handles.glContext { cs_gl_fence_release(gl, frame.fence) }
                    // Its in-flight slot comes back too: a semaphore released
                    // below its initial value traps when it is deallocated.
                    slots.signal()
                }
                pending.frame = nil
                buffers?.clear()
                handles.freeRenderContext()
                DispatchQueue.global(qos: .utility).async {
                    handles.destroyCore()
                }
            }
        }

        // 2. Stop the event drain on its own serial queue — anything already
        //    queued runs first and then sees `isStopped`.
        if let core {
            core.queue.async {
                core.stop()
                finish()
            }
        } else {
            finish()
        }
    }

    // MARK: - mpv helpers

    /// Splits scraped headers into mpv's dedicated referer / user-agent
    /// options and the remaining header lines (no duplicates — T8).
    ///
    /// Referer travels as a header line, not mpv's `referrer` option: the
    /// option cannot be unset once written (an empty value still sends an
    /// empty `Referer:`), while the header list resets cleanly per load.
    /// User-Agent uses mpv's dedicated option (always non-empty) so it is
    /// never sent twice.
    nonisolated static func splitHeaders(_ headers: [String: String]) -> (fields: [String], userAgent: String?) {
        var userAgent: String?
        var fields: [String] = []
        for (key, value) in headers.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            switch key.lowercased() {
            case "user-agent":
                userAgent = value
            case "referrer":
                // Common misspelling-in-reverse from extractors; HTTP wants "Referer".
                fields.append("Referer: \(value)")
            default:
                fields.append("\(key): \(value)")
            }
        }
        return (fields, userAgent)
    }

    /// Builds a NULL-terminated C argument vector for `mpv_command`.
    nonisolated private static func cArgs(_ strings: [String]) -> [UnsafePointer<CChar>?] {
        strings.map { UnsafePointer(strdup($0)) } + [nil]
    }

    nonisolated private static func freeArgs(_ args: [UnsafePointer<CChar>?]) {
        for arg in args {
            if let arg {
                free(UnsafeMutableRawPointer(mutating: arg))
            }
        }
    }

    /// mpv copies all arguments before returning. The reply arrives on the
    /// event queue carrying `tag`; untagged replies are reported only on failure.
    nonisolated private static func commandAsync(_ mpv: OpaquePointer, _ args: [String], tag: UInt64 = 0) {
        var argv = cArgs(args)
        mpv_command_async(mpv, tag, &argv)
        freeArgs(argv)
    }

    nonisolated private static func setFlagAsync(_ mpv: OpaquePointer, _ name: String, _ value: Bool) {
        var flag: Int32 = value ? 1 : 0
        mpv_set_property_async(mpv, 0, name, MPV_FORMAT_FLAG, &flag)
    }

    nonisolated private static func setDoubleAsync(_ mpv: OpaquePointer, _ name: String, _ value: Double) {
        var number = value
        mpv_set_property_async(mpv, 0, name, MPV_FORMAT_DOUBLE, &number)
    }

    nonisolated private static func setInt64Async(_ mpv: OpaquePointer, _ name: String, _ value: Int64) {
        var number = value
        mpv_set_property_async(mpv, 0, name, MPV_FORMAT_INT64, &number)
    }

    nonisolated private static func setStringAsync(_ mpv: OpaquePointer, _ name: String, _ value: String) {
        var cString: UnsafeMutablePointer<CChar>? = strdup(value)
        mpv_set_property_async(mpv, 0, name, MPV_FORMAT_STRING, &cString)
        free(cString)
    }

    /// Sets a string-list property as an `MPV_FORMAT_NODE_ARRAY`: no comma
    /// parsing, so header values containing commas survive intact (T8).
    nonisolated private static func setStringListAsync(_ mpv: OpaquePointer, _ name: String, _ values: [String]) {
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
        withUnsafeMutablePointer(to: &list) { listPtr in
            var root = mpv_node()
            root.format = MPV_FORMAT_NODE_ARRAY
            root.u.list = listPtr
            mpv_set_property_async(mpv, 0, name, MPV_FORMAT_NODE, &root)
        }
    }
}

/// Native render buffers survive the view until its serial render queue has
/// drained. The unchecked conformance describes queue confinement of CoreVideo
/// references; every mutable/read entry point asserts that ownership at runtime.
private final class RenderBufferState: @unchecked Sendable {
    private let queue: DispatchQueue
    private var cache: CVMetalTextureCache?
    private var pixelBufferPool: CVPixelBufferPool?
    private var pixelBufferPoolSize = CGSize.zero
    private var poolChanged = false

    init(queue: DispatchQueue, textureCache: CVMetalTextureCache) {
        self.queue = queue
        cache = textureCache
    }

    var textureCache: CVMetalTextureCache? {
        dispatchPrecondition(condition: .onQueue(queue))
        return cache
    }

    func clear() {
        dispatchPrecondition(condition: .onQueue(queue))
        pixelBufferPool = nil
        pixelBufferPoolSize = .zero
        cache = nil
    }

    /// Pooled IOSurface-backed buffers (R2, R5): a buffer still referenced by
    /// an in-flight frame is never handed out again.
    func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard width > 0, height > 0 else { return nil }
        let size = CGSize(width: width, height: height)
        if pixelBufferPool == nil || pixelBufferPoolSize != size {
            let poolAttributes: [CFString: Any] = [
                kCVPixelBufferPoolMinimumBufferCountKey: MetalVideoView.maxFramesInFlight + 1,
            ]
            let bufferAttributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            var pool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                poolAttributes as CFDictionary,
                bufferAttributes as CFDictionary,
                &pool,
            ) == kCVReturnSuccess, let pool else { return nil }
            pixelBufferPool = pool
            pixelBufferPoolSize = size
            poolChanged = true
        }
        guard let pool = pixelBufferPool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess else {
            return nil
        }
        return buffer
    }

    /// True once after the pool was replaced (cached GPU targets are stale).
    func takePoolChanged() -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        defer { poolChanged = false }
        return poolChanged
    }
}

/// Bridge context for mpv's render update callback.
/// Passes a weak reference to MetalVideoView across threads safely without actor isolation checks.
private final class RenderUpdateContext: @unchecked Sendable {
    weak var view: MetalVideoView?

    init(view: MetalVideoView) {
        self.view = view
    }
}

/// Weak display-link target: `CADisplayLink` retains its target, which would
/// otherwise keep the view alive until the link is invalidated.
@MainActor
private final class DisplayLinkProxy: NSObject {
    weak var view: MetalVideoView?

    init(view: MetalVideoView) {
        self.view = view
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let view else {
            // The view was released without `shutdown()` (e.g. a test);
            // don't keep an orphaned link ticking.
            link.invalidate()
            return
        }
        view.displayLinkFired()
    }
}

/// Keeps a frame's texture and pixel buffer alive until the GPU completes.
/// `@unchecked Sendable`: written once, released once on the completion thread.
/// The GPU frame rendered by GL whose fence has not passed yet. Accessed only
/// on the render queue (and by teardown on that queue), hence unchecked.
private final class PendingGPUFrame: @unchecked Sendable {
    struct Frame {
        let buffer: CVPixelBuffer
        let fence: UnsafeMutableRawPointer
        let width: Int
        let height: Int
        let issued: ContinuousClock.Instant
    }
    var frame: Frame?
}

private final class FrameResources: @unchecked Sendable {
    private var texture: CVMetalTexture?
    private var buffer: CVPixelBuffer?

    init(texture: CVMetalTexture, buffer: CVPixelBuffer) {
        self.texture = texture
        self.buffer = buffer
    }

    func release() {
        texture = nil
        buffer = nil
    }
}

/// C handles handed to the off-main teardown chain.
/// `@unchecked Sendable`: ownership transfers to the chain; each step runs once.
private final class TeardownHandles: @unchecked Sendable {
    private let mpv: OpaquePointer?
    private var renderContext: OpaquePointer?
    /// Read on the render queue before `freeRenderContext` destroys it.
    private(set) var glContext: OpaquePointer?
    private let coreRetainedPtr: UnsafeMutableRawPointer?
    private let renderUpdateContextPtr: UnsafeMutableRawPointer?

    init(
        mpv: OpaquePointer?,
        renderContext: OpaquePointer?,
        glContext: OpaquePointer?,
        coreRetainedPtr: UnsafeMutableRawPointer?,
        renderUpdateContextPtr: UnsafeMutableRawPointer?,
    ) {
        self.mpv = mpv
        self.renderContext = renderContext
        self.glContext = glContext
        self.coreRetainedPtr = coreRetainedPtr
        self.renderUpdateContextPtr = renderUpdateContextPtr
    }

    /// On the render queue: mpv frees its GL resources with the context
    /// current, then the context itself goes.
    func freeRenderContext() {
        if let glContext { cs_gl_make_current(glContext) }
        if let renderContext {
            mpv_render_context_free(renderContext)
            self.renderContext = nil
        }
        if let glContext {
            cs_gl_destroy(glContext)
            self.glContext = nil
        }
    }

    func destroyCore() {
        freeRenderContext()
        if let mpv {
            mpv_terminate_destroy(mpv)
        }
        // Release the retained C contexts only after mpv's threads are gone.
        if let renderUpdateContextPtr {
            Unmanaged<RenderUpdateContext>.fromOpaque(renderUpdateContextPtr).release()
        }
        if let coreRetainedPtr {
            Unmanaged<MpvCore>.fromOpaque(coreRetainedPtr).release()
        }
    }
}
