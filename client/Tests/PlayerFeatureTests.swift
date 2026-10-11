import XCTest
@testable import CloudStream

/// Records transport intents so PlayerViewModel logic runs without mpv.
@MainActor
final class FakeTransport: PlayerTransport {
    var seeks: [Double] = []
    var speeds: [Double] = []
    var delays: [Double] = []
    var selectedSubtitles: [Int64] = []
    var screenshots: [URL] = []
    var frameSteps: [Bool] = []
    var playing: Bool?

    func setPlaying(_ play: Bool) { playing = play }
    func togglePlayPause() {}
    func seek(by seconds: Double) {}
    func seek(to seconds: Double) { seeks.append(seconds) }
    func setSubtitleDelay(_ seconds: Double) { delays.append(seconds) }
    func setSpeed(_ speed: Double) { speeds.append(speed) }
    func toggleMute() {}
    func setVolume(_ volume: Double) {}
    func setMuted(_ muted: Bool) {}
    func selectAudioTrack(_ id: Int64) {}
    func selectSubtitleTrack(_ id: Int64) { selectedSubtitles.append(id) }
    func setSubtitleStyle(fontSize: Double?, outlineWidth: Double?, textColor: String?, backgroundColor: String?) {}
    func setSubtitleLayout(font: String?, bold: Bool?, shadowOffset: Double?, position: Int?) {}
    func setAspectRatio(_ ratio: String) {}
    func setFillsScreen(_ fills: Bool) {}
    func addSubtitles(_ subtitles: [PlaybackSubtitle]) {}
    func takeScreenshot(to url: URL) { screenshots.append(url) }
    func frameStep(forward: Bool) { frameSteps.append(forward) }
    var queued: [String] = []
    var queueCancels = 0
    func queueNext(url: String) { queued.append(url) }
    func cancelQueuedNext() { queueCancels += 1 }
    func shutdown() {}
}

/// Offline-Features-Plan Phase 4: skip, Up Next and trailer isolation,
/// exercised through the view model with a fake engine.
@MainActor
final class PlayerFeatureTests: XCTestCase {
    private var savedCountdown = 10
    private var savedContinuous = true

    override func setUp() async throws {
        savedCountdown = UserPreferences.shared.nextEpisodeCountdown
        savedContinuous = UserPreferences.shared.continuousPlayback
        UserPreferences.shared.nextEpisodeCountdown = 10
        UserPreferences.shared.continuousPlayback = true
    }

    override func tearDown() async throws {
        UserPreferences.shared.nextEpisodeCountdown = savedCountdown
        UserPreferences.shared.continuousPlayback = savedContinuous
    }

    private func episode(_ n: Int) -> EpisodeDto {
        EpisodeDto(data: "feature-ep-\(n)", name: "Ep \(n)", season: 1, episode: n, posterUrl: nil, description: nil, score: nil, date: nil, runTimeMinutes: 24, audio: nil)
    }

    private func series(url: String = "u/feature") -> DetailsDto {
        DetailsDto(provider: "feature-test", url: url, name: "Feature", type: "TvSeries", posterUrl: nil, backgroundPosterUrl: nil,
                   logoUrl: nil, plot: nil, year: nil, durationMinutes: nil, score: nil, tags: [], actors: [], contentRating: nil,
                   comingSoon: false, episodes: [episode(1), episode(2)], movieData: nil)
    }

    private func start(persists: Bool = true, url: String = "u/feature") -> (PlayerViewModel, FakeTransport) {
        let vm = PlayerViewModel()
        let fake = FakeTransport()
        vm.playResolved(
            details: series(url: url),
            episode: episode(1),
            links: [StreamLinkDto(url: "https://cdn/a.mp4", name: "A", source: "a", quality: 1080, type: "video")],
            persistsProgress: persists,
        )
        vm.videoView = fake
        return (vm, fake)
    }

