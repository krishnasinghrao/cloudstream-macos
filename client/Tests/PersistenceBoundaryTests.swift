import SwiftData
import SwiftUI
import XCTest
@testable import CloudStream

@MainActor
final class PersistenceBoundaryTests: XCTestCase {
    private enum Fault: Error { case injected }

    private func snapshot() -> LibraryStore.LibrarySnapshot {
        var item = BackupDocument.Item(id: "P|https://example.test/title", title: "Incoming",
            posterURL: nil, bannerURL: nil, providerName: "P", providerURL: "https://example.test/title",
            mediaType: "Movie", watchTypeRaw: WatchType.watching.rawValue, isFavorite: false,
            lastEpisodeData: nil, lastSeason: nil, lastEpisode: nil, progressSeconds: 0,
            totalDurationSeconds: 0, lastUpdated: Date(), createdAt: Date())
        item.userNote = "preserved"
        return .init(items: [item], episodes: [], playback: [])
    }

    private func details(episodes: [EpisodeDto] = []) -> DetailsDto {
        DetailsDto(provider: "P", url: "https://example.test/title", name: "Incoming", type: episodes.isEmpty ? "Movie" : "TvSeries",
            posterUrl: nil, backgroundPosterUrl: nil, logoUrl: nil, plot: nil, year: nil,
            durationMinutes: nil, score: nil, tags: [], actors: [], contentRating: nil,
            comingSoon: false, episodes: episodes, movieData: episodes.isEmpty ? "movie" : nil)
    }

    func testDownloadEntryIsWrittenToItsOwningProfileWithoutSwitchingTheVisibleOne() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("origin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(storeDirectory: directory)
        let file = directory.appendingPathComponent("video.mp4").path
        let id = UUID()
        try store.upsertDownloadRecord(id: id, title: "Shared video", episodeLabel: "Movie", provider: "P",
            episodeData: "movie", destinationPath: file, statusRaw: 4, originProfileID: UUID())
        try store.activateProfileStore(named: "profile-a")
        try store.activateProfileStore(named: "profile-b")
        let owner = try store.captureProfileOperation()
        let version = store.version

        // B is selected; the entry is filed into A, which queued the download.
        try store.markDownloaded(downloadID: id, provider: "P", url: file, title: "Shared video", inProfileStore: "profile-a")
        XCTAssertTrue(store.owns(owner), "the visible profile was not switched")
        XCTAssertEqual(store.version, version)
        XCTAssertNil(try store.item(id: LibraryIdentity.localDownload(id)), "B's library is untouched")
        try store.activateProfileStore(named: nil)
        XCTAssertNil(try store.item(id: LibraryIdentity.localDownload(id)), "the default library is untouched")
        try store.activateProfileStore(named: "profile-a")
        XCTAssertEqual(try store.item(id: LibraryIdentity.localDownload(id))?.providerURL, file)
        XCTAssertEqual(try store.downloadRecords().map(\.id), [id], "the download itself stays shared")

        // Default profile as owner while A is selected.
        let second = UUID()
        try store.upsertDownloadRecord(id: second, title: "Second", episodeLabel: "Movie", provider: "P",
            episodeData: "movie-2", destinationPath: file + "2", statusRaw: 4)
        try store.markDownloaded(downloadID: second, provider: "P", url: file + "2", title: "Second",
                                 inProfileStore: LibraryStore.defaultStoreName)
        XCTAssertNil(try store.item(id: LibraryIdentity.localDownload(second)))

        // A deleted profile is unavailable; no store is created for it.
        XCTAssertThrowsError(try store.markDownloaded(downloadID: id, provider: "P", url: file, title: "x", inProfileStore: "profile-gone"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("profile-gone.store").path))
        // An incomplete or mismatched record cannot be filed anywhere.
        XCTAssertThrowsError(try store.markDownloaded(downloadID: id, provider: "P", url: "/other", title: "x", inProfileStore: "profile-b"))

        // Removing the entry from the owning profile works the same way.
        try store.activateProfileStore(named: "profile-b")
        try store.removeDownloadedEntry(downloadID: id, inProfileStore: "profile-a")
        try store.removeDownloadedEntry(downloadID: id, inProfileStore: "profile-gone")
        try store.activateProfileStore(named: "profile-a")
        XCTAssertNil(try store.item(id: LibraryIdentity.localDownload(id)))
        try store.activateProfileStore(named: nil)
        XCTAssertNotNil(try store.item(id: LibraryIdentity.localDownload(second)))
    }

