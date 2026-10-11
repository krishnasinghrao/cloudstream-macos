import AppKit
import SwiftUI

/// Transport seam (plan WS-7): lets PlayerViewModel be unit-tested without a
/// live mpv view. `MetalVideoView` conforms. Every call is fire-and-forget —
/// the engine reports resulting state back through property observation.
@MainActor
protocol PlayerTransport: AnyObject {
    func setPlaying(_ play: Bool)
    func togglePlayPause()
    func seek(by seconds: Double)
    func seek(to seconds: Double)
    func setSubtitleDelay(_ seconds: Double)
    func setSpeed(_ speed: Double)
    func toggleMute()
    func setVolume(_ volume: Double)
    func setMuted(_ muted: Bool)
    func selectAudioTrack(_ id: Int64)
    func selectSubtitleTrack(_ id: Int64)
    func setSubtitleStyle(fontSize: Double?, outlineWidth: Double?, textColor: String?, backgroundColor: String?)
    func setAspectRatio(_ ratio: String)
    func setFillsScreen(_ fills: Bool)
    func addSubtitles(_ subtitles: [PlaybackSubtitle])
    func setSubtitleLayout(font: String?, bold: Bool?, shadowOffset: Double?, position: Int?)
    func takeScreenshot(to url: URL)
    func frameStep(forward: Bool)
    func queueNext(url: String)
    func cancelQueuedNext()
    func shutdown()
}

/// High-frequency playback clock, isolated from `PlayerViewModel` so only the
/// views that actually display time (the scrubber) are invalidated on each
/// tick — not the whole HUD with its menus (Player-Remediation-Plan U1).
@MainActor
@Observable
final class PlaybackClock {
    fileprivate(set) var elapsed: Double = 0
    fileprivate(set) var duration: Double = 0
}

/// One stream load handed to the engine. The representable loads exactly
/// once per `id` — the single load path that makes mirror failover and
/// episode changes race-free (T3).
struct StreamLoadRequest: Equatable {
    let id: Int
    let resource: PlaybackResource
    var url: String { resource.url }
    let headers: [String: String]
    var subtitles: [PlaybackSubtitle]
    let audioTracks: [PlaybackAudio]
    let startAt: Double?
    /// Switch to the entry queued by `queueNext` instead of loading anew.
    var usesQueuedNext = false
    /// ClearKey content key for this stream only (L4).
    var decryption: ClearKeyDto? = nil
}

/// Playback session state: active episode, resolved mirrors, subtitle tracks,
/// transport state, and progress persistence. Owns the player window (via
/// `PlayerWindowController`).
///
/// State flows one way (T2): intents go to the engine; the engine's observed
/// properties are projected back here. Nothing writes engine state back
/// through a SwiftUI binding.
@MainActor
@Observable
final class PlayerViewModel {
    struct Session {
        let details: DetailsDto
        let episode: EpisodeDto?
        /// Order and edition for neighbours, prefetch and autoplay.
        let sequence: PlaybackSequence
        let episodeLabel: String
        var links: [StreamLinkDto]
        var subtitles: [PlaybackSubtitle]
        var selectedLinkIndex: Int
        /// False for trailers and other extras: they must never touch the
        /// title's resume position or watch history.
        var persistsProgress = true
        var localResource: PlaybackResource? = nil
    }

    enum Phase: Equatable {
        case idle
        /// Waiting for the daemon to produce the first playable links.
        case resolving
        /// A stream is loading in the engine (open, probe, initial buffer).
        case loading
        case ready
        /// Every mirror failed or resolution produced nothing.
        case failed
    }

    private(set) var session: Session?
    private(set) var phase: Phase = .idle
    /// mpv `paused-for-cache`: network starvation mid-playback.
    private(set) var isBuffering = false
    /// Title shown while the next session resolves (no session yet, or the
    /// previous one is still on screen).
    private(set) var pendingTitle: String?
    private(set) var loadRequest: StreamLoadRequest?

    private(set) var isPlaying = false {
        didSet {
            guard isPlaying != oldValue else { return }
            updateDisplaySleepAssertion()
        }
    }

    let clock = PlaybackClock()
    var elapsed: Double { clock.elapsed }
    var duration: Double { clock.duration }

    var volume: Double = 100.0
    var isMuted: Bool = false
    private(set) var speed: Double = 1.0
    private(set) var subtitleDelay: Double = 0.0
    private(set) var aspectRatio: String = "-1"
    var activeAudioTrackId: Int64?
    var activeSubtitleTrackId: Int64?
    private(set) var hudVisible = true
    /// Mirrors the player window's fullscreen state (set by the controller's
    /// delegate callbacks) so the HUD can adapt its chrome.
    var isFullScreen = false
    private(set) var isFloatingOnTop = false

    /// Cached at session start — the HUD reads these on every render, and
    /// recomputing them meant linear `EpisodeDto` scans (U1).
    private(set) var hasPreviousEpisode = false
    private(set) var hasNextEpisode = false

    /// User-visible playback failure (all mirrors exhausted, resolution failed…).
    private(set) var error: String?

    /// Embedded tracks discovered by mpv's `track-list` observation — the only
    /// source of track IDs (T10).
    private(set) var audioTracks: [MpvTrack] = []
    private(set) var subtitleTracks: [MpvTrack] = []

    /// Live view handle for transport commands from HUD / keyboard / media keys.
    /// Not observed: the video view attaches itself from inside SwiftUI's
    /// update pass, and an observed write there re-invalidated the layout
    /// that was running (AppKit reported a constraint-pass fault). Nothing
    /// renders from this handle.
    @ObservationIgnored weak var videoView: (any PlayerTransport)?

    /// The player window, when open.
    weak var windowController: PlayerWindowController?

    let preferences = UserPreferences.shared

    // MARK: Private bookkeeping

    /// Bumped by every `play()` and `close()`; an in-flight resolution whose
    /// generation is stale discards its results (T5).
    @ObservationIgnored private var playGeneration = 0
    @ObservationIgnored private var loadRequestCounter = 0
    @ObservationIgnored private var resolutionTask: Task<Void, Never>?
    @ObservationIgnored var linksStream: @MainActor (String, String) -> AsyncThrowingStream<LinksStreamEventDto, Error> = {
        DaemonClient.shared.linksStream(provider: $0, data: $1)
    }
    @ObservationIgnored private var graceTask: Task<Void, Never>?
    /// How long one load may stay in `loading` without a first frame before
    /// it is treated as failed. Longer than the engine's own 20 s network
    /// timeout, so that timeout normally reports first.
    @ObservationIgnored var loadDeadline: Duration = .seconds(45)
    @ObservationIgnored private var loadDeadlineTask: Task<Void, Never>?
    /// Extractor keep-alive owned by the active link (audit A47).
    @ObservationIgnored var startVerifier: @MainActor (_ source: String, _ extractorData: String) async throws -> String?
        = { try await DaemonClient.shared.startExtractorVerifier(source: $0, extractorData: $1) }
    @ObservationIgnored var stopVerifier: @MainActor (_ jobID: String) async -> Void
        = { await DaemonClient.shared.stopExtractorVerifier(jobId: $0) }
    @ObservationIgnored var verifierRetryDelays: [Duration] = [.seconds(2), .seconds(8)]
    @ObservationIgnored private var verifierToken: UInt64 = 0
    @ObservationIgnored private var verifierJobID: String?
    @ObservationIgnored private var verifierTask: Task<Void, Never>?
    /// Per-resource transport for a split stream whose audio needs different
    /// headers than its video (audit A35), owned by the active load.
    @ObservationIgnored var registerRelay: @MainActor ([MediaRelayResourceDto]) async throws -> DaemonClient.MediaRelaySession
        = { try await DaemonClient.shared.registerMediaRelay($0) }
    @ObservationIgnored var revokeRelay: @MainActor (_ sessionID: String) async -> Void
        = { await DaemonClient.shared.revokeMediaRelay(sessionID: $0) }
    @ObservationIgnored private var relayToken: UInt64 = 0
    @ObservationIgnored private var relaySessionID: String?
    @ObservationIgnored private var relayTask: Task<Void, Never>?
    @ObservationIgnored private var resolution: Resolution?
    @ObservationIgnored private var hudHideTask: Task<Void, Never>?
    @ObservationIgnored private var hudHideDeadline: ContinuousClock.Instant?
    @ObservationIgnored private var seekTarget: Double?
    @ObservationIgnored private var lastPersistedAt: Double = 0
    @ObservationIgnored private var prefetchIssued = false
    @ObservationIgnored private var displaySleepActivity: NSObjectProtocol?
    /// Resume position of the current load until the engine confirms the
    /// source can seek there.
    @ObservationIgnored private var pendingResumeCheck: Double?
    /// When the current play request (first play or episode change) began.
    @ObservationIgnored private var playRequestedAt: ContinuousClock.Instant?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    /// Short, non-blocking status message (e.g. a source that cannot resume).
    private(set) var notice: String?

    // MARK: Phase 4 state (skip, up next, per-title memory, sleep timer)

    /// Named chapters of the current file (mpv `chapter-list`).
    private(set) var chapters: [MpvChapter] = []
    /// Skippable intro/recap/credits windows for the current file.
    private(set) var skipSegments: [SkipSegment] = []
    /// The segment the playhead is inside — drives the "Skip Intro" pill.
    private(set) var activeSkip: SkipSegment?

    struct UpNext: Equatable {
        let episode: EpisodeDto
        let label: String
        let title: String?
        let posterUrl: String?
        let total: Double
    }

