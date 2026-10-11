import XCTest
@testable import CloudStream

/// Per-episode watch history (Offline-Features-Plan Phase 1).
@MainActor
final class WatchHistoryTests: XCTestCase {
    private func episode(_ number: Int, season: Int = 1, audio: String? = nil) -> EpisodeDto {
        EpisodeDto(
            data: "ep-\(season)-\(number)-\(audio ?? "x")",
            name: "Episode \(number)",
            season: season,
            episode: number,
            posterUrl: nil,
            description: nil,
            score: nil,
            date: nil,
            runTimeMinutes: 24,
            audio: audio,
        )
    }

    private func series(_ episodes: [EpisodeDto]) -> DetailsDto {
        DetailsDto(
            provider: "prov",
            url: "u/series",
            name: "Series",
            type: "TvSeries",
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
            episodes: episodes,
            movieData: nil,
        )
    }

    private func movie() -> DetailsDto {
        DetailsDto(
            provider: "prov",
            url: "u/movie",
            name: "Movie",
            type: "Movie",
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
            movieData: "movie-data",
        )
    }

    private func makeStore() -> LibraryStore {
        let store = LibraryStore(inMemory: true)
        store.autoUpdateLibraryStatusOverride = true
        return store
    }

    // MARK: Policy

    func testWatchedThresholdFraction() {
        XCTAssertFalse(WatchProgressPolicy.isWatched(position: 80, duration: 100))
        XCTAssertTrue(WatchProgressPolicy.isWatched(position: 90, duration: 100))
        XCTAssertFalse(WatchProgressPolicy.isWatched(position: 0, duration: 0))
    }

    func testCreditsWindowCountsAsWatchedForLongRuntimes() {
        // 24-min episode, 100 s left: inside the credits window.
        XCTAssertTrue(WatchProgressPolicy.isWatched(position: 1340, duration: 1440))
        // A 5-minute short is below the runtime floor: fraction rules alone.
        XCTAssertFalse(WatchProgressPolicy.isWatched(position: 200, duration: 300))
    }

    func testTimestampFormatting() {
        XCTAssertEqual(WatchProgressPolicy.timestamp(2052), "34:12")
        XCTAssertEqual(WatchProgressPolicy.timestamp(3727), "1:02:07")
        XCTAssertEqual(WatchProgressPolicy.remainingLabel(30), "<1m left")
        XCTAssertEqual(WatchProgressPolicy.remainingLabel(3900), "1h 5m left")
    }

    // MARK: Store

    func testRecordingProgressCreatesEpisodeRow() throws {
        let store = makeStore()
        let eps = [episode(1), episode(2)]
        let dto = series(eps)
        try store.recordProgress(details: dto, episode: eps[0], progressSeconds: 300, totalDurationSeconds: 1440)

        let progress = try store.episodeProgress(details: dto)
        XCTAssertEqual(progress[eps[0].data]?.positionSeconds, 300)
        XCTAssertEqual(progress[eps[0].data]?.watched, false)
        XCTAssertNil(progress[eps[1].data])
    }

    func testEpisodeBecomesWatchedAndStaysWatchedWhenScrubbingBack() throws {
        let store = makeStore()
        let eps = [episode(1)]
        let dto = series(eps)
        try store.recordProgress(details: dto, episode: eps[0], progressSeconds: 1400, totalDurationSeconds: 1440)
        XCTAssertEqual(try store.episodeProgress(details: dto)[eps[0].data]?.watched, true)

        try store.recordProgress(details: dto, episode: eps[0], progressSeconds: 60, totalDurationSeconds: 1440)
        XCTAssertEqual(try store.episodeProgress(details: dto)[eps[0].data]?.watched, true)
    }

    func testWatchedTransitionNotifiesEvenForSilentWrites() throws {
        let store = makeStore()
        let eps = [episode(1)]
        let dto = series(eps)
        try store.recordProgress(details: dto, episode: eps[0], progressSeconds: 100, totalDurationSeconds: 1440)
        let before = store.version
        try store.recordProgress(details: dto, episode: eps[0], progressSeconds: 200, totalDurationSeconds: 1440, notifyObservers: false)
        XCTAssertEqual(store.version, before, "plain progress ticks stay silent")
        try store.recordProgress(details: dto, episode: eps[0], progressSeconds: 1430, totalDurationSeconds: 1440, notifyObservers: false)
        XCTAssertEqual(store.version, before + 1, "the watched tick must reach the UI")
    }

