import XCTest
@testable import CloudStream

/// Pure-logic coverage for docs/archive/plans/Player-Remediation-Plan.md.
@MainActor
final class PlayerRemediationTests: XCTestCase {
    // MARK: - A1: render sizing

    func testRenderSizeNeverExceedsNativeVideoResolution() {
        // 720p video in a 4K drawable: render at 720p, GPU upscales.
        let size = MetalVideoView.renderSize(
            drawable: CGSize(width: 3840, height: 2160),
            video: CGSize(width: 1280, height: 720),
        )
        XCTAssertEqual(size, CGSize(width: 1280, height: 720))
    }

    func testRenderSizeKeepsDrawableAspectForLetterboxing() {
        // 16:9 video in a 4:3 drawable: mpv letterboxes inside the target,
        // so the target must keep the drawable's aspect ratio.
        let size = MetalVideoView.renderSize(
            drawable: CGSize(width: 2048, height: 1536),
            video: CGSize(width: 1280, height: 720),
        )
        XCTAssertEqual(size.width / size.height, 2048.0 / 1536.0, accuracy: 0.01)
        XCTAssertLessThanOrEqual(size.width, 2048)
    }

    func testRenderSizeIsCappedForHighResolutionVideo() {
        let size = MetalVideoView.renderSize(
            drawable: CGSize(width: 3840, height: 2160),
            video: CGSize(width: 3840, height: 2160),
        )
        XCTAssertEqual(max(size.width, size.height), MetalVideoView.maxRenderDimension)
    }

    func testRenderSizeWithUnknownVideoFallsBackToDrawableCap() {
        let size = MetalVideoView.renderSize(drawable: CGSize(width: 1000, height: 500), video: .zero)
        XCTAssertEqual(size, CGSize(width: 1000, height: 500))
    }

    func testRenderSizeIsEvenAndNonZero() {
        let size = MetalVideoView.renderSize(drawable: CGSize(width: 1, height: 1), video: .zero)
        XCTAssertGreaterThanOrEqual(size.width, 2)
        XCTAssertEqual(size.width.truncatingRemainder(dividingBy: 2), 0)
        XCTAssertEqual(size.height.truncatingRemainder(dividingBy: 2), 0)
    }

    // MARK: - T8: header splitting

    func testSplitHeadersKeepsRefererAsHeaderAndRoutesUserAgentToOption() {
        let split = MetalVideoView.splitHeaders([
            "Referer": "https://site.example/",
            "User-Agent": "Mozilla/5.0 (KHTML, like Gecko)",
            "Cookie": "a=1, b=2",
        ])
        XCTAssertEqual(split.userAgent, "Mozilla/5.0 (KHTML, like Gecko)")
        // Referer must be sent (protected CDNs 403 without it); commas survive
        // intact because the list is passed as a node array.
        XCTAssertEqual(split.fields, ["Cookie: a=1, b=2", "Referer: https://site.example/"])
    }

    func testSplitHeadersIsCaseInsensitiveAndEmptySafe() {
        let split = MetalVideoView.splitHeaders(["referrer": "r", "user-agent": "ua"])
        XCTAssertEqual(split.userAgent, "ua")
        XCTAssertEqual(split.fields, ["Referer: r"])

        let empty = MetalVideoView.splitHeaders([:])
        XCTAssertNil(empty.userAgent)
        XCTAssertTrue(empty.fields.isEmpty)
    }

    // MARK: - A5: playlist links

    func testPlayableURLUsesEDLForPlaylistLinks() throws {
        let link = StreamLinkDto(
            url: "https://cdn.example/first.ts",
            name: "Segmented",
            source: "x",
            quality: 720,
            type: "VIDEO",
            isPlaylist: true,
            playlist: ["https://a.example/1.ts?x=1;y", "https://a.example/2.ts"],
        )
        let url = try PlayerViewModel.playableURL(for: link)
        XCTAssertEqual(
            url,
            "edl://%28%https://a.example/1.ts?x=1;y;%22%https://a.example/2.ts",
            "Each segment must be length-prefixed so ';' inside a URL cannot split it",
        )
    }

    func testPlayableURLPassesThroughRegularLinks() throws {
        let link = StreamLinkDto(url: "https://cdn.example/v.m3u8", name: "HLS", source: "x", quality: 1080, type: "M3U8")
        XCTAssertEqual(try PlayerViewModel.playableURL(for: link), "https://cdn.example/v.m3u8")
    }