    /// "Up Next" card while the next-episode countdown runs.
    private(set) var upNext: UpNext?
    /// Seconds left on the countdown (only the card reads it).
    private(set) var upNextRemaining: Double = 0
    @ObservationIgnored private var upNextDismissed = false
    @ObservationIgnored private var upNextTask: Task<Void, Never>?

    enum SleepTimer: Equatable {
        case endOfEpisode
        case at(Date)
    }

    private(set) var sleepTimer: SleepTimer?
    @ObservationIgnored private var sleepTask: Task<Void, Never>?

    /// Title-level playback memory loaded at session start (Phase 4.3).
    @ObservationIgnored private var titlePrefs: TitlePlaybackSnapshot?
    /// Load request whose tracks already received the remembered languages.
    @ObservationIgnored private var trackPrefsAppliedForLoad: Int?

    /// Resolution grace window: after the first link arrives, wait this long
    /// for better-quality siblings before starting playback (A2).
    static let resolutionGrace: Duration = .milliseconds(1500)
    /// Progress persistence cadence (U2).
    static let progressPersistInterval: Double = 15
    /// Fraction of runtime after which the next episode's links are warmed (A3).
    static let prefetchThreshold: Double = 0.8

    var activeLink: StreamLinkDto? {
        guard let session else { return nil }
        let index = session.selectedLinkIndex
        return session.links.indices.contains(index) ? session.links[index] : session.links.first
    }

    /// Title for the window / HUD, preferring the session being resolved.
    var displayTitle: String {
        if let pendingTitle { return pendingTitle }
        guard let session else { return "Player" }
        return session.details.isSeries || !session.persistsProgress
            ? "\(session.details.name) — \(session.episodeLabel)"
            : session.details.name
    }

    /// Whether anything (a session or a resolution) is active.
    var isActive: Bool { session != nil || phase != .idle }

    // MARK: - Pending presentation

    /// Opens the window on its spinner before the title's details are known
    /// (resume from Home, Dock, menu bar): the click is answered at once
    /// instead of after a provider round trip. Returns a token for
    /// `isPending` / `endPending`, or nil when a session is already on screen
    /// — then the existing window just comes forward.
    func beginPending(title: String) -> Int? {
        guard session == nil else {
            PlayerWindowController.shared.present(player: self)
            return nil
        }
        playGeneration += 1
        cancelResolution()
        error = nil
        pendingTitle = title
        phase = .resolving
        PlayerWindowController.shared.present(player: self)
        return playGeneration
    }

    /// False once the user closed the pending window or started something else.
    func isPending(_ token: Int) -> Bool { playGeneration == token }

    /// Closes a pending window that never reached `play()` (details failed,
    /// the request was cancelled or went stale).
    func endPending(_ token: Int) {
        guard playGeneration == token else { return }
        close()
    }

    // MARK: - Play

    func play(
        details: DetailsDto,
        episode: EpisodeDto?,
        resumeAt: Double? = nil,
        preferences: UserPreferences,
        localMediaURL: URL? = nil,
    ) async {
        playGeneration += 1
        let generation = playGeneration
        playRequestedAt = .now
        cancelResolution()
        // The previous link is being replaced: its keep-alive ends now, not
        // when the new session's first load is issued.
        releaseVerifier()
        releaseRelay()
        loadDeadlineTask?.cancel()
        upNextDismissed = false

        if session != nil {
            videoView?.setPlaying(false)
            persistProgress(notify: true)
        }

        let label: String
        let dataString: String?
        if let episode {
            label = Self.episodeLabel(for: episode, fallbackIndex: details.episodes.firstIndex(of: episode))
            dataString = episode.data
        } else {
            label = "Movie"
            dataString = details.movieData
        }

        error = nil
        pendingTitle = details.isSeries ? "\(details.name) — \(label)" : details.name

        // Local playback (Downloaded Titles): the file path is the stream —
        // no daemon /links resolution (P0-4).
        if let localMediaURL {
            let resource: PlaybackResource
            do { resource = try .authorizedLocal(localMediaURL) }
            catch { fail(error.localizedDescription); return }
            let link = StreamLinkDto(url: resource.url, name: "Local File", source: "local", quality: 0, type: "video")
            startSession(
                generation: generation,
                details: details,
                episode: episode,
                label: label,
                links: [link],
                // Subtitle sidecars saved next to the download.
                subtitles: DownloadService.sidecarSubtitles(for: localMediaURL),
                resumeAt: resumeAt,
                localResource: resource,
            )
            return
        }

        guard let dataString, !dataString.isEmpty else {
            fail("This title has no playable stream data")
            return
        }

        // Open the window immediately with a "Finding streams…" state: the
        // user sees progress and every failure (D1).
        phase = .resolving
        PlayerWindowController.shared.present(player: self)

        let task = Task { [weak self] () -> Void in
            guard let self else { return }
            await self.resolveLinks(
                generation: generation,
                details: details,
                episode: episode,
                label: label,
                data: dataString,
                resumeAt: resumeAt,
            )
        }
        resolutionTask = task
        await withTaskCancellationHandler { await task.value } onCancel: {
            task.cancel()
            Task { @MainActor [weak self] in
                guard let self, self.playGeneration == generation else { return }
                self.close()
            }
        }
    }

    /// Starts a session from links that are already resolved (deep links,
    /// tests) — the same session path as daemon resolution.
    func playResolved(
        details: DetailsDto,
        episode: EpisodeDto?,
        links: [StreamLinkDto],
        subtitles: [SubtitleDto] = [],
        resumeAt: Double? = nil,
        persistsProgress: Bool = true,
        label: String? = nil,
    ) {
        guard !links.isEmpty else { return }
        playGeneration += 1
        cancelResolution()
        error = nil
        if session != nil {
            videoView?.setPlaying(false)
            persistProgress(notify: true)
        }
        let label = label ?? episode.map { Self.episodeLabel(for: $0, fallbackIndex: details.episodes.firstIndex(of: $0)) } ?? "Movie"
        startSession(
            generation: playGeneration,
            details: details,
            episode: episode,
            label: label,
            links: links,
            subtitles: subtitles,
            resumeAt: resumeAt,
            persistsProgress: persistsProgress,
        )
    }

    /// Plays a title's trailer: raw trailers load directly; others go
    /// through the daemon's extractors (YouTube & co.). Trailers never
    /// record progress.
    func playTrailer(_ trailer: TrailerDto, for details: DetailsDto) async {
        let links: [StreamLinkDto]
        let subtitles: [SubtitleDto]
        if trailer.raw {
            links = [StreamLinkDto(url: trailer.url, name: "Trailer", source: "trailer", quality: 0, type: "video", headers: trailer.requestHeaders)]
            subtitles = []
        } else {
            playGeneration += 1
            let generation = playGeneration
            cancelResolution()
            error = nil
            pendingTitle = "\(details.name) — Trailer"
            phase = .resolving
            PlayerWindowController.shared.present(player: self)
            do {
                let response = try await DaemonClient.shared.extract(url: trailer.url, referer: trailer.referer)
                // The user closed the window or started something else meanwhile.
                guard generation == playGeneration else { return }
                links = response.links
                subtitles = response.subtitles
            } catch {
                guard generation == playGeneration else { return }
                fail("Couldn't load the trailer: \(error.localizedDescription)")
                return
            }
            guard !links.isEmpty else {
                fail("No playable stream found for this trailer")
                return
            }
        }
        playResolved(details: details, episode: nil, links: links, subtitles: subtitles, persistsProgress: false, label: "Trailer")
    }

    /// In-flight progressive resolution for one `play()` generation.
    private struct Resolution {
        let generation: Int
        let details: DetailsDto
        let episode: EpisodeDto?
        let label: String
        let resumeAt: Double?
        var links: [StreamLinkDto] = []
        var subtitles: [SubtitleDto] = []
        var started = false
    }

    /// Consumes the progressive `/links/stream` (A2). Playback starts after
    /// the grace window following the first link — or at `done` — with the
    /// best link collected so far; later links and subtitles join the live
    /// session's mirror list and subtitle menu.
    private func resolveLinks(
        generation: Int,
        details: DetailsDto,
        episode: EpisodeDto?,
        label: String,
        data: String,
        resumeAt: Double?,
    ) async {
        resolution = Resolution(generation: generation, details: details, episode: episode, label: label, resumeAt: resumeAt)
        // The link that would be ranked first anyway starts at once instead
        // of after the grace period that collects alternatives.
        let remembered = preferences.rememberPlaybackPerTitle
            ? LibraryStore.shared.readForDisplay(or: nil, { try LibraryStore.shared.playbackPrefs(details: details) })?.rememberedSource
            : nil
        let preferred = preferences.sourcePreferences.priority.first
        var firstRejection: String?

        do {
            for try await event in linksStream(details.providerKey, data) {
                guard generation == playGeneration, !Task.isCancelled else { return }
                let started = resolution?.started == true
                switch event.type {
                case "link":
                    guard let link = event.link else { continue }
                    // One unusable link never ends playback: the others may play (L1).
                    do { try MediaResourcePolicy.validate(link) }
                    catch {
                        firstRejection = firstRejection ?? error.localizedDescription
                        continue
                    }
                    if started {
                        session?.links.append(link)
                    } else {
                        resolution?.links.append(link)
                        if Self.startsImmediately(link, remembered: remembered, preferred: preferred) {
                            startResolvedSessionIfNeeded(generation: generation)
                        } else if graceTask == nil {
                            graceTask = Task { [weak self] in
                                try? await Task.sleep(for: Self.resolutionGrace)
                                guard !Task.isCancelled else { return }
                                self?.startResolvedSessionIfNeeded(generation: generation)
                            }
                        }
                    }
                case "subtitle":
                    guard let subtitle = event.subtitle else { continue }
                    // A malformed subtitle is dropped; it is never a reason not to play.
                    guard (try? PlaybackSubtitle.remote(subtitle)) != nil else { continue }
                    if started {
                        appendLateSubtitle(subtitle)
                    } else {
                        resolution?.subtitles.append(subtitle)
                    }
                case "error":
                    if !started, resolution?.links.isEmpty ?? true {
                        fail(event.failures?.first?.publicMessage ?? event.error ?? "The extension failed to resolve streams")
                        return
                    }
                case "done":
                    if !started, resolution?.links.isEmpty ?? true, let failure = event.failures?.first {
                        fail(failure.publicMessage)
                        return
                    }
                default:
                    break
                }
                if event.type == "done" { break }
            }
        } catch {
            guard generation == playGeneration, !Task.isCancelled else { return }
            if resolution?.started != true, resolution?.links.isEmpty ?? true {
                fail(error.localizedDescription)
                return
            }
        }

        guard generation == playGeneration, !Task.isCancelled else { return }
        graceTask?.cancel()
        graceTask = nil
        if resolution?.started != true {
            if resolution?.links.isEmpty ?? true {
                fail(firstRejection ?? "No resolvable streams for this episode")
            } else {
                startResolvedSessionIfNeeded(generation: generation)
            }
        }
    }