    func testDiskStoresReopenWithProfileAndDownloadDomainsPreserved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("persistence-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloadID = UUID()
        var writer: LibraryStore? = LibraryStore(storeDirectory: directory)
        try XCTUnwrap(writer).importSnapshot(snapshot(), mode: .replace)
        try XCTUnwrap(writer).upsertDownloadRecord(id: downloadID, title: "Shared video", episodeLabel: "Movie",
            provider: "P", episodeData: "movie", destinationPath: directory.appendingPathComponent("video.mp4").path,
            statusRaw: 0)
        try XCTUnwrap(writer).activateProfileStore(named: "owned-profile")
        XCTAssertTrue(try XCTUnwrap(writer).allEntries().isEmpty)
        try XCTUnwrap(writer).setUserNote(details: details(), note: "profile-specific")
        writer = nil

        let reopened = LibraryStore(storeDirectory: directory)
        XCTAssertEqual(try reopened.exportSnapshot().items.first?.userNote, "preserved")
        XCTAssertEqual(try reopened.downloadRecords().map(\.id), [downloadID])
        try reopened.activateProfileStore(named: "owned-profile")
        XCTAssertEqual(try reopened.exportSnapshot().items.first?.userNote, "profile-specific")
        XCTAssertEqual(try reopened.downloadRecords().map(\.id), [downloadID])
        try reopened.activateProfileStore(named: nil)
        XCTAssertEqual(try reopened.exportSnapshot().items.first?.userNote, "preserved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("CloudStreamMac.store").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("owned-profile.store").path))
    }

    func testFailedDiskMutationsAndReplaceLeaveTheLastCommittedSnapshotAfterReopen() throws {
        for profile in [nil, "owned-profile"] as [String?] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rollback-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            var writer: LibraryStore? = LibraryStore(storeDirectory: directory)
            try XCTUnwrap(writer).activateProfileStore(named: profile)
            try XCTUnwrap(writer).importSnapshot(snapshot(), mode: .replace)
            writer?.persistenceFault = {
                if $0 == .mutationCommit || $0 == .restoreCommit { throw Fault.injected }
            }
            XCTAssertThrowsError(try XCTUnwrap(writer).setUserNote(details: details(), note: "never committed"))
            XCTAssertThrowsError(try XCTUnwrap(writer).importSnapshot(.init(items: [], episodes: [], playback: []), mode: .replace))
            writer = nil

            let reopened = LibraryStore(storeDirectory: directory)
            try reopened.activateProfileStore(named: profile)
            XCTAssertEqual(try reopened.exportSnapshot().items.map(\.title), ["Incoming"])
            XCTAssertEqual(try reopened.exportSnapshot().items.first?.userNote, "preserved")
        }
    }

