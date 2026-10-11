import XCTest
@testable import CloudStream

/// Offline-Features-Plan Phase 6: discover, new-episode tracking, library
/// filters and history.
@MainActor
final class LibraryDiscoveryTests: XCTestCase {
    private func result(_ name: String, provider: String = "P", type: String = "Movie") -> SearchResultDto {
        SearchResultDto(name: name, url: "u/\(name)", provider: provider, type: type, posterUrl: nil, quality: nil, score: nil, language: nil, episodes: nil, year: nil, isMovie: type == "Movie")
    }

    private func episode(_ n: Int, season: Int = 1, audio: String? = nil) -> EpisodeDto {
        EpisodeDto(data: "d-\(season)-\(n)-\(audio ?? "")", name: nil, season: season, episode: n, posterUrl: nil, description: nil, score: nil, date: nil, runTimeMinutes: nil, audio: audio)
    }

    private func series(_ episodes: [EpisodeDto], url: String = "u/s") -> DetailsDto {
        DetailsDto(provider: "P", url: url, name: "S", type: "TvSeries", posterUrl: nil, backgroundPosterUrl: nil, logoUrl: nil, plot: nil,
                   year: nil, durationMinutes: nil, score: nil, tags: [], actors: [], contentRating: nil, comingSoon: false,
                   episodes: episodes, movieData: nil)
    }

    // MARK: Discover

    func testMergeAppendsPagesIntoSameShelfWithoutDuplicates() {
        let page1 = [HomePageListDto(name: "Trending", isHorizontal: false, items: [result("A"), result("B")])]
        let page2 = [
            HomePageListDto(name: "Trending", isHorizontal: true, items: [result("B"), result("C")]),
            HomePageListDto(name: "New", isHorizontal: false, items: [result("D"), result("D")]),
            HomePageListDto(name: "Empty", isHorizontal: false, items: []),
        ]
        let merged = DiscoverStore.merge(DiscoverStore.merge([], with: page1), with: page2)
        XCTAssertEqual(merged.map(\.name), ["Trending", "New"])
        XCTAssertEqual(merged[0].items.map(\.name), ["A", "B", "C"])
        XCTAssertFalse(merged[0].isHorizontal, "the shelf keeps its first layout")
        XCTAssertEqual(merged[1].items.map(\.name), ["D"])
    }

    func testMergeDeduplicatesWithinIncomingPageForExistingShelf() {
        let page1 = [HomePageListDto(name: "Trending", isHorizontal: false, items: [result("A")])]
        let page2 = [HomePageListDto(name: "Trending", isHorizontal: false, items: [result("B"), result("B"), result("A"), result("C")])]
        let merged = DiscoverStore.merge(page1, with: page2)
        XCTAssertEqual(merged[0].items.map(\.name), ["A", "B", "C"])
    }

    private func home(_ provider: String, page: Int, _ names: [String], hasNext: Bool = true) -> HomePageDto {
        HomePageDto(provider: provider, page: page, hasNext: hasNext,
                    lists: [HomePageListDto(name: "Shelf", isHorizontal: false, items: names.map { result($0, provider: provider) })])
    }

    private func settle(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(condition(), "Discover fixture did not reach the expected state")
    }

    func testLatePageTwoCannotAppendAfterRefreshOfSameProvider() async {
        let gate = HomeGate()
        let store = DiscoverStore(loadHome: gate.loader)
        store.load(provider: "P")
        await settle { gate.isWaiting("P", 1) }
        gate.finish("P", 1, home("P", page: 1, ["A"]))
        await settle { store.state == .loaded }
        store.loadMore()
        await settle { gate.isWaiting("P", 2) }
        XCTAssertTrue(store.isLoadingMore)

        store.load(provider: "P", force: true)
        XCTAssertFalse(store.isLoadingMore, "refresh resets pagination it invalidated")
        await settle { gate.isWaiting("P", 1) }
        gate.finish("P", 1, home("P", page: 1, ["N"]))
        await settle { store.state == .loaded }
        gate.finish("P", 2, home("P", page: 2, ["STALE"]))
        for _ in 0..<8 { await Task.yield() }
        XCTAssertEqual(store.rows.flatMap(\.items).map(\.name), ["N"])

        store.loadMore()
        await settle { gate.isWaiting("P", 2) }
        gate.finish("P", 2, home("P", page: 2, ["N", "O", "O"], hasNext: false))
        await settle { !store.isLoadingMore }
        XCTAssertEqual(store.rows.flatMap(\.items).map(\.name), ["N", "O"], "the refreshed generation paginates from page two")
        XCTAssertFalse(store.hasNextPage)
    }

    func testClearingProviderDropsLatePageOneAndPageTwo() async {
        let gate = HomeGate()
        let store = DiscoverStore(loadHome: gate.loader)
        store.load(provider: "P")
        await settle { gate.isWaiting("P", 1) }
        store.load(provider: "")
        gate.finish("P", 1, home("P", page: 1, ["A"]))
        for _ in 0..<8 { await Task.yield() }
        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertEqual(store.state, .idle)
        XCTAssertNil(store.loadedProvider)

        store.load(provider: "P")
        await settle { gate.isWaiting("P", 1) }
        gate.finish("P", 1, home("P", page: 1, ["A"]))
        await settle { store.state == .loaded }
        store.loadMore()
        await settle { gate.isWaiting("P", 2) }
        store.load(provider: "Q")
        gate.finish("P", 2, home("P", page: 2, ["B"]))
        await settle { gate.isWaiting("Q", 1) }
        gate.finish("Q", 1, home("Q", page: 1, ["Z"], hasNext: false))
        await settle { store.state == .loaded }
        XCTAssertEqual(store.rows.flatMap(\.items).map(\.name), ["Z"])
        XCTAssertFalse(store.isLoadingMore)
    }