    /// The remembered source for this title (at its quality), or else the
    /// user's first-priority source: nothing that arrives later would be
    /// ranked above it.
    nonisolated static func startsImmediately(_ link: StreamLinkDto, remembered: RememberedSource?, preferred: String?) -> Bool {
        guard !LinkRanker.isDolbyVisionOnly(link) else { return false }
        let key = LinkRanker.sourceKey(link)
        if let remembered { return key == remembered.key && (remembered.quality == nil || remembered.quality == link.quality) }
        return preferred != nil && key == preferred
    }

    private func startResolvedSessionIfNeeded(generation: Int) {
        guard var pending = resolution, pending.generation == generation, generation == playGeneration,
              !pending.started, !pending.links.isEmpty
        else { return }
        pending.started = true
        resolution = pending
        graceTask?.cancel()
        graceTask = nil
        startSession(
            generation: generation,
            details: pending.details,
            episode: pending.episode,
            label: pending.label,
            links: pending.links,
            subtitles: pending.subtitles,
            resumeAt: pending.resumeAt,
        )
    }

    private func startSession(
        generation: Int,
        details: DetailsDto,
        episode: EpisodeDto?,
        label: String,
        links: [StreamLinkDto],
        subtitles: [SubtitleDto],
        resumeAt: Double?,
        persistsProgress: Bool = true,
        localResource: PlaybackResource? = nil,
    ) {
        guard generation == playGeneration else { return }
        let validatedSubtitles: [PlaybackSubtitle]
        do {
            if let localResource {
                guard localResource.origin == .authorizedLocal, links.count == 1,
                      links[0].url == localResource.url, links[0].headers.isEmpty,
                      links[0].audioTracks.isEmpty, links[0].playlist.isEmpty else {
                    throw MediaResourcePolicy.Rejection.unauthorizedLocalFile
                }
                validatedSubtitles = try subtitles.map {
                    try .authorizedLocal($0, file: URL(fileURLWithPath: $0.url))
                }
            } else {
                for link in links { try MediaResourcePolicy.validate(link) }
                validatedSubtitles = try subtitles.map(PlaybackSubtitle.remote)
            }
        } catch { fail(error.localizedDescription); return }
        titlePrefs = persistsProgress && preferences.rememberPlaybackPerTitle
            ? LibraryStore.shared.readForDisplay(or: nil, { try LibraryStore.shared.playbackPrefs(details: details) })
            : nil
        // User source priority + quality cap; stable for ties (Phase 4.4).
        // The mirror picked for this title before goes first.
        let ordered = LinkRanker.rank(links, preferences.sourcePreferences, remembered: titlePrefs?.rememberedSource)
        preferences.noteSources(links.map { $0.source.isEmpty ? $0.name : $0.source })

        session = Session(
            details: details,
            episode: episode,
            sequence: PlaybackSequence(details: details, containing: episode),
            episodeLabel: label,
            links: ordered,
            subtitles: validatedSubtitles,
            selectedLinkIndex: 0,
            persistsProgress: persistsProgress,
            localResource: localResource,
        )
        pendingTitle = nil
        error = nil
        progressFailureShown = false
        refreshEpisodeNeighbours()

        let start = max(0, resumeAt ?? 0)
        clock.elapsed = start
        // The timeline reflects the media itself: unknown until the engine
        // reports it. Provider runtime metadata is a display label, not a
        // playback duration.
        clock.duration = 0
        seekTarget = nil
        lastPersistedAt = start
        prefetchIssued = false
        nextEpisodeLinks = nil
        audioTracks = []
        subtitleTracks = []
        activeAudioTrackId = nil
        activeSubtitleTrackId = nil
        resetPerFileState()
        if volume <= 0 || videoView == nil { volume = preferences.lastVolume > 0 ? preferences.lastVolume : 100 }
        applySessionPreferences()

        guard issueLoad(link: ordered[0], startAt: start > 1 ? start : nil) else { return }
        setPlaying(true)
        updateDisplaySleepAssertion()
        showHUD()

        PlayerWindowController.shared.present(player: self)

        NowPlayingService.shared.installCommands(
            onPlay: { [weak self] in self?.setPlaying(true) },
            onPause: { [weak self] in self?.setPlaying(false) },
            onToggle: { [weak self] in self?.togglePlayPause() },
            onSeek: { [weak self] seconds in self?.seek(to: seconds) },
            onSkip: { [weak self] seconds in self?.seek(by: seconds) },
            onNextEpisode: { [weak self] in self?.playNextEpisode() },
            onPreviousEpisode: { [weak self] in self?.playPreviousEpisode() },
        )
        updateNowPlaying()
    }

    /// Clears everything tied to one file (chapters, skip, up next).
    private func resetPerFileState() {
        resetStallTracking()
        chapters = []
        skipSegments = []
        activeSkip = nil
        cancelUpNext(dismissed: false)
        trackPrefsAppliedForLoad = nil
    }

    /// Speed, subtitle offset and volume for a session: the title's memory
    /// when there is one, otherwise neutral values. Called at session start
    /// and when a fresh video view appears.
    func applySessionPreferences() {
        let targetSpeed = titlePrefs?.speed ?? 1
        let targetDelay = titlePrefs?.subtitleDelay ?? 0
        speed = targetSpeed
        subtitleDelay = targetDelay
        videoView?.setSpeed(targetSpeed)
        videoView?.setSubtitleDelay(targetDelay)
        videoView?.setVolume(volume)
    }

    /// Hands one load to the engine through `loadRequest` (T3).
    @discardableResult
    private func issueLoad(link: StreamLinkDto, startAt: Double?) -> Bool {
        loadRequestCounter += 1
        // A relay belongs to one load; this one replaces it.
        releaseRelay()
        do {
            if let local = session?.localResource {
                commitLoad(resource: local, audioTracks: [], link: link, startAt: startAt)
            } else {
                let remote = try Self.loadPlan(for: link)
                commitLoad(resource: remote.resource, audioTracks: try remote.audioTracks.map(PlaybackAudio.remote), link: link, startAt: startAt)
            }
            return true
        } catch MediaResourcePolicy.Rejection.unsupportedSplitHeaders {
            beginRelayedLoad(link: link, startAt: startAt)
            return true
        } catch MediaResourcePolicy.Rejection.credentialedStream {
            beginRelayedLoad(link: link, startAt: startAt)
            return true
        } catch {
            return skipUnloadable(link: link, startAt: startAt, error: error)
        }
    }

    private func commitLoad(resource: PlaybackResource, audioTracks: [PlaybackAudio], link: StreamLinkDto, startAt: Double?,
                            headers: [String: String]? = nil) {
        // The preloaded entry is used only for exactly the link it was made
        // for, from the start; any other load replaces it.
        let usesQueued = queuedNext.map { $0.link == link && $0.url == resource.url && (startAt ?? 0) <= 1 && audioTracks.isEmpty } ?? false
        queuedNext = nil
        if usesQueued { DaemonLog.client("player.preload_used") }
        chapters = []
        skipSegments = []
        activeSkip = nil
        trackPrefsAppliedForLoad = nil
        loadRequest = StreamLoadRequest(
            id: loadRequestCounter,
            resource: resource,
            headers: headers ?? link.headers,
            subtitles: session?.subtitles ?? [],
            audioTracks: audioTracks,
            startAt: startAt,
            usesQueuedNext: usesQueued,
            decryption: link.drm,
        )
        pendingResumeCheck = startAt
        phase = .loading
        isBuffering = false
        bufferingPercent = nil
        resetStallTracking()
        armLoadDeadline(for: loadRequestCounter)
        // The keep-alive belongs to this link only: a mirror switch or a new
        // episode replaces it. Trailers and local files have none.
        ownVerifier(for: session?.localResource == nil && session?.persistsProgress == true ? link : nil)
    }