    func testExplicitDiskRootRejectsProfilePathsAndRetainsTheActiveStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-root-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(storeDirectory: directory)
        try store.importSnapshot(snapshot(), mode: .replace)
        for invalid in ["../escaped", "/escaped", "..", "", "nested/path", "nested\\path"] {
            XCTAssertThrowsError(try store.activateProfileStore(named: invalid))
            XCTAssertEqual(try store.exportSnapshot().items.first?.userNote, "preserved")
        }
    }

    func testQueryFailuresAreDistinctFromSuccessfulEmptyData() throws {
        let store = LibraryStore(inMemory: true)
        XCTAssertTrue(try store.allEntries().isEmpty)
        store.persistenceFault = { if $0 == .queryRead { throw Fault.injected } }
        XCTAssertThrowsError(try store.allEntries())
        XCTAssertThrowsError(try store.downloadRecords())
        XCTAssertThrowsError(try store.watchHistory())
        XCTAssertThrowsError(try store.continueWatching)
        XCTAssertThrowsError(try store.favorites)
        XCTAssertThrowsError(try store.watchStats())
        XCTAssertThrowsError(try store.counts())
        XCTAssertThrowsError(try store.resumeItem(for: details()))
        XCTAssertThrowsError(try store.episodeProgress(details: details()))
        XCTAssertThrowsError(try store.playbackPrefs(itemID: "missing"))
    }

    func testFailedPlaybackWritesRetainTheLatestPositionForExplicitRetry() throws {
        let store = LibraryStore(inMemory: true)
        try store.importSnapshot(snapshot(), mode: .replace)
        let version = store.version
        store.persistenceFault = { if $0 == .mutationCommit { throw Fault.injected } }
        for position in [20.0, 70.0] {
            XCTAssertThrowsError(try store.recordProgress(details: details(), episode: nil,
                progressSeconds: position, totalDurationSeconds: 100, notifyObservers: false))
        }
        XCTAssertEqual(try store.resumeItem(for: details())?.progressSeconds, 0)
        XCTAssertEqual(store.version, version)
        XCTAssertNotNil(store.pendingProgressFailure)
        XCTAssertThrowsError(try store.exportSnapshot(), "An unsaved playback position is not a complete backup")
        XCTAssertThrowsError(try store.activateProfileStore(named: "other"), "Failed flush must not change profile ownership")
        store.persistenceFault = nil
        try store.flushPendingProgress()
        XCTAssertNil(store.pendingProgressFailure)
        XCTAssertEqual(try store.exportSnapshot().items.first?.progressSeconds, 70)
        XCTAssertEqual(store.version, version + 1)
        try store.activateProfileStore(named: "other")
        XCTAssertTrue(try store.allEntries().isEmpty)
        try store.activateProfileStore(named: nil)
        XCTAssertEqual(try store.exportSnapshot().items.first?.progressSeconds, 70)
    }

    func testProgressPlayedWhileTheOwningStoreIsUnavailableWaitsForThatStoreOnly() throws {
        let store = LibraryStore(inMemory: true)
        try store.activateProfileStore(named: "profile-a")
        try store.importSnapshot(snapshot(), mode: .replace)
        try store.activateProfileStore(named: nil)
        // Launch could not open profile A: nothing is selectable, playback still works.
        store.suspendProfileAfterStartupFailure(Fault.injected, storeName: "profile-a")
        for position in [20.0, 65.0] {
            XCTAssertThrowsError(try store.recordProgress(details: details(), episode: nil,
                progressSeconds: position, totalDurationSeconds: 100, notifyObservers: false)) {
                XCTAssertEqual($0.localizedDescription, LibraryStore.ImportError.storeUnavailable.localizedDescription)
            }
        }
        XCTAssertEqual(store.unownedProgressCount, 1, "the latest position is kept once, not per tick")
        XCTAssertNotNil(store.pendingProgressFailure)
        XCTAssertThrowsError(try store.flushPendingProgress(), "quit and backup are told the position is not saved")

        // Another profile opening must not receive it.
        try store.activateProfileStore(named: nil)
        XCTAssertTrue(try store.allEntries().isEmpty)
        XCTAssertTrue(try store.watchHistory().isEmpty)
        XCTAssertEqual(store.unownedProgressCount, 1)
        XCTAssertNoThrow(try store.flushPendingProgress(), "this profile has nothing unsaved")

        // Its owner opens: the position is saved there.
        try store.activateProfileStore(named: "profile-a")
        XCTAssertEqual(store.unownedProgressCount, 0)
        XCTAssertNil(store.pendingProgressFailure)
        XCTAssertEqual(try store.resumeItem(for: details())?.progressSeconds, 65)
    }

    func testUnsavedProgressSurvivesAQuitAndIsReplayedIntoItsOwnStore() throws {
        let journal = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: journal) }
        // First run: profile A cannot open; the position is journaled, then the app quits.
        do {
            let store = LibraryStore(inMemory: true, progressJournalURL: journal)
            store.suspendProfileAfterStartupFailure(Fault.injected, storeName: "profile-a")
            XCTAssertThrowsError(try store.recordProgress(details: details(), episode: nil, progressSeconds: 55, totalDurationSeconds: 100))
            XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
        }
        // Next run: another profile opening does not take it; profile A does.
        let store = LibraryStore(inMemory: true, progressJournalURL: journal)
        XCTAssertEqual(store.unownedProgressCount, 1)
        try store.activateProfileStore(named: nil)
        XCTAssertTrue(try store.allEntries().isEmpty)
        try store.activateProfileStore(named: "profile-a")
        XCTAssertEqual(store.unownedProgressCount, 0)
        XCTAssertEqual(try store.resumeItem(for: details())?.progressSeconds, 55)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path), "a fully saved journal is removed")
    }

    func testFailedOwnedWriteIsJournaledUntilItIsSaved() throws {
        let journal = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: journal) }
        let store = LibraryStore(inMemory: true, progressJournalURL: journal)
        try store.importSnapshot(snapshot(), mode: .replace)
        store.persistenceFault = { if $0 == .mutationCommit { throw Fault.injected } }
        XCTAssertThrowsError(try store.recordProgress(details: details(), episode: nil, progressSeconds: 30, totalDurationSeconds: 100))
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
        store.persistenceFault = nil
        try store.flushPendingProgress()
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }

    func testAdoptedProgressThatStillCannotBeSavedStaysRetainedAndRetryable() throws {
        let store = LibraryStore(inMemory: true)
        store.suspendProfileAfterStartupFailure(Fault.injected)
        XCTAssertThrowsError(try store.recordProgress(details: details(), episode: nil, progressSeconds: 40, totalDurationSeconds: 100))
        store.persistenceFault = { if $0 == .mutationCommit { throw Fault.injected } }
        try store.retryOpeningStores(profileStoreName: nil)
        XCTAssertEqual(store.unownedProgressCount, 0)
        XCTAssertNotNil(store.pendingProgressFailure, "the store opened but the write failed: still reported")
        XCTAssertThrowsError(try store.exportSnapshot())
        store.persistenceFault = nil
        try store.flushPendingProgress()
        XCTAssertEqual(try store.resumeItem(for: details())?.progressSeconds, 40)
    }

    func testBackgroundRestoreLeavesTheAppUsableAndFencesLibraryWritesUntilItCommits() async throws {
        let store = LibraryStore(inMemory: true)
        try store.importSnapshot(snapshot(), mode: .replace)
        var item = snapshot().items[0]
        item.userNote = "restored"
        let incoming = LibraryStore.LibrarySnapshot(items: [item], episodes: [], playback: [])
        // Holds the restore inside its transaction, on its own thread.
        let gate = DispatchSemaphore(value: 0)
        store.persistenceFault = { if $0 == .restoreRead { gate.wait() } }
        let restore = Task { try await store.importSnapshotInBackground(incoming, mode: .replace) }
        while !store.isImporting { await Task.yield() }

        // The main thread is free: reads answer with the state before the restore.
        XCTAssertEqual(try store.allEntries().first?.userNote, "preserved")
        // Writes to this library and a change of its owner are refused, not interleaved.
        for attempt in [{ try store.markWatched(itemID: item.id) }, { try store.activateProfileStore(named: "other") },
                        { _ = try store.importSnapshot(incoming, mode: .merge) }] {
            XCTAssertThrowsError(try attempt()) {
                XCTAssertEqual($0.localizedDescription, LibraryStore.ImportError.restoreInProgress.localizedDescription)
            }
        }
        // Playback keeps going: its position is kept without an error.
        XCTAssertNoThrow(try store.recordProgress(details: details(), episode: nil, progressSeconds: 33, totalDurationSeconds: 100))
        XCTAssertNil(store.pendingProgressFailure)
        XCTAssertEqual(try store.allEntries().first?.progressSeconds, 0, "nothing was written during the restore")

        gate.signal()
        _ = try await restore.value
        XCTAssertFalse(store.isImporting)
        let restored = try XCTUnwrap(store.allEntries().first)
        XCTAssertEqual(restored.userNote, "restored")
        XCTAssertEqual(restored.progressSeconds, 33, "the retained position was saved onto the restored library")
        XCTAssertNoThrow(try store.markWatched(itemID: item.id))
    }

    func testFailedBackgroundRestoreChangesNothingAndReleasesTheLibrary() async throws {
        let store = LibraryStore(inMemory: true)
        try store.importSnapshot(snapshot(), mode: .replace)
        let version = store.version
        store.persistenceFault = { if $0 == .restoreCommit { throw Fault.injected } }
        do {
            _ = try await store.importSnapshotInBackground(.init(items: [], episodes: [], playback: []), mode: .replace)
            XCTFail("the restore should have failed")
        } catch {}
        store.persistenceFault = nil
        XCTAssertFalse(store.isImporting)
        XCTAssertEqual(store.version, version)
        XCTAssertEqual(try store.allEntries().first?.userNote, "preserved")
        XCTAssertNoThrow(try store.markWatched(itemID: snapshot().items[0].id))
    }

    func testRecoveryFlushesEarlierEpisodesBeforeNewPlaybackWrites() throws {
        let store = LibraryStore(inMemory: true)
        let first = EpisodeDto(data: "first", name: nil, season: 1, episode: 1, posterUrl: nil,
            description: nil, score: nil, date: nil, runTimeMinutes: 24, audio: nil)
        let second = EpisodeDto(data: "second", name: nil, season: 1, episode: 2, posterUrl: nil,
            description: nil, score: nil, date: nil, runTimeMinutes: 24, audio: nil)
        let series = details(episodes: [first, second])
        store.persistenceFault = { if $0 == .mutationCommit { throw Fault.injected } }
        XCTAssertThrowsError(try store.recordProgress(details: series, episode: first,
            progressSeconds: 50, totalDurationSeconds: 100))
        store.persistenceFault = nil
        try store.recordProgress(details: series, episode: second, progressSeconds: 30, totalDurationSeconds: 100)
        try store.flushPendingProgress()
        let saved = try store.exportSnapshot()
        XCTAssertEqual(saved.items.first?.lastEpisodeData, "second")
        XCTAssertEqual(saved.items.first?.progressSeconds, 30)
        XCTAssertEqual(Set(saved.episodes.map(\.episodeData)), ["first", "second"])
        XCTAssertNil(store.pendingProgressFailure)
    }

    func testPresentationFailurePublishesAfterRenderingAndCannotLeakIntoANewGeneration() async throws {
        let store = LibraryStore(inMemory: true)
        store.persistenceFault = { if $0 == .queryRead { throw Fault.injected } }
        _ = store.readForDisplay(or: [], { try store.allEntries() })
        XCTAssertNil(store.readFailure, "No observable state may mutate synchronously during body")
        try store.activateProfileStore(named: "replacement")
        await Task.yield()
        XCTAssertNil(store.readFailure, "An old display failure must not attach to the replacement store")
        _ = store.readForDisplay(or: [], { try store.allEntries() })
        await Task.yield()
        XCTAssertNotNil(store.readFailure)
        store.persistenceFault = nil
        try store.retryOpeningStores(profileStoreName: "replacement")
        XCTAssertNil(store.readFailure)
        XCTAssertTrue(try store.allEntries().isEmpty)
    }

    func testOpeningCanRetryWithoutReplacingDataOrChangingTheSelectedProfile() throws {
        var shouldFail = true
        let store = LibraryStore(inMemory: true, containerFactory: { schema, configuration in
            if shouldFail { throw Fault.injected }
            return try ModelContainer(for: schema, configurations: configuration)
        })
        XCTAssertThrowsError(try store.counts())
        shouldFail = false
        try store.retryOpeningStores(profileStoreName: nil)
        XCTAssertEqual(store.sharedStoreHealth, .available)
        XCTAssertEqual(store.profileStoreHealth, .available)
        try store.importSnapshot(snapshot(), mode: .replace)
        try store.retryOpeningStores(profileStoreName: nil)
        XCTAssertEqual(try store.exportSnapshot().items.map(\.title), ["Incoming"])
    }

    func testFailedStartupProfileNeverFallsBackToTheDefaultProfile() throws {
        let suite = "profiles-failure-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = ProfileStore(defaults: defaults)
        let selected = try profiles.add(name: "Selected", symbol: "person")
        let initial = LibraryStore(inMemory: true)
        try profiles.select(selected, library: initial)
        var shouldFailProfile = true
        let store = LibraryStore(inMemory: true, containerFactory: { schema, configuration in
            if shouldFailProfile, configuration.first?.name == selected.storeName { throw Fault.injected }
            return try ModelContainer(for: schema, configurations: configuration)
        })
        try store.importSnapshot(snapshot(), mode: .replace) // default-profile data must not leak
        profiles.activateStoredProfile(library: store)
        XCTAssertEqual(profiles.activeID, selected.id)
        XCTAssertEqual(defaults.string(forKey: "activeProfileID"), selected.id.uuidString)
        XCTAssertThrowsError(try store.allEntries())
        XCTAssertThrowsError(try store.exportSnapshot())
        XCTAssertThrowsError(try store.importSnapshot(.init(items: [], episodes: [], playback: []), mode: .replace),
            "Recovery must not restore into the default database under the failed selected profile")
        XCTAssertNotNil(store.readFailure)
        shouldFailProfile = false
        try store.retryOpeningStores(profileStoreName: selected.storeName)
        XCTAssertNil(store.readFailure)
        XCTAssertTrue(try store.allEntries().isEmpty)
        XCTAssertEqual(profiles.activeID, selected.id)
    }

    func testFailedOrdinaryMutationRollsBackAndNeverPublishesSuccess() throws {
        let store = LibraryStore(inMemory: true)
        try store.importSnapshot(snapshot(), mode: .replace)
        let version = store.version
        store.persistenceFault = { if $0 == .mutationCommit { throw Fault.injected } }
        XCTAssertThrowsError(try store.setUserNote(details: details(), note: "unsaved"))
        XCTAssertEqual(store.version, version)
        store.persistenceFault = nil
        XCTAssertEqual(try store.exportSnapshot().items.first?.userNote, "preserved")
        try store.setUserNote(details: details(), note: "retry saved")
        XCTAssertEqual(try store.exportSnapshot().items.first?.userNote, "retry saved")
        XCTAssertEqual(store.version, version + 1)
    }

    func testReadFailureInMutationDoesNotInsertAFakeMissingItem() throws {
        let store = LibraryStore(inMemory: true)
        store.persistenceFault = { if $0 == .mutationRead { throw Fault.injected } }
        XCTAssertThrowsError(try store.upsertLibraryEntry(details: details(), watchType: .watching))
        XCTAssertEqual(store.version, 0)
        store.persistenceFault = nil
        XCTAssertTrue(try store.exportSnapshot().items.isEmpty)
    }

    func testDownloadAndLibraryMutationsDoNotSaveAnUnrelatedContext() throws {
        let store = LibraryStore(inMemory: true)
        let unrelated = try XCTUnwrap(store.container).mainContext
        unrelated.autosaveEnabled = false
        unrelated.insert(StoredMediaItem(id: "pending", title: "Pending", posterURL: nil,
            bannerURL: nil, providerName: "P", providerURL: "pending", mediaType: "Movie", watchType: nil))
        try store.setUserNote(details: details(), note: "owned")
        XCTAssertTrue(unrelated.hasChanges)
        let id = UUID()
        store.persistenceFault = { if $0 == .mutationCommit { throw Fault.injected } }
        XCTAssertThrowsError(try store.upsertDownloadRecord(id: id, title: "T", episodeLabel: "Movie",
            provider: "P", episodeData: "movie", destinationPath: "/fixture/video.mp4", statusRaw: 0))
        XCTAssertTrue(unrelated.hasChanges)
        XCTAssertTrue(try store.downloadRecords().isEmpty)
        store.persistenceFault = nil
        try store.upsertDownloadRecord(id: id, title: "T", episodeLabel: "Movie", provider: "P",
            episodeData: "movie", destinationPath: "/fixture/video.mp4", statusRaw: 0)
        XCTAssertEqual(try store.downloadRecords().map(\.id), [id])
        XCTAssertTrue(unrelated.hasChanges)
        unrelated.rollback()
    }

    func testOpenFailureCannotExportAnApparentlyEmptyLibrary() throws {
        let store = LibraryStore(inMemory: true, containerFactory: { _, _ in throw Fault.injected })
        guard case .failed = store.sharedStoreHealth else { return XCTFail("Missing open failure") }
        XCTAssertThrowsError(try store.exportSnapshot())
        XCTAssertThrowsError(try store.importSnapshot(snapshot(), mode: .replace))
        XCTAssertEqual(store.version, 0)
    }

    func testSnapshotReadFailurePropagatesWithoutChangingDataOrVersion() throws {
        let store = LibraryStore(inMemory: true)
        try store.importSnapshot(snapshot(), mode: .replace)
        let version = store.version
        store.persistenceFault = { boundary in
            if boundary == .snapshotRead { throw Fault.injected }
        }
        XCTAssertThrowsError(try store.exportSnapshot())
        XCTAssertEqual(store.version, version)
        store.persistenceFault = nil
        XCTAssertEqual(try store.exportSnapshot().items.first?.userNote, "preserved")
    }

    func testFailedRestoreRollsBackOnlyItsOwnContextForEveryProfile() throws {
        for profile in [nil, "isolated-profile"] as [String?] {
            let store = LibraryStore(inMemory: true)
            try store.activateProfileStore(named: profile)
            try store.importSnapshot(snapshot(), mode: .replace)
            let version = store.version
            let shared = try XCTUnwrap(store.container).mainContext
            shared.autosaveEnabled = false
            let unrelated = StoredMediaItem(id: "pending-unrelated", title: "Pending",
                posterURL: nil, bannerURL: nil, providerName: "P", providerURL: "pending",
                mediaType: "Movie", watchType: nil)
            shared.insert(unrelated)
            store.persistenceFault = { boundary in
                if boundary == .restoreCommit { throw Fault.injected }
            }
            XCTAssertThrowsError(try store.importSnapshot(.init(items: [], episodes: [], playback: []), mode: .replace))
            XCTAssertEqual(store.version, version)
            XCTAssertTrue(shared.hasChanges)
            XCTAssertTrue(shared.insertedModelsArray.contains { $0.persistentModelID == unrelated.persistentModelID })
            store.persistenceFault = nil
            XCTAssertEqual(try store.exportSnapshot().items.map(\.title), ["Incoming"])
            shared.rollback()
        }
    }

    func testSuccessfulRestoreRefreshesFacadeWithoutCommittingUnrelatedWork() throws {
        let store = LibraryStore(inMemory: true)
        let shared = try XCTUnwrap(store.container).mainContext
        shared.autosaveEnabled = false
        let unrelated = StoredMediaItem(id: "pending", title: "Pending", posterURL: nil,
            bannerURL: nil, providerName: "P", providerURL: "pending", mediaType: "Movie", watchType: nil)
        shared.insert(unrelated)
        try store.importSnapshot(snapshot(), mode: .replace)
        XCTAssertEqual(try store.allEntries().map(\.title), ["Incoming"])
        XCTAssertTrue(shared.hasChanges)
        XCTAssertEqual(shared.insertedModelsArray.count, 1)
        shared.rollback()
    }

    func testReplaceRejectsAnUnreadableSafetySnapshotBeforeAnyMutation() async throws {
        let store = LibraryStore(inMemory: true)
        try store.importSnapshot(snapshot(), mode: .replace)
        let version = store.version
        let service = BackupService()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        service.backupsDirectoryOverride = directory
        defer { try? FileManager.default.removeItem(at: directory) }
        store.persistenceFault = { boundary in
            if boundary == .snapshotRead { throw Fault.injected }
        }
        let empty = LibraryStore.LibrarySnapshot(items: [], episodes: [], playback: [])
        let pending = BackupService.Pending(source: .android(itemCount: 0), snapshot: empty, document: nil)
        do {
            _ = try await service.restore(pending, mode: .replace, includePreferences: false, appState: nil, store: store)
            XCTFail("Replace must not proceed with an unreadable safety snapshot")
        } catch {
            guard case .safetyBackupFailed = error as? BackupService.RestoreError else {
                return XCTFail("Unexpected restore error: \(error)")
            }
        }
        XCTAssertEqual(store.version, version)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        store.persistenceFault = nil
        XCTAssertEqual(try store.exportSnapshot().items.map(\.title), ["Incoming"])
    }
}