    func testHomepageLoadedUnderAnotherConfigurationIsNotReused() async {
        let gate = HomeGate()
        let store = DiscoverStore(loadHome: gate.loader)
        store.load(provider: "P", configuration: [1, 1, 0])
        await settle { gate.isWaiting("P", 1) }
        gate.finish("P", 1, home("P", page: 1, ["A"]))
        await settle { store.state == .loaded }
        store.load(provider: "P", configuration: [1, 1, 0])
        XCTAssertEqual(store.state, .loaded, "a fresh copy for the same configuration is reused")
        store.load(provider: "P", configuration: [2, 1, 0])
        XCTAssertEqual(store.state, .loading, "an engine or provider change reloads the homepage")
        XCTAssertEqual(store.rows.flatMap(\.items).map(\.name), ["A"], "the same provider's rows stay visible while reloading")
        await settle { gate.isWaiting("P", 1) }
        gate.finish("P", 1, home("P", page: 1, ["B"]))
        await settle { store.state == .loaded }
        XCTAssertEqual(store.rows.flatMap(\.items).map(\.name), ["B"])
    }

    // MARK: Details cache (audit A38)

    func testDetailsCacheIsAuthoritativeOnlyForItsGenerationAndFreshness() {
        var cache = DetailsCache()
        let key = DetailCoordinate.result(result("A"))
        let details = series([episode(1)])
        let first = DetailsCache.Generation(engine: 1, extensions: 1, settings: 0)
        let now = Date()
        cache.store(details, for: key, generation: first, now: now)
        XCTAssertEqual(cache.current(key, generation: first, now: now.addingTimeInterval(60))?.url, details.url)
        XCTAssertFalse(cache.isStale(key, generation: first, now: now))

        // Engine restart, extension replacement/enable change and provider
        // address/credential changes each invalidate the hit.
        for changed in [DetailsCache.Generation(engine: 2, extensions: 1, settings: 0),
                        .init(engine: 1, extensions: 2, settings: 0), .init(engine: 1, extensions: 1, settings: 1)] {
            XCTAssertNil(cache.current(key, generation: changed, now: now))
            XCTAssertTrue(cache.isStale(key, generation: changed, now: now))
        }
        // Age alone also ends authority; the copy stays available for display.
        XCTAssertNil(cache.current(key, generation: first, now: now.addingTimeInterval(DetailsCache.freshness)))
        XCTAssertNotNil(cache.snapshot(key))
        XCTAssertNil(cache.snapshot(.result(result("Missing"))))
        XCTAssertFalse(cache.isStale(.result(result("Missing")), generation: first))
    }

    func testDetailsCacheEvictsLeastRecentlyUsedAndKeepsOpenPages() {
        var cache = DetailsCache()
        let generation = DetailsCache.Generation(engine: 1, extensions: 1, settings: 0)
        let keys = (0..<DetailsCache.limit).map { DetailCoordinate.result(result("T\($0)")) }
        for key in keys { cache.store(series([episode(1)]), for: key, generation: generation) }
        // Touch the oldest so it is no longer the eviction candidate.
        XCTAssertNotNil(cache.current(keys[0], generation: generation))
        let open = keys[1]
        cache.store(series([episode(1)]), for: .result(result("New")), generation: generation, keeping: [open])
        XCTAssertEqual(cache.count, DetailsCache.limit)
        XCTAssertNotNil(cache.snapshot(keys[0]), "recently used")
        XCTAssertNotNil(cache.snapshot(open), "an open page keeps its entry")
        XCTAssertNil(cache.snapshot(keys[2]), "the least recently used closed page was evicted")
    }

    func testCategoryMapping() {
        XCTAssertEqual(MediaCategory.of("TvSeries"), .series)
        XCTAssertEqual(MediaCategory.of("AnimeMovie"), .anime)
        XCTAssertEqual(MediaCategory.of("OVA"), .anime)
        XCTAssertEqual(MediaCategory.of("AsianDrama"), .asianDrama)
        XCTAssertEqual(MediaCategory.of("Live"), .live)
        XCTAssertEqual(MediaCategory.of("Podcast"), .other)
        XCTAssertEqual(MediaTypeDisplay.name(for: "AnimeMovie"), "Anime Movie")
    }

    // MARK: New episodes

    func testEpisodeCountIgnoresDubDuplicates() {
        let details = series([episode(1, audio: "sub"), episode(1, audio: "dub"), episode(2, audio: "sub")])
        XCTAssertEqual(LibraryStore.episodeCount(details), 2)
    }