    private func startWithMirrors() -> (PlayerViewModel, FakeTransport) {
        let vm = PlayerViewModel()
        let fake = FakeTransport()
        vm.playResolved(details: series(), episode: episode(1), links: [
            StreamLinkDto(url: "https://cdn/a.mp4", name: "A", source: "a", quality: 1080, type: "video"),
            StreamLinkDto(url: "https://cdn/b.mp4", name: "B", source: "b", quality: 720, type: "video"),
        ], persistsProgress: false)
        vm.videoView = fake
        vm.handlePlaybackRestart() // loaded: phase .ready
        return (vm, fake)
    }

    func testNextEpisodeIsQueuedNearTheEndAndUsedWhenItsLinkLoads() async throws {
        let (vm, fake) = start(persists: true, url: "u/preload-\(UUID().uuidString)")
        defer { vm.close() }
        let nextLink = StreamLinkDto(url: "https://cdn/ep2.mp4", name: "A", source: "a", quality: 1080, type: "video")
        vm.handleProgress(elapsed: 100, duration: 1440)
        vm.prepareNextEpisode(data: episode(2).data, links: [nextLink])
        XCTAssertTrue(fake.queued.isEmpty, "not queued before the last minute")
        vm.handleProgress(elapsed: 1400, duration: 1440)
        XCTAssertEqual(fake.queued, ["https://cdn/ep2.mp4"])
        vm.handleProgress(elapsed: 1300, duration: 1440)
        XCTAssertEqual(fake.queueCancels, 1, "seeking back out of the window drops it")
        XCTAssertNil(vm.queuedNext)
        vm.handleProgress(elapsed: 1420, duration: 1440)
        XCTAssertEqual(fake.queued.count, 2, "re-queued when the window is entered again")

        vm.playResolved(details: series(), episode: episode(2), links: [nextLink])
        XCTAssertEqual(vm.loadRequest?.usesQueuedNext, true, "the preloaded entry is switched to")
        XCTAssertNil(vm.queuedNext)
    }

    func testPreloadSkipsLinksThatNeedOtherHeaders() {
        let (vm, fake) = start(persists: true, url: "u/preload-h-\(UUID().uuidString)")
        defer { vm.close() }
        vm.handleProgress(elapsed: 1400, duration: 1440)
        vm.prepareNextEpisode(data: episode(2).data, links: [
            StreamLinkDto(url: "https://cdn/ep2.mp4", name: "A", source: "a", quality: 1080, type: "video", headers: ["Referer": "https://other"]),
        ])
        XCTAssertTrue(fake.queued.isEmpty)
    }

    func testRepeatedStallsSwitchToTheNextMirrorAndSayWhy() {
        let (vm, _) = startWithMirrors()
        defer { vm.close() }
        vm.stallPolicy = .init(minimum: .zero, long: .seconds(60), count: 3, window: .seconds(60))
        for _ in 0..<2 { vm.handleBuffering(true); vm.handleBuffering(false) }
        XCTAssertEqual(vm.session?.selectedLinkIndex, 0, "two stalls are tolerated")
        vm.handleBuffering(true); vm.handleBuffering(false)
        XCTAssertEqual(vm.session?.selectedLinkIndex, 1)
        XCTAssertTrue(vm.notice?.contains("keeps stalling") == true, vm.notice ?? "no notice")
    }

    func testOneLongStallSwitchesMirror() async throws {
        let (vm, _) = startWithMirrors()
        defer { vm.close() }
        vm.stallPolicy = .init(minimum: .zero, long: .milliseconds(100), count: 3, window: .seconds(60))
        vm.handleBuffering(true)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(vm.session?.selectedLinkIndex, 1)
    }

    func testBufferingWhileLoadingIsNotAStallAndFailoverIsAnnounced() {
        let (vm, _) = startWithMirrors()
        defer { vm.close() }
        vm.stallPolicy = .init(minimum: .zero, long: .seconds(60), count: 1, window: .seconds(60))
        vm.handlePlaybackError() // mirror A failed
        XCTAssertEqual(vm.session?.selectedLinkIndex, 1)
        XCTAssertTrue(vm.notice?.contains("trying b 720p") == true, vm.notice ?? "no notice")
        vm.handleBuffering(true); vm.handleBuffering(false) // still loading B
        XCTAssertEqual(vm.session?.selectedLinkIndex, 1)
    }