/// Measured large-library behavior (plan E01). Gated: set
/// CS_LARGE_LIBRARY_TESTS=1 to run; an ordinary unit run reports it as skipped.
/// The bounds are generous regressions guards, not performance targets; the
/// printed timings are the evidence.
@MainActor
final class LargeLibraryMeasurementTests: XCTestCase {
    private func snapshot(titles: Int, episodesPerTitle: Int, stamp: Date, allWatching: Bool = false) -> LibraryStore.LibrarySnapshot {
        var items: [BackupDocument.Item] = [], episodes: [BackupDocument.Episode] = []
        items.reserveCapacity(titles); episodes.reserveCapacity(titles * episodesPerTitle)
        for index in 0..<titles {
            let url = "https://large.example/title/\(index)"
            let id = LibraryIdentity.remote(providerID: "inst:Large", url: url)
            items.append(.init(id: id, title: "Title \(index)", posterURL: nil, bannerURL: nil, providerName: "Large",
                providerURL: url, mediaType: "TvSeries", watchTypeRaw: allWatching ? WatchType.watching.rawValue : index % 5, isFavorite: index % 7 == 0,
                lastEpisodeData: "e-\(index)-0", lastSeason: 1, lastEpisode: 1, progressSeconds: Double(20 + index % 900),
                totalDurationSeconds: 1440, lastUpdated: stamp, createdAt: stamp.addingTimeInterval(-Double(index)),
                knownEpisodeCount: episodesPerTitle, userNote: index % 50 == 0 ? "note" : nil, userRating: index % 6,
                providerID: "inst:Large", identityVersion: LibraryIdentity.version, identityResolution: "resolved",
                noteUpdatedAt: index % 50 == 0 ? stamp : nil, ratingUpdatedAt: stamp, favoriteUpdatedAt: stamp,
                watchTypeUpdatedAt: stamp, progressUpdatedAt: stamp))
            for episode in 0..<episodesPerTitle {
                episodes.append(.init(itemID: id, episodeData: "e-\(index)-\(episode)", season: 1, episode: episode + 1,
                    positionSeconds: 300, durationSeconds: 1440, watched: episode % 2 == 0,
                    updatedAt: stamp.addingTimeInterval(-Double(index * episodesPerTitle + episode)), kind: "episode", audio: nil))
            }
        }
        return .init(items: items, episodes: episodes, playback: [])
    }

