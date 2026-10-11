import Synchronization
import XCTest
import CoreSpotlight
import MediaPlayer
@testable import CloudStream

/// Offline-Features-Plan Phase 9: deep links, external players, Spotlight.
@MainActor
final class SystemIntegrationTests: XCTestCase {
    private func route(_ string: String) -> DeepLinkRoute {
        DeepLinkRouter.route(URL(string: string)!)
    }

    func testRepositorySchemesStillAddRepositories() {
        XCTAssertEqual(route("cloudstreamrepo://example.com/repo.json"), .addRepository("https://example.com/repo.json"))
        XCTAssertEqual(route("cs3://example.com/r.json"), .addRepository("https://example.com/r.json"))
    }

    func testSearchRoutes() {
        XCTAssertEqual(route("cloudstreamapp://search?q=Frieren%20S2"), .search("Frieren S2"))
        XCTAssertEqual(route("cloudstreamapp://search"), .navigate(.search))
        XCTAssertEqual(route("cloudstreamapp://Frieren"), .search("Frieren"), "legacy host-as-query form keeps working")
        XCTAssertEqual(route("cloudstreamplayer:///Dune"), .search("Dune"))
    }

    func testOpenContinueAndNavigateRoutes() {
        XCTAssertEqual(route("cloudstreamapp://open?provider=Prov&url=https%3A%2F%2Fsite%2Fx%3Fa%3D1"),
                       .openTitle(provider: "Prov", url: "https://site/x?a=1"))
        XCTAssertEqual(route("cloudstreamapp://open?provider=Prov"), .ignored)
        XCTAssertEqual(route("cloudstreamapp://continue"), .continueWatching)
        XCTAssertEqual(route("cloudstreamapp://history"), .navigate(.history))
        XCTAssertEqual(route("https://example.com"), .ignored)
    }

    func testTitleURLRoundTrips() throws {
        let url = try XCTUnwrap(DeepLinkRouter.titleURL(provider: "P & Q", url: "https://s/a?b=c&d=e"))
        XCTAssertEqual(DeepLinkRouter.route(url), .openTitle(provider: "P & Q", url: "https://s/a?b=c&d=e"))
    }

    func testOverlongLinksAreIgnored() {
        XCTAssertEqual(route("cloudstreamapp://search?q=" + String(repeating: "a", count: 5000)), .ignored)
    }

    /// Audit-Fix M8: Keychain reads can block, so resending credentials after
    /// an engine start never reads them on the main actor.
    func testCredentialResendReadsTheKeychainOffTheMainActor() async throws {
        let provider = "m8-\(UUID().uuidString):Provider"
        try ProviderCredentialStore.save("secret", for: provider)
        defer { ProviderCredentialStore.delete(for: provider) }
        let reads = Mutex<[Bool]>([])
        ProviderCredentialStore.readObserver.withLock { $0 = { let onMain = Thread.isMainThread; reads.withLock { $0.append(onMain) } } }
        defer { ProviderCredentialStore.readObserver.withLock { $0 = nil } }
        _ = await ProviderCredentialStore.resendAll(availableProviderIds: [provider])
        let observed = reads.withLock { $0 }
        XCTAssertGreaterThanOrEqual(observed.count, 2, "the stored IDs and the credential were read")
        XCTAssertFalse(observed.contains(true), "no Keychain read ran on the main thread")
    }

    func testLegacyImportFailureIsShownOncePerEngineGeneration() {
        // Q8: retried silently on later bootstrap passes, shown again only for a new engine.
        var notice = OncePerGeneration()
        XCTAssertTrue(notice.shouldShow(generation: 4))
        XCTAssertFalse(notice.shouldShow(generation: 4))
        XCTAssertFalse(notice.shouldShow(generation: 4))
        XCTAssertTrue(notice.shouldShow(generation: 5), "a restarted engine reports a failure that persists")
        XCTAssertFalse(notice.shouldShow(generation: 5))
        XCTAssertEqual(notice.shownGeneration, 5)
    }

