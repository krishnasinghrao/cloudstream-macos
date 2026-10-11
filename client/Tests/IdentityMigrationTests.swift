import SQLite3
import Darwin
import SwiftData
import XCTest
@testable import CloudStream

@MainActor
final class IdentityMigrationTests: XCTestCase {
    func testActualOldSchemaUpgradesAndItsOriginalRecoveryOpensWithOldModel() throws {
        guard let tool = ProcessInfo.processInfo.environment["CS_IDENTITY_LEGACY_TOOL"],
              FileManager.default.isExecutableFile(atPath: tool) else {
            throw XCTSkip("Build the frozen legacy schema tool and set CS_IDENTITY_LEGACY_TOOL to run old-schema compatibility")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("old-schema-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("CloudStreamMac.store")
        _ = try runLegacyTool(tool, mode: "create", store: source)
        XCTAssertTrue(try SQLiteRecoverySnapshot.needsSchemaRecovery(source))
        let current = LibraryStore(storeDirectory: root)
        XCTAssertEqual(current.sharedStoreHealth, .available)
        let oldID = "P|https://fixture.test/old"
        XCTAssertEqual(try current.item(id: oldID)?.userNote, "Old schema note")
        let legacyFields = try XCTUnwrap(current.item(id: oldID))
        // History fields added later default to an episode of unknown edition;
        // the one-time backfill keeps the existing row and commits its marker.
        XCTAssertNil(legacyFields.lastAudio)
        let oldHistory = try current.watchHistory()
        XCTAssertEqual(oldHistory.map(\.kind), [EpisodeProgress.episodeKind])
        XCTAssertNil(oldHistory.first?.audio)
        XCTAssertEqual(try current.container!.mainContext.fetch(FetchDescriptor<LibraryMigrationRecord>())
            .filter { $0.name == LibraryStore.historyMigrationName }.count, 1)
        XCTAssertNil(legacyFields.noteUpdatedAt)
        XCTAssertNil(legacyFields.ratingUpdatedAt)
        XCTAssertNil(legacyFields.favoriteUpdatedAt)
        XCTAssertNil(legacyFields.watchTypeUpdatedAt)
        XCTAssertNil(legacyFields.progressUpdatedAt)
        try current.migrateProviderIdentities(providers: [])
        let marker = try XCTUnwrap(current.container!.mainContext.fetch(FetchDescriptor<LibraryMigrationRecord>()).first { $0.name == "provider-identity-v2" })
        let schemaCopy = URL(fileURLWithPath: try XCTUnwrap(marker.schemaRecoverySnapshotPath))
        try SQLiteRecoverySnapshot.verify(schemaCopy)
        XCTAssertTrue(try SQLiteRecoverySnapshot.needsSchemaRecovery(schemaCopy))
        let recovered = try runLegacyTool(tool, mode: "inspect", store: schemaCopy)
        XCTAssertEqual(recovered["itemID"] as? String, oldID)
        XCTAssertEqual(recovered["episodeOwner"] as? String, oldID)
        XCTAssertEqual(recovered["note"] as? String, "Old schema note")
        XCTAssertEqual(recovered["speed"] as? Double, 1.5)
        XCTAssertEqual(recovered["downloads"] as? Int, 1)
        let newID = LibraryIdentity.remote(providerID: "stable-old", url: "https://fixture.test/old")
        XCTAssertEqual(try current.item(id: oldID)?.id, newID)
        XCTAssertEqual(try current.episodeProgress(itemID: newID)["old-episode"]?.positionSeconds, 123)
        XCTAssertEqual(try current.downloadRecords().count, 1)
    }

    func testKilledMigrationReopensSameStoreAndRecoversOriginalSchemaAtEveryBoundary() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let oldTool = environment["CS_IDENTITY_LEGACY_TOOL"],
              let app = environment["CS_IDENTITY_PROCESS_APP"],
              FileManager.default.isExecutableFile(atPath: oldTool), FileManager.default.isExecutableFile(atPath: app) else {
            throw XCTSkip("Run the identity compatibility command to provision the old schema and separate debug app process")
        }
        for profile in [nil, "CloudStreamMac-Profile-fixture"] as [String?] {
          for phase in ["schema-snapshot", "schema-opened", "identity-commit", "identity-committed"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("identity-kill-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let source = root.appendingPathComponent((profile ?? "CloudStreamMac") + ".store")
            if profile != nil { _ = try runLegacyTool(oldTool, mode: "create", store: root.appendingPathComponent("CloudStreamMac.store")) }
            _ = try runLegacyTool(oldTool, mode: profile == nil ? "create" : "create-profile", store: source)
            try await killMigrationProcess(app, phase: phase, root: root, profile: profile)
            let reopened = LibraryStore(storeDirectory: root)
            XCTAssertEqual(reopened.sharedStoreHealth, .available, phase)
            let oldID = "P|https://fixture.test/old"
            let newID = LibraryIdentity.remote(providerID: "stable-old", url: "https://fixture.test/old")
            XCTAssertEqual(try storedKey(source), phase == "identity-committed" ? newID : oldID, phase)
            if let profile { try reopened.activateProfileStore(named: profile) }
            else { try reopened.migrateProviderIdentities(providers: []) }
            let row = try XCTUnwrap(reopened.item(id: oldID))
            XCTAssertEqual(row.id, newID, phase)
            XCTAssertEqual(row.userNote, "Old schema note", phase)
            XCTAssertEqual(try reopened.episodeProgress(itemID: newID)["old-episode"]?.positionSeconds, 123, phase)
            XCTAssertEqual(try reopened.playbackPrefs(itemID: newID)?.speed, 1.5, phase)
            XCTAssertEqual(try reopened.downloadRecords().count, 1, phase)
            let schema = Schema(profile == nil ? LibraryStore.modelTypes : LibraryStore.profileModelTypes)
            let inspected = try ModelContainer(for: schema, configurations: [ModelConfiguration("Inspect", schema: schema, url: source, cloudKitDatabase: .none)])
            let marker = try XCTUnwrap(inspected.mainContext.fetch(FetchDescriptor<LibraryMigrationRecord>()).first { $0.name == "provider-identity-v2" })
            let original = URL(fileURLWithPath: try XCTUnwrap(marker.schemaRecoverySnapshotPath, phase))
            try SQLiteRecoverySnapshot.verify(original)
            let oldModel = try runLegacyTool(oldTool, mode: profile == nil ? "inspect" : "inspect-profile", store: original)
            XCTAssertEqual(oldModel["itemID"] as? String, oldID, phase)
            XCTAssertEqual(oldModel["note"] as? String, "Old schema note", phase)
            XCTAssertTrue(try reopened.migrateProviderIdentities(providers: []).changes.isEmpty, phase)
            if profile != nil {
                let shared = LibraryStore(storeDirectory: root)
                XCTAssertEqual(try shared.item(id: oldID)?.id, oldID, "Profile migration cannot rekey another owner's title")
                XCTAssertEqual(try shared.downloadRecords().count, 1)
            }
          }
        }
    }

    func testRecoveryRediscoveryRejectsSameBasenameFromAnotherStore() throws {
        guard let tool = ProcessInfo.processInfo.environment["CS_IDENTITY_LEGACY_TOOL"],
              FileManager.default.isExecutableFile(atPath: tool) else { throw XCTSkip("Run the identity compatibility command") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("identity-lineage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first/CloudStreamMac.store")
        let second = root.appendingPathComponent("second/CloudStreamMac.store")
        _ = try runLegacyTool(tool, mode: "create", store: first)
        _ = try runLegacyTool(tool, mode: "create", store: second)
        let directory = root.appendingPathComponent("IdentityRecovery")
        let snapshot = try SQLiteRecoverySnapshot.create(source: first, directory: directory, reason: "before-provider-identity-schema-v2")
        XCTAssertEqual(try SQLiteRecoverySnapshot.originalSchemaSnapshot(source: first, directory: directory)?.resolvingSymlinksInPath(), snapshot.resolvingSymlinksInPath())
        XCTAssertNil(try SQLiteRecoverySnapshot.originalSchemaSnapshot(source: second, directory: directory))
        let unpublished = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: unpublished, withIntermediateDirectories: true)
        try Data("partial copy".utf8).write(to: unpublished.appendingPathComponent("recovery.store"))
        XCTAssertEqual(try SQLiteRecoverySnapshot.originalSchemaSnapshot(source: first, directory: directory)?.resolvingSymlinksInPath(), snapshot.resolvingSymlinksInPath())
        let unrelated = try SQLiteRecoverySnapshot.create(source: second, directory: directory, reason: "before-provider-identity-schema-v2")
        try Data("malformed unrelated manifest".utf8).write(to: unrelated.deletingLastPathComponent().appendingPathComponent("manifest.json"))
        XCTAssertEqual(try SQLiteRecoverySnapshot.originalSchemaSnapshot(source: first, directory: directory)?.resolvingSymlinksInPath(), snapshot.resolvingSymlinksInPath())
        try Data("corrupt published snapshot".utf8).write(to: snapshot)
        XCTAssertThrowsError(try SQLiteRecoverySnapshot.originalSchemaSnapshot(source: first, directory: directory))
    }

    private func killMigrationProcess(_ app: String, phase: String, root: URL, profile: String?) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: app)
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(),
            "CS_IN_MEMORY_DB": "1", "CS_TEST_ROOT": root.path, "CS_IDENTITY_PROCESS_PHASE": phase]
        if let profile { process.environment?["CS_IDENTITY_PROCESS_PROFILE"] = profile }
        let logURL = root.appendingPathComponent("child.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        process.standardOutput = log
        process.standardError = log
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        defer { cleanupMigrationProcess(process, exited: exited) }
        let ready = root.appendingPathComponent("identity-process-ready")
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !FileManager.default.fileExists(atPath: ready.path) {
            guard process.isRunning, ContinuousClock.now < deadline else {
                XCTFail("Migration process did not reach boundary: \(phase), exit \(process.isRunning ? -1 : process.terminationStatus)")
                throw URLError(.timedOut)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(try String(contentsOf: ready, encoding: .utf8), phase)
        XCTAssertEqual(kill(process.processIdentifier, SIGKILL), 0)
        let exitDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while process.isRunning, ContinuousClock.now < exitDeadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(process.isRunning)
        guard !process.isRunning else { throw URLError(.timedOut) }
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGKILL)
    }

    private func storedKey(_ source: URL) throws -> String {
        var database: OpaquePointer?, statement: OpaquePointer?
        guard sqlite3_open_v2(source.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw Fault.injected }
        defer { sqlite3_close(database) }
        guard sqlite3_prepare_v2(database, "SELECT ZID FROM ZSTOREDMEDIAITEM", -1, &statement, nil) == SQLITE_OK else { throw Fault.injected }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { throw Fault.injected }
        return String(cString: value)
    }

    private func cleanupMigrationProcess(_ process: Process, exited: DispatchSemaphore) {
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + 3)
        }
    }

    private func runLegacyTool(_ tool: String, mode: String, store: URL) throws -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = [mode, store.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        guard exited.wait(timeout: .now() + 10) == .success else {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 3)
            }
            throw URLError(.timedOut)
        }
        guard process.terminationStatus == 0 else { throw NSError(domain: "LegacySchemaFixture", code: Int(process.terminationStatus)) }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as? [String: Any])
    }
    private enum Fault: Error { case injected }
    private func legacy(_ providerID: String? = "stable", id: String = "P|https://fixture.test/title") -> BackupDocument.Item {
        var row = BackupDocument.Item(id: id, title: "Preserved title", posterURL: nil, bannerURL: nil,
            providerName: "P", providerURL: "https://fixture.test/title", mediaType: "TvSeries",
            watchTypeRaw: 3, isFavorite: true, lastEpisodeData: "episode", lastSeason: 1, lastEpisode: 2,
            progressSeconds: 100, totalDurationSeconds: 1000, lastUpdated: Date(timeIntervalSince1970: 100),
            createdAt: Date(timeIntervalSince1970: 50), knownEpisodeCount: 7,
            userNote: "Private note", userRating: 4, providerID: providerID)
        row.identityVersion = 0
        return row
    }
    private func fixture(_ store: LibraryStore, providerID: String? = "stable") throws {
        let item = legacy(providerID)
        try store.importSnapshot(.init(items: [item], episodes: [
            .init(itemID: item.id, episodeData: "episode", season: 1, episode: 2,
                  positionSeconds: 100, durationSeconds: 1000, watched: false, updatedAt: item.lastUpdated)
        ], playback: [
            .init(itemID: item.id, audioLanguage: "ja", subtitleLanguage: "en", subtitlesOff: false,
                  subtitleDelay: -2, speed: 1.5, introStart: 5, introEnd: 30, updatedAt: item.lastUpdated)
        ]), mode: .replace)
    }

    func testLocalDownloadUUIDSeparatesPlaybackAndSurvivesDisplayNameAndPathChanges() throws {
        let store = LibraryStore(inMemory: true)
        let first = UUID(), second = UUID()
        for (id, path) in [(first, "/fixture/a.mkv"), (second, "/fixture/b.mkv")] {
            try store.upsertDownloadRecord(id: id, title: "Local", episodeLabel: "", provider: "P",
                episodeData: "", destinationPath: path, statusRaw: 4)
            try store.markDownloaded(downloadID: id, provider: "P", url: path, title: "Local")
            let item = try XCTUnwrap(store.item(id: LibraryIdentity.localDownload(id)))
            let details = store.detailsPreview(for: item)
            XCTAssertEqual(details.localDownloadID, id)
            XCTAssertEqual(details.id, item.id)
            XCTAssertNil(details.providerId)
            try store.recordProgress(details: details, episode: nil, progressSeconds: id == first ? 10 : 20, totalDurationSeconds: 100)
        }
        XCTAssertEqual(try store.item(id: LibraryIdentity.localDownload(first))?.progressSeconds, 10)
        XCTAssertEqual(try store.item(id: LibraryIdentity.localDownload(second))?.progressSeconds, 20)
        try store.upsertDownloadRecord(id: first, title: "Local", episodeLabel: "", provider: "Renamed",
            episodeData: "", destinationPath: "/fixture/moved.mkv", statusRaw: 4)
        try store.markDownloaded(downloadID: first, provider: "Renamed", url: "/fixture/moved.mkv", title: "Local")
        XCTAssertEqual(try store.container!.mainContext.fetch(FetchDescriptor<StoredMediaItem>()).count, 2)
        XCTAssertEqual(try store.item(id: LibraryIdentity.localDownload(first))?.providerURL, "/fixture/moved.mkv")
        XCTAssertEqual(try store.item(id: LibraryIdentity.localDownload(first))?.progressSeconds, 10)
        XCTAssertTrue(try store.exportSnapshot().items.isEmpty)
        try store.removeDownloadedEntry(downloadID: first, provider: "Renamed", url: "/fixture/moved.mkv")
        XCTAssertNil(try store.item(id: LibraryIdentity.localDownload(first)))
        XCTAssertNotNil(try store.item(id: LibraryIdentity.localDownload(second)))
        XCTAssertThrowsError(try store.markDownloaded(downloadID: UUID(), provider: "P", url: "/fixture/a.mkv", title: "Wrong"))
    }

    func testLegacyLocalRekeyIncludesHistoryPreferencesAndDurableAlias() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("local-rekey-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(storeDirectory: root)
        let id = UUID(), path = "/fixture/local.mkv", old = "P|local:/fixture/local.mkv"
        try store.upsertDownloadRecord(id: id, title: "Local", episodeLabel: "", provider: "P",
            episodeData: "", destinationPath: path, statusRaw: 4)
        let context = try XCTUnwrap(store.container).mainContext
        let row = StoredMediaItem(id: old, title: "Local", providerName: "P", providerURL: path, mediaType: "Download")
        row.userNote = "Keep me"
        context.insert(row)
        try context.save()
        let details = store.detailsPreview(for: row)
        try store.recordProgress(details: details, episode: nil, progressSeconds: 12, totalDurationSeconds: 100)
        try store.updatePlaybackPrefs(itemID: old) { $0.speed = 1.5 }
        let result = try store.migrateProviderIdentities(providers: [])
        XCTAssertTrue(result.changes.isEmpty)
        XCTAssertEqual(result.localChanges.map(\.downloadID), [id])
        try SQLiteRecoverySnapshot.verify(try XCTUnwrap(result.recoverySnapshot))
        let reopened = LibraryStore(storeDirectory: root)
        let migrated = try XCTUnwrap(reopened.item(id: old))
        XCTAssertEqual(migrated.id, LibraryIdentity.localDownload(id))
        XCTAssertEqual(migrated.downloadRecordID, id)
        XCTAssertEqual(migrated.userNote, "Keep me")
        XCTAssertNil(migrated.providerID)
        XCTAssertEqual(try reopened.playbackPrefs(itemID: migrated.id)?.speed, 1.5)
        XCTAssertTrue(try reopened.migrateProviderIdentities(providers: []).localChanges.isEmpty)
    }

    func testExplicitLocalIDsNeverAliasAnotherUUIDAtTheSamePath() throws {
        let store = LibraryStore(inMemory: true)
        let first = UUID(), second = UUID(), path = "/fixture/shared.mkv"
        try store.upsertDownloadRecord(id: first, title: "First", episodeLabel: "", provider: "P",
            episodeData: "", destinationPath: path, statusRaw: 4)
        try store.markDownloaded(downloadID: first, provider: "P", url: path, title: "First")
        var details = store.detailsPreview(for: try XCTUnwrap(store.item(id: LibraryIdentity.localDownload(first))))
        details.localDownloadID = second
        try store.recordProgress(details: details, episode: nil, progressSeconds: 25, totalDurationSeconds: 100)
        XCTAssertEqual(try store.item(id: LibraryIdentity.localDownload(first))?.progressSeconds, 0)
        XCTAssertEqual(try store.item(id: LibraryIdentity.localDownload(second))?.progressSeconds, 25)
    }

    func testAmbiguousLegacyDownloadPathsRemainUnassigned() {
        let path = "/fixture/same.mkv"
        let report = LibraryIdentityMigration.plan(items: [
            .init(id: "P|local:" + path, providerID: nil, providerName: "P", url: path, isDownload: true)
        ], providers: [], downloads: [.init(id: UUID(), path: path), .init(id: UUID(), path: path)])
        XCTAssertTrue(report.localChanges.isEmpty)
        XCTAssertEqual(report.unresolved.count, 1)
    }

    func testExplicitAssignmentResolvesOnlySelectedUnknownTitleAndPreservesDependents() throws {
        let store = LibraryStore(inMemory: true)
        try fixture(store, providerID: nil)
        let providers: [LibraryIdentityMigration.Provider] = [
            .init(id: "first", name: "P"), .init(id: "second", name: "P")
        ]
        XCTAssertEqual(try store.identityMigrationPlan(providers: providers).unresolved.count, 1)
        let oldID = legacy(nil).id
        let report = try store.reassignProvider(itemID: oldID, providerID: "second", providers: providers)
        XCTAssertEqual(report.changes.count, 1)
        let newID = LibraryIdentity.remote(providerID: "second", url: legacy(nil).providerURL)
        XCTAssertEqual(try store.item(id: oldID)?.id, newID)
        XCTAssertEqual(try store.item(id: newID)?.providerID, "second")
        XCTAssertEqual(try store.item(id: newID)?.userNote, "Private note")
        XCTAssertEqual(try store.episodeProgress(itemID: newID)["episode"]?.positionSeconds, 100)
        XCTAssertEqual(try store.playbackPrefs(itemID: newID)?.speed, 1.5)
        XCTAssertThrowsError(try store.reassignProvider(itemID: newID, providerID: "first", providers: providers))
    }

    /// Two installations named alike serve different hosts (an Android
    /// backup records only the name). One choice covers the titles on the
    /// chosen title's host and leaves the other host's titles unresolved.
    func testExplicitAssignmentCoversUnresolvedTitlesOfTheSameNameAndHostOnly() throws {
        let store = LibraryStore(inMemory: true)
        func row(_ url: String, name: String = "P") -> BackupDocument.Item {
            var item = legacy(nil, id: "\(name)|\(url)")
            item.providerName = name
            item.providerURL = url
            item.lastEpisodeData = nil
            return item
        }
        let a1 = row("https://a.fixture.test/1"), a2 = row("https://a.fixture.test/2")
        let b1 = row("https://b.fixture.test/1"), other = row("https://a.fixture.test/3", name: "Q")
        try store.importSnapshot(.init(items: [a1, a2, b1, other], episodes: [], playback: []), mode: .replace)
        let providers: [LibraryIdentityMigration.Provider] = [
            .init(id: "first", name: "P"), .init(id: "second", name: "P")
        ]
        let group = try store.reassignmentGroup(itemID: a1.id, providers: providers)
        XCTAssertEqual(group, .init(providerName: "P", host: "a.fixture.test", url: a1.providerURL, siblings: [a2.id]))

        let batch = try store.reassignableBatch(itemID: a1.id, siblings: group.siblings, providerID: "first")
        XCTAssertEqual(batch, [a1.id, a2.id])
        XCTAssertEqual(try store.reassignProvider(itemIDs: batch, providerID: "first", providers: providers).changes.count, 2)
        for item in [a1, a2] {
            XCTAssertEqual(try store.item(id: LibraryIdentity.remote(providerID: "first", url: item.providerURL))?.providerID, "first")
        }
        XCTAssertNil(try XCTUnwrap(store.item(id: b1.id)).providerID)
        XCTAssertNil(try XCTUnwrap(store.item(id: other.id)).providerID)
        // A bound title is not offered again, and cannot ride along in a batch.
        XCTAssertEqual(try store.reassignmentGroup(itemID: b1.id, providers: providers).siblings, [])
        let bound = LibraryIdentity.remote(providerID: "first", url: a1.providerURL)
        XCTAssertThrowsError(try store.reassignProvider(itemIDs: [b1.id, bound], providerID: "second", providers: providers))
        XCTAssertNil(try XCTUnwrap(store.item(id: b1.id)).providerID)
    }

    func testTitleWhoseInstallationWasRemovedCanBeReassignedAndLaterChangesResolveLegacyTitles() throws {
        let store = LibraryStore(inMemory: true)
        try fixture(store, providerID: nil)
        let legacyID = legacy(nil).id
        // No provider installed yet: the title waits, untouched.
        XCTAssertEqual(try store.migrateProviderIdentities(providers: []).unresolved.count, 1)
        XCTAssertNil(try store.item(id: legacyID)?.providerID)
        // The provider is installed while the app runs: the same reconciliation binds it.
        XCTAssertEqual(try store.migrateProviderIdentities(providers: [.init(id: "old-install", name: "P")]).changes.count, 1)
        let boundID = LibraryIdentity.remote(providerID: "old-install", url: legacy(nil).providerURL)
        XCTAssertEqual(try store.item(id: boundID)?.providerID, "old-install")

        // That installation is removed and the provider reinstalled under a new identity.
        let reinstalled: [LibraryIdentityMigration.Provider] = [.init(id: "new-install", name: "P")]
        let untouched = try store.migrateProviderIdentities(providers: reinstalled)
        XCTAssertTrue(untouched.changes.isEmpty, "a recorded installation is never rebound by name")
        XCTAssertEqual(try store.item(id: boundID)?.providerID, "old-install")
        // The user may choose, because the recorded installation is gone.
        try store.reassignProvider(itemID: boundID, providerID: "new-install", providers: reinstalled)
        let newID = LibraryIdentity.remote(providerID: "new-install", url: legacy(nil).providerURL)
        XCTAssertEqual(try store.item(id: newID)?.providerID, "new-install")
        XCTAssertEqual(try store.item(id: legacyID)?.id, newID, "older identifiers still find the title")
        XCTAssertEqual(try store.item(id: newID)?.userNote, "Private note")
        XCTAssertEqual(try store.episodeProgress(itemID: newID)["episode"]?.positionSeconds, 100)
        XCTAssertEqual(try store.playbackPrefs(itemID: newID)?.speed, 1.5)
    }

    func testExplicitAssignmentRejectsUnavailableSelectionAndCollisionWithoutMutation() throws {
        let store = LibraryStore(inMemory: true)
        let unknown = legacy(nil)
        var identified = legacy("chosen", id: LibraryIdentity.remote(providerID: "chosen", url: unknown.providerURL))
        identified.identityVersion = 2
        identified.identityResolution = "resolved"
        try store.importSnapshot(.init(items: [unknown, identified], episodes: [], playback: []), mode: .replace)
        let before = store.version
        XCTAssertThrowsError(try store.reassignProvider(itemID: unknown.id, providerID: "missing", providers: []))
        XCTAssertThrowsError(try store.reassignProvider(itemID: unknown.id, providerID: "chosen",
                                                       providers: [.init(id: "chosen", name: "Renamed")]))
        XCTAssertEqual(store.version, before)
        XCTAssertNil(try store.item(id: unknown.id)?.providerID)
        XCTAssertEqual(try store.allEntries().count, 2)
    }

    func testExplicitAssignmentCommitFailureRollsBackAndRetryPreservesAliasOnDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("assignment-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(storeDirectory: root)
        try fixture(store, providerID: nil)
        let oldID = legacy(nil).id
        let providers: [LibraryIdentityMigration.Provider] = [.init(id: "chosen", name: "Renamed")]
        let before = store.version
        store.persistenceFault = { if $0 == .identityCommit { throw Fault.injected } }
        XCTAssertThrowsError(try store.reassignProvider(itemID: oldID, providerID: "chosen", providers: providers))
        XCTAssertEqual(store.version, before)
        XCTAssertNil(try store.item(id: oldID)?.providerID)
        XCTAssertEqual(try store.playbackPrefs(itemID: oldID)?.speed, 1.5)
        store.persistenceFault = nil
        let report = try store.reassignProvider(itemID: oldID, providerID: "chosen", providers: providers)
        try SQLiteRecoverySnapshot.verify(try XCTUnwrap(report.recoverySnapshot))
        let reopened = LibraryStore(storeDirectory: root)
        let row = try XCTUnwrap(reopened.item(id: oldID))
        XCTAssertEqual(row.providerName, "Renamed")
        XCTAssertEqual(row.providerID, "chosen")
        XCTAssertEqual(try reopened.playbackPrefs(itemID: row.id)?.speed, 1.5)
    }

    func testExplicitAssignmentDoesNotMigrateUnrelatedResolvableRows() {
        let report = LibraryIdentityMigration.plan(items: [
            .init(id: "selected", providerID: nil, providerName: "Old", url: "https://fixture.test/a", isDownload: false),
            .init(id: "other", providerID: "known", providerName: "Other", url: "https://fixture.test/b", isDownload: false)
        ], providers: [], assignments: ["selected": .init(id: "chosen", name: "New")])
        XCTAssertEqual(report.changes.map(\.oldID), ["selected"])
        XCTAssertEqual(report.changes.first?.providerID, "chosen")
    }

    func testDiskRekeyPreservesDependentsAliasesAndVerifiedPreMigrationCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var writer: LibraryStore? = LibraryStore(storeDirectory: root)
        let store = try XCTUnwrap(writer)
        try fixture(store)
        let old = legacy().id
        let new = LibraryIdentity.remote(providerID: "stable", url: legacy().providerURL)
        let plan = try store.identityMigrationPlan(providers: [])
        XCTAssertEqual(plan.changes, [.init(oldID: old, newID: new, providerID: "stable")])
        XCTAssertEqual(try store.allEntries().first?.id, old, "Dry run must not write")
        let result = try store.migrateProviderIdentities(providers: [])
        let recovery = try XCTUnwrap(result.recoverySnapshot)
        try SQLiteRecoverySnapshot.verify(recovery)
        let row = try XCTUnwrap(store.item(id: old))
        XCTAssertEqual(row.id, new)
        XCTAssertEqual(row.legacyItemID, old)
        XCTAssertEqual(row.identityVersion, 2)
        XCTAssertEqual(row.userNote, "Private note")
        XCTAssertEqual(row.userRating, 4)
        XCTAssertEqual(row.watchTypeRaw, 3)
        XCTAssertTrue(row.isFavorite)
        XCTAssertEqual(try store.episodeProgress(itemID: new)["episode"]?.positionSeconds, 100)
        XCTAssertEqual(try store.playbackPrefs(itemID: new)?.speed, 1.5)
        XCTAssertTrue(try store.episodeProgress(itemID: old).isEmpty)
        XCTAssertNil(try store.playbackPrefs(itemID: old))
        let version = store.version
        XCTAssertTrue(try store.migrateProviderIdentities(providers: []).changes.isEmpty)
        XCTAssertEqual(store.version, version)
        let marker = try store.container!.mainContext.fetch(FetchDescriptor<LibraryMigrationRecord>())
            .first { $0.name == "provider-identity-v2" }
        XCTAssertEqual(marker?.recoverySnapshotPath, recovery.path)
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: XCTUnwrap(marker).keyMappingData)[old], new)

        writer = nil
        let reopened = LibraryStore(storeDirectory: root)
        XCTAssertEqual(try reopened.item(id: old)?.id, new)
        XCTAssertEqual(try reopened.playbackPrefs(itemID: new)?.subtitleDelay, -2)
        // Open the physical recovery copy separately: it contains old keys and
        // dependents, not merely a JSON export of the new graph.
        let configuration = ModelConfiguration("Recovery", schema: Schema(LibraryStore.modelTypes),
            url: recovery, cloudKitDatabase: .none)
        let recoveryContainer = try ModelContainer(for: Schema(LibraryStore.modelTypes), configurations: [configuration])
        let recovered = try recoveryContainer.mainContext.fetch(FetchDescriptor<StoredMediaItem>()).first
        XCTAssertEqual(recovered?.id, old)
        XCTAssertEqual(try recoveryContainer.mainContext.fetch(FetchDescriptor<EpisodeProgress>()).first?.itemID, old)
    }

    func testSnapshotAndCommitFailuresLeaveOldGraphAndVersionIntact() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("migration-failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(storeDirectory: root)
        try fixture(store)
        let before = store.version
        for boundary in [LibraryStore.PersistenceBoundary.identitySnapshot, .identityCommit] {
            store.persistenceFault = { if $0 == boundary { throw Fault.injected } }
            XCTAssertThrowsError(try store.migrateProviderIdentities(providers: []))
            XCTAssertNotNil(store.identityMigrationFailure)
            XCTAssertEqual(store.version, before)
            XCTAssertEqual(try store.allEntries().first?.id, legacy().id)
            XCTAssertEqual(try store.episodeProgress(itemID: legacy().id)["episode"]?.positionSeconds, 100)
            XCTAssertEqual(try store.playbackPrefs(itemID: legacy().id)?.speed, 1.5)
        }
        store.persistenceFault = nil
        XCTAssertEqual(try store.migrateProviderIdentities(providers: []).changes.count, 1)
        XCTAssertNil(store.identityMigrationFailure)
    }

    func testFailedNamedProfileMigrationRestoresThePreviousProfileContext() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("migration-profile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "migration-profile-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = ProfileStore(defaults: defaults)
        let other = try profiles.add(name: "Other", symbol: ViewerProfile.symbols[0])
        let store = LibraryStore(storeDirectory: root)
        try profiles.select(other, library: store)
        try fixture(store)
        let main = try XCTUnwrap(profiles.profiles.first { $0.isDefault })
        try profiles.select(main, library: store)
        store.persistenceFault = { if $0 == .identityCommit { throw Fault.injected } }
        XCTAssertThrowsError(try profiles.select(other, library: store))
        XCTAssertEqual(profiles.activeID, main.id)
        XCTAssertTrue(try store.allEntries().isEmpty, "A failed switch cannot expose another profile under the main profile's identity")
        store.persistenceFault = nil
        try profiles.select(other, library: store)
        XCTAssertEqual(profiles.activeID, other.id)
        XCTAssertEqual(try store.allEntries().first?.userNote, "Private note")
        XCTAssertEqual(try store.allEntries().first?.identityVersion, 2)
    }

    func testUnambiguousCatalogResolutionAndMissingOrAmbiguousOwnersStaySeparate() throws {
        let store = LibraryStore(inMemory: true)
        try fixture(store, providerID: nil)
        XCTAssertEqual(try store.identityMigrationPlan(providers: []).unresolved.count, 1)
        let ambiguous = [LibraryIdentityMigration.Provider(id: "one", name: "P"), .init(id: "two", name: "P")]
        XCTAssertTrue(try store.migrateProviderIdentities(providers: ambiguous).changes.isEmpty)
        XCTAssertNil(try store.allEntries().first?.providerID)
        let report = try store.migrateProviderIdentities(providers: [.init(id: "only", name: "P")])
        XCTAssertEqual(report.changes.count, 1)
        XCTAssertEqual(try store.item(id: legacy().id)?.providerID, "only")
    }

    private func watched(_ store: LibraryStore, providerID: String) throws {
        let details = DetailsDto(provider: "P", providerId: providerID, url: "https://fixture.test/title", name: "Preserved title",
            type: "TvSeries", posterUrl: nil, backgroundPosterUrl: nil, logoUrl: nil, plot: nil, year: nil, durationMinutes: nil,
            score: nil, tags: [], actors: [], contentRating: nil, comingSoon: false, episodes: [], movieData: nil)
        try store.upsertLibraryEntry(details: details, watchType: .completed)
    }

    func testALegacyTitleUsedThroughItsOnlyProviderIsBoundInsteadOfDuplicated() throws {
        // Remediation 4.3: one installed provider named "P" and it is the one in use.
        let store = LibraryStore(inMemory: true)
        try fixture(store, providerID: nil)
        XCTAssertTrue(try store.migrateProviderIdentities(providers: []).changes.isEmpty)
        XCTAssertEqual(try store.item(id: legacy().id)?.identityResolution, "legacy_unresolved", "the unresolved pass is recorded")
        store.installedProviders = [.init(id: "only", name: "P")]
        try watched(store, providerID: "only")
        let rows = try store.allEntries()
        XCTAssertEqual(rows.count, 1, "no second record next to the legacy one")
        XCTAssertEqual(rows.first?.providerID, "only")
        XCTAssertEqual(rows.first?.userNote, "Private note", "the user's data stays with the title")
        XCTAssertEqual(rows.first?.identityResolution, "resolved_by_use")
        let report = try store.migrateProviderIdentities(providers: [.init(id: "only", name: "P")])
        XCTAssertEqual(report.changes.count, 1, "the next reconcile gives it its durable identifier")
        XCTAssertEqual(try store.allEntries().map(\.id), [LibraryIdentity.remote(providerID: "only", url: "https://fixture.test/title")])
    }

    func testALegacyTitleIsNotBoundWhenTheNameIsAmbiguousOrAnotherProviderIsUsed() throws {
        for (catalog, used) in [([LibraryIdentityMigration.Provider(id: "one", name: "P"), .init(id: "two", name: "P")], "two"),
                                ([.init(id: "only", name: "P")], "different")] {
            let store = LibraryStore(inMemory: true)
            try fixture(store, providerID: nil)
            store.installedProviders = catalog
            try watched(store, providerID: used)
            XCTAssertNil(try store.item(id: legacy().id)?.providerID, "a name shared by installations, or another installation, binds nothing")
            XCTAssertEqual(try store.allEntries().count, 2)
        }
    }

    func testConflictsCannotMergeRowsOrTouchTheStore() throws {
        let store = LibraryStore(inMemory: true)
        let rows = [legacy(nil, id: "old-a"), legacy(nil, id: "old-b")]
        try store.importSnapshot(.init(items: rows, episodes: [], playback: []), mode: .replace)
        let providers = [LibraryIdentityMigration.Provider(id: "one", name: "P")]
        XCTAssertFalse(try store.identityMigrationPlan(providers: providers).canApply)
        let version = store.version
        XCTAssertThrowsError(try store.migrateProviderIdentities(providers: providers))
        XCTAssertEqual(store.version, version)
        XCTAssertEqual(Set(try store.allEntries().map(\.id)), ["old-a", "old-b"])
    }

    func testSchemaInspectionLockFailureIsBoundedAndNeverBecomesAnEmptyStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sqlite-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("locked.store")
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        XCTAssertEqual(sqlite3_exec(writer, "CREATE TABLE fixture(value TEXT); INSERT INTO fixture VALUES('preserve'); BEGIN EXCLUSIVE;", nil, nil, nil), SQLITE_OK)
        let began = ContinuousClock.now
        XCTAssertThrowsError(try SQLiteRecoverySnapshot.needsSchemaRecovery(source))
        XCTAssertLessThan(began.duration(to: .now), .seconds(5))
        XCTAssertEqual(sqlite3_exec(writer, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        XCTAssertTrue(try SQLiteRecoverySnapshot.needsSchemaRecovery(source))
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(writer, "SELECT value FROM fixture", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "preserve")
    }

    func testSQLiteSnapshotIncludesCommittedWALAndRejectsTampering() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sqlite-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.store")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE fixture(value TEXT); INSERT INTO fixture VALUES('committed-wal');", nil, nil, nil), SQLITE_OK)
        let recovery = try SQLiteRecoverySnapshot.create(source: source, directory: root.appendingPathComponent("copies"), reason: "fixture")
        try SQLiteRecoverySnapshot.verify(recovery)
        var copy: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(recovery.path, &copy, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(copy) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(copy, "SELECT value FROM fixture", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "committed-wal")
        let manifestURL = recovery.deletingLastPathComponent().appendingPathComponent("manifest.json")
        let validManifest = try Data(contentsOf: manifestURL)
        try Data(repeating: 0, count: 64 * 1024 + 1).write(to: manifestURL)
        XCTAssertThrowsError(try SQLiteRecoverySnapshot.verify(recovery))
        try validManifest.write(to: manifestURL)
        try Data("tampered".utf8).write(to: recovery)
        XCTAssertThrowsError(try SQLiteRecoverySnapshot.verify(recovery))
    }
}
