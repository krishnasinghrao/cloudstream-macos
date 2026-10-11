import Synchronization
import XCTest
@testable import CloudStream

/// Offline-Features-Plan Phase 7: backup/restore, Android import, profiles
/// and the app lock.
@MainActor
final class BackupProfileTests: XCTestCase {
    private func episode(_ n: Int) -> EpisodeDto {
        EpisodeDto(data: "bk-\(n)", name: nil, season: 1, episode: n, posterUrl: nil, description: nil, score: nil, date: nil, runTimeMinutes: 24, audio: nil)
    }

    private func series(_ url: String = "u/show") -> DetailsDto {
        DetailsDto(provider: "P", url: url, name: "Show \(url)", type: "TvSeries", posterUrl: "https://img/p.jpg", backgroundPosterUrl: nil,
                   logoUrl: nil, plot: nil, year: nil, durationMinutes: nil, score: nil, tags: [], actors: [], contentRating: nil,
                   comingSoon: false, episodes: [episode(1), episode(2)], movieData: nil)
    }

    private func seededStore() throws -> LibraryStore {
        let store = LibraryStore(inMemory: true)
        store.autoUpdateLibraryStatusOverride = false
        let show = series()
        try store.upsertLibraryEntry(details: show, watchType: .watching)
        try store.toggleFavorite(details: show)
        try store.recordProgress(details: show, episode: episode(1), progressSeconds: 1430, totalDurationSeconds: 1440)
        try store.recordProgress(details: show, episode: episode(2), progressSeconds: 300, totalDurationSeconds: 1440)
        try store.updatePlaybackPrefs(itemID: LibraryStore.itemID(for: show)) { $0.speed = 1.25; $0.audioLanguage = "ja" }
        try store.setUserNote(details: show, note: "great")
        try store.setUserRating(details: show, rating: 4)
        let downloadID = UUID()
        try store.upsertDownloadRecord(id: downloadID, title: "Local", episodeLabel: "", provider: "P",
            episodeData: "", destinationPath: "/Users/x/Movies/file.mkv", statusRaw: 4)
        try store.markDownloaded(downloadID: downloadID, provider: "P", url: "/Users/x/Movies/file.mkv", title: "Local")
        return store
    }

    private func timedSnapshot(_ time: TimeInterval = 100) -> LibraryStore.LibrarySnapshot {
        let date = Date(timeIntervalSince1970: time)
        let item = BackupDocument.Item(id: LibraryStore.itemID(for: series()), title: "Show", posterURL: nil,
            bannerURL: nil, providerName: "P", providerURL: series().url, mediaType: "TvSeries", watchTypeRaw: 0,
            isFavorite: true, lastEpisodeData: episode(1).data, lastSeason: 1, lastEpisode: 1,
            progressSeconds: 100, totalDurationSeconds: 1000, lastUpdated: date, createdAt: date,
            knownEpisodeCount: 2, userNote: "Initial", userRating: 5,
            noteUpdatedAt: date, ratingUpdatedAt: date, favoriteUpdatedAt: date, watchTypeUpdatedAt: date, progressUpdatedAt: date)
        let playback = BackupDocument.Playback(itemID: item.id, audioLanguage: "ja", subtitleLanguage: "en",
            subtitlesOff: false, subtitleDelay: 2, speed: 1.5, introStart: 5, introEnd: 30, updatedAt: date)
        return .init(items: [item], episodes: [], playback: [playback])
    }

    func testNewerExplicitClearsMergeAllIndependentFieldsAndPlayback() throws {
        let store = LibraryStore(inMemory: true)
        try store.importSnapshot(timedSnapshot(), mode: .replace)
        var incoming = timedSnapshot()
        let newer = Date(timeIntervalSince1970: 200)
        incoming.items[0].lastUpdated = newer
        incoming.items[0].userNote = nil
        incoming.items[0].userRating = 0
        incoming.items[0].isFavorite = false
        incoming.items[0].watchTypeRaw = -1
        incoming.items[0].noteUpdatedAt = newer
        incoming.items[0].ratingUpdatedAt = newer
        incoming.items[0].favoriteUpdatedAt = newer
        incoming.items[0].watchTypeUpdatedAt = newer
        incoming.playback[0].updatedAt = newer
        incoming.playback[0].audioLanguage = nil
        incoming.playback[0].subtitleLanguage = nil
        incoming.playback[0].introStart = nil
        incoming.playback[0].introEnd = nil
        incoming.playback[0].speed = 1
        let report = try store.importSnapshot(incoming, mode: .merge)
        let row = try XCTUnwrap(store.item(id: incoming.items[0].id))
        XCTAssertNil(row.userNote)
        XCTAssertEqual(row.userRating, 0)
        XCTAssertFalse(row.isFavorite)
        XCTAssertNil(row.watchType)
        XCTAssertEqual(row.progressSeconds, 100)
        let prefs = try XCTUnwrap(store.playbackPrefs(itemID: row.id))
        XCTAssertNil(prefs.audioLanguage)
        XCTAssertNil(prefs.subtitleLanguage)
        XCTAssertNil(prefs.introStart)
        XCTAssertNil(prefs.introEnd)
        XCTAssertEqual(prefs.speed, 1)
        XCTAssertTrue(report.warnings.isEmpty)
        try store.clearWatchHistory(itemID: row.id)
        XCTAssertNotNil(try store.item(id: row.id), "Clear metadata must survive unrelated history removal")
    }

    func testProgressAndNoteChronologyAreIndependentAndOldPlaybackCannotOverwrite() throws {
        let store = LibraryStore(inMemory: true)
        var initial = timedSnapshot()
        initial.items[0].progressUpdatedAt = Date(timeIntervalSince1970: 900)
        initial.items[0].lastUpdated = Date(timeIntervalSince1970: 900)
        initial.playback[0].updatedAt = Date(timeIntervalSince1970: 800)
        try store.importSnapshot(initial, mode: .replace)
        var note = timedSnapshot()
        note.items[0].userNote = "Newer note, older overall title"
        note.items[0].noteUpdatedAt = Date(timeIntervalSince1970: 200)
        note.items[0].lastUpdated = Date(timeIntervalSince1970: 300)
        note.playback[0].speed = 2
        try store.importSnapshot(note, mode: .merge)
        XCTAssertEqual(try store.item(id: note.items[0].id)?.userNote, note.items[0].userNote)
        XCTAssertEqual(try store.playbackPrefs(itemID: note.items[0].id)?.speed, 1.5)
        var progress = timedSnapshot()
        progress.items[0].lastUpdated = Date(timeIntervalSince1970: 1000)
        progress.items[0].progressUpdatedAt = Date(timeIntervalSince1970: 1000)
        progress.items[0].progressSeconds = 700
        try store.importSnapshot(progress, mode: .merge)
        XCTAssertEqual(try store.item(id: progress.items[0].id)?.progressSeconds, 700)
        XCTAssertEqual(try store.item(id: progress.items[0].id)?.userNote, note.items[0].userNote)
    }