    func testExternalPlayerArgumentsCarryHeaders() throws {
        XCTAssertThrowsError(try ExternalPlayer.mpv.arguments(url: "https://cdn/v.m3u8", headers: ["X-Token": "t"], title: nil, startAt: nil),
            "a header other than Referer/User-Agent never goes on argv")
        let headers = ["Referer": "https://ref/", "User-Agent": "UA/1"]
        let mpv = try ExternalPlayer.mpv.arguments(url: "https://cdn/v.m3u8", headers: headers, title: "Show", startAt: 125)
        let whitelist = "protocol_whitelist=%40%http,https,tls,tcp,crypto,httpproxy,data"
            + ",allowed_extensions=ALL,allowed_segment_extensions=ALL,extension_picky=0"
        XCTAssertEqual(mpv, ["--load-unsafe-playlists=no", "--demuxer-lavf-o=" + whitelist,
                             "--referrer=https://ref/", "--user-agent=UA/1",
                             "--force-media-title=Show", "--start=125", "--", "https://cdn/v.m3u8"])
        let iina = try ExternalPlayer.iina.arguments(url: "https://cdn/v.m3u8", headers: headers, title: nil, startAt: 0)
        XCTAssertEqual(iina.first, "https://cdn/v.m3u8")
        XCTAssertTrue(iina.contains("--mpv-referrer=https://ref/"))
        // A remote stream handed to an mpv-based player may only pull remote resources.
        XCTAssertTrue(iina.contains("--mpv-load-unsafe-playlists=no"))
        XCTAssertTrue(iina.contains("--mpv-demuxer-lavf-o=" + whitelist))
        XCTAssertTrue(ExternalPlayer.mpv.confinesNestedResources && ExternalPlayer.iina.confinesNestedResources)
        XCTAssertFalse(ExternalPlayer.vlc.confinesNestedResources || ExternalPlayer.quickTime.confinesNestedResources)
        // A file the user chose is theirs to open: no remote-only limits.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("external-\(UUID().uuidString).mp4")
        try Data([0]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let local = try ExternalPlayer.mpv.arguments(resource: .authorizedLocal(file), headers: [:], title: nil, startAt: nil)
        XCTAssertEqual(local, ["--", file.path])
        XCTAssertFalse(iina.contains { $0.hasPrefix("--mpv-start") }, "no start flag at the beginning")
        let vlc = try ExternalPlayer.vlc.arguments(url: "https://cdn/video.mp4", headers: headers, title: nil, startAt: nil)
        XCTAssertEqual(vlc.last, "https://cdn/video.mp4")
        XCTAssertTrue(vlc.contains("--http-user-agent=UA/1"))
    }

    func testStreamsWithHeadersAPlayerCantCarryGoThroughTheRelay() {
        let plain = StreamLinkDto(url: "https://a/b.mp4", name: "n", source: "s", quality: 720, type: "video")
        let referer = StreamLinkDto(url: "https://a/b.mp4", name: "n", source: "s", quality: 720, type: "video", headers: ["Referer": "x"])
        let secret = StreamLinkDto(url: "https://a/b.m3u8", name: "n", source: "s", quality: 720, type: "M3U8",
                                   headers: ["Cookie": "c=1", "X-Token": "t", "Referer": "x"])
        XCTAssertFalse(ExternalPlayer.quickTime.needsRelay(plain))
        XCTAssertTrue(ExternalPlayer.quickTime.needsRelay(referer), "QuickTime takes no headers at all")
        XCTAssertFalse(ExternalPlayer.mpv.needsRelay(referer), "Referer and User-Agent may go on the command line")
        for player in ExternalPlayer.allCases {
            XCTAssertTrue(player.needsRelay(secret), "\(player): cookies and unknown headers never go on argv")
            XCTAssertTrue(player.supports(secret), "\(player): offered, through the relay")
        }
        let edl = StreamLinkDto(url: "https://a/1.ts", name: "n", source: "s", quality: 720, type: "video",
                                headers: ["Cookie": "c=1"], isPlaylist: true, playlist: ["https://a/1.ts", "https://a/2.ts"])
        XCTAssertFalse(ExternalPlayer.mpv.supports(edl), "an EDL playlist with secrets cannot be relayed as one resource")
    }

    func testRelayedExternalArgumentsCarryNoHeaders() throws {
        let relayed = try ExternalPlayer.mpv.arguments(url: "http://127.0.0.1:50000/media/relay/" + String(repeating: "a", count: 64),
                                                     headers: [:], title: "Show", startAt: nil)
        XCTAssertFalse(relayed.contains { $0.contains("http-header-fields") || $0.contains("referrer") || $0.contains("Cookie") })
        XCTAssertEqual(relayed.last, "http://127.0.0.1:50000/media/relay/" + String(repeating: "a", count: 64))
    }

    func testSpotlightItemsSkipDownloadsAndDuplicates() {
        let item = StoredMediaItem(id: "P|u", title: "Show", providerName: "P", providerURL: "u", mediaType: "TvSeries", watchType: .watching)
        let download = StoredMediaItem(id: "P|local:/x", title: "File", providerName: "P", providerURL: "/x", mediaType: "Download")
        let items = SpotlightIndexer.searchableItems(for: [item, item, download])
        XCTAssertEqual(items.map(\.uniqueIdentifier), ["P|u"])
        XCTAssertEqual(items.first?.attributeSet.title, "Show")
        XCTAssertEqual(items.first?.attributeSet.contentDescription, "Watching · Series · P")
    }

    func testSpotlightSerializesOldProfileInsertionBeforeReplacement() async throws {
        let store = LibraryStore(inMemory: true)
        try addSpotlightTitle("A", store: store)
        let preferences = spotlightPreferences()
        let client = ControlledSpotlightIndex()
        client.holdIndex = true
        let indexer = SpotlightIndexer(library: store, preferences: preferences, client: client, debounce: .zero)
        let first = Task { await indexer.reindex() }
        await waitForSpotlight { client.indexPending != nil }
        try store.activateProfileStore(named: "fixture-b")
        try addSpotlightTitle("B", store: store)
        let second = Task { await indexer.reindex() }
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(client.events, ["remove", "index"], "The replacement cannot overlap the old OS insertion")
        client.holdIndex = false
        client.indexPending?.resume(); client.indexPending = nil
        await first.value; await second.value
        XCTAssertEqual(client.titles, ["B"])
        XCTAssertEqual(client.events, ["remove", "index", "remove", "index"])
        XCTAssertNil(indexer.lastFailure)
    }

    func testGlobalAppLockRemovesAndSuppressesSpotlightIndex() async throws {
        let store = LibraryStore(inMemory: true)
        try addSpotlightTitle("A", store: store)
        let preferences = spotlightPreferences()
        let client = ControlledSpotlightIndex()
        let indexer = SpotlightIndexer(library: store, preferences: preferences, client: client, debounce: .zero)
        await indexer.reindex()
        XCTAssertEqual(client.titles, ["A"])
        preferences.requireUnlock = true
        await indexer.reindex()
        XCTAssertTrue(client.titles.isEmpty, "with the app lock on, library titles are not searchable in Spotlight")
        try addSpotlightTitle("B", store: store)
        await indexer.reindex()
        XCTAssertTrue(client.titles.isEmpty, "nothing is indexed while the lock applies")
        preferences.requireUnlock = false
        await indexer.reindex()
        XCTAssertEqual(Set(client.titles), ["A", "B"])
    }

    func testSpotlightDisableRemovesLateInsertionAndDoesNotCacheSuccess() async throws {
        let store = LibraryStore(inMemory: true)
        try addSpotlightTitle("A", store: store)
        let preferences = spotlightPreferences()
        let client = ControlledSpotlightIndex()
        client.holdIndex = true
        let indexer = SpotlightIndexer(library: store, preferences: preferences, client: client)
        let first = Task { await indexer.reindex() }
        await waitForSpotlight { client.indexPending != nil }
        preferences.indexInSpotlight = false
        let removal = Task { await indexer.removeAll() }
        for _ in 0..<4 { await Task.yield() }
        client.holdIndex = false
        client.indexPending?.resume(); client.indexPending = nil
        await first.value; await removal.value
        XCTAssertTrue(client.titles.isEmpty)
        XCTAssertEqual(client.events, ["remove", "index", "remove"])
        preferences.indexInSpotlight = true
        await indexer.reindex()
        XCTAssertEqual(client.titles, ["A"], "A disabled generation must not suppress re-enable at the same library version")
    }

    func testSpotlightChecksOwnershipAfterDeletionBeforeInsertion() async throws {
        let store = LibraryStore(inMemory: true)
        try addSpotlightTitle("A", store: store)
        let client = ControlledSpotlightIndex()
        client.holdRemoval = true
        let indexer = SpotlightIndexer(library: store, preferences: spotlightPreferences(), client: client)
        let first = Task { await indexer.reindex() }
        await waitForSpotlight { client.removePending != nil }
        try store.activateProfileStore(named: "fixture-b")
        client.holdRemoval = false
        client.removePending?.resume(); client.removePending = nil
        await first.value
        XCTAssertEqual(client.events, ["remove"])
        XCTAssertTrue(client.titles.isEmpty)
    }

    func testSpotlightDirectStoreChangeCleansCompletedStaleInsertion() async throws {
        let store = LibraryStore(inMemory: true)
        try addSpotlightTitle("A", store: store)
        let client = ControlledSpotlightIndex()
        client.holdIndex = true
        let indexer = SpotlightIndexer(library: store, preferences: spotlightPreferences(), client: client)
        let first = Task { await indexer.reindex() }
        await waitForSpotlight { client.indexPending != nil }
        try store.activateProfileStore(named: "fixture-b")
        client.holdIndex = false
        client.indexPending?.resume(); client.indexPending = nil
        await first.value
        XCTAssertEqual(client.events, ["remove", "index", "remove"])
        XCTAssertTrue(client.titles.isEmpty)
    }

    func testSpotlightReadDeleteAndIndexFailuresRemainRetryable() async throws {
        for failure in 0..<3 {
            let store = LibraryStore(inMemory: true)
            try addSpotlightTitle("A", store: store)
            let client = ControlledSpotlightIndex()
            let indexer = SpotlightIndexer(library: store, preferences: spotlightPreferences(), client: client)
            switch failure {
            case 0: store.persistenceFault = { if $0 == .queryRead { throw URLError(.cannotOpenFile) } }
            case 1: client.failRemoval = true
            default: client.failIndex = true
            }
            await indexer.reindex()
            XCTAssertNotNil(indexer.lastFailure)
            store.persistenceFault = nil; client.failRemoval = false; client.failIndex = false
            await indexer.retry()
            XCTAssertNil(indexer.lastFailure)
            XCTAssertEqual(client.titles, ["A"])
            let events = client.events
            await indexer.reindex()
            XCTAssertEqual(client.events, events, "Only completed success suppresses an unchanged reindex")
        }
    }

    func testSpotlightNewReadFailureCannotBeErasedByOldInsertionSuccess() async throws {
        let store = LibraryStore(inMemory: true)
        try addSpotlightTitle("A", store: store)
        let client = ControlledSpotlightIndex()
        client.holdIndex = true
        let indexer = SpotlightIndexer(library: store, preferences: spotlightPreferences(), client: client)
        let first = Task { await indexer.reindex() }
        await waitForSpotlight { client.indexPending != nil }
        store.persistenceFault = { if $0 == .queryRead { throw URLError(.cannotOpenFile) } }
        let failed = Task { await indexer.reindex() }
        await waitForSpotlight { indexer.lastFailure != nil }
        client.holdIndex = false
        client.indexPending?.resume(); client.indexPending = nil
        await first.value; await failed.value
        XCTAssertNotNil(indexer.lastFailure, "Older success and cleanup cannot report a newer failed read as successful")
        XCTAssertTrue(client.titles.isEmpty)
        store.persistenceFault = nil
        await indexer.retry()
        XCTAssertNil(indexer.lastFailure)
        XCTAssertEqual(client.titles, ["A"])
    }

    func testSpotlightUnavailableScheduledOwnerClearsOldDomainAndRetainsRetry() async throws {
        let store = LibraryStore(inMemory: true)
        try addSpotlightTitle("A", store: store)
        let client = ControlledSpotlightIndex()
        let indexer = SpotlightIndexer(library: store, preferences: spotlightPreferences(), client: client)
        await indexer.reindex()
        XCTAssertEqual(client.titles, ["A"])
        store.suspendProfileAfterStartupFailure(URLError(.cannotOpenFile))
        indexer.scheduleReindex()
        await waitForSpotlight { client.titles.isEmpty }
        XCTAssertNotNil(indexer.lastFailure)
        try store.retryOpeningStores(profileStoreName: nil)
        await indexer.retry()
        XCTAssertNil(indexer.lastFailure)
        XCTAssertEqual(client.titles, ["A"])
    }

    func testSpotlightFailedRemovalCanRetryWhileDisabled() async {
        let preferences = spotlightPreferences()
        preferences.indexInSpotlight = false
        let client = ControlledSpotlightIndex()
        client.titles = ["A"]; client.failRemoval = true
        let indexer = SpotlightIndexer(library: LibraryStore(inMemory: true), preferences: preferences, client: client)
        await indexer.removeAll()
        XCTAssertNotNil(indexer.lastFailure)
        XCTAssertEqual(client.titles, ["A"])
        client.failRemoval = false
        await indexer.retry()
        XCTAssertNil(indexer.lastFailure)
        XCTAssertTrue(client.titles.isEmpty)
    }

    private func spotlightPreferences() -> UserPreferences {
        let suite = "spotlight-tests-" + UUID().uuidString
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let preferences = UserPreferences(defaults: UserDefaults(suiteName: suite)!)
        preferences.indexInSpotlight = true
        return preferences
    }
    private func addSpotlightTitle(_ name: String, store: LibraryStore) throws {
        let details = DetailsDto(provider: "P", url: "https://fixture.test/" + name, name: name, type: "Movie",
            posterUrl: nil, backgroundPosterUrl: nil, logoUrl: nil, plot: nil, year: nil,
            durationMinutes: nil, score: nil, tags: [], actors: [], contentRating: nil,
            comingSoon: false, episodes: [], movieData: "movie")
        try store.upsertLibraryEntry(details: details, watchType: .watching)
    }
    private func waitForSpotlight(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "Spotlight fixture did not reach the OS suspension boundary")
    }