    func testMarkPreviousWatchedAcrossSeasons() throws {
        let store = makeStore()
        let eps = [episode(1), episode(2), episode(1, season: 2), episode(2, season: 2)]
        let dto = series(eps)
        try store.markPreviousWatched(details: dto, orderedEpisodes: eps, upTo: eps[2])

        let progress = try store.episodeProgress(details: dto)
        XCTAssertEqual(progress[eps[0].data]?.watched, true)
        XCTAssertEqual(progress[eps[1].data]?.watched, true)
        XCTAssertNil(progress[eps[2].data])
        XCTAssertNil(progress[eps[3].data])
    }

    func testUnwatchClearsPosition() throws {
        let store = makeStore()
        let eps = [episode(1)]
        let dto = series(eps)
        try store.recordProgress(details: dto, episode: eps[0], progressSeconds: 600, totalDurationSeconds: 1440)
        try store.setEpisodesWatched(details: dto, episodes: eps, watched: true)
        try store.setEpisodesWatched(details: dto, episodes: eps, watched: false)
        let row = try store.episodeProgress(details: dto)[eps[0].data]
        XCTAssertEqual(row?.watched, false)
        XCTAssertEqual(row?.positionSeconds, 0)
    }

    func testPlanToWatchPromotesToWatchingOnPlayback() throws {
        let store = makeStore()
        let eps = [episode(1), episode(2)]
        let dto = series(eps)
        try store.upsertLibraryEntry(details: dto, watchType: .planToWatch)
        try store.recordProgress(details: dto, episode: eps[0], progressSeconds: 120, totalDurationSeconds: 1440)
        XCTAssertEqual(try store.watchType(details: dto), .watching)
    }

    func testFinishingEverySeriesEpisodeCompletesLibraryEntry() throws {
        let store = makeStore()
        let eps = [episode(1), episode(2)]
        let dto = series(eps)
        try store.upsertLibraryEntry(details: dto, watchType: .watching)
        try store.recordProgress(details: dto, episode: eps[0], progressSeconds: 1430, totalDurationSeconds: 1440)
        XCTAssertEqual(try store.watchType(details: dto), .watching)
        try store.recordProgress(details: dto, episode: eps[1], progressSeconds: 1430, totalDurationSeconds: 1440)
        XCTAssertEqual(try store.watchType(details: dto), .completed)
    }

    func testAnimeCompletionOnlyConsidersTheWatchedAudioTrack() throws {
        let store = makeStore()
        let eps = [episode(1, audio: "sub"), episode(1, audio: "dub")]
        let dto = series(eps)
        try store.upsertLibraryEntry(details: dto, watchType: .watching)
        try store.recordProgress(details: dto, episode: eps[0], progressSeconds: 1430, totalDurationSeconds: 1440)
        XCTAssertEqual(try store.watchType(details: dto), .completed)
    }

    func testAutoPromotionRespectsPreference() throws {
        let store = makeStore()
        store.autoUpdateLibraryStatusOverride = false
        let dto = movie()
        try store.upsertLibraryEntry(details: dto, watchType: .planToWatch)
        try store.recordProgress(details: dto, episode: nil, progressSeconds: 5900, totalDurationSeconds: 6000)
        XCTAssertEqual(try store.watchType(details: dto), .planToWatch)
    }

    func testMovieCompletion() throws {
        let store = makeStore()
        let dto = movie()
        try store.upsertLibraryEntry(details: dto, watchType: .watching)
        try store.recordProgress(details: dto, episode: nil, progressSeconds: 5900, totalDurationSeconds: 6000)
        XCTAssertEqual(try store.watchType(details: dto), .completed)
    }

    func testPlaybackNeverFilesUnlibraryTitles() throws {
        let store = makeStore()
        let dto = movie()
        try store.recordProgress(details: dto, episode: nil, progressSeconds: 5900, totalDurationSeconds: 6000)
        XCTAssertNil(try store.watchType(details: dto))
    }