    @discardableResult
    private func timed<T>(_ label: String, limit: Double, _ work: () throws -> T) rethrows -> T {
        let start = ContinuousClock.now
        let result = try work()
        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print("LARGE-LIBRARY \(label): \(String(format: "%.3f", seconds)) s")
        XCTAssertLessThan(seconds, limit, "\(label) regressed")
        return result
    }

    func testTenThousandTitlesFiftyThousandHistoryRows() throws {
        guard ProcessInfo.processInfo.environment["CS_LARGE_LIBRARY_TESTS"] == "1" else {
            throw XCTSkip("Set CS_LARGE_LIBRARY_TESTS=1 to run large-library measurements")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("large-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let stamp = Date(timeIntervalSince1970: 1_790_000_000)
        let large = snapshot(titles: 10_000, episodesPerTitle: 5, stamp: stamp)
        var store: LibraryStore? = LibraryStore(storeDirectory: directory)
        try timed("replace-import 10k titles + 50k history", limit: 60) { try XCTUnwrap(store).importSnapshot(large, mode: .replace) }
        store = nil
        let reopened = timed("reopen store (incl. migrations)", limit: 20) { LibraryStore(storeDirectory: directory) }
        XCTAssertEqual(reopened.profileStoreHealth, .available)
        let counts = try timed("counts", limit: 5) { try reopened.counts() }
        XCTAssertEqual([counts.watching, counts.planToWatch, counts.completed, counts.onHold, counts.dropped, counts.favorites],
                       [2000, 2000, 2000, 2000, 2000, 1429])
        XCTAssertEqual(try timed("all library entries", limit: 5) { try reopened.allEntries() }.count, 10_000)
        XCTAssertFalse(try timed("continue watching", limit: 5) { try reopened.continueWatching }.isEmpty)
        XCTAssertEqual(try timed("history page (500)", limit: 5) { try reopened.watchHistory(limit: 500) }.count, 500)
        XCTAssertEqual(try timed("watch statistics", limit: 10) { try reopened.watchStats() }.titles, 10_000)
        let details = DetailsDto(provider: "Large", providerId: "inst:Large", url: "https://large.example/title/5000", name: "Title 5000",
            type: "TvSeries", posterUrl: nil, backgroundPosterUrl: nil, logoUrl: nil, plot: nil, year: nil, durationMinutes: nil,
            score: nil, tags: [], actors: [], contentRating: nil, comingSoon: false,
            episodes: [EpisodeDto(data: "e-5000-0", name: nil, season: 1, episode: 1, posterUrl: nil, description: nil, score: nil,
                                  date: nil, runTimeMinutes: nil, audio: nil)], movieData: nil)
        // The high-frequency path: one playback tick must not scan the library.
        try timed("100 playback progress writes", limit: 5) {
            for tick in 0..<100 {
                try reopened.recordProgress(details: details, episode: details.episodes[0], progressSeconds: Double(400 + tick),
                                            totalDurationSeconds: 1440, notifyObservers: false)
            }
        }
        try timed("one list-status mutation", limit: 2) { try reopened.setWatchType(details: details, watchType: .completed) }
        let exported = try timed("export snapshot", limit: 20) { try reopened.exportSnapshot() }
        XCTAssertEqual(exported.items.count, 10_000)
        XCTAssertEqual(exported.episodes.count, 50_000)
        _ = try timed("backup validate + encode", limit: 20) {
            try BackupDocument(createdAt: stamp, appVersion: "t", items: exported.items, episodes: exported.episodes,
                               playback: [], preferences: [:], repositories: [], disabledProviders: []).encoded()
        }
        // Merge of a newer copy of the whole library into itself.
        let newer = snapshot(titles: 10_000, episodesPerTitle: 5, stamp: stamp.addingTimeInterval(3600))
        try timed("merge 10k titles + 50k history", limit: 90) { try reopened.importSnapshot(newer, mode: .merge) }
        XCTAssertEqual(try reopened.allEntries().count, 10_000)
    }

    /// Section 4: the real Library screen with 10 000 titles in one
    /// collection (CS_LARGE_LIBRARY_TITLES overrides the count) — fetch and
    /// sort, the grid's first build, scrolling, and the re-render after a
    /// library change.
    func testScrollingALargeCollection() async throws {
        guard ProcessInfo.processInfo.environment["CS_LARGE_LIBRARY_TESTS"] == "1" else {
            throw XCTSkip("Set CS_LARGE_LIBRARY_TESTS=1 to run large-library measurements")
        }
        let titles = Int(ProcessInfo.processInfo.environment["CS_LARGE_LIBRARY_TITLES"] ?? "") ?? 10_000
        let store = LibraryStore.shared   // in memory under tests
        let stamp = Date(timeIntervalSince1970: 1_790_000_000)
        try store.importSnapshot(snapshot(titles: titles, episodesPerTitle: 0, stamp: stamp, allWatching: true), mode: .replace)
        defer { _ = try? store.importSnapshot(.init(items: [], episodes: [], playback: []), mode: .replace) }
        let fetched = try timed("fetch one collection (\(titles))", limit: 5) { try store.items(withWatchType: .watching) }
        XCTAssertEqual(fetched.count, titles)
        for order in LibraryView.SortOrder.allCases {
            timed("sort \(titles) by \(order)", limit: 2) { _ = LibraryView.filterAndSort(fetched, query: "", order: order) }
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: LibraryView(collection: .watching).environment(WindowSession()).environment(AppState.shared))
        window.contentView = host
        window.orderFront(nil)
        func render() { host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }
        func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap(scrollView(in:)).first
        }
        func seconds(since start: ContinuousClock.Instant) -> Double {
            let elapsed = ContinuousClock.now - start
            return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        }
        // SwiftUI builds the body on a later run-loop turn, so every timing
        // includes one 5 ms yield to the main run loop: that is where the
        // window would be blocked. The first build reads the store, arranges
        // the collection and draws the first screen of cards.
        let opened = ContinuousClock.now
        render()
        try await Task.sleep(for: .milliseconds(5))
        render()
        let firstBuild = seconds(since: opened)
        let scroll = try XCTUnwrap(scrollView(in: host), "the grid appeared")
        var steps: [Double] = []
        for step in 1...60 {
            let start = ContinuousClock.now
            scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(step) * 400))
            scroll.reflectScrolledClipView(scroll.contentView)
            render()
            try await Task.sleep(for: .milliseconds(5))
            steps.append(seconds(since: start))
        }
        let scrolling = steps
        print("LARGE-LIBRARY \(titles) titles: first build \(Int(firstBuild * 1000)) ms; scroll steps of 400 pt mean \(Int(scrolling.reduce(0, +) / Double(scrolling.count) * 1000)) ms, slowest \(Int((scrolling.max() ?? 0) * 1000)) ms")
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 1_000, "the grid scrolled")
        XCTAssertLessThan(firstBuild, 3, "first build regressed")
        XCTAssertLessThan(scrolling.max() ?? 0, 0.25, "a scroll step stalls")
        let item = try XCTUnwrap(fetched.last)
        try store.setWatchType(itemIDs: [item.id], watchType: .completed)
        let changed = ContinuousClock.now
        render()
        try await Task.sleep(for: .milliseconds(5))
        render()
        let rerender = seconds(since: changed)
        print("LARGE-LIBRARY \(titles) titles: re-render after one change \(Int(rerender * 1000)) ms")
        XCTAssertLessThan(rerender, 2, "re-render after a change regressed")
    }
}