    /// A mirror the player cannot load is skipped like a failed one; the
    /// reason is shown only when no other mirror is left.
    private func skipUnloadable(link: StreamLinkDto, startAt: Double?, error: any Error) -> Bool {
        loadRequest = nil
        if let session, session.links.indices.contains(session.selectedLinkIndex + 1),
           session.links[session.selectedLinkIndex] == link {
            DaemonLog.client("player.mirror_unsupported", fields: ["mirror": String(session.selectedLinkIndex + 1)])
            // What failover reports, not whether a load request exists: a relayed
            // mirror registers its relay first and has none yet (audit Q1).
            return failover(to: session.selectedLinkIndex + 1, startAt: startAt)
        }
        fail(error.localizedDescription)
        return false
    }

    // MARK: - Split-stream relay

    /// Loads a split stream through the engine's relay, so the video and
    /// each audio track are requested with their own headers. The load is
    /// issued when the relay addresses arrive; a registration that returns
    /// after the load was replaced is revoked instead of used.
    private func beginRelayedLoad(link: StreamLinkDto, startAt: Double?) {
        loadRequest = nil
        phase = .loading
        isBuffering = false
        let token = relayToken
        let ordered = Self.preferredAudioOrder(link.audioTracks)
        let resources = MediaResourcePolicy.relayResources(video: link.url, headers: link.headers, orderedAudio: ordered)
        let (register, revoke) = (registerRelay, revokeRelay)
        relayTask = Task { [weak self] in
            do {
                // Shielded: even a cancelled relayTask (close) receives the
                // session, so the stale check below revokes it instead of the
                // engine keeping an orphaned session (audit M6a).
                let registration = Task { try await register(resources) }
                let relay = try await registration.value
                guard let self, self.relayToken == token else {
                    await revoke(relay.sessionID)
                    return
                }
                self.relaySessionID = relay.sessionID
                // The engine adds each resource's own headers; the player sends none.
                let resource = try PlaybackResource.split(video: link.url, orderedAudio: ordered, relayed: relay.urls)
                self.commitLoad(resource: resource, audioTracks: [], link: link, startAt: startAt, headers: [:])
            } catch {
                guard let self, self.relayToken == token else { return }
                DaemonLog.client("player.relay_unavailable")
                // Fail closed: a credentialed stream is never loaded natively instead.
                let reason: MediaResourcePolicy.Rejection = MediaResourcePolicy.carriesCredentials(link) && link.audioTracks.isEmpty
                    ? .credentialedStream : .unsupportedSplitHeaders
                _ = self.skipUnloadable(link: link, startAt: startAt, error: reason)
            }
        }
    }

    /// A new engine generation is verified. Relay sessions live in the engine,
    /// so a stream read through the relay is registered again with the new
    /// engine and resumed where it was, instead of failing on dead URLs.
    ///
    /// A stream that is not relayed but keeps its link alive through an
    /// extractor verifier gets a new keep-alive job: the old one ended with
    /// the old engine (audit M7). The relayed branch gets one through
    /// failover → commitLoad. Downloads keep their behaviour: a link that dies
    /// fails over and is resolved again.
    func engineReconnected() {
        guard let session, session.links.indices.contains(session.selectedLinkIndex) else { return }
        if relaySessionID != nil {
            relaySessionID = nil // gone with the old engine: nothing to revoke
            DaemonLog.client("player.relay_reestablished")
            showNotice("The engine restarted — reconnecting this stream.")
            failover(to: session.selectedLinkIndex, startAt: elapsed)
            return
        }
        let link = session.links[session.selectedLinkIndex]
        guard let data = link.extractorData, !data.isEmpty, session.localResource == nil, session.persistsProgress else { return }
        verifierJobID = nil // the old engine's job is gone: never send it a stop
        DaemonLog.client("player.verifier_reestablished")
        ownVerifier(for: link)
    }

    /// [cancelPending] only on close: otherwise an in-flight registration is
    /// left to finish, and the token check revokes it (audit M6a).
    private func releaseRelay(cancelPending: Bool = false) {
        relayToken &+= 1
        if cancelPending { relayTask?.cancel() }
        relayTask = nil
        if let sessionID = relaySessionID {
            relaySessionID = nil
            let revoke = revokeRelay
            Task { await revoke(sessionID) }
        }
    }

    /// A load that never produces a first frame must not spin forever: once
    /// the deadline passes it fails over like any other failed mirror. While
    /// the engine reports buffering the deadline is extended once.
    private func armLoadDeadline(for requestID: Int) {
        loadDeadlineTask?.cancel()
        let deadline = loadDeadline
        loadDeadlineTask = Task { [weak self] in
            for attempt in 0..<2 {
                do { try await Task.sleep(for: deadline) } catch { return }
                guard let self, self.phase == .loading, self.loadRequest?.id == requestID else { return }
                if attempt == 0, self.isBuffering { continue }
                DaemonLog.client("player.load_deadline", fields: ["mirror": String((self.session?.selectedLinkIndex ?? 0) + 1)])
                self.handlePlaybackError()
                return
            }
        }
    }

    // MARK: - Extractor keep-alive

    /// Starts the daemon's verifier for `link` (nil stops it). A start that
    /// returns after the link was replaced is stopped at once instead of
    /// being attached to the new session.
    private func ownVerifier(for link: StreamLinkDto?) {
        releaseVerifier()
        guard let link, let data = link.extractorData, !data.isEmpty else { return }
        let token = verifierToken
        let source = link.source
        let (start, stop, delays) = (startVerifier, stopVerifier, verifierRetryDelays)
        verifierTask = Task { [weak self] in
            for attempt in 0...delays.count {
                if attempt > 0 {
                    do { try await Task.sleep(for: delays[attempt - 1]) } catch { return }
                }
                guard self?.verifierToken == token else { return }
                do {
                    let job = try await start(source, data)
                    guard let self, self.verifierToken == token else {
                        if let job { await stop(job) }
                        return
                    }
                    self.verifierJobID = job
                    return
                } catch {
                    guard !Task.isCancelled, let self, self.verifierToken == token else { return }
                    DaemonLog.client("player.verifier_failed", fields: ["attempt": String(attempt + 1)])
                }
            }
            guard let self, self.verifierToken == token else { return }
            // Playback continues; the link may simply expire sooner.
            self.showNotice("This stream couldn’t be kept alive and may stop early. Switching mirrors restarts it.")
        }
    }

    private func releaseVerifier() {
        verifierToken &+= 1
        verifierTask?.cancel()
        verifierTask = nil
        if let job = verifierJobID {
            verifierJobID = nil
            let stop = stopVerifier
            Task { await stop(job) }
        }
    }

    // MARK: - Engine and command outcomes

    /// The engine could not start at all. Another mirror would fail the same
    /// way, so this ends the attempt with an actionable message.
    func handleEngineFailure(_ stage: String) {
        DaemonLog.client("player.engine_failed", fields: ["stage": stage])
        loadDeadlineTask?.cancel()
        releaseVerifier()
        releaseRelay()
        fail("The video player couldn’t start (\(stage)). Close this window and try again; if it keeps happening, restart CloudStream.")
    }

    func handleCommandReply(_ reply: MpvCommandReply) {
        switch reply.kind {
        case .seek:
            guard reply.error != nil else { return }
            // The position will not arrive: stop waiting for it, so the
            // scrubber follows the real clock again.
            seekTarget = nil
            showNotice("This stream couldn’t seek to that position.")
        case .screenshot:
            let saved = reply.error == nil && reply.url.map { FileManager.default.fileExists(atPath: $0.path) } == true
            showNotice(saved ? "Screenshot saved to \(reply.url?.deletingLastPathComponent().lastPathComponent ?? "folder")"
                             : "Couldn’t save the screenshot.")
        case .other:
            break // already logged; nothing the user asked for by name
        }
    }

    /// What the engine loads for a link.
    /// * Split (DASH-style) links — video-only URL + separate audio files, as
    ///   the YouTube extractor produces — are merged into one EDL manifest so
    ///   video and audio open, buffer, and seek together on one timeline.
    ///   Adding audio with `audio-add` after load left the first frames
    ///   silent, ran each track on its own connection, and let a starved
    ///   video track fall behind free-running audio (measured ~1 s drift and
    ///   a snap-back on resume).
    /// * Playlist links concatenate through EDL (A5).
    /// * Everything else loads as-is.
    struct LoadPlan {
        let resource: PlaybackResource
        let audioTracks: [AudioTrackDto]
        var url: String { resource.url }
    }

    static func loadPlan(for link: StreamLinkDto) throws -> LoadPlan {
        try MediaResourcePolicy.validate(link)
        if link.isPlaylist, !link.playlist.isEmpty {
            // EDL segment lists stay native: each segment is its own validated
            // remote URL and no manifest can name further hosts.
            return LoadPlan(resource: try .playlist(link.playlist), audioTracks: link.audioTracks)
        }
        // Credentials go only to the engine, which adds them per resource on
        // the provider's own origin (Security M2, Audit-Fix A2 decision 2).
        if MediaResourcePolicy.carriesCredentials(link) { throw MediaResourcePolicy.Rejection.credentialedStream }
        if !link.audioTracks.isEmpty {
            try MediaResourcePolicy.validateSplitHeaders(video: link.url, headers: link.headers, audio: link.audioTracks)
            return LoadPlan(resource: try .split(video: link.url, orderedAudio: preferredAudioOrder(link.audioTracks)), audioTracks: [])
        }
        return LoadPlan(resource: try .remote(link.url), audioTracks: [])
    }