    func testClearWatchHistoryRemovesRowsAndResume() throws {
        let store = makeStore()
        let eps = [episode(1)]
        let dto = series(eps)
        try store.recordProgress(details: dto, episode: eps[0], progressSeconds: 600, totalDurationSeconds: 1440)
        try store.clearWatchHistory(itemID: LibraryStore.itemID(for: dto))
        XCTAssertTrue(try store.episodeProgress(details: dto).isEmpty)
        XCTAssertNil(try store.resumeItem(for: dto), "an entry that only held progress is removed")
    }

    func testWatchStatsAndHistory() throws {
        let store = makeStore()
        let eps = [episode(1), episode(2)]
        let dto = series(eps)
        try store.recordProgress(details: dto, episode: eps[0], progressSeconds: 1430, totalDurationSeconds: 1440)
        try store.recordProgress(details: dto, episode: eps[1], progressSeconds: 300, totalDurationSeconds: 1440)
        let stats = try store.watchStats()
        XCTAssertEqual(stats.titles, 1)
        XCTAssertEqual(stats.episodesWatched, 1)
        XCTAssertEqual(stats.secondsWatched, 1440 + 300)
        XCTAssertEqual(try store.watchHistory().count, 2)
    }

    // MARK: Movies, deletion and migration (audit A22/A23/A24/A26)

    func testMoviePlaybackHasHistoryAndStatsIndependentOfRotatingLink() throws {
        let store = makeStore()
        var dto = movie()
        try store.recordProgress(details: dto, episode: nil, progressSeconds: 600, totalDurationSeconds: 6000)
        dto = DetailsDto(provider: dto.provider, url: dto.url, name: dto.name, type: dto.type, posterUrl: nil,
            backgroundPosterUrl: nil, logoUrl: nil, plot: nil, year: nil, durationMinutes: nil, score: nil, tags: [],
            actors: [], contentRating: nil, comingSoon: false, episodes: [], movieData: "rotated-signed-link")
        try store.recordProgress(details: dto, episode: nil, progressSeconds: 5900, totalDurationSeconds: 6000)
        let history = try store.watchHistory()
        XCTAssertEqual(history.count, 1, "a rotating movie link keeps one history row")
        XCTAssertTrue(history[0].isMovie)
        XCTAssertTrue(history[0].watched)
        let stats = try store.watchStats()
        XCTAssertEqual(stats, LibraryStore.WatchStats(titles: 1, episodesWatched: 0, moviesWatched: 1, secondsWatched: 6000, unownedEntries: 0))
        XCTAssertEqual(EpisodeProgress.moviePlaybackData, BackupDocument.moviePlaybackData)
        XCTAssertEqual(EpisodeProgress.movieKind, BackupDocument.movieKind)

        try store.clearAllWatchHistory()
        XCTAssertEqual(try store.watchStats(), LibraryStore.WatchStats())
        XCTAssertTrue(try store.continueWatching.isEmpty)
    }

    func testMovieHistorySurvivesBackupRoundTripAndOldBackupsStayEpisodes() throws {
        let store = makeStore()
        try store.recordProgress(details: movie(), episode: nil, progressSeconds: 600, totalDurationSeconds: 6000)
        let eps = [episode(1, audio: "dub")]
        try store.recordProgress(details: series(eps), episode: eps[0], progressSeconds: 60, totalDurationSeconds: 1440)
        let snapshot = try store.exportSnapshot()
        XCTAssertEqual(Set(snapshot.episodes.map(\.kind)), ["movie", "episode"])
        let document = BackupDocument(createdAt: Date(), appVersion: "t", items: snapshot.items, episodes: snapshot.episodes,
            playback: snapshot.playback, preferences: [:], repositories: [], disabledProviders: [])
        let decoded = try BackupDocument.decode(try document.encoded())
        let other = makeStore()
        try other.importSnapshot(.init(items: decoded.items, episodes: decoded.episodes, playback: decoded.playback), mode: .replace)
        XCTAssertEqual(try other.watchStats().titles, 2)
        XCTAssertEqual(try other.watchHistory().filter(\.isMovie).count, 1)
        XCTAssertEqual(try other.watchHistory().first { !$0.isMovie }?.audio, "dub")
        XCTAssertEqual(try other.item(id: LibraryStore.itemID(for: series(eps)))?.lastAudio, "dub")

        var forged = decoded
        forged.episodes[0].kind = forged.episodes[0].kind == "movie" ? "episode" : "movie"
        XCTAssertThrowsError(try forged.validate(), "kind and movie identity must agree")
        var legacy = decoded
        legacy.episodes = legacy.episodes.filter { $0.kind != "movie" }.map { var row = $0; row.kind = nil; row.audio = nil; return row }
        XCTAssertNoThrow(try legacy.validate())
    }