    func testEqualTimestampsPreserveLocalAndReportConflict() throws {
        let store = LibraryStore(inMemory: true)
        try store.importSnapshot(timedSnapshot(), mode: .replace)
        var incoming = timedSnapshot()
        incoming.items[0].userNote = "Conflicting equal time"
        incoming.playback[0].speed = 2
        let report = try store.importSnapshot(incoming, mode: .merge)
        XCTAssertEqual(report.equalTimestampConflicts, 2)
        XCTAssertEqual(try store.item(id: incoming.items[0].id)?.userNote, "Initial")
        XCTAssertEqual(try store.playbackPrefs(itemID: incoming.items[0].id)?.speed, 1.5)
    }

    func testVersionOneMergePreservesCurrentValuesAndReplaceAppliesLegacyWithoutInventedClocks() throws {
        let store = LibraryStore(inMemory: true)
        try store.importSnapshot(timedSnapshot(), mode: .replace)
        var legacy = timedSnapshot()
        legacy.formatVersion = 1
        legacy.items[0].lastUpdated = Date(timeIntervalSince1970: 10000)
        legacy.items[0].userNote = nil
        legacy.items[0].progressSeconds = 900
        legacy.items[0].isFavorite = false
        legacy.playback[0].speed = 2
        legacy.playback[0].updatedAt = Date(timeIntervalSince1970: 10000)
        let report = try store.importSnapshot(legacy, mode: .merge)
        XCTAssertGreaterThan(report.unversionedFieldsPreserved, 0)
        XCTAssertEqual(try store.item(id: legacy.items[0].id)?.userNote, "Initial")
        XCTAssertEqual(try store.item(id: legacy.items[0].id)?.progressSeconds, 100)
        XCTAssertEqual(try store.item(id: legacy.items[0].id)?.lastUpdated, Date(timeIntervalSince1970: 100))
        XCTAssertTrue(try store.item(id: legacy.items[0].id)?.isFavorite == true)
        XCTAssertEqual(try store.playbackPrefs(itemID: legacy.items[0].id)?.speed, 1.5)
        try store.importSnapshot(legacy, mode: .replace)
        XCTAssertNil(try store.item(id: legacy.items[0].id)?.userNote)
        let exported = try store.exportSnapshot()
        XCTAssertNil(exported.items[0].noteUpdatedAt)
        XCTAssertNil(exported.playback[0].updatedAt)
        XCTAssertEqual(exported.playback[0].speed, 2)
    }

    func testKnownIncomingClockCannotInventOrderForAnUnknownLocalField() throws {
        let store = LibraryStore(inMemory: true)
        var unknown = timedSnapshot()
        unknown.items[0].noteUpdatedAt = nil
        unknown.items[0].progressUpdatedAt = nil
        unknown.playback[0].updatedAt = nil
        try store.importSnapshot(unknown, mode: .replace)
        var known = timedSnapshot(200)
        known.items[0].userNote = "Cannot prove this is newer"
        known.items[0].progressSeconds = 500
        known.playback[0].speed = 2
        let report = try store.importSnapshot(known, mode: .merge)
        XCTAssertEqual(report.unversionedFieldsPreserved, 3)
        XCTAssertEqual(try store.item(id: unknown.items[0].id)?.userNote, "Initial")
        XCTAssertEqual(try store.item(id: unknown.items[0].id)?.progressSeconds, 100)
        XCTAssertEqual(try store.playbackPrefs(itemID: unknown.items[0].id)?.speed, 1.5)
    }

    func testReadCarriesVersionOneThroughProductionPendingSnapshot() throws {
        let snapshot = timedSnapshot()
        var document = BackupDocument(createdAt: Date(), appVersion: "legacy", items: snapshot.items,
            episodes: snapshot.episodes, playback: snapshot.playback, preferences: [:], repositories: [], disabledProviders: [])
        document.version = 1
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-format-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try document.encoded().write(to: file)
        let pending = try BackupService.shared.read(file)
        XCTAssertEqual(pending.snapshot.formatVersion, 1)
    }

    func testInvalidFieldClockAndLocalNamespaceRestoreFailBeforeMutation() throws {
        let store = LibraryStore(inMemory: true)
        try store.importSnapshot(timedSnapshot(), mode: .replace)
        let before = try store.exportSnapshot()
        let version = store.version
        var invalid = timedSnapshot()
        invalid.items[0].noteUpdatedAt = Date(timeIntervalSince1970: 1000)
        XCTAssertThrowsError(try store.importSnapshot(invalid, mode: .replace))
        invalid = timedSnapshot()
        invalid.items[0].id = LibraryIdentity.localDownload(UUID())
        XCTAssertThrowsError(try store.importSnapshot(invalid, mode: .replace))
        invalid = timedSnapshot()
        invalid.items[0].mediaType = "Download"
        XCTAssertThrowsError(try store.importSnapshot(invalid, mode: .replace))
        XCTAssertEqual(store.version, version)
        XCTAssertEqual(try store.exportSnapshot().items, before.items)
    }