    func testFirstCheckIsABaselineThenNewEpisodesBadge() throws {
        let store = LibraryStore(inMemory: true)
        let v1 = series([episode(1), episode(2)])
        try store.upsertLibraryEntry(details: v1, watchType: .watching)
        XCTAssertEqual(try store.recordEpisodeCheck(details: v1), 0)

        let v2 = series([episode(1), episode(2), episode(3), episode(4)])
        XCTAssertEqual(try store.recordEpisodeCheck(details: v2), 2)
        XCTAssertEqual(try store.resumeItem(for: v2)?.newEpisodeCount, 2)

        try store.acknowledgeEpisodes(details: v2)
        XCTAssertEqual(try store.resumeItem(for: v2)?.newEpisodeCount, 0)
        XCTAssertEqual(try store.resumeItem(for: v2)?.knownEpisodeCount, 4)
    }

    func testOnlyWatchingSeriesAreDueForChecks() throws {
        let store = LibraryStore(inMemory: true)
        try store.upsertLibraryEntry(details: series([episode(1)], url: "u/a"), watchType: .watching)
        try store.upsertLibraryEntry(details: series([episode(1)], url: "u/b"), watchType: .completed)
        let due = try store.titlesDueForEpisodeCheck(olderThan: 60, limit: 10)
        XCTAssertEqual(due.map(\.providerURL), ["u/a"])
        try store.recordEpisodeCheck(details: series([episode(1)], url: "u/a"))
        XCTAssertTrue(try store.titlesDueForEpisodeCheck(olderThan: 60, limit: 10).isEmpty)
    }

    func testEpisodeCheckCannotWriteAfterSwitchAwayAndBack() async throws {
        let store = LibraryStore(inMemory: true)
        let initial = series([episode(1)])
        try store.upsertLibraryEntry(details: initial, watchType: .watching)
        let original = try store.captureProfileOperation()
        let preferences = UserPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        preferences.checkForNewEpisodes = true
        var pending: CheckedContinuation<DetailsDto, Error>?
        let checker = EpisodeUpdateChecker(library: store, preferences: preferences, spacing: .zero,
            authorization: { 0 }, loadDetails: { _, _ in
                try await withCheckedThrowingContinuation { pending = $0 }
            })
        let run = Task { await checker.runOnce(canCheck: { true }, engineGeneration: { 1 }, reportError: { XCTFail($0) }) }
        await waitForEpisodeRequest { pending != nil }
        try store.activateProfileStore(named: "fixture-other")
        XCTAssertFalse(store.owns(original))
        try store.activateProfileStore(named: nil)
        XCTAssertFalse(store.owns(original), "Returning to the same owner must not revive an operation")
        pending?.resume(returning: series([episode(1), episode(2)]))
        await run.value
        XCTAssertNil(try store.resumeItem(for: initial)?.lastEpisodeCheck)
        XCTAssertFalse(checker.isRunning)
    }

    func testEpisodeCheckRejectsEngineReplacementLockCycleAndCancellation() async throws {
        for invalidation in 0..<3 {
            let store = LibraryStore(inMemory: true)
            let initial = series([episode(1)])
            try store.upsertLibraryEntry(details: initial, watchType: .watching)
            let preferences = UserPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
            preferences.checkForNewEpisodes = true
            let state = EpisodeCheckAuthorization()
            var pending: CheckedContinuation<DetailsDto, Error>?
            let checker = EpisodeUpdateChecker(library: store, preferences: preferences, spacing: .zero,
                authorization: { state.authorization }, loadDetails: { _, _ in
                    try await withCheckedThrowingContinuation { pending = $0 }
                })
            let run = Task { await checker.runOnce(canCheck: { true }, engineGeneration: { state.engine }, reportError: { XCTFail($0) }) }
            await waitForEpisodeRequest { pending != nil }
            switch invalidation {
            case 0: state.engine += 1
            case 1: state.authorization = nil; state.authorization = 1
            default: checker.cancelCurrentRun()
            }
            pending?.resume(returning: series([episode(1), episode(2)]))
            await run.value
            XCTAssertNil(try store.resumeItem(for: initial)?.lastEpisodeCheck)
            XCTAssertFalse(checker.isRunning)
        }
    }

    func testEpisodeNotificationPermissionCannotPublishAfterProfileSwitch() async throws {
        let store = LibraryStore(inMemory: true)
        let initial = series([episode(1)])
        try store.upsertLibraryEntry(details: initial, watchType: .watching)
        store.mutationClock = { .distantPast }
        try store.recordEpisodeCheck(details: initial)
        let preferences = UserPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        preferences.checkForNewEpisodes = true
        preferences.notifyNewEpisodes = true
        var permission: CheckedContinuation<Bool, Never>?
        var delivered = 0
        let updated = series([episode(1), episode(2)])
        let checker = EpisodeUpdateChecker(library: store, preferences: preferences, spacing: .zero,
            authorization: { 0 }, loadDetails: { _, _ in updated },
            requestNotificationAuthorization: { await withCheckedContinuation { permission = $0 } },
            deliverNotification: { _ in delivered += 1 })
        let run = Task { await checker.runOnce(canCheck: { true }, engineGeneration: { 1 }, reportError: { XCTFail($0) }) }
        await waitForEpisodeRequest { permission != nil }
        try store.activateProfileStore(named: "fixture-other")
        permission?.resume(returning: true)
        await run.value
        XCTAssertEqual(delivered, 0)
    }