    func testDeletingHistoryMovesOrClearsTheResumePointerInOneCommit() throws {
        let store = makeStore()
        let eps = [episode(1), episode(2)]
        let dto = series(eps)
        let id = LibraryStore.itemID(for: dto)
        try store.recordProgress(details: dto, episode: eps[0], progressSeconds: 300, totalDurationSeconds: 1440)
        try store.recordProgress(details: dto, episode: eps[1], progressSeconds: 700, totalDurationSeconds: 1500)

        // Deleting an older row leaves the newer episode's pointer alone.
        try store.deleteHistoryEntry(id: EpisodeProgress.key(itemID: id, episodeData: eps[0].data))
        var item = try XCTUnwrap(try store.item(id: id))
        XCTAssertEqual(item.lastEpisodeData, eps[1].data)
        XCTAssertEqual(item.progressSeconds, 700)

        try store.recordProgress(details: dto, episode: eps[0], progressSeconds: 300, totalDurationSeconds: 1440)
        try store.recordProgress(details: dto, episode: eps[1], progressSeconds: 700, totalDurationSeconds: 1500)
        // Deleting the pointer's row falls back to the latest remaining row.
        try store.deleteHistoryEntry(id: EpisodeProgress.key(itemID: id, episodeData: eps[1].data))
        item = try XCTUnwrap(try store.item(id: id))
        XCTAssertEqual(item.lastEpisodeData, eps[0].data)
        XCTAssertEqual(item.lastEpisode, 1)
        XCTAssertEqual(item.progressSeconds, 300)
        XCTAssertEqual(item.totalDurationSeconds, 1440)

        // Deleting the last row removes a title that only held progress.
        try store.deleteHistoryEntry(id: EpisodeProgress.key(itemID: id, episodeData: eps[0].data))
        XCTAssertNil(try store.item(id: id))
        XCTAssertTrue(try store.continueWatching.isEmpty)
    }

    func testDeletingLastHistoryRowKeepsLibraryDataAndClearsResume() throws {
        let store = makeStore()
        let eps = [episode(1)]
        let dto = series(eps)
        try store.upsertLibraryEntry(details: dto, watchType: .watching)
        try store.setUserNote(details: dto, note: "keep")
        try store.updatePlaybackPrefs(details: dto) { $0.speed = 1.5 }
        try store.recordProgress(details: dto, episode: eps[0], progressSeconds: 300, totalDurationSeconds: 1440)
        let id = LibraryStore.itemID(for: dto)
        try store.deleteHistoryEntry(id: EpisodeProgress.key(itemID: id, episodeData: eps[0].data))
        let item = try XCTUnwrap(try store.item(id: id))
        XCTAssertNil(item.lastEpisodeData)
        XCTAssertEqual(item.progressSeconds, 0)
        XCTAssertEqual(item.watchType, .watching)
        XCTAssertEqual(item.userNote, "keep")
        XCTAssertEqual(try store.playbackPrefs(details: dto)?.speed, 1.5)
        XCTAssertTrue(try store.continueWatching.isEmpty)
    }