    func testMutationClockAndClearMetadataPersistAcrossDiskReopenAndFailedRestore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("field-clocks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(storeDirectory: root)
        try store.importSnapshot(timedSnapshot(), mode: .replace)
        store.mutationClock = { Date(timeIntervalSince1970: 200) }
        try store.setUserNote(details: series(), note: "Changed")
        try store.setUserNote(details: series(), note: nil)
        try store.setUserRating(details: series(), rating: 0)
        try store.toggleFavorite(details: series())
        try store.removeFromLibrary(details: series())
        let updated = try store.exportSnapshot()
        XCTAssertGreaterThan(try XCTUnwrap(updated.items[0].noteUpdatedAt), Date(timeIntervalSince1970: 200))
        XCTAssertEqual(updated.items[0].ratingUpdatedAt, Date(timeIntervalSince1970: 200))
        XCTAssertNotNil(updated.items[0].watchTypeUpdatedAt)
        enum Fault: Error { case injected }
        store.persistenceFault = { if $0 == .restoreCommit { throw Fault.injected } }
        XCTAssertThrowsError(try store.importSnapshot(timedSnapshot(300), mode: .merge))
        store.persistenceFault = nil
        let reopened = LibraryStore(storeDirectory: root)
        XCTAssertEqual(try reopened.exportSnapshot().items, updated.items)
        try reopened.importSnapshot(timedSnapshot(), mode: .merge)
        let row = try XCTUnwrap(reopened.item(id: updated.items[0].id))
        XCTAssertNil(row.userNote)
        XCTAssertEqual(row.userRating, 0)
        XCTAssertFalse(row.isFavorite)
        XCTAssertNil(row.watchType)
    }

    // MARK: Document