    func testSuggestionQueryStaysOneExactValue() throws {
        for query in ["Tom & Jerry", "a=b&page=9", "1+1", "100% Wolf", "進撃の巨人 é", "x#y?z"] {
            let url = try XCTUnwrap(SearchSuggestionService.requestURL(query: query, apiKey: "k"))
            let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertEqual(items.map(\.name), ["api_key", "query", "include_adult", "page"], query)
            XCTAssertEqual(items[1].value, query)
            XCTAssertEqual(items[3].value, "1")
            XCTAssertFalse(url.query(percentEncoded: true)?.contains("+") ?? true, "a literal plus must not decode as a space")
            XCTAssertNil(url.fragment)
        }
        XCTAssertNil(SearchSuggestionService.requestURL(query: "q", apiKey: ""))
    }

    func testNowPlayingArtworkBelongsToCurrentSessionOnly() async {
        let gate = ArtworkGate()
        let service = NowPlayingService(loadArtwork: { await gate.image(for: $0) })
        addTeardownBlock { @MainActor in service.clearNowPlaying() }
        func update(_ title: String, _ url: String?) {
            service.updateNowPlaying(title: title, subtitle: nil, duration: 10, elapsed: 1, rate: 1, isPlaying: true, artworkURL: url)
        }
        update("A", "art://a")
        await waitForSpotlight { gate.isWaiting("art://a") }
        update("B", "art://b")
        await waitForSpotlight { gate.isWaiting("art://b") }
        gate.finish("art://a")
        for _ in 0..<8 { await Task.yield() }
        XCTAssertNil(service.publishedArtworkURL, "the previous title's artwork is not applied to the new session")
        update("B", "art://b")
        XCTAssertEqual(gate.requests, ["art://a", "art://b"], "the old completion must not release the newer fetch's ownership")
        gate.finish("art://b")
        await waitForSpotlight { service.publishedArtworkURL == "art://b" }

        update("C", "art://c")
        await waitForSpotlight { gate.isWaiting("art://c") }
        service.clearNowPlaying()
        gate.finish("art://c")
        for _ in 0..<8 { await Task.yield() }
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo, "a late image cannot restore cleared playback")
    }

    func testMenuBarLabel() {
        let item = StoredMediaItem(id: "P|u", title: "Show", providerName: "P", providerURL: "u", mediaType: "TvSeries")
        item.lastSeason = 2
        item.lastEpisode = 5
        item.progressSeconds = 600
        item.totalDurationSeconds = 1440
        XCTAssertEqual(CloudStreamMenuBarContent.label(for: item), "Show — S2 E5 (14m left)")
    }
}