    func testRememberedOrPreferredSourceStartsWithoutTheGracePeriod() {
        let link = StreamLinkDto(url: "https://cdn/x", name: "Fast 1080p", source: "Fast", quality: 1080, type: "video")
        XCTAssertTrue(PlayerViewModel.startsImmediately(link, remembered: RememberedSource(key: "fast", quality: 1080), preferred: nil))
        XCTAssertFalse(PlayerViewModel.startsImmediately(link, remembered: RememberedSource(key: "fast", quality: 720), preferred: nil))
        XCTAssertFalse(PlayerViewModel.startsImmediately(link, remembered: RememberedSource(key: "other", quality: nil), preferred: "fast"),
                       "a remembered source outranks the global priority")
        XCTAssertTrue(PlayerViewModel.startsImmediately(link, remembered: nil, preferred: "fast"))
        XCTAssertFalse(PlayerViewModel.startsImmediately(link, remembered: nil, preferred: nil))
    }

    func testSkipIntroChapterJumpsToItsEnd() {
        let (vm, fake) = start()
        defer { vm.close() }
        vm.handleProgress(elapsed: 10, duration: 1440)
        vm.updateChapters([
            MpvChapter(index: 0, title: "Cold Open", time: 0),
            MpvChapter(index: 1, title: "Opening", time: 60),
            MpvChapter(index: 2, title: "Part A", time: 150),
        ])
        XCTAssertNil(vm.activeSkip)
        vm.handleProgress(elapsed: 90, duration: 1440)
        XCTAssertEqual(vm.activeSkip?.kind, .intro)
        vm.skipActiveSegment()
        XCTAssertEqual(fake.seeks.last, 150)
        XCTAssertNil(vm.activeSkip)
    }

    func testUpNextAppearsDismissesAndReturnsAfterSeekBack() {
        let (vm, _) = start()
        defer { vm.close() }
        vm.handleProgress(elapsed: 1000, duration: 1440)
        XCTAssertNil(vm.upNext)
        vm.handleProgress(elapsed: 1432, duration: 1440)
        XCTAssertEqual(vm.upNext?.episode, episode(2))
        XCTAssertEqual(vm.upNextRemaining, 10)

        vm.dismissUpNext()
        XCTAssertNil(vm.upNext)
        vm.handleProgress(elapsed: 1434, duration: 1440)
        XCTAssertNil(vm.upNext, "a dismissed countdown stays dismissed for this episode")
    }

    func testSeekingBackCancelsCountdownWithoutDismissing() {
        let (vm, _) = start()
        defer { vm.close() }
        vm.handleProgress(elapsed: 1432, duration: 1440)
        XCTAssertNotNil(vm.upNext)
        vm.handleProgress(elapsed: 500, duration: 1440)
        XCTAssertNil(vm.upNext)
        vm.handleProgress(elapsed: 1433, duration: 1440)
        XCTAssertNotNil(vm.upNext)
    }

    func testCountdownOffMeansNoCard() {
        UserPreferences.shared.nextEpisodeCountdown = 0
        let (vm, _) = start()
        defer { vm.close() }
        vm.handleProgress(elapsed: 1439, duration: 1440)
        XCTAssertNil(vm.upNext)
    }

    func testSleepAtEndOfEpisodeSuppressesUpNext() {
        let (vm, _) = start()
        defer { vm.close() }
        vm.setSleepAtEndOfEpisode()
        vm.handleProgress(elapsed: 1435, duration: 1440)
        XCTAssertNil(vm.upNext)
        XCTAssertEqual(vm.sleepTimer, .endOfEpisode)
    }