    // MARK: - T10 / engine projection

    func testTracksComeOnlyFromEngineTrackList() {
        let vm = PlayerViewModel()
        vm.updateTracks([
            MpvTrack(id: 1, type: "video", title: nil, lang: nil, codec: "h264"),
            MpvTrack(id: 1, type: "audio", title: "Main", lang: "eng", codec: "aac"),
            MpvTrack(id: 2, type: "audio", title: "Commentary", lang: "eng", codec: "aac"),
            MpvTrack(id: 1, type: "sub", title: nil, lang: "spa", codec: "subrip"),
        ])
        XCTAssertEqual(vm.audioTracks.map(\.id), [1, 2])
        XCTAssertEqual(vm.subtitleTracks.map(\.id), [1])

        vm.updateTracks([])
        XCTAssertTrue(vm.audioTracks.isEmpty, "No fabricated fallback tracks")
    }

    func testSubtitleDelayStepsAreRoundedToTenths() {
        let vm = PlayerViewModel()
        for _ in 0..<3 { vm.adjustSubtitleDelay(by: 0.1) }
        XCTAssertEqual(vm.subtitleDelay, 0.3, accuracy: 1e-9)
        vm.adjustSubtitleDelay(by: -0.5)
        XCTAssertEqual(vm.subtitleDelay, -0.2, accuracy: 1e-9)
    }

    func testEnginePauseProjectionIsIdempotent() {
        let vm = PlayerViewModel()
        vm.handleEnginePause(false)
        XCTAssertTrue(vm.isPlaying)
        vm.handleEnginePause(false)
        XCTAssertTrue(vm.isPlaying)
        vm.handleEnginePause(true)
        XCTAssertFalse(vm.isPlaying)
    }

    func testSeekWithoutSessionIsIgnored() {
        let vm = PlayerViewModel()
        vm.seek(to: 120)
        XCTAssertEqual(vm.elapsed, 0, "No session → no optimistic clock change")
    }

    func testIdleViewModelIsInactive() {
        let vm = PlayerViewModel()
        XCTAssertEqual(vm.phase, .idle)
        XCTAssertFalse(vm.isActive)
        XCTAssertFalse(vm.isPlaying, "Nothing plays (or holds a display-sleep assertion) before a session")
    }

    // MARK: - HUD formatting

    func testSpeedShortLabel() {
        XCTAssertEqual(PlayerSpeedPicker.shortLabel(1.0), "1×")
        XCTAssertEqual(PlayerSpeedPicker.shortLabel(1.25), "1.25×")
        XCTAssertEqual(PlayerSpeedPicker.shortLabel(0.5), "0.5×")
    }

    func testTimeStringHandlesNonFiniteValues() {
        XCTAssertEqual(PlayerTimelineScrubber.timeString(.nan), "00:00")
        XCTAssertEqual(PlayerTimelineScrubber.timeString(3725), "1:02:05")
    }
}

/// U2: progress writes during playback must not re-render the library.
@MainActor
final class QuietProgressPersistenceTests: XCTestCase {
    private func details() -> DetailsDto {
        DetailsDto(
            provider: "prov",
            url: "u/Quiet",
            name: "Quiet",
            type: "tvseries",
            posterUrl: nil,
            backgroundPosterUrl: nil,
            logoUrl: nil,
            plot: nil,
            year: nil,
            durationMinutes: nil,
            score: nil,
            tags: [],
            actors: [],
            contentRating: nil,
            comingSoon: false,
            episodes: [],
            movieData: nil,
        )
    }

    func testQuietProgressWriteDoesNotBumpVersionButPersists() throws {
        let store = LibraryStore(inMemory: true)
        let dto = details()
        try store.recordProgress(details: dto, episode: nil, progressSeconds: 100, totalDurationSeconds: 1000)
        let afterInsert = store.version

        try store.recordProgress(details: dto, episode: nil, progressSeconds: 200, totalDurationSeconds: 1000, notifyObservers: false)
        XCTAssertEqual(store.version, afterInsert, "Periodic progress must not invalidate library views")
        XCTAssertEqual(try store.resumeItem(for: dto)?.progressSeconds, 200, "…but the value is still saved")

        try store.recordProgress(details: dto, episode: nil, progressSeconds: 300, totalDurationSeconds: 1000)
        XCTAssertEqual(store.version, afterInsert + 1, "Session boundaries notify")
    }