    func testEpisodeCheckUsesCapturedTitleAndRejectsConcurrentBatch() async throws {
        let store = LibraryStore(inMemory: true)
        let initial = series([episode(1)])
        try store.upsertLibraryEntry(details: initial, watchType: .watching)
        let preferences = UserPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        preferences.checkForNewEpisodes = true
        var pending: CheckedContinuation<DetailsDto, Error>?
        var requests = 0
        let checker = EpisodeUpdateChecker(library: store, preferences: preferences, spacing: .zero,
            authorization: { 0 }, loadDetails: { _, _ in
                requests += 1
                return try await withCheckedThrowingContinuation { pending = $0 }
            })
        let run = Task { await checker.runOnce(canCheck: { true }, engineGeneration: { 1 }, reportError: { XCTFail($0) }) }
        await waitForEpisodeRequest { pending != nil }
        await checker.runOnce(canCheck: { true }, engineGeneration: { 1 }, reportError: { XCTFail($0) })
        pending?.resume(returning: series([episode(1), episode(2)], url: "u/other"))
        await run.value
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(try store.resumeItem(for: initial)?.knownEpisodeCount, 2)
        XCTAssertNil(try store.resumeItem(for: series([], url: "u/other")))
    }

    @MainActor
    private final class EpisodeCheckAuthorization {
        var engine: UInt64 = 1
        var authorization: UInt64? = 0
    }