    func testTrailersNeverTouchHistoryOrUpNext() throws {
        let (vm, _) = start(persists: false, url: "u/trailer-only")
        vm.handleProgress(elapsed: 1435, duration: 1440)
        XCTAssertNil(vm.upNext)
        vm.close()
        XCTAssertNil(try LibraryStore.shared.resumeItem(for: series(url: "u/trailer-only")), "trailer playback must not create a library entry")
    }

    // MARK: Engine outcomes, load deadline and keep-alive (audit A36/A47)

    /// The window is closed and presented again in every order the player
    /// can produce (same run-loop turn, after a failure, across a layout
    /// pass). With the video-view handle observed, re-attaching it during
    /// SwiftUI's update pass made AppKit raise "more Update Constraints in
    /// Window passes than there are views" here; the test host fails the run
    /// on that fault.
    func testPlayerWindowSurvivesRepeatedCloseAndPresentInEveryOrder() async {
        let vm = PlayerViewModel()
        vm.loadDeadline = .milliseconds(30)
        for round in 0..<12 {
            vm.playResolved(details: series(), episode: episode(1), links: [link("a\(round)")], persistsProgress: false)
            switch round % 4 {
            case 0:
                // Same run-loop turn: the closed window's teardown has not been flushed.
                vm.close()
                vm.playResolved(details: series(), episode: episode(1), links: [link("b\(round)")], persistsProgress: false)
                XCTAssertEqual(vm.loadRequest?.url, link("b\(round)").url)
            case 1:
                // Fail in place, then start again over the error state.
                await settle { vm.phase == .failed }
                vm.playResolved(details: series(), episode: episode(1), links: [link("c\(round)")], persistsProgress: false)
                XCTAssertNil(vm.error)
            case 2:
                // Let a layout pass run with the window on screen first.
                try? await Task.sleep(for: .milliseconds(20))
                vm.windowController?.setVideoAspectRatio(NSSize(width: 1920, height: round == 2 ? 800 : 1080))
            default:
                vm.handlePlaybackRestart()
                vm.showNotice("notice \(round)")
            }
            vm.close()
            if round % 3 == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertFalse(vm.isActive)
    }

    private func link(_ name: String, verifier: String? = nil) -> StreamLinkDto {
        StreamLinkDto(url: "https://cdn/\(name).mp4", name: name, source: "src-\(name)", quality: 1080, type: "video", extractorData: verifier)
    }

    private func settle(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "player fixture did not reach the expected state")
    }