    func testQuietWriteOfNewEntryStillNotifies() throws {
        let store = LibraryStore(inMemory: true)
        let before = store.version
        try store.recordProgress(details: details(), episode: nil, progressSeconds: 50, totalDurationSeconds: 1000, notifyObservers: false)
        XCTAssertEqual(store.version, before + 1, "A new Continue Watching entry is structural")
    }
}

/// Split-stream merging, audio preference, and metadata sanity
/// (Player-Remediation-Plan phase 6).
@MainActor
final class SplitStreamPlanTests: XCTestCase {
    private let video = "https://cdn.example/v.mp4?sparams=a,b;c"
    private let aacLow = AudioTrackDto(url: "https://cdn.example/a?mime=audio%2Fmp4&x=1", label: "m4a (48 kbps)", language: nil)
    private let aacHigh = AudioTrackDto(url: "https://cdn.example/b?mime=audio%2Fmp4", label: "m4a (128 kbps)", language: nil)
    private let opus = AudioTrackDto(url: "https://cdn.example/c?mime=audio%2Fwebm", label: "WebM Opus (160 kbps)", language: nil)

    func testSplitLinkBecomesSingleMergedManifest() throws {
        let link = StreamLinkDto(url: video, name: "YT", source: "yt", quality: 720, type: "VIDEO", audioTracks: [aacLow, opus, aacHigh])
        let plan = try PlayerViewModel.loadPlan(for: link)
        XCTAssertTrue(plan.audioTracks.isEmpty, "audio must not also be audio-added")
        XCTAssertTrue(plan.url.hasPrefix("edl://!no_clip;!no_chapters;%\(video.utf8.count)%\(video);"))
        // Three audio streams; the preferred (AAC 128) is eager, others lazy with codecs.
        XCTAssertEqual(plan.url.components(separatedBy: "!new_stream").count - 1, 3)
        XCTAssertEqual(plan.url.components(separatedBy: "!delay_open").count - 1, 2)
        let firstAudio = plan.url.components(separatedBy: "!new_stream")[1]
        XCTAssertTrue(firstAudio.contains(aacHigh.url), "AAC 128 kbps opens first")
        XCTAssertFalse(firstAudio.contains("!delay_open"))
        XCTAssertTrue(plan.url.contains("!delay_open,media_type=audio,codec=opus;!track_meta,title=%20%WebM Opus (160 kbps)"),
                      "delay_open (with codec) must precede track_meta")
    }

    func testMuxedLinkLoadsAsIs() throws {
        let link = StreamLinkDto(url: "https://cdn.example/master.m3u8", name: "HLS", source: "x", quality: 1080, type: "M3U8")
        let plan = try PlayerViewModel.loadPlan(for: link)
        XCTAssertEqual(plan.url, link.url)
        XCTAssertTrue(plan.audioTracks.isEmpty)
    }

    func testAudioPreferenceLanguageThenAACThenBitrate() {
        let french = AudioTrackDto(url: "https://x/fr", label: "m4a (128 kbps)", language: "fr")
        let english = AudioTrackDto(url: "https://x/en", label: "WebM Opus (70 kbps)", language: "en")
        let order = PlayerViewModel.preferredAudioOrder([french, english, aacLow], preferredLanguages: ["en-US"])
        XCTAssertEqual(order.first?.url, english.url, "user's language wins over codec/bitrate")

        let noLanguage = PlayerViewModel.preferredAudioOrder([opus, aacLow, aacHigh], preferredLanguages: ["en-US"])
        XCTAssertEqual(noLanguage.map(\.url), [aacHigh.url, aacLow.url, opus.url])
    }

    func testAudioCodecGuess() {
        XCTAssertEqual(PlayerViewModel.audioCodecGuess(opus), "opus")
        XCTAssertEqual(PlayerViewModel.audioCodecGuess(aacLow), "aac")
        XCTAssertEqual(PlayerViewModel.audioCodecGuess(AudioTrackDto(url: "https://x/y.webm")), "opus")
    }
}