    func testListRemovalKeepsIndependentDataWithoutHiddenOrphans() throws {
        let store = makeStore()
        let eps = [episode(1)]
        let dto = series(eps)
        try store.upsertLibraryEntry(details: dto, watchType: .watching)
        try store.toggleFavorite(details: dto)
        try store.setUserRating(details: dto, rating: 4)
        try store.updatePlaybackPrefs(details: dto) { $0.subtitleDelay = -0.5 }
        try store.recordProgress(details: dto, episode: eps[0], progressSeconds: 300, totalDurationSeconds: 1440)
        try store.removeFromLibrary(details: dto)
        let item = try XCTUnwrap(try store.item(id: LibraryStore.itemID(for: dto)))
        XCTAssertNil(item.watchType)
        XCTAssertTrue(item.isFavorite)
        XCTAssertEqual(item.userRating, 4)
        XCTAssertEqual(try store.playbackPrefs(details: dto)?.subtitleDelay, -0.5)
        XCTAssertEqual(try store.watchHistory().count, 1)
        XCTAssertEqual(try store.watchStats().unownedEntries, 0)
    }

    func testImportKeepsUnownedHistoryWithWarningAndStatsMatchHistory() throws {
        let store = makeStore()
        let orphan = BackupDocument.Episode(itemID: "gone|title", episodeData: "e", season: 1, episode: 1,
            positionSeconds: 100, durationSeconds: 1000, watched: true, updatedAt: Date())
        let prefs = BackupDocument.Playback(itemID: "gone|title", audioLanguage: nil, subtitleLanguage: nil,
            subtitlesOff: false, subtitleDelay: 0, speed: 1, introStart: nil, introEnd: nil)
        let report = try store.importSnapshot(.init(items: [], episodes: [orphan], playback: [prefs]), mode: .merge)
        XCTAssertEqual(report.unownedEntries, 2)
        XCTAssertEqual(report.warnings.count, 1)
        let stats = try store.watchStats()
        XCTAssertEqual(stats.titles, 0, "statistics count what History shows")
        XCTAssertEqual(stats.episodesWatched, 0)
        XCTAssertEqual(stats.unownedEntries, 1)
        try store.clearAllWatchHistory()
        XCTAssertEqual(try store.watchStats().unownedEntries, 0)
    }

    func testSwitchingEpisodesResetsStaleDurationAndCoordinates() throws {
        let store = makeStore()
        let first = episode(3, season: 2, audio: "sub")
        let special = EpisodeDto(data: "special", name: nil, season: nil, episode: nil, posterUrl: nil, description: nil,
            score: nil, date: nil, runTimeMinutes: nil, audio: nil)
        let dto = series([first, special])
        try store.recordProgress(details: dto, episode: first, progressSeconds: 300, totalDurationSeconds: 1440)
        try store.recordProgress(details: dto, episode: first, progressSeconds: 310, totalDurationSeconds: 0)
        var item = try XCTUnwrap(try store.item(id: LibraryStore.itemID(for: dto)))
        XCTAssertEqual(item.totalDurationSeconds, 1440, "an unknown length keeps the same episode's length")
        XCTAssertEqual(item.lastAudio, "sub")
        try store.recordProgress(details: dto, episode: special, progressSeconds: 5, totalDurationSeconds: 0)
        item = try XCTUnwrap(try store.item(id: LibraryStore.itemID(for: dto)))
        XCTAssertEqual(item.totalDurationSeconds, 0)
        XCTAssertNil(item.lastSeason)
        XCTAssertNil(item.lastEpisode)
        XCTAssertNil(item.lastAudio)
        XCTAssertEqual(item.lastEpisodeData, "special")
    }

    func testDeletedLastHistoryRowIsNotResurrectedAfterReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let eps = [episode(1)]
        let dto = series(eps)
        let id = LibraryStore.itemID(for: dto)
        var writer: LibraryStore? = LibraryStore(storeDirectory: directory)
        try XCTUnwrap(writer).upsertLibraryEntry(details: dto, watchType: .watching)
        try XCTUnwrap(writer).recordProgress(details: dto, episode: eps[0], progressSeconds: 300, totalDurationSeconds: 1440)
        try XCTUnwrap(writer).recordProgress(details: movie(), episode: nil, progressSeconds: 300, totalDurationSeconds: 6000)
        try XCTUnwrap(writer).deleteHistoryEntry(id: EpisodeProgress.key(itemID: id, episodeData: eps[0].data))
        for row in try XCTUnwrap(writer).watchHistory() { try XCTUnwrap(writer).deleteHistoryEntry(id: row.id) }
        writer = nil