    private func waitForEpisodeRequest(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "Episode fixture did not reach its suspension boundary")
    }

    func testResumeExactEpisodeWinsBeforeEarlierCoordinateMatch() throws {
        let wrong = episode(2, audio: "dub"), exact = episode(2, audio: "sub")
        let details = series([wrong, exact])
        XCTAssertEqual(try LibraryStore.resumeEpisode(in: details, data: exact.data, season: 1, episode: 2), exact)
        XCTAssertThrowsError(try LibraryStore.resumeEpisode(in: details, data: "missing", season: 1, episode: 2))
        XCTAssertThrowsError(try LibraryStore.resumeEpisode(in: series([episode(1)]), data: nil, season: nil, episode: nil))
        XCTAssertEqual(try LibraryStore.resumeEpisode(in: series([exact]), data: "rotated", season: 1, episode: 2), exact)
        XCTAssertThrowsError(try LibraryStore.resumeEpisode(in: series([]), data: exact.data, season: 1, episode: 2))
        // A rotated link falls back to coordinates only within the saved edition.
        XCTAssertEqual(try LibraryStore.resumeEpisode(in: details, data: "rotated", season: 1, episode: 2, audio: "sub"), exact)
        XCTAssertEqual(try LibraryStore.resumeEpisode(in: details, data: "rotated", season: 1, episode: 2, audio: "dub"), wrong)
        XCTAssertThrowsError(try LibraryStore.resumeEpisode(in: details, data: "rotated", season: 1, episode: 2))
        XCTAssertThrowsError(try LibraryStore.resumeEpisode(in: series([wrong]), data: "rotated", season: 1, episode: 2, audio: "sub"),
                             "the other edition is not the saved episode")
    }

    func testPendingResumeRejectsProfileSwitchAndStaleFailure() async throws {
        for returnsError in [false, true] {
            let store = LibraryStore(inMemory: true)
            let details = series([episode(1)])
            try store.recordProgress(details: details, episode: details.episodes[0], progressSeconds: 100, totalDurationSeconds: 1000)
            let item = try XCTUnwrap(store.resumeItem(for: details))
            let request = try store.resumeRequest(for: item)
            var pending: CheckedContinuation<DetailsDto, Error>?
            var plays = 0, errors = 0
            let run = Task { await store.resume(request: request, isAuthorized: { true },
                loadDetails: { _, _ in try await withCheckedThrowingContinuation { pending = $0 } },
                play: { _, _, _ in plays += 1 }, reportError: { _ in errors += 1 }) }
            await waitForEpisodeRequest { pending != nil }
            try store.activateProfileStore(named: "fixture-other")
            try store.activateProfileStore(named: nil)
            XCTAssertThrowsError(try store.resumeRequest(for: item), "Old displayed model ownership must not be recaptured")
            if returnsError { pending?.resume(throwing: URLError(.notConnectedToInternet)) }
            else { pending?.resume(returning: details) }
            await run.value
            XCTAssertEqual(plays, 0); XCTAssertEqual(errors, 0)
        }
    }

    func testResumeRejectsAuthorizationChangeCancellationAndPrivacyClear() async throws {
        for invalidation in 0..<3 {
            let store = LibraryStore(inMemory: true)
            let details = series([episode(1)])
            try store.recordProgress(details: details, episode: details.episodes[0], progressSeconds: 100, totalDurationSeconds: 1000)
            let request = try store.resumeRequest(for: XCTUnwrap(store.resumeItem(for: details)))
            let state = EpisodeCheckAuthorization()
            var pending: CheckedContinuation<DetailsDto, Error>?
            var plays = 0
            let run = Task { await store.resume(request: request, isAuthorized: { state.authorization == 0 },
                loadDetails: { _, _ in try await withCheckedThrowingContinuation { pending = $0 } },
                play: { _, _, _ in plays += 1 }, reportError: { XCTFail($0) }) }
            await waitForEpisodeRequest { pending != nil }
            switch invalidation {
            case 0: state.authorization = 1
            case 1: run.cancel()
            default: try store.removeProgress(id: request.itemID)
            }
            pending?.resume(returning: details)
            await run.value
            XCTAssertEqual(plays, 0)
        }
    }

    func testResumeUsesValueSnapshotAndReportsUnavailableEpisode() async throws {
        let store = LibraryStore(inMemory: true)
        let details = series([episode(1, audio: "sub")])
        try store.recordProgress(details: details, episode: details.episodes[0], progressSeconds: 100, totalDurationSeconds: 1000)
        let request = try store.resumeRequest(for: XCTUnwrap(store.resumeItem(for: details)))
        var played: EpisodeDto?, position: Double?, errors = 0
        await store.resume(request: request, isAuthorized: { true }, loadDetails: { _, _ in details },
            play: { _, episode, at in played = episode; position = at }, reportError: { XCTFail($0) })
        XCTAssertEqual(played, details.episodes[0]); XCTAssertEqual(position, 100)
        await store.resume(request: request, isAuthorized: { true }, loadDetails: { _, _ in self.series([]) },
            play: { _, _, _ in XCTFail("Missing episode entered movie playback") }, reportError: { _ in errors += 1 })
        XCTAssertEqual(errors, 1)
        let epoch = try store.captureProfileOperation()
        try store.setUserNote(details: details, note: "Independent edit")
        XCTAssertTrue(store.owns(epoch), "Unrelated metadata edits do not invalidate profile ownership")
    }

    func testCancellingPlaybackRequestClosesItsPendingResolution() async {
        let player = PlayerViewModel()
        var stream: AsyncThrowingStream<LinksStreamEventDto, Error>.Continuation?
        player.linksStream = { _, _ in AsyncThrowingStream { stream = $0 } }
        defer { stream?.finish(); player.close() }
        let details = series([episode(1)])
        let run = Task { await player.play(details: details, episode: details.episodes[0], preferences: .shared) }
        await waitForEpisodeRequest { stream != nil }
        XCTAssertEqual(player.phase, .resolving)
        run.cancel()
        await run.value
        await waitForEpisodeRequest { player.phase == .idle }
        XCTAssertNil(player.error)
        XCTAssertNil(player.session)
    }

    func testCancelledOldPlaybackCannotCloseReplacementSession() async {
        let player = PlayerViewModel()
        var stream: AsyncThrowingStream<LinksStreamEventDto, Error>.Continuation?
        player.linksStream = { _, _ in AsyncThrowingStream { stream = $0 } }
        defer { stream?.finish(); player.close() }
        let details = series([episode(1), episode(2)])
        let run = Task { await player.play(details: details, episode: details.episodes[0], preferences: .shared) }
        await waitForEpisodeRequest { stream != nil }
        run.cancel()
        player.playResolved(details: details, episode: details.episodes[1],
            links: [.init(url: "https://fixture.test/video", name: "fixture", source: "fixture", quality: 0, type: "video")],
            persistsProgress: false)
        await run.value
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(player.session?.episode, details.episodes[1])
        XCTAssertNotEqual(player.phase, .idle)
    }

    func testDownloadedResumeUsesUUIDAndFileWithoutProviderRequest() async throws {
        let store = LibraryStore(inMemory: true)
        let file = try localResumeFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let (id, request) = try localResumeFixture(store: store, file: file, savedEpisode: episode(1))
        var played: DetailsDto?, position: Double?
        await store.resume(request: request, isAuthorized: { true },
            loadDetails: { _, _ in XCTFail("Local resume contacted a provider"); throw URLError(.notConnectedToInternet) },
            play: { details, episode, at in played = details; position = at; XCTAssertNil(episode) },
            reportError: { XCTFail($0) })
        XCTAssertEqual(played?.id, LibraryIdentity.localDownload(id))
        XCTAssertEqual(played?.localDownloadID, id)
        XCTAssertNil(played?.providerId)
        XCTAssertEqual(played?.url, file.path)
        XCTAssertEqual(position, 100)
    }

    func testDownloadedResumeRejectsMissingMismatchedIncompleteAndNonFileRecords() async throws {
        for failure in 0..<6 {
            let store = LibraryStore(inMemory: true)
            let file = try localResumeFile()
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            let (id, request) = try localResumeFixture(store: store, file: file)
            switch failure {
            case 0: try store.deleteDownloadRecord(id: id)
            case 1:
                try store.upsertDownloadRecord(id: id, title: "Local", episodeLabel: "", provider: "P",
                    episodeData: "", destinationPath: file.path + ".moved", statusRaw: 4)
            case 2:
                try store.upsertDownloadRecord(id: id, title: "Local", episodeLabel: "", provider: "P",
                    episodeData: "", destinationPath: file.path, statusRaw: 3)
            case 3: try FileManager.default.removeItem(at: file)
            case 4:
                try store.deleteDownloadRecord(id: id)
                try store.upsertDownloadRecord(id: UUID(), title: "Other", episodeLabel: "", provider: "P",
                    episodeData: "", destinationPath: file.path, statusRaw: 4)
            default:
                try FileManager.default.removeItem(at: file)
                try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            }
            var errors = 0
            await store.resume(request: request, isAuthorized: { true },
                loadDetails: { _, _ in XCTFail("Invalid local record contacted a provider"); throw URLError(.badURL) },
                play: { _, _, _ in XCTFail("Invalid local record started playback") },
                reportError: { _ in errors += 1 })
            XCTAssertEqual(errors, 1, "Invalid record must report an actionable error")
        }
    }

    func testProviderCannotClaimDownloadedPlaybackPrivileges() async throws {
        let store = LibraryStore(inMemory: true)
        let details = series([episode(1)])
        try store.recordProgress(details: details, episode: details.episodes[0], progressSeconds: 100, totalDurationSeconds: 1000)
        let request = try store.resumeRequest(for: XCTUnwrap(store.resumeItem(for: details)))
        let file = try localResumeFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let localStore = LibraryStore(inMemory: true)
        let (id, _) = try localResumeFixture(store: localStore, file: file)
        let forged = localStore.detailsPreview(for: try XCTUnwrap(localStore.item(id: LibraryIdentity.localDownload(id))))
        var errors = 0
        await store.resume(request: request, isAuthorized: { true }, loadDetails: { _, _ in forged },
            play: { _, _, _ in XCTFail("Provider response acquired local privileges") }, reportError: { _ in errors += 1 })
        XCTAssertEqual(errors, 1)
    }

    func testDownloadedContinueWatchingStartsAuthorizedLocalSessionWithoutEngine() async throws {
        let store = LibraryStore.shared
        let app = AppState.shared
        let previousError = app.transientError
        app.dismissTransientError()
        let file = try localResumeFile()
        let (id, _) = try localResumeFixture(store: store, file: file)
        defer {
            app.player.close()
            app.transientError = previousError
            store.cancelProfileOperations()
            try? store.removeDownloadedEntry(downloadID: id, provider: "P", url: file.path)
            try? store.deleteDownloadRecord(id: id)
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        XCTAssertFalse(app.isEngineBootstrapped)
        store.startResume(item: try XCTUnwrap(store.item(id: LibraryIdentity.localDownload(id))), appState: app)
        await waitForEpisodeRequest { app.player.session != nil || app.transientError != nil }
        XCTAssertNil(app.transientError)
        XCTAssertEqual(app.player.session?.details.localDownloadID, id)
        XCTAssertEqual(app.player.loadRequest?.resource.origin, .authorizedLocal)
        XCTAssertEqual(app.player.loadRequest?.url, file.path)
        XCTAssertEqual(app.player.loadRequest?.startAt, 100)
    }

    func testRemoteMovieResumeStillUsesProviderAndSavedPosition() async throws {
        let store = LibraryStore(inMemory: true)
        let movie = DetailsDto(provider: "P", url: "https://fixture.test/movie", name: "Movie", type: "Movie",
            posterUrl: nil, backgroundPosterUrl: nil, logoUrl: nil, plot: nil, year: nil,
            durationMinutes: nil, score: nil, tags: [], actors: [], contentRating: nil,
            comingSoon: false, episodes: [], movieData: "opaque-provider-data")
        try store.recordProgress(details: movie, episode: nil, progressSeconds: 100, totalDurationSeconds: 1000)
        let request = try store.resumeRequest(for: XCTUnwrap(store.resumeItem(for: movie)))
        var requested = 0, played = 0
        await store.resume(request: request, isAuthorized: { true },
            loadDetails: { provider, url in
                requested += 1; XCTAssertEqual(provider, movie.provider); XCTAssertEqual(url, movie.url)
                return movie
            }, play: { details, episode, position in
                played += 1; XCTAssertEqual(details.id, movie.id); XCTAssertNil(episode); XCTAssertEqual(position, 100)
            }, reportError: { XCTFail($0) })
        XCTAssertEqual(requested, 1); XCTAssertEqual(played, 1)
    }

    private func localResumeFixture(store: LibraryStore, file: URL, savedEpisode: EpisodeDto? = nil) throws -> (UUID, LibraryStore.ResumeRequest) {
        let id = UUID()
        try store.upsertDownloadRecord(id: id, title: "Local", episodeLabel: "", provider: "P",
            episodeData: "", destinationPath: file.path, statusRaw: 4)
        try store.markDownloaded(downloadID: id, provider: "P", url: file.path, title: "Local")
        let item = try XCTUnwrap(store.item(id: LibraryIdentity.localDownload(id)))
        let details = store.detailsPreview(for: item)
        try store.recordProgress(details: details, episode: savedEpisode, progressSeconds: 100, totalDurationSeconds: 1000)
        return (id, try store.resumeRequest(for: XCTUnwrap(store.item(id: item.id))))
    }

    private func localResumeFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("local-resume-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("clip.wav")
        // Valid mono 8 kHz PCM WAV with sixteen silent samples. This fixture
        // checks routing/session ownership, not decoded playback quality.
        var bytes = Data([82,73,70,70,68,0,0,0,87,65,86,69,102,109,116,32,
            16,0,0,0,1,0,1,0,64,31,0,0,128,62,0,0,2,0,16,0,100,97,116,97,32,0,0,0])
        bytes.append(Data(repeating: 0, count: 32))
        try bytes.write(to: file)
        return file
    }

    // MARK: Notes, rating, bulk

    func testNotesAndRatingPersistAndClamp() throws {
        let store = LibraryStore(inMemory: true)
        let details = series([], url: "u/n")
        try store.setUserRating(details: details, rating: 9)
        try store.setUserNote(details: details, note: "  rewatch S2  ")
        XCTAssertEqual(try store.resumeItem(for: details)?.userRating, 5)
        XCTAssertEqual(try store.resumeItem(for: details)?.userNote, "rewatch S2")
        try store.setUserNote(details: details, note: "   ")
        XCTAssertNil(try store.resumeItem(for: details)?.userNote)
    }

    func testBulkStatusChangeAndRemove() throws {
        let store = LibraryStore(inMemory: true)
        let a = series([], url: "u/1"), b = series([], url: "u/2")
        try store.upsertLibraryEntry(details: a, watchType: .planToWatch)
        try store.upsertLibraryEntry(details: b, watchType: .planToWatch)
        let ids: Set<String> = [LibraryStore.itemID(for: a), LibraryStore.itemID(for: b)]
        try store.setWatchType(itemIDs: ids, watchType: .onHold)
        XCTAssertEqual(try store.items(withWatchType: .onHold).count, 2)
        try store.setWatchType(itemIDs: ids, watchType: nil)
        XCTAssertTrue(try store.allEntries().isEmpty)
    }

    func testLibrarySortAndNoteSearch() throws {
        let store = LibraryStore(inMemory: true)
        let a = series([], url: "u/alpha"), b = series([], url: "u/beta")
        try store.upsertLibraryEntry(details: a, watchType: .watching)
        try store.upsertLibraryEntry(details: b, watchType: .watching)
        try store.setUserRating(details: b, rating: 4)
        try store.setUserNote(details: a, note: "cozy mystery")
        let items = try store.items(withWatchType: .watching)
        XCTAssertEqual(LibraryView.filterAndSort(items, query: "", order: .rating).first?.providerURL, "u/beta")
        XCTAssertEqual(LibraryView.filterAndSort(items, query: "mystery", order: .alphabetical).map(\.providerURL), ["u/alpha"])
    }

    func testLibrarySortsByReleaseYearAndDirection() throws {
        let store = LibraryStore(inMemory: true)
        func movie(_ url: String, year: Int?) -> DetailsDto {
            DetailsDto(provider: "P", url: url, name: url, type: "Movie", posterUrl: nil, backgroundPosterUrl: nil, logoUrl: nil,
                       plot: nil, year: year, durationMinutes: nil, score: nil, tags: [], actors: [], contentRating: nil,
                       comingSoon: false, episodes: [], movieData: nil)
        }
        try store.upsertLibraryEntry(details: movie("u/old", year: 1999), watchType: .watching)
        try store.upsertLibraryEntry(details: movie("u/unknown", year: nil), watchType: .watching)
        try store.upsertLibraryEntry(details: movie("u/new", year: 2024), watchType: .watching)
        var items = try store.items(withWatchType: .watching)
        XCTAssertEqual(LibraryView.filterAndSort(items, query: "", order: .releaseYear).map(\.providerURL), ["u/new", "u/old", "u/unknown"])
        XCTAssertEqual(LibraryView.filterAndSort(items, query: "", order: .releaseYear, reversed: true).map(\.providerURL),
                       ["u/old", "u/new", "u/unknown"], "titles without a year stay last")
        XCTAssertEqual(LibraryView.filterAndSort(items, query: "", order: .alphabetical, reversed: true).map(\.providerURL),
                       ["u/unknown", "u/old", "u/new"])
        XCTAssertEqual(LibraryView.filterAndSort(items, query: "", order: .dateAdded).first?.providerURL, "u/new")
        XCTAssertEqual(LibraryView.filterAndSort(items, query: "", order: .dateAdded, reversed: true).first?.providerURL, "u/old")

        // Opening the title later fills in a year it was filed without.
        try store.acknowledgeEpisodes(details: movie("u/unknown", year: 2030))
        items = try store.items(withWatchType: .watching)
        XCTAssertEqual(LibraryView.filterAndSort(items, query: "", order: .releaseYear).first?.providerURL, "u/unknown")
    }

    func testCustomOrderIsSavedPerCollectionAndNewTitlesLead() throws {
        let store = LibraryStore(inMemory: true)
        let a = series([], url: "u/a"), b = series([], url: "u/b"), c = series([], url: "u/c")
        for details in [a, b, c] { try store.upsertLibraryEntry(details: details, watchType: .planToWatch) }
        func ids(_ collection: LibraryCollection, _ items: [StoredMediaItem]) -> [String] {
            var options = LibraryViewOptions()
            options.sort = .custom
            return LibraryView.arranged(items, options: options, collection: collection).map(\.providerURL)
        }
        let shown = try store.items(withWatchType: .planToWatch).map(\.id)
        let idA = LibraryStore.itemID(for: a), idC = LibraryStore.itemID(for: c)
        let order = try XCTUnwrap(LibraryView.reordered(shown, moving: shown[2], onto: shown[0]))
        XCTAssertEqual(order, [shown[2], shown[0], shown[1]])
        XCTAssertEqual(LibraryView.reordered(shown, moving: shown[0], onto: shown[2]), [shown[1], shown[2], shown[0]])
        XCTAssertNil(LibraryView.reordered(shown, moving: idC, onto: idC))
        let activity = try store.items(withWatchType: .planToWatch).map(\.lastUpdated)
        try store.setCustomOrder(itemIDs: [idC, idA, LibraryStore.itemID(for: b)], favorites: false)
        XCTAssertEqual(ids(.planToWatch, try store.items(withWatchType: .planToWatch)), ["u/c", "u/a", "u/b"])
        XCTAssertEqual(try store.items(withWatchType: .planToWatch).map(\.lastUpdated), activity, "arranging is not activity")

        // A title added afterwards has no place yet and leads.
        let d = series([], url: "u/d")
        try store.upsertLibraryEntry(details: d, watchType: .planToWatch)
        XCTAssertEqual(ids(.planToWatch, try store.items(withWatchType: .planToWatch)), ["u/d", "u/c", "u/a", "u/b"])

        // Favorites keep their own arrangement; moving collections forgets the old place.
        try store.toggleFavorite(details: a)
        try store.toggleFavorite(details: b)
        try store.setCustomOrder(itemIDs: [LibraryStore.itemID(for: b), idA], favorites: true)
        XCTAssertEqual(ids(.favorites, try store.favorites), ["u/b", "u/a"])
        XCTAssertEqual(ids(.planToWatch, try store.items(withWatchType: .planToWatch)), ["u/d", "u/c", "u/a", "u/b"])
        try store.upsertLibraryEntry(details: a, watchType: .watching)
        XCTAssertNil(try store.items(withWatchType: .watching).first?.sortPosition)
        XCTAssertEqual(ids(.favorites, try store.favorites), ["u/b", "u/a"])
    }

    func testLibraryViewOptionsAndHomeShelfPersist() throws {
        let suite = UserDefaults(suiteName: UUID().uuidString)!
        let preferences = UserPreferences(defaults: suite)
        XCTAssertEqual(preferences.homeShelf, .collection(.planToWatch))
        XCTAssertNil(preferences.libraryViewOptions[LibraryCollection.watching.rawValue])
        preferences.homeShelf = .collection(.completed)
        var options = LibraryViewOptions()
        options.sort = .releaseYear
        options.reversed = true
        options.category = MediaCategory.anime.rawValue
        options.provider = "P"
        preferences.libraryViewOptions[LibraryCollection.watching.rawValue] = options

        let reloaded = UserPreferences(defaults: suite)
        XCTAssertEqual(reloaded.homeShelf, .collection(.completed))
        reloaded.homeShelf = .collection(.favorites)
        XCTAssertEqual(UserPreferences(defaults: suite).homeShelf, .collection(.favorites))
        reloaded.homeShelf = .page(id: "P1")
        XCTAssertEqual(UserPreferences(defaults: suite).homeShelf, .page(id: "P1"))
        // Earlier versions stored a WatchType raw value; unknown values fall back.
        suite.set(WatchType.onHold.rawValue, forKey: "homeShelf")
        XCTAssertEqual(UserPreferences(defaults: suite).homeShelf, .collection(.onHold))
        suite.set("page:", forKey: "homeShelf")
        XCTAssertEqual(UserPreferences(defaults: suite).homeShelf, .default)
        XCTAssertEqual(reloaded.libraryViewOptions[LibraryCollection.watching.rawValue], options)
        XCTAssertNil(reloaded.libraryViewOptions[LibraryCollection.favorites.rawValue], "each collection keeps its own")

        // A sort this build does not know falls back instead of dropping everything.
        suite.set(Data(#"{"watching":{"sort":"future","reversed":true,"provider":"P"}}"#.utf8), forKey: "libraryViewOptions")
        let tolerant = UserPreferences(defaults: suite).libraryViewOptions["watching"]
        XCTAssertEqual(tolerant?.sort, .recentActivity)
        XCTAssertEqual(tolerant?.reversed, true)
        XCTAssertEqual(tolerant?.provider, "P")
    }

    // MARK: History

    func testHistoryGroupsByDayMostRecentFirst() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        func row(_ id: String, _ date: Date) -> HistoryView.Row {
            HistoryView.Row(id: id, itemID: id, title: id, posterURL: nil, provider: "P", providerID: nil, providerURL: "u", label: nil, fraction: nil, watched: false, updatedAt: date)
        }
        let groups = HistoryView.groupedByDay([row("a", now), row("b", now), row("c", yesterday)], calendar: calendar)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].rows.map(\.id), ["a", "b"])
        XCTAssertEqual(groups[1].rows.map(\.id), ["c"])
    }

    func testPreviewForSearchResultCarriesIdentity() {
        let preview = LibraryStore.shared.detailsPreview(for: result("X", provider: "Prov", type: "Anime"))
        XCTAssertEqual(LibraryStore.itemID(for: preview), "Prov|u/X")
        XCTAssertEqual(preview.type, "Anime")
    }
}


/// Holds each homepage request until the test releases it.
@MainActor
private final class HomeGate {
    private var waiting: [String: [CheckedContinuation<HomePageDto, Error>]] = [:]
    nonisolated var loader: DiscoverStore.HomeLoader {
        { [self] provider, page in
            try await withCheckedThrowingContinuation { continuation in
                Task { @MainActor in self.waiting["\(provider)#\(page)", default: []].append(continuation) }
            }
        }
    }
    func isWaiting(_ provider: String, _ page: Int) -> Bool { !(waiting["\(provider)#\(page)"] ?? []).isEmpty }
    func finish(_ provider: String, _ page: Int, _ home: HomePageDto) {
        guard var queue = waiting["\(provider)#\(page)"], !queue.isEmpty else { return XCTFail("no pending \(provider) page \(page)") }
        queue.removeFirst().resume(returning: home)
        waiting["\(provider)#\(page)"] = queue
    }
}