    func testRejectedSeekStopsWaitingAndScreenshotIsAnnouncedOnlyWhenTheFileExists() throws {
        let (vm, fake) = start()
        defer { vm.close() }
        vm.handleProgress(elapsed: 10, duration: 1440)
        vm.seek(to: 600)
        vm.handleProgress(elapsed: 11, duration: 1440)
        XCTAssertEqual(vm.elapsed, 600, "pre-seek ticks are held back while the seek is pending")
        vm.handleCommandReply(MpvCommandReply(kind: .seek, error: "unsupported"))
        XCTAssertEqual(vm.notice, "This stream couldn’t seek to that position.")
        vm.handleProgress(elapsed: 12, duration: 1440)
        XCTAssertEqual(vm.elapsed, 12, "a rejected seek no longer blocks the real clock")
        vm.handleCommandReply(MpvCommandReply(kind: .seek, error: nil))
        vm.handleCommandReply(MpvCommandReply(kind: .other, error: "ignored"))

        vm.takeScreenshot()
        let target = try XCTUnwrap(fake.screenshots.last)
        XCTAssertNotEqual(vm.notice?.hasPrefix("Screenshot saved"), true, "nothing is announced before the engine answers")
        vm.handleCommandReply(MpvCommandReply(kind: .screenshot, error: nil, url: target))
        XCTAssertEqual(vm.notice, "Couldn’t save the screenshot.", "a success reply without a file is not a saved screenshot")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: target)
        defer { try? FileManager.default.removeItem(at: target) }
        vm.handleCommandReply(MpvCommandReply(kind: .screenshot, error: nil, url: target))
        XCTAssertEqual(vm.notice?.hasPrefix("Screenshot saved to"), true)
        vm.handleCommandReply(MpvCommandReply(kind: .screenshot, error: "write failed", url: target))
        XCTAssertEqual(vm.notice, "Couldn’t save the screenshot.")
        XCTAssertEqual(MpvCommandReply.Kind(rawValue: MpvCommandReply.tag(.screenshot, sequence: 9) & 0xff), .screenshot)
    }

    func testEngineStartFailureEndsLoadingWithoutBurningMirrors() {
        let vm = PlayerViewModel()
        defer { vm.close() }
        vm.playResolved(details: series(), episode: episode(1), links: [link("a"), link("b")], persistsProgress: false)
        XCTAssertEqual(vm.phase, .loading)
        vm.handleEngineFailure("the video renderer could not be created")
        XCTAssertEqual(vm.phase, .failed)
        XCTAssertEqual(vm.session?.selectedLinkIndex, 0, "another mirror cannot fix an engine that did not start")
        XCTAssertEqual(vm.error?.contains("couldn’t start"), true)
    }

    func testLoadThatNeverStartsFailsOverThenReportsARecoverableError() async {
        let vm = PlayerViewModel()
        defer { vm.close() }
        vm.loadDeadline = .milliseconds(40)
        vm.playResolved(details: series(), episode: episode(1), links: [link("a"), link("b")], persistsProgress: false)
        await settle { vm.session?.selectedLinkIndex == 1 }
        XCTAssertEqual(vm.phase, .loading, "the second mirror gets its own attempt")
        await settle { vm.phase == .failed }
        XCTAssertEqual(vm.error?.contains("mirrors failed"), true)

        // A load that does start is left alone by the deadline.
        vm.playResolved(details: series(), episode: episode(1), links: [link("c")], persistsProgress: false)
        vm.handlePlaybackRestart()
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(vm.phase, .ready)
    }

    func testVerifierFollowsTheActiveLinkAndIsReleasedOnEveryExit() async {
        let vm = PlayerViewModel()
        var started: [String] = [], stopped: [String] = []
        vm.startVerifier = { source, data in started.append("\(source)|\(data)"); return "job-\(started.count)" }
        vm.stopVerifier = { stopped.append($0) }
        vm.playResolved(details: series(), episode: episode(1), links: [link("a", verifier: "keep-a"), link("b"), link("c", verifier: "keep-c")])
        await settle { started == ["src-a|keep-a"] }

        // Mirror switch to a link without keep-alive data: the old job stops, none starts.
        vm.failover(to: 1)
        await settle { stopped == ["job-1"] }
        XCTAssertEqual(started.count, 1)
        // A mirror that needs one gets its own.
        vm.failover(to: 2)
        await settle { started.count == 2 }
        XCTAssertEqual(started.last, "src-c|keep-c")
        vm.close()
        await settle { stopped == ["job-1", "job-2"] }
    }

    func testEngineRestartRestartsTheKeepAliveWithoutStoppingTheOldJob() async {
        // M7: the old engine's job is gone; a new one starts on the new engine.
        let vm = PlayerViewModel()
        var started: [String] = [], stopped: [String] = []
        vm.startVerifier = { source, data in started.append("\(source)|\(data)"); return "job-\(started.count)" }
        vm.stopVerifier = { stopped.append($0) }
        vm.playResolved(details: series(), episode: episode(1), links: [link("a", verifier: "keep-a")])
        await settle { started.count == 1 }
        vm.engineReconnected()
        await settle { started.count == 2 }
        XCTAssertEqual(started, ["src-a|keep-a", "src-a|keep-a"])
        XCTAssertTrue(stopped.isEmpty, "no stop is sent for a job the old engine took with it")
        vm.close()
        await settle { stopped == ["job-2"] }

        // A link without keep-alive data starts nothing.
        let plain = PlayerViewModel()
        var plainStarts = 0
        plain.startVerifier = { _, _ in plainStarts += 1; return "x" }
        plain.stopVerifier = { _ in }
        plain.playResolved(details: series(), episode: episode(1), links: [link("b")])
        plain.engineReconnected()
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(plainStarts, 0)
        plain.close()
    }

    func testPeriodicProgressFailuresAreReportedOncePerSession() async throws {
        // Q9: each failed periodic write is logged; the banner appears once per session.
        struct Fault: Error, LocalizedError { var errorDescription: String? { "disk unavailable" } }
        let store = LibraryStore.shared
        store.persistenceFault = { boundary in if boundary == .mutationCommit { throw Fault() } }
        defer { store.persistenceFault = nil; AppState.shared.dismissTransientError() }
        let vm = PlayerViewModel()
        vm.startVerifier = { _, _ in nil }
        vm.stopVerifier = { _ in }
        vm.playResolved(details: series(), episode: episode(1), links: [link("a")])
        AppState.shared.dismissTransientError()
        var shown = 0
        for step in 1...4 {
            vm.handleProgress(elapsed: Double(step) * (PlayerViewModel.progressPersistInterval + 1), duration: 3000)
            if AppState.shared.transientError != nil { shown += 1; AppState.shared.dismissTransientError() }
        }
        XCTAssertEqual(shown, 1, "four failed periodic saves, one banner")
        store.persistenceFault = nil
        vm.close()
    }

    func testTrailersNeverStartAKeepAlive() async {
        let vm = PlayerViewModel()
        defer { vm.close() }
        var started = 0
        vm.startVerifier = { _, _ in started += 1; return "job" }
        vm.stopVerifier = { _ in }
        vm.playResolved(details: series(), episode: nil, links: [link("t", verifier: "keep-t")], persistsProgress: false)
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(started, 0)
    }

    func testLateVerifierStartIsStoppedInsteadOfJoiningTheNewSession() async {
        let vm = PlayerViewModel()
        defer { vm.close() }
        var stopped: [String] = []
        var pending: CheckedContinuation<String?, Error>?
        vm.startVerifier = { _, data in
            if data == "slow" { return try await withCheckedThrowingContinuation { pending = $0 } }
            return "job-fast"
        }
        vm.stopVerifier = { stopped.append($0) }
        vm.playResolved(details: series(), episode: episode(1), links: [link("slow", verifier: "slow"), link("fast", verifier: "fast")])
        await settle { pending != nil }
        vm.failover(to: 1)
        await settle { vm.session?.selectedLinkIndex == 1 }
        pending?.resume(returning: "job-late")
        await settle { stopped.contains("job-late") }
        vm.close()
        await settle { stopped.contains("job-fast") }
        XCTAssertEqual(Set(stopped), ["job-late", "job-fast"], "each started job is stopped exactly once")
        XCTAssertEqual(stopped.count, 2)
    }

    func testVerifierFailureRetriesWithinBoundsThenSaysSo() async {
        let vm = PlayerViewModel()
        defer { vm.close() }
        var attempts = 0
        vm.verifierRetryDelays = [.milliseconds(5), .milliseconds(5)]
        vm.startVerifier = { _, _ in attempts += 1; throw URLError(.timedOut) }
        vm.stopVerifier = { _ in XCTFail("nothing was started") }
        vm.playResolved(details: series(), episode: episode(1), links: [link("a", verifier: "keep")])
        await settle { vm.notice?.contains("kept alive") == true }
        XCTAssertEqual(attempts, 3, "bounded: the first attempt plus two retries")
        XCTAssertNotEqual(vm.phase, .failed, "playback itself is not failed by the keep-alive")
    }

    func testScreenshotAndFrameStepReachTheEngine() {
        let (vm, fake) = start()
        defer { vm.close() }
        vm.frameStep(forward: true)
        vm.frameStep(forward: false)
        XCTAssertEqual(fake.frameSteps, [true, false])
        vm.takeScreenshot()
        XCTAssertEqual(fake.screenshots.count, 1)
        XCTAssertEqual(fake.screenshots.first?.pathExtension, "png")
    }
}