    func testExportRoundTripsThroughJSON() throws {
        let store = try seededStore()
        let snapshot = try store.exportSnapshot()
        XCTAssertEqual(snapshot.items.count, 1, "download placeholders are machine-specific and skipped")
        XCTAssertEqual(snapshot.episodes.count, 2)
        XCTAssertEqual(snapshot.playback.first?.speed, 1.25)

        let document = BackupDocument(createdAt: Date(timeIntervalSince1970: 1_800_000_000), appVersion: "test",
                                      items: snapshot.items, episodes: snapshot.episodes, playback: snapshot.playback,
                                      preferences: ["seekStepSeconds": .double(15.5), "sourcePriority": .strings(["a"])],
                                      repositories: ["https://repo/json"], disabledProviders: ["Bad"])
        let decoded = try BackupDocument.decode(try document.encoded())
        // Dates are stored to the millisecond: the file is stable across
        // round trips even though in-memory Dates carry more precision.
        XCTAssertEqual(String(decoding: try decoded.encoded(), as: UTF8.self), String(decoding: try document.encoded(), as: UTF8.self))
        XCTAssertEqual(decoded.items.map(\.id), document.items.map(\.id))
        XCTAssertEqual(decoded.preferences, document.preferences)
        XCTAssertEqual(decoded.items[0].lastUpdated.timeIntervalSince1970, document.items[0].lastUpdated.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(decoded.summary.favorites, 1)
        XCTAssertEqual(decoded.summary.libraryEntries, 1)
    }

    func testRestoreIntoEmptyStoreReproducesLibrary() throws {
        let snapshot = try seededStore().exportSnapshot()
        let target = LibraryStore(inMemory: true)
        try target.importSnapshot(snapshot, mode: .merge)
        let show = series()
        XCTAssertEqual(try target.watchType(details: show), .watching)
        XCTAssertTrue(try target.isFavorite(details: show))
        XCTAssertEqual(try target.episodeProgress(details: show)[episode(1).data]?.watched, true)
        XCTAssertEqual(try target.playbackPrefs(itemID: LibraryStore.itemID(for: show))?.audioLanguage, "ja")
        XCTAssertEqual(try target.resumeItem(for: show)?.userNote, "great")
        XCTAssertEqual(try target.resumeItem(for: show)?.userRating, 4)
    }

    func testMergeKeepsNewerLocalChanges() throws {
        let snapshot = try seededStore().exportSnapshot()
        let target = LibraryStore(inMemory: true)
        let show = series()
        try target.importSnapshot(snapshot, mode: .merge)
        try target.upsertLibraryEntry(details: show, watchType: .completed) // newer local change
        try target.importSnapshot(snapshot, mode: .merge)
        XCTAssertEqual(try target.watchType(details: show), .completed, "an older backup must not revert a newer local status")
    }

    func testReplaceDropsEntriesNotInBackup() throws {
        let snapshot = try seededStore().exportSnapshot()
        let target = LibraryStore(inMemory: true)
        try target.upsertLibraryEntry(details: series("u/other"), watchType: .planToWatch)
        try target.importSnapshot(snapshot, mode: .replace)
        XCTAssertNil(try target.watchType(details: series("u/other")))
        XCTAssertEqual(try target.watchType(details: series()), .watching)
    }

    func testReplaceNeedsASafetyBackupButEmptyLibraryDoesNot() async throws {
        let service = BackupService.shared
        let shared = LibraryStore.shared
        let snapshot = try seededStore().exportSnapshot()
        let pending = BackupService.Pending(source: .android(itemCount: snapshot.items.count), snapshot: snapshot, document: nil)
        let empty = LibraryStore.LibrarySnapshot(items: [], episodes: [], playback: [])
        // A regular file where the backups folder should be: every write fails.
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("blocker-\(UUID().uuidString)")
        try Data().write(to: blocker)
        service.backupsDirectoryOverride = blocker.appendingPathComponent("Backups")
        defer {
            service.backupsDirectoryOverride = nil
            try? FileManager.default.removeItem(at: blocker)
            _ = try? shared.importSnapshot(empty, mode: .replace)
        }

        // Empty library: nothing to protect, so Replace proceeds.
        try shared.importSnapshot(empty, mode: .replace)
        _ = try await service.restore(pending, mode: .replace, includePreferences: false, appState: nil)
        XCTAssertEqual(try shared.watchType(details: series()), .watching)

        // Non-empty library and no way to save it: Replace must refuse.
        try shared.upsertLibraryEntry(details: series("u/mine"), watchType: .planToWatch)
        do {
            _ = try await service.restore(pending, mode: .replace, includePreferences: false, appState: nil)
            XCTFail("replace must not run without a safety backup")
        } catch let error as BackupService.RestoreError {
            guard case .safetyBackupFailed = error else { return XCTFail("wrong error \(error)") }
        }
        XCTAssertEqual(try shared.watchType(details: series("u/mine")), .planToWatch, "library untouched")

        // Merge retains the established continuation policy, with a truthful warning.
        let warnings = try await service.restore(pending, mode: .merge, includePreferences: false, appState: nil)
        XCTAssertTrue(warnings.contains { $0.contains("safety copy") })
        XCTAssertEqual(try shared.watchType(details: series("u/mine")), .planToWatch)
    }

    func testValidationRejectsForeignNewerAndCorruptFiles() throws {
        XCTAssertThrowsError(try BackupDocument.decode(Data(#"{"hello":1}"#.utf8))) {
            XCTAssertEqual($0 as? BackupDocument.ValidationError, .notABackup)
        }
        XCTAssertThrowsError(try BackupDocument.decode(Data(#"{"format":"cloudstream-macos-backup","version":99}"#.utf8))) {
            XCTAssertEqual($0 as? BackupDocument.ValidationError, .newerVersion(99))
        }
        XCTAssertThrowsError(try BackupDocument.decode(Data(#"{"format":"cloudstream-macos-backup","version":1,"items":"x"}"#.utf8))) {
            guard case .corrupt = $0 as? BackupDocument.ValidationError else { return XCTFail("expected corrupt") }
        }
    }

    func testPreferenceRestoreValidatesValuesBeforeApplyingAny() throws {
        let suite = UserDefaults(suiteName: "cs-backup-prefs-\(UUID().uuidString)")!
        let prefs = UserPreferences(defaults: suite)
        XCTAssertThrowsError(try prefs.applyBackupValues([
            "seekStepSeconds": .int(30),
            "nextEpisodeCountdown": .int(9999),
        ]))
        XCTAssertEqual(prefs.seekStepSeconds, 10, "invalid patches must not partially apply")
        XCTAssertEqual(prefs.nextEpisodeCountdown, 10)
        try prefs.applyBackupValues([
            "seekStepSeconds": .int(30),
            "resumeBehavior": .string("alwaysResume"),
            "sourcePriority": .strings(["  VidPlay "]),
            "downloadDirectory": .string("/etc"),
        ])
        XCTAssertEqual(prefs.seekStepSeconds, 30)
        XCTAssertEqual(prefs.nextEpisodeCountdown, 10)
        XCTAssertEqual(prefs.resumeBehavior, .alwaysResume)
        XCTAssertEqual(prefs.sourcePriority, ["vidplay"])
        XCTAssertNotEqual(prefs.downloadDirectory.path, "/etc", "paths never travel in a backup")
        XCTAssertNil(prefs.backupValues()["downloadDirectory"])
    }

    func testAutoBackupPruningKeepsNewest() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cs-backups-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<10 {
            let url = directory.appendingPathComponent("CloudStream-Backup-\(index).daily.json")
            try Data("{}".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(1_000 + index))], ofItemAtPath: url.path)
        }
        try Data("keep".utf8).write(to: directory.appendingPathComponent("unrelated.json"))
        BackupService.shared.pruneAutoBackups(in: directory, keep: 7)
        let remaining = BackupService.autoBackupFiles(in: directory).map(\.lastPathComponent)
        XCTAssertEqual(remaining.count, 7)
        XCTAssertEqual(remaining.first, "CloudStream-Backup-9.daily.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("unrelated.json").path))
    }

    // MARK: Android

    private let androidBackup = """
    {"datastore":{"_String":{
      "0/result_watch_state_data/101":"{\\"bookmarkedTime\\":1700000000000,\\"id\\":101,\\"latestUpdatedTime\\":1700000500000,\\"name\\":\\"Frieren\\",\\"url\\":\\"https://site/frieren\\",\\"apiName\\":\\"AnimeProv\\",\\"type\\":\\"Anime\\",\\"posterUrl\\":\\"https://img/f.jpg\\",\\"year\\":2023}",
      "0/result_watch_state/101":"0",
      "0/result_favorites_state_data/202":"{\\"favoritesTime\\":1700000000000,\\"id\\":202,\\"latestUpdatedTime\\":1700000000000,\\"name\\":\\"Dune\\",\\"url\\":\\"https://site/dune\\",\\"apiName\\":\\"MovieProv\\",\\"type\\":\\"Movie\\",\\"posterUrl\\":null,\\"year\\":2021}",
      "0/result_resume_watching_2/101":"{\\"parentId\\":101,\\"episodeId\\":555,\\"episode\\":7,\\"season\\":1,\\"updateTime\\":1700000900000,\\"isFromDownload\\":false}",
      "0/video_pos_dur/555":"{\\"position\\":600000,\\"duration\\":1440000}",
      "1/result_watch_state_data/303":"{\\"bookmarkedTime\\":1,\\"id\\":303,\\"latestUpdatedTime\\":1,\\"name\\":\\"Other Account\\",\\"url\\":\\"https://site/o\\",\\"apiName\\":\\"P\\",\\"type\\":\\"TvSeries\\",\\"posterUrl\\":null,\\"year\\":null}",
      "0/result_watch_state_data/404":"not json",
      "unrelated_key":"x"
    },"_Int":{}},"settings":{"_Bool":{}}}
    """

    func testAndroidBackupImport() throws {
        let data = Data(androidBackup.utf8)
        XCTAssertTrue(AndroidBackupImporter.looksLikeAndroidBackup(data))
        let snapshot = try AndroidBackupImporter.snapshot(from: data)
        let byName = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.title, $0) })
        XCTAssertEqual(byName.count, 3, "all accounts merge; corrupt entries are skipped")

        let frieren = try XCTUnwrap(byName["Frieren"])
        XCTAssertEqual(frieren.id, "AnimeProv|https://site/frieren")
        XCTAssertEqual(frieren.watchTypeRaw, WatchType.watching.rawValue)
        XCTAssertEqual(frieren.lastEpisode, 7)
        XCTAssertEqual(frieren.progressSeconds, 600)
        XCTAssertEqual(frieren.totalDurationSeconds, 1440)

        let dune = try XCTUnwrap(byName["Dune"])
        XCTAssertTrue(dune.isFavorite)
        XCTAssertEqual(dune.watchTypeRaw, -1)

        let store = LibraryStore(inMemory: true)
        try store.importSnapshot(snapshot, mode: .merge)
        XCTAssertEqual(try store.items(withWatchType: .watching).count, 1)
        XCTAssertEqual(try store.favorites.count, 1)
        XCTAssertEqual(try store.continueWatching.first?.title, "Frieren")
    }

    private let multiAccountBackup = """
    {"datastore":{"_String":{
      "0/result_watch_state_data/7":"{\\"bookmarkedTime\\":1700000000000,\\"latestUpdatedTime\\":1700000000000,\\"name\\":\\"Shared\\",\\"url\\":\\"https://site/shared\\",\\"apiName\\":\\"P\\",\\"type\\":\\"TvSeries\\",\\"posterUrl\\":null}",
      "0/result_watch_state/7":"0",
      "0/result_resume_watching_2/7":"{\\"parentId\\":7,\\"episodeId\\":70,\\"episode\\":2,\\"season\\":1,\\"updateTime\\":1700000100000}",
      "0/video_pos_dur/70":"{\\"position\\":120000,\\"duration\\":1440000}",
      "1/result_watch_state_data/7":"{\\"bookmarkedTime\\":1700000000000,\\"latestUpdatedTime\\":1700009000000,\\"name\\":\\"Other title, same number\\",\\"url\\":\\"https://site/other\\",\\"apiName\\":\\"P\\",\\"type\\":\\"TvSeries\\",\\"posterUrl\\":null}",
      "1/result_watch_state/7":"3",
      "1/result_resume_watching_2/7":"{\\"parentId\\":7,\\"episodeId\\":70,\\"episode\\":9,\\"season\\":4,\\"updateTime\\":1700009000000}",
      "1/video_pos_dur/70":"{\\"position\\":900000,\\"duration\\":1440000}",
      "1/result_watch_state_data/8":"{\\"bookmarkedTime\\":1700000000000,\\"latestUpdatedTime\\":1700005000000,\\"name\\":\\"Shared\\",\\"url\\":\\"https://site/shared\\",\\"apiName\\":\\"P\\",\\"type\\":\\"TvSeries\\",\\"posterUrl\\":null}",
      "1/result_watch_state/8":"1",
      "1/result_resume_watching_2/8":"{\\"parentId\\":8,\\"episodeId\\":80,\\"episode\\":5,\\"season\\":1,\\"updateTime\\":1700005000000}",
      "1/video_pos_dur/80":"{\\"position\\":300000,\\"duration\\":1440000}",
      "0/result_watch_state_data/9":"{\\"name\\":\\"Undated\\",\\"url\\":\\"https://site/undated\\",\\"apiName\\":\\"P\\",\\"type\\":\\"Movie\\",\\"posterUrl\\":null}",
      "0/result_watch_state/9":"4",
      "1/result_watch_state_data/9":"{\\"name\\":\\"Undated\\",\\"url\\":\\"https://site/undated\\",\\"apiName\\":\\"P\\",\\"type\\":\\"Movie\\",\\"posterUrl\\":null}",
      "1/result_watch_state/9":"2",
      "1/result_favorites_state_data/9":"{\\"name\\":\\"Undated\\",\\"url\\":\\"https://site/undated\\",\\"apiName\\":\\"P\\",\\"type\\":\\"Movie\\",\\"posterUrl\\":null}"
    },"_Int":{}},"settings":{"_Bool":{}}}
    """

    func testAndroidAccountsKeepTheirIdentityAndConflictsAreExplicit() throws {
        let data = Data(multiAccountBackup.utf8)
        XCTAssertEqual(AndroidBackupImporter.accounts(in: data), [0, 1])
        let all = try AndroidBackupImporter.plan(from: data, account: nil, now: Date(timeIntervalSince1970: 1_800_000_000))
        let titles = Dictionary(uniqueKeysWithValues: all.snapshot.items.map { ($0.providerURL, $0) })
        XCTAssertEqual(Set(titles.keys), ["https://site/shared", "https://site/other", "https://site/undated"],
                       "the same number in two accounts is two records, not one overwritten value")

        // Account 1's numeric id 7 is another title: its resume must not land on "Shared".
        XCTAssertEqual(titles["https://site/other"]?.lastEpisode, 9)
        XCTAssertEqual(titles["https://site/other"]?.watchTypeRaw, WatchType.dropped.rawValue)
        // "Shared" is in both accounts under different numbers; the newer account wins, as a unit.
        let shared = try XCTUnwrap(titles["https://site/shared"])
        XCTAssertEqual(shared.watchTypeRaw, WatchType.completed.rawValue)
        XCTAssertEqual(shared.lastEpisode, 5)
        XCTAssertEqual(shared.progressSeconds, 300)
        // No usable dates: the lowest-numbered account stays, favorites are a union, and it is reported.
        let undated = try XCTUnwrap(titles["https://site/undated"])
        XCTAssertEqual(undated.watchTypeRaw, WatchType.planToWatch.rawValue)
        XCTAssertTrue(undated.isFavorite)
        XCTAssertEqual(all.report.resolvedConflicts, 1)
        XCTAssertEqual(all.report.unresolvedConflicts, ["Undated"])
        XCTAssertEqual(all.report.warnings.count, 2)

        // Deterministic: repeated conversion is identical (no dictionary-order dependence).
        for _ in 0..<5 {
            let again = try AndroidBackupImporter.plan(from: data, account: nil, now: Date(timeIntervalSince1970: 1_800_000_000))
            XCTAssertEqual(again.snapshot.items, all.snapshot.items)
            XCTAssertEqual(again.report, all.report)
        }

        // One selected account imports only that account's view, with no conflicts.
        let first = try AndroidBackupImporter.plan(from: data, account: 0)
        XCTAssertEqual(Set(first.snapshot.items.map(\.providerURL)), ["https://site/shared", "https://site/undated"])
        XCTAssertEqual(first.snapshot.items.first { $0.providerURL == "https://site/shared" }?.lastEpisode, 2)
        XCTAssertTrue(first.report.warnings.isEmpty)
        let second = try AndroidBackupImporter.plan(from: data, account: 1)
        XCTAssertEqual(second.snapshot.items.first { $0.providerURL == "https://site/undated" }?.watchTypeRaw, WatchType.onHold.rawValue)
        XCTAssertThrowsError(try AndroidBackupImporter.plan(from: data, account: 5))
    }

    // MARK: Scheduling and external restore phases (audit A19/A21)

    func testEveryProfileHasItsOwnDailyBackupWithoutSwitchingTheVisibleOne() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("schedule-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "schedule-" + UUID().uuidString
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { suite.removePersistentDomain(forName: suiteName) }
        let store = LibraryStore(storeDirectory: root.appendingPathComponent("stores"))
        let profiles = ProfileStore(defaults: suite)
        let preferences = UserPreferences(defaults: suite)
        preferences.autoBackupEnabled = true
        let service = BackupService(defaults: suite)
        service.backupsDirectoryOverride = root.appendingPathComponent("Backups")

        try store.upsertLibraryEntry(details: series("u/default"), watchType: .watching)
        let other = try profiles.add(name: "Other", symbol: ViewerProfile.symbols[1])
        try profiles.select(other, library: store)
        try store.upsertLibraryEntry(details: series("u/other"), watchType: .completed)
        let empty = try profiles.add(name: "Empty", symbol: ViewerProfile.symbols[2])
        try profiles.select(empty, library: store)
        try profiles.select(profiles.profiles[0], library: store)
        let owner = try store.captureProfileOperation()

        func files(_ profile: ViewerProfile) -> [URL] {
            BackupService.autoBackupFiles(in: root.appendingPathComponent("Backups/\(profile.id.uuidString)/Daily"))
        }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(Set(service.runDueBackups(now: start, store: store, profiles: profiles, preferences: preferences)),
                       [ViewerProfile.defaultID, other.id], "the inactive profile is covered too; an empty one has nothing to write")
        XCTAssertTrue(store.owns(owner), "the visible profile was not switched to back up another")
        XCTAssertEqual(files(profiles.profiles[0]).count, 1)
        XCTAssertEqual(files(other).count, 1)
        XCTAssertTrue(files(empty).isEmpty)
        let otherDocument = try BackupDocument.decode(try Data(contentsOf: try XCTUnwrap(files(other).first)))
        XCTAssertEqual(otherDocument.items.map(\.providerURL), ["u/other"], "each backup holds its own profile's library")
        XCTAssertEqual(otherDocument.profileID, other.id)
        XCTAssertNil(otherDocument.extensionSetupCapturedAt, "no engine setup was read, and the backup says so")

        // A running app: nothing within the day, both again after it, each on its own clock.
        XCTAssertTrue(service.runDueBackups(now: start.addingTimeInterval(23 * 3600), store: store, profiles: profiles, preferences: preferences).isEmpty)
        preferences.setLastAutoBackup(start.addingTimeInterval(20 * 3600), for: other.id)
        XCTAssertEqual(service.runDueBackups(now: start.addingTimeInterval(25 * 3600), store: store, profiles: profiles, preferences: preferences),
                       [ViewerProfile.defaultID], "one profile's backup does not suppress or trigger another's")
        XCTAssertEqual(files(profiles.profiles[0]).count, 2)
        XCTAssertEqual(files(other).count, 1)
        XCTAssertEqual(preferences.lastAutoBackup(for: other.id), start.addingTimeInterval(20 * 3600))

        // Disabled, and failure, leave the profile due rather than recorded.
        preferences.autoBackupEnabled = false
        XCTAssertTrue(service.runDueBackups(now: start.addingTimeInterval(90 * 3600), store: store, profiles: profiles, preferences: preferences).isEmpty)
        preferences.autoBackupEnabled = true
        store.persistenceFault = { if $0 == .snapshotRead { throw URLError(.cannotOpenFile) } }
        XCTAssertTrue(service.runDueBackups(now: start.addingTimeInterval(90 * 3600), store: store, profiles: profiles, preferences: preferences).isEmpty)
        store.persistenceFault = nil
        XCTAssertEqual(preferences.lastAutoBackup(for: ViewerProfile.defaultID), start.addingTimeInterval(25 * 3600))
        XCTAssertEqual(service.runDueBackups(now: start.addingTimeInterval(90 * 3600), store: store, profiles: profiles, preferences: preferences).count, 2)
    }

    func testRestoreReportsExternalPhasesAndRetriesThemWithoutTouchingTheLibraryAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("external-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "external-" + UUID().uuidString
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { suite.removePersistentDomain(forName: suiteName) }
        let service = BackupService(defaults: suite)
        service.backupsDirectoryOverride = root
        let store = LibraryStore(inMemory: true)
        try store.upsertLibraryEntry(details: series("u/local"), watchType: .planToWatch)

        let source = try seededStore().exportSnapshot()
        var document = BackupDocument(createdAt: Date(), appVersion: "t", items: source.items, episodes: source.episodes,
            playback: source.playback, preferences: [:], repositories: ["https://ok.example/repo.json", "https://blocked.example/repo.json"],
            disabledProviders: ["Legacy Name"], disabledProviderIDs: ["inst:Known", "inst:Missing"], extensionSetupCapturedAt: Date())
        document = try BackupDocument.decode(try document.encoded())
        XCTAssertEqual(document.disabledProviderIDs, ["inst:Known", "inst:Missing"])
        let pending = BackupService.Pending(source: .mac(document), snapshot: .init(items: document.items, episodes: document.episodes,
            playback: document.playback, formatVersion: document.version), document: document, owner: try store.captureProfileOperation())

        var usable = false, generation: UInt64 = 1, registered: [[String]] = [], disabled: [String] = []
        let failDisable = Mutex(true)
        service.engineAccess = .init(isUsable: { usable }, generation: { generation }, refresh: {})
        service.registerRepositories = { urls in
            registered.append(urls)
            return [RepoRegistrationDto(url: urls[0], status: registered.count == 1 ? "applied" : "already_present"),
                    RepoRegistrationDto(url: urls[1], status: "rejected", reason: "Your organization does not allow this repository.")]
        }
        service.listProviders = {
            [ProviderInfoDto(name: "Known", providerId: "inst:Known", enabled: true, plugin: nil, mainUrl: "", language: "en",
                             tvTypes: [], hasMainPage: false, hasQuickSearch: false, vpnStatus: "None")]
        }
        service.setProviderEnabled = { id, enabled in
            XCTAssertFalse(enabled)
            if failDisable.withLock({ $0 }) { throw URLError(.timedOut) }
            disabled.append(id)
        }

        // Engine not ready: the library is restored, the setup is truthfully pending.
        var result = try await service.restoreDetailed(pending, mode: .merge, includePreferences: false, appState: nil, store: store)
        XCTAssertTrue(result.externalPhasesPending)
        XCTAssertNotNil(service.pendingExternalRestore)
        XCTAssertTrue(registered.isEmpty)
        XCTAssertEqual(try store.watchType(details: series()), .watching)
        let safetyCopies = try FileManager.default.subpathsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".json") }
        XCTAssertEqual(safetyCopies.count, 1)
        let version = store.version

        // Engine ready, but disabling fails: still pending, with per-phase outcomes.
        usable = true
        result = try await service.retryExternalRestore(appState: nil)
        XCTAssertTrue(result.externalPhasesPending)
        XCTAssertEqual(result.repositories.map(\.status), ["applied", "rejected"])
        XCTAssertTrue(result.warnings.contains { $0.contains("blocked.example") && $0.contains("does not allow") }, "policy rejection is a warning, not silence")
        XCTAssertTrue(result.warnings.contains { $0.contains("aren’t installed") }, "an unknown provider is reported, not ignored")

        // A third attempt completes; nothing about the library or its safety copy changed.
        failDisable.withLock { $0 = false }
        result = try await service.retryExternalRestore(appState: nil)
        XCTAssertFalse(result.externalPhasesPending)
        XCTAssertNil(service.pendingExternalRestore)
        XCTAssertEqual(disabled, ["inst:Known"])
        XCTAssertEqual(result.providersDisabled, 1)
        XCTAssertEqual(registered.count, 2, "registration is simply repeated; it is idempotent in the engine")
        XCTAssertEqual(store.version, version, "retrying external phases never replaces the library again")
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".json") }, safetyCopies,
                       "the original safety copy is neither overwritten nor duplicated")

        // An engine replaced mid-phase cannot be given the rest of the setup.
        service.registerRepositories = { urls in generation += 1; return urls.map { RepoRegistrationDto(url: $0, status: "applied") } }
        // (A restore replaces the store's context, so a new one is prepared.)
        var again = pending
        again.owner = try store.captureProfileOperation()
        result = try await service.restoreDetailed(again, mode: .merge, includePreferences: false, appState: nil, store: store)
        XCTAssertTrue(result.externalPhasesPending)

        // A restore prepared for one profile never lands in another.
        again.owner = try store.captureProfileOperation()
        try store.activateProfileStore(named: "fixture-other")
        do {
            _ = try await service.restoreDetailed(again, mode: .replace, includePreferences: false, appState: nil, store: store)
            XCTFail("the profile changed after the backup was chosen")
        } catch { XCTAssertEqual(error as? BackupService.RestoreError, .profileChanged) }
        XCTAssertTrue(try store.allEntries().isEmpty, "the newly selected profile is untouched")
    }

    func testOlderBackupsDisableProvidersByNameOnlyWhenUnambiguous() async throws {
        let suiteName = "legacy-providers-" + UUID().uuidString
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { suite.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-providers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = BackupService(defaults: suite)
        service.backupsDirectoryOverride = root
        let source = try seededStore().exportSnapshot()
        let document = BackupDocument(version: 1, createdAt: Date(), appVersion: "old", items: source.items.map { var item = $0; item.providerID = nil; item.identityVersion = nil; item.legacyItemID = nil; item.identityResolution = nil; return item },
            episodes: [], playback: [], preferences: [:], repositories: [], disabledProviders: ["Unique", "Twice", "Absent"])
        var disabled: [String] = []
        func info(_ name: String, _ id: String) -> ProviderInfoDto {
            ProviderInfoDto(name: name, providerId: id, enabled: true, plugin: nil, mainUrl: "", language: "en", tvTypes: [],
                            hasMainPage: false, hasQuickSearch: false, vpnStatus: "None")
        }
        service.engineAccess = .init(isUsable: { true }, generation: { 1 }, refresh: {})
        service.listProviders = { [info("Unique", "a:Unique"), info("Twice", "a:Twice"), info("Twice", "b:Twice")] }
        service.setProviderEnabled = { id, _ in disabled.append(id) }
        let pending = BackupService.Pending(source: .mac(document), snapshot: .init(items: document.items, episodes: [], playback: [], formatVersion: 1), document: document)
        let result = try await service.restoreDetailed(pending, mode: .merge, includePreferences: false, appState: nil, store: LibraryStore(inMemory: true))
        XCTAssertEqual(disabled, ["a:Unique"], "a display name selects a provider only when exactly one has it")
        XCTAssertTrue(result.warnings.contains { $0.contains("more than one extension") && $0.contains("Twice") })
        XCTAssertTrue(result.warnings.contains { $0.contains("aren’t installed") })
        XCTAssertFalse(result.externalPhasesPending)
    }

    func testBackupCarriesTheRememberedExtensionSetupWithItsAge() throws {
        let suiteName = "setup-" + UUID().uuidString
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { suite.removePersistentDomain(forName: suiteName) }
        let service = BackupService(defaults: suite)
        XCTAssertNil(service.extensionSetup)
        let captured = Date(timeIntervalSince1970: 1_800_000_000)
        service.rememberExtensionSetup(repositories: ["https://b.example/r.json", "https://a.example/r.json"], providers: [
            ProviderInfoDto(name: "Off", providerId: "x:Off", enabled: false, plugin: nil, mainUrl: "", language: "en", tvTypes: [],
                            hasMainPage: false, hasQuickSearch: false, vpnStatus: "None"),
            ProviderInfoDto(name: "On", providerId: "x:On", enabled: true, plugin: nil, mainUrl: "", language: "en", tvTypes: [],
                            hasMainPage: false, hasQuickSearch: false, vpnStatus: "None"),
        ], at: captured)
        // Survives a relaunch, so a backup written before the engine starts still has it.
        let relaunched = BackupService(defaults: suite)
        let document = try relaunched.makeDocument(appState: nil, store: try seededStore())
        XCTAssertEqual(document.repositories, ["https://a.example/r.json", "https://b.example/r.json"])
        XCTAssertEqual(document.disabledProviderIDs, ["x:Off"])
        XCTAssertEqual(document.disabledProviders, ["Off"])
        XCTAssertEqual(document.extensionSetupCapturedAt, captured)
    }

    func testAndroidStatusMapping() {
        XCTAssertEqual(AndroidBackupImporter.watchType(androidID: 1), .completed)
        XCTAssertEqual(AndroidBackupImporter.watchType(androidID: 2), .onHold)
        XCTAssertEqual(AndroidBackupImporter.watchType(androidID: 3), .dropped)
        XCTAssertEqual(AndroidBackupImporter.watchType(androidID: 4), .planToWatch)
        XCTAssertNil(AndroidBackupImporter.watchType(androidID: 5))
    }

    func testAndroidImportRejectsOtherFiles() throws {
        XCTAssertFalse(AndroidBackupImporter.looksLikeAndroidBackup(Data(#"{"format":"cloudstream-macos-backup"}"#.utf8)))
        XCTAssertThrowsError(try AndroidBackupImporter.snapshot(from: Data(#"{"datastore":{"_String":{}}}"#.utf8))) {
            XCTAssertEqual($0 as? AndroidBackupImporter.ImportError, .nothingToImport)
        }
    }

    // MARK: Profiles

    func testProfilesHaveSeparateLibraries() throws {
        let suite = UserDefaults(suiteName: "cs-profiles-\(UUID().uuidString)")!
        let profiles = ProfileStore(defaults: suite)
        let library = LibraryStore(inMemory: true)
        XCTAssertEqual(profiles.profiles.count, 1)
        XCTAssertTrue(profiles.active.isDefault)

        try library.upsertLibraryEntry(details: series("u/mine"), watchType: .watching)
        let kid = try profiles.add(name: "  Kid  ", symbol: "star.circle.fill")
        XCTAssertEqual(kid.name, "Kid")

        try profiles.select(kid, library: library)
        XCTAssertTrue(try library.allEntries().isEmpty, "a new profile starts empty")
        try library.upsertLibraryEntry(details: series("u/kids"), watchType: .planToWatch)

        try profiles.select(profiles.profiles[0], library: library)
        XCTAssertEqual(try library.allEntries().map(\.providerURL), ["u/mine"])

        // Persisted across launches.
        let reloaded = ProfileStore(defaults: suite)
        XCTAssertEqual(reloaded.profiles.map(\.name), ["Me", "Kid"])
        XCTAssertTrue(reloaded.active.isDefault)
    }

    func testDownloadsStaySharedAcrossProfiles() throws {
        let suite = UserDefaults(suiteName: "cs-profiles-\(UUID().uuidString)")!
        let profiles = ProfileStore(defaults: suite)
        let library = LibraryStore(inMemory: true)
        let id = UUID()
        try library.upsertDownloadRecord(id: id, title: "T", episodeLabel: "E", provider: "P", episodeData: "d", destinationPath: "/tmp/x", statusRaw: 4)
        try profiles.select(try profiles.add(name: "B", symbol: "sparkles"), library: library)
        XCTAssertEqual(try library.downloadRecords().map(\.id), [id])
    }

    func testProfileRules() throws {
        let suite = UserDefaults(suiteName: "cs-profiles-\(UUID().uuidString)")!
        let profiles = ProfileStore(defaults: suite)
        XCTAssertThrowsError(try profiles.add(name: "   ", symbol: "x"))
        XCTAssertThrowsError(try profiles.delete(profiles.profiles[0])) {
            XCTAssertEqual(($0 as? ProfileStore.ProfileError)?.errorDescription, ProfileStore.ProfileError.cannotDeleteDefault.errorDescription)
        }
        for index in 1..<ProfileStore.maxProfiles { try profiles.add(name: "P\(index)", symbol: "x") }
        XCTAssertThrowsError(try profiles.add(name: "One too many", symbol: "x"))
        XCTAssertEqual(ProfileStore.sanitizedName(String(repeating: "a", count: 100))?.count, ProfileStore.maxNameLength)
    }

    // MARK: Lock

    func testUnlockUsesAuthenticatorAndReportsFailures() async {
        let lock = AppLock()
        var allow = false
        lock.authenticator = { _ in allow ? .success(()) : .failure(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "nope"])) }
        let savedRequire = UserPreferences.shared.requireUnlock
        UserPreferences.shared.requireUnlock = true
        defer { UserPreferences.shared.requireUnlock = savedRequire }

        lock.lockIfEnabled(reason: "test")
        XCTAssertTrue(lock.isLocked)
        await lock.unlock()
        XCTAssertTrue(lock.isLocked)
        XCTAssertEqual(lock.lastError, "nope")
        allow = true
        await lock.unlock()
        XCTAssertFalse(lock.isLocked)
        XCTAssertNil(lock.lastError)
    }

    func testRoutesAreIgnoredWhileLocked() async {
        let lock = AppLock.shared
        let savedRequire = UserPreferences.shared.requireUnlock
        let savedAuthenticator = lock.authenticator
        UserPreferences.shared.requireUnlock = true
        lock.authenticator = { _ in .success(()) }
        defer {
            UserPreferences.shared.requireUnlock = savedRequire
            lock.authenticator = savedAuthenticator
        }
        let appState = AppState.shared
        let before = appState.windowSession.searchQuery

        lock.lockIfEnabled(reason: "test")
        XCTAssertTrue(lock.isLocked)
        appState.perform(.search("blocked-query"))
        XCTAssertEqual(appState.windowSession.searchQuery, before, "a deep link must not reach the library while locked")

        await lock.unlock()
        XCTAssertFalse(lock.isLocked)
    }

    func testLockDoesNothingWhenDisabled() {
        let lock = AppLock()
        let savedRequire = UserPreferences.shared.requireUnlock
        UserPreferences.shared.requireUnlock = false
        defer { UserPreferences.shared.requireUnlock = savedRequire }
        guard !ProfileStore.shared.active.requiresUnlock else { return }
        lock.lockIfEnabled(reason: "test")
        XCTAssertFalse(lock.isLocked)
    }

    func testProfileLockCannotBeBypassedByPlistTampering() throws {
        let suite = UserDefaults(suiteName: "cs-profiles-tamper-\(UUID().uuidString)")!
        let store = ProfileStore(defaults: suite)
        let lockedProfile = try store.add(name: "SecretProfile", symbol: "lock.fill", requiresUnlock: true)
        XCTAssertTrue(lockedProfile.requiresUnlock)

        // Simulate an attacker modifying UserDefaults plist on disk
        // to set requiresUnlock = false for all profiles
        var attackerProfiles = store.profiles
        for i in attackerProfiles.indices {
            attackerProfiles[i].requiresUnlock = false
        }
        suite.set(try JSONEncoder().encode(attackerProfiles), forKey: "profiles.v1")

        // Reload ProfileStore from UserDefaults
        let reloaded = ProfileStore(defaults: suite)
        let reloadedProfile = reloaded.profiles.first { $0.id == lockedProfile.id }
        XCTAssertNotNil(reloadedProfile)
        // Keychain must enforce that requiresUnlock is restored to true
        XCTAssertTrue(reloadedProfile?.requiresUnlock == true, "Keychain security record must restore requiresUnlock")
    }
}