        let reopened = LibraryStore(storeDirectory: directory)
        XCTAssertTrue(try reopened.watchHistory().isEmpty, "user-deleted history is not a missing migration")
        XCTAssertTrue(try reopened.continueWatching.isEmpty)
        XCTAssertEqual(try reopened.item(id: id)?.watchType, .watching)
        try reopened.activateProfileStore(named: nil)
        XCTAssertTrue(try reopened.watchHistory().isEmpty)
    }

    func testKeyIsStableAndHashesData() {
        let a = EpisodeProgress.key(itemID: "p|u", episodeData: String(repeating: "x", count: 5000))
        let b = EpisodeProgress.key(itemID: "p|u", episodeData: String(repeating: "x", count: 5000))
        XCTAssertEqual(a, b)
        XCTAssertLessThan(a.count, 80)
    }

    // MARK: Next-episode resolver

    func testResolverPrefersInProgressLastEpisode() {
        let eps = [episode(1), episode(2), episode(3)]
        let progress = [
            eps[0].data: snapshot(eps[0], position: 1440, watched: true),
            eps[1].data: snapshot(eps[1], position: 500),
        ]
        let pick = NextEpisodeResolver.pick(episodes: eps, progress: progress, lastEpisodeData: eps[1].data)
        XCTAssertEqual(pick, .init(episode: eps[1], resumeAt: 500))
    }

    func testResolverAdvancesPastFurthestWatched() {
        let eps = [episode(1), episode(2), episode(3)]
        let progress = [
            eps[0].data: snapshot(eps[0], position: 1440, watched: true),
            eps[1].data: snapshot(eps[1], position: 1440, watched: true),
        ]
        let pick = NextEpisodeResolver.pick(episodes: eps, progress: progress, lastEpisodeData: eps[1].data)
        XCTAssertEqual(pick, .init(episode: eps[2], resumeAt: nil))
    }

    func testResolverRestartsWhenEverythingWatched() {
        let eps = [episode(1), episode(2)]
        let progress = Dictionary(uniqueKeysWithValues: eps.map { ($0.data, snapshot($0, position: 1440, watched: true)) })
        let pick = NextEpisodeResolver.pick(episodes: eps, progress: progress, lastEpisodeData: eps[1].data)
        XCTAssertEqual(pick, .init(episode: eps[0], resumeAt: nil))
    }

    func testResolverDefaultsToFirstEpisode() {
        let eps = [episode(1), episode(2)]
        XCTAssertEqual(NextEpisodeResolver.pick(episodes: eps, progress: [:], lastEpisodeData: nil), .init(episode: eps[0], resumeAt: nil))
        XCTAssertNil(NextEpisodeResolver.pick(episodes: [], progress: [:], lastEpisodeData: nil))
    }

    func testResolverIgnoresMisclickPositions() {
        let eps = [episode(1), episode(2)]
        let progress = [eps[0].data: snapshot(eps[0], position: 3)]
        let pick = NextEpisodeResolver.pick(episodes: eps, progress: progress, lastEpisodeData: eps[0].data)
        XCTAssertEqual(pick, .init(episode: eps[0], resumeAt: nil))
    }

    private func snapshot(_ episode: EpisodeDto, position: Double, watched: Bool = false) -> EpisodeProgressSnapshot {
        EpisodeProgressSnapshot(
            episodeData: episode.data,
            positionSeconds: position,
            durationSeconds: 1440,
            watched: watched,
            updatedAt: Date(),
        )
    }
}

/// Phase 10 performance budget: bulk marking stays fast on long shows.
extension WatchHistoryTests {
    func testMarkingThousandEpisodesIsFastAndIdempotent() throws {
        let store = makeStore()
        let episodes = (1...1000).map { episode($0) }
        let details = series(episodes)
        let start = Date()
        try store.setEpisodesWatched(details: details, episodes: episodes, watched: true)
        try store.setEpisodesWatched(details: details, episodes: episodes, watched: true)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3, "bulk mark should be one fetch, not one per episode")
        let progress = try store.episodeProgress(details: details)
        XCTAssertEqual(progress.count, 1000, "second pass must not duplicate rows")
        XCTAssertTrue(progress.values.allSatisfy(\.watched))
    }
}