@MainActor
private final class ControlledSpotlightIndex: SpotlightIndexClient {
    var events: [String] = []
    var titles: Set<String> = []
    var holdIndex = false, holdRemoval = false
    var failIndex = false, failRemoval = false
    var indexPending: CheckedContinuation<Void, Error>?
    var removePending: CheckedContinuation<Void, Error>?
    func removeLibrary() async throws {
        events.append("remove")
        if holdRemoval { try await withCheckedThrowingContinuation { removePending = $0 } }
        if failRemoval { throw URLError(.cannotRemoveFile) }
        titles.removeAll()
    }
    func index(_ items: [CSSearchableItem]) async throws {
        events.append("index")
        if holdIndex { try await withCheckedThrowingContinuation { indexPending = $0 } }
        titles.formUnion(items.compactMap { $0.attributeSet.title })
        if failIndex { throw URLError(.cannotWriteToFile) }
    }
}


@MainActor
private final class ArtworkGate {
    private var waiting: [String: CheckedContinuation<NSImage?, Never>] = [:]
    private(set) var requests: [String] = []
    func image(for url: String) async -> NSImage? {
        requests.append(url)
        return await withCheckedContinuation { waiting[url] = $0 }
    }
    func isWaiting(_ url: String) -> Bool { waiting[url] != nil }
    func finish(_ url: String) { waiting.removeValue(forKey: url)?.resume(returning: NSImage(size: NSSize(width: 2, height: 2))) }
}