    /// Playlist links (segmented extractor output) play through mpv's EDL
    /// concatenation; every segment URL is length-prefixed so `;`/`,` in
    /// query strings cannot break the syntax (A5).
    static func playableURL(for link: StreamLinkDto) throws -> String {
        try MediaResourcePolicy.validate(link)
        guard link.isPlaylist, !link.playlist.isEmpty else { return link.url }
        return try PlaybackResource.playlist(link.playlist).url
    }

    /// mpv codec name for a lazily opened audio track, inferred from the
    /// label or URL (googlevideo URLs carry `mime=audio/webm|mp4`).
    static func audioCodecGuess(_ track: AudioTrackDto) -> String { PlaybackResource.audioCodecGuess(track) }

    static func edlQuoted(_ value: String) -> String { PlaybackResource.edlQuoted(value) }

    /// Audio preference: the user's language first, then AAC/M4A (decoded by
    /// the system, the most widely compatible), then the highest bitrate.
    static func preferredAudioOrder(_ tracks: [AudioTrackDto], preferredLanguages: [String] = Locale.preferredLanguages) -> [AudioTrackDto] {
        let languageCodes = preferredLanguages.compactMap { Locale(identifier: $0).language.languageCode?.identifier.lowercased() }
        func languageRank(_ track: AudioTrackDto) -> Int {
            guard let language = track.language?.lowercased(), !language.isEmpty else { return languageCodes.count }
            return languageCodes.firstIndex(where: { language.hasPrefix($0) || language.contains($0) }) ?? languageCodes.count + 1
        }
        func isAAC(_ track: AudioTrackDto) -> Bool {
            let text = ((track.label ?? "") + " " + track.url).lowercased()
            return text.contains("m4a") || text.contains("aac") || text.contains("mp4a")
        }
        func bitrate(_ track: AudioTrackDto) -> Int {
            guard let label = track.label,
                  let match = label.range(of: #"(\d+)\s*kbps"#, options: .regularExpression)
            else { return 0 }
            return Int(label[match].filter(\.isNumber)) ?? 0
        }
        return tracks.enumerated().sorted { lhs, rhs in
            let (a, b) = (lhs.element, rhs.element)
            if languageRank(a) != languageRank(b) { return languageRank(a) < languageRank(b) }
            if isAAC(a) != isAAC(b) { return isAAC(a) }
            if bitrate(a) != bitrate(b) { return bitrate(a) > bitrate(b) }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    // MARK: - Local subtitle files (Phase 5)

    static let subtitleFileExtensions: Set<String> = ["srt", "vtt", "ass", "ssa", "sub", "ttml", "smi"]

    /// Builds the DTO for a user-chosen subtitle file; nil for non-subtitle
    /// files. "Show.S01E02.en.srt" → language "en".
    static func localSubtitle(for url: URL) -> SubtitleDto? {
        guard url.isFileURL, subtitleFileExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        let stem = url.deletingPathExtension()
        let tag = stem.pathExtension.lowercased()
        let language = (2...3).contains(tag.count) && tag.allSatisfy(\.isLetter) ? tag : "und"
        return SubtitleDto(url: url.path, language: language, label: url.lastPathComponent, mimeType: nil)
    }

    /// "Add Subtitle File…" / drag-and-drop onto the player. The new track
    /// is selected as soon as mpv lists it.
    @discardableResult
    func addLocalSubtitleFile(_ url: URL) -> Bool {
        guard session != nil, let subtitle = Self.localSubtitle(for: url) else {
            showNotice("That file isn't a supported subtitle (\(Self.subtitleFileExtensions.sorted().joined(separator: ", ")))")
            return false
        }
        pendingLocalSubtitleSelection = url.lastPathComponent
        do { appendLateSubtitle(try .authorizedLocal(subtitle, file: url)) }
        catch { showNotice(error.localizedDescription); return false }
        showNotice("Added subtitles: \(url.lastPathComponent)")
        return true
    }

    @ObservationIgnored private var pendingLocalSubtitleSelection: String?

    private func selectPendingLocalSubtitleIfListed() {
        guard let wanted = pendingLocalSubtitleSelection,
              let track = subtitleTracks.last(where: { $0.title == wanted }) else { return }
        pendingLocalSubtitleSelection = nil
        selectSubtitleTrack(track.id)
    }

    private func appendLateSubtitle(_ subtitle: SubtitleDto) {
        do { appendLateSubtitle(try .remote(subtitle)) }
        catch { showNotice(error.localizedDescription) }
    }

    private func appendLateSubtitle(_ subtitle: PlaybackSubtitle) {
        guard session != nil else { return }
        session?.subtitles.append(subtitle)
        loadRequest?.subtitles.append(subtitle)
        videoView?.addSubtitles([subtitle])
    }

    private func fail(_ message: String) {
        error = message
        phase = .failed
        isBuffering = false
        loadDeadlineTask?.cancel()
        releaseVerifier()
        releaseRelay()
        if session == nil {
            PlayerWindowController.shared.present(player: self)
        }
    }

    private func cancelResolution() {
        resolution = nil
        resolutionTask?.cancel()
        resolutionTask = nil
        graceTask?.cancel()
        graceTask = nil
    }

    /// Applies the persisted subtitle style once the mpv view is live.
    func applySubtitleStyle() {
        videoView?.setSubtitleStyle(
            fontSize: preferences.subtitleFontSize,
            outlineWidth: preferences.subtitleOutlineWidth,
            textColor: preferences.subtitleTextColor,
            backgroundColor: preferences.subtitleBackgroundColor,
        )
        videoView?.setSubtitleLayout(
            font: preferences.subtitleFont ?? "sans-serif",
            bold: preferences.subtitleBold,
            shadowOffset: preferences.subtitleShadowOffset,
            position: preferences.subtitlePosition,
        )
    }

    // MARK: - Mirrors & failure

    /// - Parameter startAt: explicit resume point; defaults to the current
    ///   position (mirror switch mid-playback).
    /// Returns whether the load was issued. The error is cleared and
    /// playback resumed only then: a mirror that fails at once (the last one
    /// rejected by policy, say) keeps the failure it reported (audit Q1).
    @discardableResult
    func failover(to index: Int, startAt: Double? = nil) -> Bool {
        guard let session, session.links.indices.contains(index) else { return false }
        self.session?.selectedLinkIndex = index
        let position = startAt ?? elapsed
        let issued = issueLoad(link: session.links[index], startAt: position > 1 ? position : nil)
        guard issued, phase != .failed else { return false }
        error = nil
        setPlaying(true)
        return true
    }

    /// The user's own pick in the mirror menu: switches now and is remembered
    /// for the title. Automatic failover never changes that memory.
    func selectMirror(_ index: Int) {
        guard let session, session.links.indices.contains(index), index != session.selectedLinkIndex else { return }
        let link = session.links[index]
        // A source whose load failed is not remembered for the title.
        guard failover(to: index) else { return }
        rememberForTitle {
            $0.source = LinkRanker.sourceKey(link)
            $0.sourceQuality = link.quality
        }
    }

    var hasNextMirror: Bool {
        guard let session else { return false }
        return session.links.indices.contains(session.selectedLinkIndex + 1)
    }

    /// Rules.md §4.3: automatic mirror failover without user interruption.
    /// Called when mpv reports an END_FILE with reason=error for the current file.
    func handlePlaybackError() {
        guard let session else { return }
        let next = session.selectedLinkIndex + 1
        if session.links.indices.contains(next) {
            showNotice("That mirror failed — trying \(Self.mirrorName(session.links[next])) (\(next + 1) of \(session.links.count)).")
            failover(to: next)
        } else {
            fail("All \(session.links.count) mirrors failed — try another episode or provider")
        }
    }

    func tryNextMirror() {
        guard let session else { return }
        failover(to: session.selectedLinkIndex + 1)
    }

    /// End of file: auto-advance to the next episode when the user has
    /// continuous playback enabled (Settings ▸ Playback) and a next episode
    /// exists; otherwise close.
    func handleEndOfFile() {
        guard let session, phase == .ready else { return }
        if sleepTimer == .endOfEpisode {
            sleepTimer = nil
            close()
            return
        }
        if preferences.continuousPlayback, session.persistsProgress, session.details.isSeries,
           hasNextEpisode, !upNextDismissed {
            playNextEpisode()
        } else {
            close()
        }
    }

    // MARK: - Engine projection (read-only inputs from mpv)

    /// File loaded, or playback resumed after a seek.
    func handlePlaybackRestart() {
        if phase == .loading {
            if let requested = playRequestedAt {
                // Section 7 measurement: request (episode change, first play) to first frame.
                let elapsed = ContinuousClock.now - requested
                DaemonLog.client("player.first_frame", fields: ["ms": String(Int(elapsed / .milliseconds(1)))])
                playRequestedAt = nil
            }
            phase = .ready
            loadDeadlineTask?.cancel()
            applySubtitleStyle()
        }
        seekTarget = nil
    }

    func handleEnginePause(_ paused: Bool) {
        let playing = !paused
        guard isPlaying != playing else { return }
        isPlaying = playing
        updateNowPlaying()
        if playing { scheduleHUDHide() } else { showHUD() }
    }

    /// mpv `seekable`. A source that cannot seek (server ignores HTTP Range,
    /// live/event playlist) silently discards `start=` and plays from 0:00 —
    /// the "resume starts at the beginning" defect. Prefer another mirror
    /// that can resume; if none is left, keep playing and say why.
    func handleSeekable(_ seekable: Bool) {
        guard let resumeAt = pendingResumeCheck, phase == .loading || phase == .ready else { return }
        pendingResumeCheck = nil
        guard !seekable else { return }
        if hasNextMirror {
            DaemonLog.client("player.unseekable_failover", fields: ["resumeAt": String(Int(resumeAt))])
            // Resume at the intended point, not wherever the unseekable
            // source's clock got to.
            if let session {
                failover(to: session.selectedLinkIndex + 1, startAt: resumeAt)
            }
        } else {
            showNotice("This source can't resume playback — starting from the beginning.")
        }
    }

    func showNotice(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    func handleBuffering(_ buffering: Bool) {
        if isBuffering != buffering { isBuffering = buffering }
        if !buffering { bufferingPercent = nil }
        trackStall(buffering)
    }

    /// mpv `cache-buffering-state`: how full the buffer is before playback resumes.
    private(set) var bufferingPercent: Int?

    func handleBufferingProgress(_ percent: Int64) {
        bufferingPercent = isBuffering ? Int(max(0, min(100, percent))) : nil
    }

    // MARK: - Stalls (section 7: switch mirrors on repeated stalls, not only failures)

    /// One stall of `long`, or `count` stalls of at least `minimum` within
    /// `window`, moves playback to the next mirror.
    struct StallPolicy {
        var minimum: Duration = .seconds(1)
        var long: Duration = .seconds(12)
        var count = 3
        var window: Duration = .seconds(90)
    }
    @ObservationIgnored var stallPolicy = StallPolicy()
    @ObservationIgnored private var recentStalls: [ContinuousClock.Instant] = []
    @ObservationIgnored private var stallStartedAt: ContinuousClock.Instant?
    @ObservationIgnored private var longStallTask: Task<Void, Never>?

    private func trackStall(_ buffering: Bool) {
        // Buffering while loading or after a seek is expected, not a stall.
        guard phase == .ready, seekTarget == nil else { stallStartedAt = nil; longStallTask?.cancel(); return }
        if buffering {
            guard stallStartedAt == nil else { return }
            stallStartedAt = .now
            longStallTask?.cancel()
            longStallTask = Task { [weak self] in
                try? await Task.sleep(for: self?.stallPolicy.long ?? .seconds(12))
                guard !Task.isCancelled, let self, self.isBuffering, self.stallStartedAt != nil else { return }
                self.switchMirrorForStalls("This mirror stopped loading")
            }
        } else if let started = stallStartedAt {
            stallStartedAt = nil
            longStallTask?.cancel()
            let now = ContinuousClock.now
            guard now - started >= stallPolicy.minimum else { return }
            recentStalls = recentStalls.filter { now - $0 < stallPolicy.window } + [now]
            if recentStalls.count >= stallPolicy.count { switchMirrorForStalls("This mirror keeps stalling") }
        }
    }

    private func switchMirrorForStalls(_ reason: String) {
        resetStallTracking()
        guard let session, hasNextMirror else { return }
        let next = session.selectedLinkIndex + 1
        DaemonLog.client("player.stall_failover", fields: ["mirror": String(next + 1)])
        showNotice("\(reason) — switched to \(Self.mirrorName(session.links[next])).")
        failover(to: next)
    }

    private func resetStallTracking() {
        recentStalls = []
        stallStartedAt = nil
        longStallTask?.cancel()
        longStallTask = nil
    }

    static func mirrorName(_ link: StreamLinkDto) -> String {
        let name = link.source.isEmpty ? link.name : link.source
        return link.quality > 0 ? "\(name) \(link.quality)p" : name
    }

    /// What is playing (resolution, codec, colour, HDR type, decoder, renderer).
    private(set) var streamInfo = StreamInfo()
    /// Shows `streamInfo` above the timeline.
    var showsStreamInfo = false

    func updateStreamInfo(_ name: String, _ value: MpvValue) {
        var info = streamInfo
        if info.apply(name, value) { streamInfo = info }
    }

    func setRenderer(_ name: String) {
        streamInfo.renderer = name
    }

    func handleVideoSize(width: Int64, height: Int64) {
        guard width > 0, height > 0 else { return }
        windowController?.setVideoAspectRatio(NSSize(width: CGFloat(width), height: CGFloat(height)))
    }

    // MARK: - Transport

    func setPlaying(_ play: Bool) {
        isPlaying = play
        videoView?.setPlaying(play)
        updateNowPlaying()
        if play {
            scheduleHUDHide()
        } else {
            showHUD()
        }
    }

    func togglePlayPause() {
        setPlaying(!isPlaying)
    }

    /// Relative seeks are converted to absolute targets from the optimistic
    /// clock, so rapid repeats accumulate exactly instead of racing mpv's
    /// not-yet-updated position.
    func seek(by delta: Double) {
        guard session != nil else { return }
        let upper = duration > 0 ? duration : .greatestFiniteMagnitude
        seek(to: max(0, min(upper, elapsed + delta)))
    }

    func seek(to seconds: Double) {
        guard session != nil else { return }
        seekTarget = seconds
        clock.elapsed = seconds
        videoView?.seek(to: seconds)
        updateNowPlaying()
    }

    func setSubtitleDelay(_ seconds: Double) {
        subtitleDelay = seconds
        videoView?.setSubtitleDelay(seconds)
        rememberForTitle { $0.subtitleDelay = seconds }
    }

    func adjustSubtitleDelay(by delta: Double) {
        setSubtitleDelay(((subtitleDelay + delta) * 10).rounded() / 10)
    }

    func setSpeed(_ speed: Double) {
        self.speed = speed
        videoView?.setSpeed(speed)
        updateNowPlaying()
        rememberForTitle { $0.speed = speed }
    }

    func setVolume(_ volume: Double) {
        let clamped = max(0, min(100, volume))
        self.volume = clamped
        if isMuted && clamped > 0 {
            isMuted = false
            videoView?.setMuted(false)
        }
        videoView?.setVolume(clamped)
        preferences.lastVolume = clamped
    }

    func setMuted(_ muted: Bool? = nil) {
        if let muted {
            isMuted = muted
        } else {
            isMuted.toggle()
        }
        videoView?.setMuted(isMuted)
    }

    func toggleMute() {
        setMuted()
    }

    func dismissError() {
        error = nil
        if session == nil {
            close()
        } else if phase == .failed {
            phase = .ready
        }
    }

    func selectAudioTrack(_ id: Int64) {
        // A manual pick ends automatic selection for this load.
        trackPrefsAppliedForLoad = loadRequest?.id
        activeAudioTrackId = id
        videoView?.selectAudioTrack(id)
        if let language = audioTracks.first(where: { $0.id == id })?.lang {
            rememberForTitle { $0.audioLanguage = language }
        }
    }

    func selectSubtitleTrack(_ id: Int64) {
        trackPrefsAppliedForLoad = loadRequest?.id
        activeSubtitleTrackId = id
        videoView?.selectSubtitleTrack(id)
        if id <= 0 {
            rememberForTitle { $0.subtitlesOff = true }
        } else if let track = subtitleTracks.first(where: { $0.id == id }) {
            rememberForTitle {
                $0.subtitlesOff = false
                $0.subtitleLanguage = track.lang ?? track.title
            }
        }
    }

    /// Persists a user choice into the title's playback memory.
    private func rememberForTitle(_ mutate: (inout TitlePlaybackSnapshot) -> Void) {
        guard preferences.rememberPlaybackPerTitle, let session, session.persistsProgress else { return }
        var snapshot = titlePrefs ?? TitlePlaybackSnapshot()
        mutate(&snapshot)
        guard LibraryStore.shared.perform({ try LibraryStore.shared.updatePlaybackPrefs(details: session.details, mutate) }) else { return }
        titlePrefs = snapshot
    }

    func setAspectRatio(_ ratio: String) {
        aspectRatio = ratio
        videoView?.setAspectRatio(ratio)
    }

    var fillsScreen: Bool { preferences.videoFillsScreen }

    func setFillsScreen(_ fills: Bool) {
        preferences.videoFillsScreen = fills
        videoView?.setFillsScreen(fills)
    }

    /// Re-applies the persisted fill mode to a newly created video view.
    func applyVideoFill() {
        videoView?.setFillsScreen(fillsScreen)
    }

    func toggleFloatOnTop() {
        isFloatingOnTop.toggle()
        windowController?.setFloating(isFloatingOnTop)
    }

    func toggleFullScreen() {
        PlayerWindowController.shared.toggleFullScreen()
    }

    /// Tracks come from mpv's `track-list` only — mpv assigns the IDs, so any
    /// IDs derived from the link's `audioTracks` were wrong (T10).
    func updateTracks(_ tracks: [MpvTrack]) {
        audioTracks = tracks.filter { $0.type == "audio" }
        subtitleTracks = tracks.filter { $0.type == "sub" }
        applyRememberedTracks()
        selectPendingLocalSubtitleIfListed()
    }

    /// Selects the remembered (or globally preferred) audio/subtitle
    /// language once per load, as soon as matching tracks exist. Late
    /// subtitles keep getting a chance until one matches.
    private func applyRememberedTracks() {
        guard let request = loadRequest, trackPrefsAppliedForLoad != request.id else { return }
        let plan = TrackSelectionPolicy.plan(
            audio: audioTracks,
            subtitles: subtitleTracks,
            remembered: titlePrefs,
            preferredSubtitleLanguages: preferences.preferredSubtitleLanguages,
            autoSelectSubtitles: preferences.autoSelectSubtitles,
        )
        if let audio = plan.audioTrack, audio != activeAudioTrackId {
            activeAudioTrackId = audio
            videoView?.selectAudioTrack(audio)
        }
        if let subtitle = plan.subtitleTrack, subtitle != activeSubtitleTrackId {
            activeSubtitleTrackId = subtitle
            videoView?.selectSubtitleTrack(subtitle)
        }
        if plan.isComplete { trackPrefsAppliedForLoad = request.id }
    }

    // MARK: - Chapters & skip (Phase 4.2)

    func updateChapters(_ chapters: [MpvChapter]) {
        self.chapters = chapters
        rebuildSkipSegments()
    }

    private func rebuildSkipSegments() {
        var segments = ChapterClassifier.segments(from: chapters, duration: clock.duration)
        if !segments.contains(where: { $0.kind == .intro }), let learned = titlePrefs?.introSegment {
            segments.append(learned)
        }
        skipSegments = segments.sorted { $0.start < $1.start }
        refreshActiveSkip(at: clock.elapsed)
    }

    private func refreshActiveSkip(at time: Double) {
        let active = skipSegments.first { $0.contains(time) }
        if active != activeSkip { activeSkip = active }
    }

    /// "Skip Intro" / "Skip Credits": jumps to the end of the active segment.
    /// Skipping credits with a next episode queued goes straight to it.
    func skipActiveSegment() {
        guard let segment = activeSkip else { return }
        if segment.kind == .credits, upNext != nil || (hasNextEpisode && preferences.continuousPlayback && !upNextDismissed) {
            playNextEpisode()
            return
        }
        seek(to: segment.end)
        activeSkip = nil
    }

    /// Manual skip for files without chapter markers (Android "skip op").
    func manualSkip() {
        seek(by: preferences.manualSkipSeconds)
        showHUD()
    }

    /// "Set Intro Start/End Here": teaches skip for this show's files that
    /// carry no chapters.
    func markIntro(start: Bool) {
        let position = elapsed
        rememberForTitle { prefs in
            if start {
                prefs.introStart = position
                if let end = prefs.introEnd, end <= position { prefs.introEnd = nil }
            } else {
                prefs.introEnd = position
                if prefs.introStart == nil || (prefs.introStart ?? 0) >= position {
                    prefs.introStart = max(0, position - self.preferences.manualSkipSeconds)
                }
            }
        }
        rebuildSkipSegments()
        showNotice(start ? "Intro start saved for this show" : "Intro end saved — Skip Intro will appear on the next episodes")
    }

    func clearLearnedIntro() {
        rememberForTitle { $0.introStart = nil; $0.introEnd = nil }
        rebuildSkipSegments()
        showNotice("Saved intro cleared")
    }

    var hasLearnedIntro: Bool { titlePrefs?.introSegment != nil }

    // MARK: - Up Next (Phase 4.1)

    private func evaluateUpNext(elapsed time: Double) {
        guard let session, session.persistsProgress, preferences.continuousPlayback, session.details.isSeries,
              !upNextDismissed, sleepTimer != .endOfEpisode, let next = nextEpisode(),
              let start = UpNextPolicy.countdownStart(
                  duration: clock.duration,
                  countdown: preferences.nextEpisodeCountdown,
                  creditsStart: skipSegments.last(where: { $0.kind == .credits })?.start,
              )
        else {
            if upNext != nil { cancelUpNext(dismissed: false) }
            return
        }
        if time >= start {
            guard upNext == nil else { return }
            let seconds = Double(preferences.nextEpisodeCountdown)
            upNext = UpNext(
                episode: next,
                label: Self.episodeLabel(for: next, fallbackIndex: session.details.episodes.firstIndex(of: next)),
                title: next.name,
                posterUrl: next.posterUrl ?? session.details.backgroundPosterUrl,
                total: seconds,
            )
            upNextRemaining = seconds
            upNextTask?.cancel()
            upNextTask = Task { [weak self] in await self?.runUpNextCountdown() }
        } else if upNext != nil {
            // Seeked back out of the credits: the countdown no longer applies.
            cancelUpNext(dismissed: false)
        }
    }

    /// Ticks only while playing: pausing freezes the countdown.
    private func runUpNextCountdown() async {
        let tick = 0.25
        while !Task.isCancelled, upNext != nil {
            try? await Task.sleep(for: .milliseconds(Int(tick * 1000)))
            guard !Task.isCancelled, upNext != nil else { return }
            if isPlaying { upNextRemaining = max(0, upNextRemaining - tick) }
            if upNextRemaining <= 0 {
                upNext = nil
                playNextEpisode()
                return
            }
        }
    }

    func playUpNextNow() {
        guard upNext != nil else { return }
        cancelUpNext(dismissed: false)
        playNextEpisode()
    }

    /// "Cancel": keep watching the credits; the episode then ends normally.
    func dismissUpNext() {
        cancelUpNext(dismissed: true)
    }

    private func cancelUpNext(dismissed: Bool) {
        upNextTask?.cancel()
        upNextTask = nil
        if upNext != nil { upNext = nil }
        upNextDismissed = dismissed
    }

    // MARK: - Sleep timer

    func setSleepTimer(minutes: Int?) {
        sleepTask?.cancel()
        sleepTask = nil
        guard let minutes, minutes > 0 else {
            sleepTimer = nil
            return
        }
        let deadline = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTimer = .at(deadline)
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled, let self, self.sleepTimer == .at(deadline) else { return }
            self.sleepTimer = nil
            self.setPlaying(false)
            self.showNotice("Sleep timer — playback paused")
        }
        showNotice("Playback pauses in \(minutes) min")
    }

    func setSleepAtEndOfEpisode() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepTimer = .endOfEpisode
        cancelUpNext(dismissed: false)
        showNotice("Playback stops after this episode")
    }

    // MARK: - Screenshot & frame step

    func takeScreenshot() {
        guard let session else { return }
        let directory = preferences.screenshotDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            showNotice("Couldn't create the screenshot folder")
            return
        }
        let stamp = WatchProgressPolicy.timestamp(elapsed).replacing(":", with: ".")
        let base = DownloadService.sanitizedFileName("\(session.details.name) \(session.episode == nil ? "" : session.episodeLabel) \(stamp)")
        var url = directory.appendingPathComponent(base).appendingPathExtension("png")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) \(counter)").appendingPathExtension("png")
            counter += 1
        }
        // Success is announced by the engine's reply, once the file exists.
        guard let videoView else { showNotice("Couldn’t save the screenshot."); return }
        videoView.takeScreenshot(to: url)
    }

    /// Hands the current stream (with its headers and position) to an
    /// external player and pauses here (Phase 9).
    /// A stream with headers the external player can't be given safely is
    /// handed over as an engine relay address with none (see
    /// `ExternalPlayer.needsRelay`). The relay session lives while the player
    /// reads it and expires with the relay's idle rules or the engine.
    func openExternally(with external: ExternalPlayer) {
        guard let link = activeLink else { return }
        let title = displayTitle, position = elapsed
        guard session?.localResource == nil, external.needsRelay(link) else {
            launchExternally(external, link: link, title: title, startAt: position, relayedURL: nil)
            return
        }
        let register = registerRelay
        let resources = [MediaRelayResourceDto(url: link.url, headers: link.headers)]
        Task { [weak self] in
            do {
                // Shielded like playback relays: the session is never abandoned mid-registration.
                let relay = try await Task { try await register(resources) }.value
                guard let url = relay.urls.first else { throw MediaResourcePolicy.Rejection.credentialedStream }
                self?.launchExternally(external, link: link, title: title, startAt: position, relayedURL: url)
            } catch {
                DaemonLog.client("player.external_relay_unavailable")
                self?.showNotice(MediaResourcePolicy.Rejection.credentialedStream.localizedDescription)
            }
        }
    }

    private func launchExternally(_ external: ExternalPlayer, link: StreamLinkDto, title: String?, startAt: Double, relayedURL: String?) {
        do {
            try external.open(link, title: title, startAt: startAt, authorizedLocal: session?.localResource, relayedURL: relayedURL)
            setPlaying(false)
            persistProgress(notify: true)
            showNotice("Opened in \(external.rawValue)")
        } catch {
            showNotice(error.localizedDescription)
        }
    }

    func frameStep(forward: Bool) {
        guard session != nil else { return }
        videoView?.frameStep(forward: forward)
        showHUD()
    }

    // MARK: - Episodes

    private func refreshEpisodeNeighbours() {
        hasPreviousEpisode = previousEpisode() != nil
        hasNextEpisode = nextEpisode() != nil
    }

    private func previousEpisode() -> EpisodeDto? {
        session.flatMap { $0.sequence.previous(before: $0.episode) }
    }

    private func nextEpisode() -> EpisodeDto? {
        session.flatMap { $0.sequence.next(after: $0.episode) }
    }

    func playPreviousEpisode() {
        guard let session, let prev = previousEpisode() else { return }
        Task {
            await play(details: session.details, episode: prev, preferences: preferences)
        }
    }

    func playNextEpisode() {
        guard let session, let next = nextEpisode() else { return }
        Task {
            await play(details: session.details, episode: next, preferences: preferences)
        }
    }

    func playEpisode(_ episode: EpisodeDto) {
        guard let session else { return }
        Task {
            await play(details: session.details, episode: episode, preferences: preferences)
        }
    }

    /// Warms the daemon's link cache for the next episode so auto-advance
    /// starts instantly (A3), and keeps the links for the preload. Failures
    /// are irrelevant: the next episode then resolves as usual.
    private func prefetchNextEpisodeLinks() {
        guard !prefetchIssued, let session, let next = nextEpisode(), !next.data.isEmpty else { return }
        let data = next.data
        prefetchIssued = true
        let provider = session.details.providerKey
        let generation = playGeneration
        Task { [weak self] in
            guard let response = try? await DaemonClient.shared.links(provider: provider, data: data),
                  let self, self.playGeneration == generation else { return }
            self.prepareNextEpisode(data: data, links: response.links)
        }
    }

    /// The next episode's resolved links (from the prefetch; tests call it directly).
    func prepareNextEpisode(data: String, links: [StreamLinkDto]) {
        nextEpisodeLinks = (data, links)
        queueNextEpisodeIfDue(elapsed: clock.elapsed)
    }

    // MARK: - Next-episode preload (section 7)

    /// How long before the end the next episode is queued for preloading.
    static let preloadLeadTime: Double = 60
    @ObservationIgnored private var nextEpisodeLinks: (data: String, links: [StreamLinkDto])?
    /// What was queued: the link, so a load of exactly it switches instead.
    @ObservationIgnored private(set) var queuedNext: (data: String, link: StreamLinkDto, url: String)?

    /// Queues the next episode's best link near the end of this one, when it
    /// will play automatically and can use this file's connection settings:
    /// a plain stream (no separate audio, no relay) with the same headers.
    private func queueNextEpisodeIfDue(elapsed: Double) {
        guard queuedNext == nil, let session, session.persistsProgress, session.localResource == nil,
              session.details.isSeries, preferences.continuousPlayback, !upNextDismissed,
              sleepTimer != .endOfEpisode, clock.duration > 0, clock.duration - elapsed <= Self.preloadLeadTime,
              let next = nextEpisode(), let prepared = nextEpisodeLinks, prepared.data == next.data,
              session.links.indices.contains(session.selectedLinkIndex) else { return }
        let currentHeaders = session.links[session.selectedLinkIndex].headers
        let ranked = LinkRanker.rank(prepared.links, preferences.sourcePreferences, remembered: titlePrefs?.rememberedSource)
        // An encrypted stream needs its key as a per-file option, which a queued entry cannot carry.
        guard let best = ranked.first, best.headers == currentHeaders, best.drm == nil,
              (try? MediaResourcePolicy.validate(best)) != nil,
              let plan = try? Self.loadPlan(for: best), plan.audioTracks.isEmpty else { return }
        queuedNext = (next.data, best, plan.resource.url)
        videoView?.queueNext(url: plan.resource.url)
        DaemonLog.client("player.preload_queued", fields: ["remaining": String(Int(clock.duration - elapsed))])
    }

    /// Seeking back out of the preload window drops the queued episode.
    private func cancelQueuedNextIfOutOfWindow(elapsed: Double) {
        guard queuedNext != nil, clock.duration > 0, clock.duration - elapsed > Self.preloadLeadTime + 30 else { return }
        queuedNext = nil
        videoView?.cancelQueuedNext()
    }

    // MARK: - Close

    /// - Parameter fromWindow: true when the window itself is closing
    ///   (`windowWillClose`), so the controller must not be asked to close it
    ///   again (T11).
    func close(fromWindow: Bool = false) {
        guard isActive || error != nil else { return }
        playGeneration += 1
        cancelResolution()
        loadDeadlineTask?.cancel()
        loadDeadlineTask = nil
        releaseVerifier()
        releaseRelay(cancelPending: true)
        persistProgress(notify: true)
        progressFailureShown = false
        NowPlayingService.shared.clearNowPlaying()
        queuedNext = nil
        nextEpisodeLinks = nil
        session = nil
        loadRequest = nil
        pendingTitle = nil
        phase = .idle
        isBuffering = false
        videoView = nil
        hudHideTask?.cancel()
        hudHideTask = nil
        hudHideDeadline = nil
        hudVisible = true
        error = nil
        isPlaying = false
        isFloatingOnTop = false
        pendingResumeCheck = nil
        noticeTask?.cancel()
        notice = nil
        resetPerFileState()
        upNextDismissed = false
        sleepTask?.cancel()
        sleepTask = nil
        sleepTimer = nil
        titlePrefs = nil
        updateDisplaySleepAssertion()
        if !fromWindow {
            windowController?.closeWindow()
        }
    }

    // MARK: - HUD auto-hide (Design.md: 2.5 s cursor inactivity)

    var isInteractingWithHUD = false {
        didSet {
            guard isInteractingWithHUD != oldValue else { return }
            if isInteractingWithHUD {
                if !hudVisible { hudVisible = true }
                hudHideDeadline = nil
            } else {
                scheduleHUDHide()
            }
        }
    }

    func showHUD() {
        if !hudVisible { hudVisible = true }
        scheduleHUDHide()
    }

    /// Pushes the hide deadline forward. One long-lived task sleeps until the
    /// (possibly moved) deadline — mouse-move bursts no longer allocate a Task
    /// per event (U3).
    func scheduleHUDHide() {
        guard !isInteractingWithHUD, isPlaying, phase == .ready || phase == .loading else {
            hudHideDeadline = nil
            return
        }
        hudHideDeadline = .now + .milliseconds(2500)
        guard hudHideTask == nil else { return }
        hudHideTask = Task { [weak self] in
            await self?.runHUDHideLoop()
        }
    }

    private func runHUDHideLoop() async {
        defer { hudHideTask = nil }
        while let deadline = hudHideDeadline {
            try? await Task.sleep(until: deadline, clock: .continuous)
            if Task.isCancelled { return }
            guard let current = hudHideDeadline else { return }
            if current <= .now {
                hudHideDeadline = nil
                if !isInteractingWithHUD, isPlaying, hudVisible {
                    hudVisible = false
                }
                return
            }
        }
    }

    // MARK: - Progress bookkeeping

    func handleProgress(elapsed newElapsed: Double, duration newDuration: Double) {
        if newDuration > 0, newDuration != clock.duration {
            clock.duration = newDuration
            // Chapter ends at the file end depend on the duration.
            if !chapters.isEmpty { rebuildSkipSegments() }
        }
        // U4: until the engine confirms the seek, pre-seek ticks would snap
        // the scrubber back to the old position.
        if let target = seekTarget {
            guard abs(newElapsed - target) < 2 else { return }
            seekTarget = nil
        }
        if newElapsed != clock.elapsed {
            clock.elapsed = newElapsed
        }

        // Time-based throttle on forward playback; a backward jump resets the
        // mark so the next tick persists promptly (P2-11).
        if newElapsed < lastPersistedAt {
            lastPersistedAt = newElapsed
        } else if newElapsed - lastPersistedAt >= Self.progressPersistInterval {
            lastPersistedAt = newElapsed
            persistProgress(notify: false)
            updateNowPlaying()
        }

        if !prefetchIssued, clock.duration > 0, newElapsed / clock.duration >= Self.prefetchThreshold {
            prefetchNextEpisodeLinks()
        }
        queueNextEpisodeIfDue(elapsed: newElapsed)
        cancelQueuedNextIfOutOfWindow(elapsed: newElapsed)

        refreshActiveSkip(at: newElapsed)
        evaluateUpNext(elapsed: newElapsed)
    }

    private func updateNowPlaying() {
        guard let session else { return }
        NowPlayingService.shared.updateNowPlaying(
            title: session.details.name,
            subtitle: session.episode == nil ? nil : session.episodeLabel,
            duration: duration,
            elapsed: elapsed,
            rate: isPlaying ? speed : 0.0,
            isPlaying: isPlaying,
            artworkURL: session.details.backgroundPosterUrl ?? session.details.posterUrl,
        )
    }

    /// - Parameter notify: progress-only writes during playback skip the
    ///   library's observation bump, which re-rendered and re-queried the
    ///   whole main window every few seconds (U2). Session boundaries notify.
    ///
    /// A failed periodic write is logged every time but shown at most once
    /// per session: the store keeps the unsaved position (journal) and later
    /// writes retry it. A session boundary (`notify`) always reports (audit Q9).
    private func persistProgress(notify: Bool) {
        guard let session, session.persistsProgress else { return }
        let save = {
            try LibraryStore.shared.recordProgress(
                details: session.details,
                episode: session.episode,
                progressSeconds: self.elapsed,
                totalDurationSeconds: self.duration,
                notifyObservers: notify,
            )
        }
        if notify {
            LibraryStore.shared.perform(save)
            return
        }
        do { try save() } catch {
            DaemonLog.client("player.progress_save_failed", fields: ["error": error.localizedDescription])
            guard !progressFailureShown else { return }
            progressFailureShown = true
            AppState.shared.presentError("Couldn't save your progress: \(error.localizedDescription)")
        }
    }

    /// The periodic progress failure has been shown for this session.
    @ObservationIgnored private var progressFailureShown = false

    // MARK: - Display sleep (U5)

    /// vo=libmpv cannot inhibit display sleep itself; hold an activity while
    /// a session is actually playing.
    private func updateDisplaySleepAssertion() {
        let shouldHold = isPlaying && session != nil
        if shouldHold, displaySleepActivity == nil {
            displaySleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated],
                reason: "Video playback",
            )
        } else if !shouldHold, let activity = displaySleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            displaySleepActivity = nil
        }
    }

    static func episodeLabel(for episode: EpisodeDto, fallbackIndex: Int?) -> String {
        switch (episode.season, episode.episode) {
        case let (season?, episodeNumber?):
            return "S\(season), E\(episodeNumber)"
        case (nil, let episodeNumber?):
            return "Episode \(episodeNumber)"
        case (_, nil):
            if let fallbackIndex { return "Episode \(fallbackIndex + 1)" }
            return episode.name ?? "Episode"
        }
    }
}

extension MetalVideoView: PlayerTransport {}
