import Foundation
import SwiftData

/// SwiftData persistence facade for library, watch history, and search history
/// (Architecture.md §2.1 Storage).
///
/// Mutations use an exclusively owned context, rollback on read/save failure,
/// and throw to their caller. Only successful `save()` calls bump
/// `version`. Views read `LibraryStore.shared.version` once per body so the
/// Observation system invalidates them on change — no `.id()` nukes, no
/// polling timers.
@MainActor
@Observable
final class LibraryStore {
    static let shared = LibraryStore(storeDirectory: AppEnvironment.crashFixtureStoreDirectory)

    /// The app-wide store: download records plus the default profile's
    /// library (the original single-user database, unchanged on disk).
    private(set) var container: ModelContainer?
    /// A non-default profile's library store (Phase 7.2); nil = default.
    private var profileContainer: ModelContainer?
    private let inMemory: Bool
    @ObservationIgnored private let storeDirectory: URL?
    @ObservationIgnored private var libraryContext: ModelContext?
    @ObservationIgnored private var downloadsContext: ModelContext?
    @ObservationIgnored private let containerFactory: (Schema, [ModelConfiguration]) throws -> ModelContainer
    @ObservationIgnored private var schemaRecoverySnapshots: [String: URL] = [:]
    private struct ProgressKey: Hashable {
        let owner: ObjectIdentifier
        let item: String
        let episode: String?
    }
    private struct PendingProgress {
        let context: ModelContext
        let details: DetailsDto
        let episode: EpisodeDto?
        let position: Double
        let duration: Double
        let recordedAt: Date
        let order: ContinuousClock.Instant
        let notify: Bool
    }
    @ObservationIgnored private var pendingProgress: [ProgressKey: PendingProgress] = [:]
    /// Positions played while the selected profile's store could not be
    /// opened. They wait for that same store and are never written to another
    /// profile. Unsaved positions are also journaled to disk
    /// (`progressJournalURL`), so quitting first does not lose them.
    private struct UnownedProgressKey: Hashable {
        let storeName: String
        let item: String
        let episode: String?
    }
    private struct UnownedProgress {
        let details: DetailsDto
        let episode: EpisodeDto?
        let position: Double
        let duration: Double
        let recordedAt: Date
        let order: ContinuousClock.Instant
    }
    @ObservationIgnored private var unownedProgress: [UnownedProgressKey: UnownedProgress] = [:]
    /// One unsaved position on disk, replayed into its store at the next launch.
    private struct ProgressJournalEntry: Codable {
        let storeName: String
        let details: DetailsDto
        let episode: EpisodeDto?
        let position: Double
        let duration: Double
        let recordedAt: Date
    }
    /// Unsaved positions survive a quit here; nil keeps them in memory only.
    @ObservationIgnored private let progressJournalURL: URL?
    @ObservationIgnored private var progressJournalOnDisk = false
    /// Store the selected profile is meant to use, whether or not it opened.
    @ObservationIgnored private var intendedProfileStoreName = LibraryStore.defaultStoreName
    var unownedProgressCount: Int { unownedProgress.count }
    private(set) var pendingProgressFailure: String?
    /// True while a restore writes this profile's store off the main thread.
    private(set) var isImporting = false
    private(set) var identityMigrationFailure: String?

    enum StoreHealth: Equatable {
        case opening
        case available
        case failed(String)
    }
    private(set) var sharedStoreHealth: StoreHealth = .opening
    private(set) var profileStoreHealth: StoreHealth = .opening
    private(set) var readFailure: String?
    @ObservationIgnored private var scheduledReadFailure: String?
    @ObservationIgnored private var scheduledReadGeneration: UInt64?

    /// Narrow fault seam: tests fail actual read/commit boundaries, retaining
    /// the production SwiftData transaction and model graph.
    enum PersistenceBoundary: Equatable {
        case snapshotRead, restoreRead, restoreCommit, mutationRead, mutationCommit, queryRead
        case identitySnapshot, identityCommit
    }
    @ObservationIgnored var mutationClock: () -> Date = Date.init
    @ObservationIgnored var persistenceFault: ((PersistenceBoundary) throws -> Void)?

    /// Bumped on every persisted mutation; the observation hook for views.
    private(set) var version: UInt64 = 0

    /// Unlike `version`, this changes only when the selected store's ownership
    /// changes. Returning to the same profile must not revive suspended work.
    private(set) var profileGeneration: UInt64 = 0
    /// Store file name of the selected profile (default store when none).
    @ObservationIgnored private var activeProfileStoreName = LibraryStore.defaultStoreName
    struct ProfileOperationContext: Equatable {
        fileprivate let store: ObjectIdentifier
        fileprivate let context: ObjectIdentifier
        fileprivate let generation: UInt64
    }

    func captureProfileOperation() throws -> ProfileOperationContext {
        guard let context, profileStoreHealth == .available else { throw ImportError.storeUnavailable }
        return ProfileOperationContext(store: ObjectIdentifier(self), context: ObjectIdentifier(context),
                                       generation: profileGeneration)
    }

    func owns(_ operation: ProfileOperationContext) -> Bool {
        guard let context, profileStoreHealth == .available else { return false }
        return operation.store == ObjectIdentifier(self) && operation.context == ObjectIdentifier(context)
            && operation.generation == profileGeneration
    }

    /// `CS_IN_MEMORY_DB=1` keeps the old behavior for smoke tests; tests can
    /// also construct an isolated store directly. An explicit directory permits
    /// disk-backed fixtures without ever opening the production database.
    /// - Parameter progressJournalURL: where unsaved playback positions are
    ///   kept across launches; nil uses the store directory (or Application
    ///   Support) for disk-backed stores and no journal for in-memory ones.
    init(inMemory: Bool = false,
         storeDirectory: URL? = nil,
         progressJournalURL: URL? = nil,
         containerFactory: @escaping (Schema, [ModelConfiguration]) throws -> ModelContainer = {
             try ModelContainer(for: $0, configurations: $1)
         }) {
        self.inMemory = inMemory || (AppEnvironment.isIsolated() && storeDirectory == nil)
        self.storeDirectory = storeDirectory
        self.containerFactory = containerFactory
        if let progressJournalURL {
            self.progressJournalURL = progressJournalURL
        } else if self.inMemory {
            self.progressJournalURL = nil
        } else {
            let base = storeDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("CloudStream", isDirectory: true)
            self.progressJournalURL = base?.appendingPathComponent("PendingProgress.json")
        }
        do {
            let schema = Schema(Self.modelTypes)
            let configuration = try configuration(named: Self.defaultStoreName, schema: schema)
            try preservePreMigrationSchema(configuration)
            container = try containerFactory(schema, [configuration])
            libraryContext = ModelContext(container!)
            libraryContext?.autosaveEnabled = false
            downloadsContext = ModelContext(container!)
            downloadsContext?.autosaveEnabled = false
            sharedStoreHealth = .available
            profileStoreHealth = .available
        } catch {
            DaemonLog.client("store.container_failed", fields: ["error": error.localizedDescription])
            container = nil
            sharedStoreHealth = .failed(error.localizedDescription)
            profileStoreHealth = .failed(error.localizedDescription)
        }
        do { try backfillEpisodeProgressIfNeeded() }
        catch { profileStoreHealth = .failed(error.localizedDescription) }
        loadProgressJournal()
    }

    /// Every persisted model. Evolution is additive-only with defaulted
    /// properties so SwiftData lightweight-migrates (docs/adr/0006).
    static let modelTypes: [any PersistentModel.Type] = [
        StoredMediaItem.self,
        DownloadRecord.self,
        EpisodeProgress.self,
        TitlePlaybackPrefs.self,
        LibraryMigrationRecord.self,
        LibraryPage.self,
        LibraryPageEntry.self,
    ]

    nonisolated static let defaultStoreName = "CloudStreamMac"

    private func configuration(named name: String, schema: Schema) throws -> ModelConfiguration {
        guard !inMemory, let storeDirectory else {
            return ModelConfiguration(name, schema: schema, isStoredInMemoryOnly: inMemory)
        }
        // Profile names are generated identifiers, never arbitrary paths.
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"), !name.contains("\0") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        return ModelConfiguration(name, schema: schema,
            url: storeDirectory.appendingPathComponent(name + ".store"), cloudKitDatabase: .none)
    }

    private func preservePreMigrationSchema(_ configuration: ModelConfiguration) throws {
        guard !inMemory else { return }
        let source = configuration.url
        let directory = source.deletingLastPathComponent().appendingPathComponent("IdentityRecovery", isDirectory: true)
        if try SQLiteRecoverySnapshot.needsSchemaRecovery(source) {
            schemaRecoverySnapshots[source.path] = try SQLiteRecoverySnapshot.create(source: source,
                directory: directory, reason: "before-provider-identity-schema-v2")
        } else if FileManager.default.fileExists(atPath: source.path),
                  let original = try SQLiteRecoverySnapshot.originalSchemaSnapshot(source: source, directory: directory) {
            schemaRecoverySnapshots[source.path] = original
        }
    }

    /// Models that live in a profile's own store.
    static let profileModelTypes: [any PersistentModel.Type] = [
        StoredMediaItem.self,
        EpisodeProgress.self,
        TitlePlaybackPrefs.self,
        LibraryMigrationRecord.self,
        LibraryPage.self,
        LibraryPageEntry.self,
    ]

    /// Library, history and playback memory of the active profile.
    private var context: ModelContext? {
        libraryContext
    }

    /// Download records are per-Mac, not per-profile.
    private var sharedContext: ModelContext? {
        downloadsContext
    }

    /// Switches the library to a profile's store (nil = default profile).
    /// Every view re-reads through `version`.
    func activateProfileStore(named storeName: String?, identityProviders: [LibraryIdentityMigration.Provider] = []) throws {
        guard !isImporting else { throw ImportError.restoreInProgress }
        try flushOwnedProgress(notifyObservers: true)
        guard context?.hasChanges != true else { throw ImportError.pendingChanges }
        let previousContainer = profileContainer
        let previousContext = libraryContext
        let previousIdentityFailure = identityMigrationFailure
        profileStoreHealth = .opening
        do {
            if let storeName, storeName != Self.defaultStoreName {
                let schema = Schema(Self.profileModelTypes)
                let configuration = try configuration(named: storeName, schema: schema)
                try preservePreMigrationSchema(configuration)
                profileContainer = try containerFactory(schema, [configuration])
            } else {
                guard container != nil else { throw ImportError.storeUnavailable }
                profileContainer = nil
            }
            libraryContext = (profileContainer ?? container).map(ModelContext.init)
            libraryContext?.autosaveEnabled = false
            try backfillEpisodeProgressIfNeeded()
            try migrateProviderIdentities(providers: identityProviders)
            profileStoreHealth = .available
            activeProfileStoreName = storeName ?? Self.defaultStoreName
            intendedProfileStoreName = activeProfileStoreName
            readFailure = nil
            cancelProfileOperations()
            profileGeneration &+= 1
            version += 1
            adoptUnownedProgress()
            mergeStrongMatchesLogged()
        } catch {
            // Retain the previous store/context until a replacement opens.
            profileContainer = previousContainer
            libraryContext = previousContext
            identityMigrationFailure = previousIdentityFailure
            profileStoreHealth = previousContext == nil ? .failed(error.localizedDescription) : .available
            throw error
        }
    }

    /// A failed startup must never display the default profile under the
    /// selected profile's identity. Downloads keep their independent store.
    /// - Parameter storeName: the store that failed to open (nil = default),
    ///   so progress played meanwhile can wait for it.
    func suspendProfileAfterStartupFailure(_ error: Error, storeName: String? = nil) {
        cancelProfileOperations()
        profileGeneration &+= 1
        intendedProfileStoreName = storeName ?? Self.defaultStoreName
        libraryContext = nil
        profileStoreHealth = .failed(error.localizedDescription)
        readFailure = error.localizedDescription
        version += 1
    }

    func retryOpeningStores(profileStoreName: String?) throws {
        if container == nil {
            let schema = Schema(Self.modelTypes)
            do {
                let configuration = try configuration(named: Self.defaultStoreName, schema: schema)
                try preservePreMigrationSchema(configuration)
                let reopened = try containerFactory(schema, [configuration])
                container = reopened
                downloadsContext = ModelContext(reopened)
                downloadsContext?.autosaveEnabled = false
                sharedStoreHealth = .available
            } catch {
                sharedStoreHealth = .failed(error.localizedDescription)
                throw error
            }
        }
        do {
            try activateProfileStore(named: profileStoreName)
            // Verify both domains before dismissing the recovery state.
            _ = try downloadRecords()
            _ = try counts()
            readFailure = nil
        } catch {
            readFailure = error.localizedDescription
            throw error
        }
    }

    /// SwiftUI rendering cannot throw. This named presentation policy reports
    /// failure after the render pass, avoiding observable mutation in body.
    /// The fallback is unavailable display data; readFailure keeps it distinct
    /// from a successful empty database and offers explicit retry.
    func readForDisplay<T>(or fallback: T, _ action: () throws -> T) -> T {
        do { return try action() }
        catch {
            let message = error.localizedDescription
            if readFailure != message, scheduledReadFailure != message || scheduledReadGeneration != version {
                scheduledReadFailure = message
                let generation = version
                scheduledReadGeneration = generation
                Task { @MainActor [weak self] in
                    guard let self, self.scheduledReadFailure == message, self.scheduledReadGeneration == generation else { return }
                    self.scheduledReadFailure = nil
                    self.scheduledReadGeneration = nil
                    guard self.version == generation else { return }
                    self.readFailure = message
                }
            }
            return fallback
        }
    }

    /// Deletes a (non-active, non-default) profile's store files.
    nonisolated static func deleteProfileStore(named storeName: String) {
        guard storeName != defaultStoreName, !AppEnvironment.isIsolated() else { return }
        let url = ModelConfiguration(storeName).url
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }

    /// Runs `body` in a context owned by `storeName`'s profile library without
    /// switching the visible profile. The store must already exist: a deleted
    /// or never-opened profile is unavailable, not silently recreated.
    private func withOwnedProfileContext<T>(storeName: String, _ body: (ModelContext) throws -> T) throws -> T {
        if storeName == activeProfileStoreName { return try withMutation(shared: false, body) }
        guard !inMemory else { throw ImportError.storeUnavailable }
        let owner: ModelContainer
        if storeName == Self.defaultStoreName {
            guard let container else { throw ImportError.storeUnavailable }
            owner = container
        } else {
            let schema = Schema(Self.profileModelTypes)
            let configuration = try configuration(named: storeName, schema: schema)
            guard FileManager.default.fileExists(atPath: configuration.url.path) else { throw ImportError.storeUnavailable }
            try preservePreMigrationSchema(configuration)
            owner = try containerFactory(schema, [configuration])
        }
        let context = ModelContext(owner)
        context.autosaveEnabled = false
        do {
            try persistenceFault?(.mutationRead)
            return try body(context)
        } catch {
            context.rollback()
            throw error
        }
    }

    /// Files a finished download into the library of the profile that queued
    /// it, whichever profile is selected now.
    func markDownloaded(downloadID: UUID, provider: String, url: String, title: String, inProfileStore storeName: String) throws {
        if storeName == activeProfileStoreName {
            return try markDownloaded(downloadID: downloadID, provider: provider, url: url, title: title)
        }
        guard try downloadRecords().contains(where: { $0.id == downloadID && $0.destinationPath == url && $0.statusRaw == 4 }) else {
            throw ImportError.identityConflict("The completed download record does not match this file.")
        }
        let id = LibraryIdentity.localDownload(downloadID)
        try withOwnedProfileContext(storeName: storeName) { context in
            if let existing = try mutationItem(id: id, in: context) {
                guard existing.mediaType == "Download" else { throw ImportError.identityConflict("The local title identity is already in use.") }
                existing.providerURL = url
                existing.providerName = provider
            } else {
                let item = StoredMediaItem(id: id, title: title, providerName: provider, providerURL: url, mediaType: "Download")
                item.identityVersion = LibraryIdentity.version
                item.identityResolution = "local_download"
                context.insert(item)
            }
            try persistenceFault?(.mutationCommit)
            try context.save()
        }
    }

    /// Removes a download's library entry from an owning profile that is not
    /// necessarily selected. A missing profile store has nothing to remove.
    func removeDownloadedEntry(downloadID: UUID, inProfileStore storeName: String) throws {
        guard storeName != activeProfileStoreName else { return }
        let id = LibraryIdentity.localDownload(downloadID)
        do {
            try withOwnedProfileContext(storeName: storeName) { context in
                guard let item = try mutationItem(id: id, in: context) else { return }
                context.delete(item)
                try persistenceFault?(.mutationCommit)
                try context.save()
            }
        } catch ImportError.storeUnavailable { return }
    }

    /// Marks a finished download in the library ("Recently Added") without a
    /// watch status unless an entry already exists.
    func markDownloaded(downloadID: UUID, provider: String, url: String, title: String) throws {
        let id = LibraryIdentity.localDownload(downloadID)
        guard try downloadRecords().contains(where: { $0.id == downloadID && $0.destinationPath == url && $0.statusRaw == 4 }) else {
            throw ImportError.identityConflict("The completed download record does not match this file.")
        }
        // Upgrade a legacy placeholder before admitting another row for the
        // same shared record; all dependent user data follows the rekey.
        if let context {
            let legacy = try context.fetch(FetchDescriptor<StoredMediaItem>(predicate: #Predicate {
                $0.mediaType == "Download" && $0.providerURL == url
            }))
            if legacy.contains(where: { $0.downloadRecordID == nil }) {
                try migrateProviderIdentities(providers: [])
            }
        }
        try withMutation(shared: false) { context in
            if let existing = try mutationItem(id: id, in: context) {
                guard existing.mediaType == "Download" else { throw ImportError.identityConflict("The local title identity is already in use.") }
                existing.providerURL = url
                existing.providerName = provider
            } else {
                let item = StoredMediaItem(id: id, title: title, providerName: provider,
                    providerURL: url, mediaType: "Download")
                item.identityVersion = LibraryIdentity.version
                item.identityResolution = "local_download"
                context.insert(item)
            }
            try save(context: context)
        }
    }

    /// All download records, newest first (Downloads view).
    func downloadRecords() throws -> [DownloadRecord] {
        let context = sharedContext
        guard let context else { throw ImportError.storeUnavailable }
        try persistenceFault?(.queryRead)
        let descriptor = FetchDescriptor<DownloadRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)],
        )
        return (try context.fetch(descriptor))
    }

    /// UUID lookup keeps local playback authorization tied to the shared
    /// completed record without materializing the entire download queue.
    func downloadRecord(id: UUID) throws -> DownloadRecord? {
        guard let context = sharedContext else { throw ImportError.storeUnavailable }
        try persistenceFault?(.queryRead)
        var descriptor = FetchDescriptor<DownloadRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    // MARK: - Download Record Mutations

    func upsertDownloadRecord(
        id: UUID,
        title: String,
        episodeLabel: String,
        provider: String,
        episodeData: String,
        destinationPath: String,
        statusRaw: Int,
        bytesWritten: Int64 = 0,
        durationSeconds: Double? = nil,
        failureReason: String? = nil,
        completedAt: Date? = nil,
        createdAt: Date = Date(),
        providerID: String? = nil,
        preferredSource: String? = nil,
        originProfileID: UUID? = nil
    ) throws {
        try withMutation(shared: true) { context in
            let descriptor = FetchDescriptor<DownloadRecord>(predicate: #Predicate { $0.id == id })
            if let existing = (try context.fetch(descriptor)).first {
                if existing.originProfileID == nil { existing.originProfileID = originProfileID }
                existing.statusRaw = statusRaw
                existing.bytesWritten = bytesWritten
                existing.failureReason = failureReason
                // The final extension is only known on completion (direct .mkv,
                // Matroska fallback, collision rename).
                existing.destinationPath = destinationPath
                existing.createdAt = createdAt
                if existing.providerID == nil { existing.providerID = providerID }
                if let completedAt {
                    existing.completedAt = completedAt
                }
            } else {
                context.insert(
                    DownloadRecord(
                        id: id,
                        title: title,
                        episodeLabel: episodeLabel,
                        provider: provider,
                        episodeData: episodeData,
                        destinationPath: destinationPath,
                        statusRaw: statusRaw,
                        bytesWritten: bytesWritten,
                        durationSeconds: durationSeconds,
                        failureReason: failureReason,
                        createdAt: createdAt,
                        completedAt: completedAt,
                        providerID: providerID,
                        preferredSource: preferredSource,
                        originProfileID: originProfileID,
                    )
                )
            }
            try save(context: context)
        }
    }

    /// Records (or withdraws) the intent to delete a download's file. Saved
    /// before the file is touched, so an interrupted deletion can be finished.
    func setDownloadDeletionIntent(id: UUID, at date: Date?) throws {
        try withMutation(shared: true) { context in
            guard let record = try context.fetch(FetchDescriptor<DownloadRecord>(predicate: #Predicate { $0.id == id })).first else {
                throw ImportError.identityConflict("The download record no longer exists.")
            }
            record.deletionRequestedAt = date
            try save(context: context)
        }
    }

    /// Removes the "Download" library entry `markDownloaded` created, so a
    /// deleted file doesn't leave a dead library item behind.
    func removeDownloadedEntry(downloadID: UUID, provider: String, url: String) throws {
        let candidates = Set(try downloadRecords().filter { $0.destinationPath == url }.map(\.id))
        let allowLegacy = candidates == [downloadID]
        try withMutation(shared: false) { context in
            let id = LibraryIdentity.localDownload(downloadID)
            let legacyID = allowLegacy ? "\(provider)|local:\(url)" : id
            let descriptor = FetchDescriptor<StoredMediaItem>(predicate: #Predicate { $0.id == id || $0.id == legacyID })
            let matches = (try context.fetch(descriptor))
            guard !matches.isEmpty else { return }
            for item in matches {
                context.delete(item)
            }
            try save(context: context)
        }
    }

    func deleteDownloadRecord(id: UUID) throws {
        try withMutation(shared: true) { context in
            let descriptor = FetchDescriptor<DownloadRecord>(predicate: #Predicate { $0.id == id })
            for record in (try context.fetch(descriptor)) {
                context.delete(record)
            }
            try save(context: context)
        }
    }

    func deleteDownloadRecords(ids: [UUID]) throws {
        try withMutation(shared: true) { context in
            guard !ids.isEmpty else { return }
            let idSet = Set(ids)
            let descriptor = FetchDescriptor<DownloadRecord>()
            let records = (try context.fetch(descriptor))
            for record in records where idSet.contains(record.id) {
                context.delete(record)
            }
            try save(context: context)
        }
    }

    /// - Parameter notify: false for high-frequency, non-structural writes
    ///   (playback progress) that must not re-render every library view
    ///   (Player-Remediation-Plan U2). The next notifying save publishes them.
    private func save(context: ModelContext, notify: Bool = true) throws {
        try persistenceFault?(.mutationCommit)
        try context.save()
        if notify, context === libraryContext || context === downloadsContext { version += 1 }
    }

    /// Private cached contexts belong exclusively to this facade. Reusing
    /// them preserves playback batching; each synchronous mutation begins
    /// clean and rolls back only its own changes if a read or save fails.
    private func withMutation<T>(shared: Bool, _ body: (ModelContext) throws -> T) throws -> T {
        guard let context = shared ? sharedContext : context else { throw ImportError.storeUnavailable }
        return try withMutation(in: context, body)
    }

    private func withMutation<T>(in context: ModelContext, _ body: (ModelContext) throws -> T) throws -> T {
        // The restore replaces what this context has loaded; a write through
        // it now could resurrect or lose rows.
        guard !(isImporting && context === libraryContext) else { throw ImportError.restoreInProgress }
        guard !context.hasChanges else { throw ImportError.pendingChanges }
        do {
            try persistenceFault?(.mutationRead)
            return try body(context)
        } catch {
            context.rollback()
            throw error
        }
    }

    /// Provider facts a saved title may have been filed without. Returns
    /// whether anything changed.
    @discardableResult
    private func absorbMetadata(_ item: StoredMediaItem, from details: DetailsDto) -> Bool {
        guard let year = details.year, year > 0, item.releaseYear != year else { return false }
        item.releaseYear = year
        return true
    }

    /// A new, not yet inserted library row for `details`.
    private func newItem(id: String, from details: DetailsDto, watchType: WatchType? = nil, isFavorite: Bool = false) -> StoredMediaItem {
        let item = StoredMediaItem(
            id: id,
            title: details.name,
            posterURL: details.posterUrl,
            bannerURL: details.backgroundPosterUrl ?? details.posterUrl,
            providerName: details.provider,
            providerID: details.providerId,
            providerURL: details.url,
            mediaType: details.type,
            watchType: watchType,
            isFavorite: isFavorite
        )
        absorbMetadata(item, from: details)
        return item
    }

    private func mutationItem(id: String, in context: ModelContext) throws -> StoredMediaItem? {
        try context.fetch(FetchDescriptor<StoredMediaItem>(predicate: #Predicate { $0.id == id })).first
    }

    /// UI actions have no throwing event-handler signature. Keep their
    /// failure visible and return whether the action actually committed.
    @discardableResult
    func perform(_ action: () throws -> Void) -> Bool {
        do {
            try action()
            return true
        } catch {
            AppState.shared.presentError("Couldn't save your changes: \(error.localizedDescription)")
            return false
        }
    }

    private func stamp(_ item: StoredMediaItem, _ field: ReferenceWritableKeyPath<StoredMediaItem, Date?>, at date: Date? = nil) {
        let now = date ?? mutationClock()
        // Millisecond backup precision must still distinguish consecutive edits
        // to one field, including when the wall clock moves backwards.
        let changed = min(Date.distantFuture, item[keyPath: field].map { max(now, $0.addingTimeInterval(0.001)) } ?? now)
        item[keyPath: field] = changed
        item.lastUpdated = max(item.lastUpdated, changed)
    }

    // MARK: - Library mutations

    func upsertLibraryEntry(details: DetailsDto, watchType: WatchType) throws {
        try withMutation(shared: false) { context in
            let id = try resolvedItemID(for: details, in: context)

            let descriptor = FetchDescriptor<StoredMediaItem>(predicate: #Predicate { $0.id == id })
            let existing = (try context.fetch(descriptor)).first

            if let existing {
                existing.providerID = existing.providerID ?? details.providerId
                absorbMetadata(existing, from: details)
                let title = try titleEntry(existing, in: context)
                title.watchType = watchType
                stamp(title, \.watchTypeUpdatedAt)
                try autoMerge(title, in: context)
            } else {
                let item = newItem(id: id, from: details, watchType: watchType)
                stamp(item, \.watchTypeUpdatedAt)
                context.insert(item)
                try autoMerge(item, in: context)
            }
            try save(context: context)
        }
    }

    func removeFromLibrary(details: DetailsDto) throws {
        try setWatchType(details: details, watchType: nil)
    }

    func setWatchType(details: DetailsDto, watchType: WatchType?) throws {
        try withMutation(shared: false) { context in
            let id = try resolvedItemID(for: details, in: context)
            let descriptor = FetchDescriptor<StoredMediaItem>(predicate: #Predicate { $0.id == id })
            guard let existing = (try context.fetch(descriptor)).first else { return }
            let title = try titleEntry(existing, in: context)
            title.watchType = watchType
            stamp(title, \.watchTypeUpdatedAt)
            // Keep the clear tombstone and independent notes/history/settings.
            try save(context: context)
        }
    }

    /// Context-menu "Mark as Watched": marks the entry completed and clears
    /// the resume position — distinct from plain removal (V-23).
    func markWatched(itemID: String) throws {
        try withMutation(shared: false) { context in
            let descriptor = FetchDescriptor<StoredMediaItem>(predicate: #Predicate { $0.id == itemID })
            guard let existing = (try context.fetch(descriptor)).first else { return }
            let title = try titleEntry(existing, in: context)
            title.watchType = .completed
            stamp(title, \.watchTypeUpdatedAt)
            existing.progressSeconds = 0
            stamp(existing, \.progressUpdatedAt)
            try save(context: context)
        }
    }

    func watchType(details: DetailsDto) throws -> WatchType? {
        let context = context
        guard let context else { throw ImportError.storeUnavailable }
        try persistenceFault?(.queryRead)
        let id = try resolvedItemID(for: details, in: context)
        let descriptor = FetchDescriptor<StoredMediaItem>(predicate: #Predicate { $0.id == id })
        guard let existing = (try context.fetch(descriptor)).first else { return nil }
        return try titleEntry(existing, in: context).watchType
    }

    /// Continue Watching + resume position bookkeeping during playback.
    /// Periodic in-playback writes pass `notifyObservers: false`; session
    /// boundaries (episode change, close) notify so Continue Watching refreshes.
    func recordProgress(
        details: DetailsDto,
        episode: EpisodeDto?,
        progressSeconds: Double,
        totalDurationSeconds: Double,
        notifyObservers: Bool = true,
    ) throws {
        guard let context else {
            // The owner cannot be written now. Keep the latest position for
            // it instead of dropping it, and report that it is not saved.
            unownedProgress[UnownedProgressKey(storeName: intendedProfileStoreName, item: Self.itemID(for: details), episode: episode?.data)] =
                UnownedProgress(details: details, episode: episode, position: progressSeconds, duration: totalDurationSeconds,
                                recordedAt: mutationClock(), order: .now)
            pendingProgressFailure = ImportError.storeUnavailable.localizedDescription
            persistProgressJournal()
            throw ImportError.storeUnavailable
        }
        let key = ProgressKey(owner: ObjectIdentifier(context), item: Self.itemID(for: details), episode: episode?.data)
        let pending = PendingProgress(context: context, details: details, episode: episode,
            position: progressSeconds, duration: totalDurationSeconds, recordedAt: mutationClock(), order: .now,
            notify: notifyObservers || (pendingProgress[key]?.notify ?? false))
        pendingProgress[key] = pending
        // Kept, and saved as soon as the restore has finished.
        if isImporting { return }
        try flushOwnedProgress(notifyObservers: false)
    }

    /// Saves every retained playback position. Throws while any position is
    /// unsaved, including one waiting for the selected profile's store to
    /// open, so callers never treat the library as complete.
    func flushPendingProgress(notifyObservers: Bool = true) throws {
        try flushOwnedProgress(notifyObservers: notifyObservers)
        if context == nil, unownedProgress.keys.contains(where: { $0.storeName == intendedProfileStoreName }) {
            pendingProgressFailure = ImportError.storeUnavailable.localizedDescription
            throw ImportError.storeUnavailable
        }
    }

    /// The store that owns waiting positions has opened: they become ordinary
    /// retained writes for it, applied in the order they were played. A
    /// failure leaves them retained and visible like any other failed write.
    private func adoptUnownedProgress() {
        guard let context else { return }
        let owned = unownedProgress.filter { $0.key.storeName == activeProfileStoreName }
        guard !owned.isEmpty else { return }
        for (key, waiting) in owned {
            unownedProgress[key] = nil
            let pendingKey = ProgressKey(owner: ObjectIdentifier(context), item: key.item, episode: key.episode)
            pendingProgress[pendingKey] = PendingProgress(context: context, details: waiting.details, episode: waiting.episode,
                position: waiting.position, duration: waiting.duration, recordedAt: waiting.recordedAt, order: waiting.order, notify: true)
        }
        do { try flushOwnedProgress(notifyObservers: true) }
        catch { DaemonLog.client("store.progress_adoption_failed", fields: ["error": error.localizedDescription]) }
    }

    private func flushOwnedProgress(notifyObservers: Bool) throws {
        for (key, pending) in pendingProgress.sorted(by: { $0.value.order < $1.value.order }) {
            do {
                try commitProgress(pending, forceNotify: notifyObservers)
                pendingProgress[key] = nil
            } catch {
                pendingProgressFailure = error.localizedDescription
                persistProgressJournal()
                throw error
            }
        }
        pendingProgressFailure = nil
        if progressJournalOnDisk { persistProgressJournal() }
    }

    // MARK: - Progress journal

    /// Positions left unsaved by a previous run wait for their own store,
    /// exactly like positions played while it could not be opened.
    private func loadProgressJournal() {
        guard let url = progressJournalURL, FileManager.default.fileExists(atPath: url.path) else { return }
        progressJournalOnDisk = true
        do {
            let entries = try JSONDecoder().decode([ProgressJournalEntry].self, from: Data(contentsOf: url))
            let base = ContinuousClock.now
            for (index, entry) in entries.sorted(by: { $0.recordedAt < $1.recordedAt }).enumerated() {
                unownedProgress[UnownedProgressKey(storeName: entry.storeName, item: Self.itemID(for: entry.details), episode: entry.episode?.data)] =
                    UnownedProgress(details: entry.details, episode: entry.episode, position: entry.position, duration: entry.duration,
                                    recordedAt: entry.recordedAt, order: base.advanced(by: .nanoseconds(index)))
            }
            DaemonLog.client("store.progress_journal_loaded", fields: ["entries": "\(entries.count)"])
        } catch {
            // Never block launch on it; keep the file for inspection.
            DaemonLog.client("store.progress_journal_unreadable", fields: ["error": error.localizedDescription])
            progressJournalOnDisk = false
        }
    }

    /// Writes every unsaved position (or removes the journal when none is left).
    private func persistProgressJournal() {
        guard let url = progressJournalURL else { return }
        let waiting = unownedProgress.map { key, value in
            ProgressJournalEntry(storeName: key.storeName, details: value.details, episode: value.episode,
                                 position: value.position, duration: value.duration, recordedAt: value.recordedAt)
        }
        // Retained owned writes belong to the selected store: a profile switch
        // flushes them first and refuses to proceed while any fails.
        let retained = pendingProgress.values.map {
            ProgressJournalEntry(storeName: activeProfileStoreName, details: $0.details, episode: $0.episode,
                                 position: $0.position, duration: $0.duration, recordedAt: $0.recordedAt)
        }
        let entries = waiting + retained
        do {
            if entries.isEmpty {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                progressJournalOnDisk = false
                return
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(entries).write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            progressJournalOnDisk = true
        } catch {
            DaemonLog.client("store.progress_journal_failed", fields: ["error": error.localizedDescription])
        }
    }

    private func commitProgress(_ pending: PendingProgress, forceNotify: Bool) throws {
        let context = pending.context
        let details = pending.details
        let episode = pending.episode
        let progressSeconds = pending.position
        let totalDurationSeconds = pending.duration
        let notifyObservers = pending.notify || forceNotify
        let recordedAt = pending.recordedAt
        try withMutation(in: context) { context in
            let id = try resolvedItemID(for: details, in: context)

            let descriptor = FetchDescriptor<StoredMediaItem>(predicate: #Predicate { $0.id == id })
            let existing = (try context.fetch(descriptor)).first

            if let existing {
                existing.providerID = existing.providerID ?? details.providerId
                absorbMetadata(existing, from: details)
                existing.progressSeconds = progressSeconds
                // 0 means the length is not yet known: keep what is stored for
                // the same episode, never another episode's length.
                let switched = episode.map { $0.data != existing.lastEpisodeData } ?? false
                if totalDurationSeconds > 0 || switched {
                    existing.totalDurationSeconds = totalDurationSeconds
                }
                if let episode {
                    existing.lastEpisodeData = episode.data
                    existing.lastSeason = episode.season
                    existing.lastEpisode = episode.episode
                    existing.lastAudio = episode.audio
                }
                stamp(existing, \.progressUpdatedAt, at: recordedAt)
            } else {
                // Playback never files a title into the library: "Watching"
                // is a user-curated list, separate from Continue Watching
                // (matches Android's bookmarks vs. resume-watching split).
                let item = newItem(id: id, from: details)
                item.progressSeconds = progressSeconds
                item.totalDurationSeconds = totalDurationSeconds
                item.lastUpdated = recordedAt
                item.progressUpdatedAt = recordedAt
                item.lastEpisodeData = episode?.data
                item.lastSeason = episode?.season
                item.lastEpisode = episode?.episode
                item.lastAudio = episode?.audio
                context.insert(item)
            }
            var structural = existing == nil
            if let episode, !episode.data.isEmpty {
                structural = try recordHistory(
                    row: try episodeRow(itemID: id, episode: episode, in: context),
                    position: progressSeconds, duration: totalDurationSeconds, updatedAt: recordedAt,
                ) || structural
            } else if episode == nil, !details.isSeries {
                structural = try recordHistory(
                    row: try movieRow(itemID: id, in: context),
                    position: progressSeconds, duration: totalDurationSeconds, updatedAt: recordedAt,
                ) || structural
            }
            // The source last played fronts its title (ADR-0020).
            if let existing, existing.mergedIntoID != nil {
                try promote(existing, in: context)
                structural = true
            }
            if try applyLibraryAutoPromotion(item: existing, details: details, episode: episode, position: progressSeconds, duration: totalDurationSeconds, in: context) {
                structural = true
            }
            // A new entry (or a watched/status transition) is structural — always notify.
            try save(context: context, notify: notifyObservers || structural)
        }
    }

    /// Lightweight DTO for context-menu operations on library entries
    /// (upsert/remove take DetailsDto).
    func detailsPreview(for item: StoredMediaItem) -> DetailsDto {
        var details = DetailsDto(
            provider: item.providerName,
            providerId: item.providerID,
            url: item.providerURL,
            name: item.title,
            type: item.mediaType,
            posterUrl: item.posterURL,
            backgroundPosterUrl: item.bannerURL,
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
        details.localDownloadID = item.downloadRecordID
        return details
    }

    /// Minimal details for filing a search/browse result into the library
    /// without loading its page first.
    func detailsPreview(for result: SearchResultDto) -> DetailsDto {
        DetailsDto(
            provider: result.provider,
            providerId: result.providerId,
            url: result.url,
            name: result.name,
            type: result.type,
            posterUrl: result.posterUrl,
            backgroundPosterUrl: nil,
            logoUrl: nil,
            plot: nil,
            year: result.year,
            durationMinutes: nil,
            score: result.score,
            tags: [],
            actors: [],
            contentRating: nil,
            comingSoon: false,
            episodes: [],
            movieData: nil,
        )
    }

    func resumeItem(for details: DetailsDto) throws -> StoredMediaItem? {
        let context = context
        guard let context else { throw ImportError.storeUnavailable }
        try persistenceFault?(.queryRead)
        let id = try resolvedItemID(for: details, in: context)
        let descriptor = FetchDescriptor<StoredMediaItem>(predicate: #Predicate { $0.id == id })
        return (try context.fetch(descriptor)).first
    }

    // MARK: - Library queries

    /// All entries regardless of status, newest first ("Recently Added", "All").
    func allEntries() throws -> [StoredMediaItem] {
        try items(withWatchType: nil)
    }

    /// `watchType == nil` means "All": every entry with an explicit status.
    /// A source merged into another title (ADR-0020) is shown through its
    /// primary, never as a card of its own (Remediation 4.1).
    func items(withWatchType watchType: WatchType?) throws -> [StoredMediaItem] {
        let context = context
        guard let context else { throw ImportError.storeUnavailable }
        try persistenceFault?(.queryRead)
        if let watchType {
            let raw = watchType.rawValue
            let descriptor = FetchDescriptor<StoredMediaItem>(
                predicate: #Predicate { $0.watchTypeRaw == raw && $0.mergedIntoID == nil },
                sortBy: [SortDescriptor(\.lastUpdated, order: .reverse)],
            )
            return (try context.fetch(descriptor))
        }
        let descriptor = FetchDescriptor<StoredMediaItem>(
            predicate: #Predicate { $0.watchTypeRaw != -1 && $0.mergedIntoID == nil },
            sortBy: [SortDescriptor(\.lastUpdated, order: .reverse)],
        )
        return (try context.fetch(descriptor))
    }

    /// Tally for sidebar badges. Counted in the store (six COUNT queries):
    /// materializing every title to count it took ~0.4 s at 10,000 titles on
    /// every sidebar render, measured in LargeLibraryMeasurementTests.
    struct LibraryCounts {
        var watching = 0
        var planToWatch = 0
        var completed = 0
        var onHold = 0
        var dropped = 0
        var favorites = 0
    }

    func counts() throws -> LibraryCounts {
        let context = context
        guard let context else { throw ImportError.storeUnavailable }
        try persistenceFault?(.queryRead)
        func count(_ type: WatchType) throws -> Int {
            let raw = type.rawValue
            return try context.fetchCount(FetchDescriptor<StoredMediaItem>(predicate: #Predicate { $0.watchTypeRaw == raw && $0.mergedIntoID == nil }))
        }
        // Badges count distinct titles, as the lists show them.
        return LibraryCounts(
            watching: try count(.watching), planToWatch: try count(.planToWatch), completed: try count(.completed),
            onHold: try count(.onHold), dropped: try count(.dropped),
            favorites: try context.fetchCount(FetchDescriptor<StoredMediaItem>(predicate: #Predicate { $0.isFavorite && $0.mergedIntoID == nil })),
        )
    }

    var favorites: [StoredMediaItem] {
        get throws {
            let context = context
            guard let context else { throw ImportError.storeUnavailable }
            try persistenceFault?(.queryRead)
            let descriptor = FetchDescriptor<StoredMediaItem>(
                predicate: #Predicate { $0.isFavorite && $0.mergedIntoID == nil },
                sortBy: [SortDescriptor(\.lastUpdated, order: .reverse)],
            )
            return (try context.fetch(descriptor))

        }
    }

    func isFavorite(details: DetailsDto) throws -> Bool {
        let context = context
        guard let context else { throw ImportError.storeUnavailable }
        try persistenceFault?(.queryRead)
        let id = try resolvedItemID(for: details, in: context)
        let descriptor = FetchDescriptor<StoredMediaItem>(predicate: #Predicate { $0.id == id })
        guard let existing = (try context.fetch(descriptor)).first else { return false }
        return try titleEntry(existing, in: context).isFavorite
    }

    func toggleFavorite(details: DetailsDto) throws {
        try withMutation(shared: false) { context in
            let id = try resolvedItemID(for: details, in: context)
            let descriptor = FetchDescriptor<StoredMediaItem>(predicate: #Predicate { $0.id == id })
            let existing = (try context.fetch(descriptor)).first

            if let existing {
                existing.providerID = existing.providerID ?? details.providerId
                absorbMetadata(existing, from: details)
                let title = try titleEntry(existing, in: context)
                title.isFavorite.toggle()
                stamp(title, \.favoriteUpdatedAt)
                try autoMerge(title, in: context)
            } else {
                let item = newItem(id: id, from: details, isFavorite: true)
                stamp(item, \.favoriteUpdatedAt)
                context.insert(item)
                try autoMerge(item, in: context)
            }
            try save(context: context)
        }
    }

    /// Titles with real resume positions. A title whose duration is unknown
    /// (total == 0) stays eligible — it can never reach a fraction threshold.
    var continueWatching: [StoredMediaItem] {
        get throws {
            let context = context
            guard let context else { throw ImportError.storeUnavailable }
            try persistenceFault?(.queryRead)
            let descriptor = FetchDescriptor<StoredMediaItem>(
                predicate: #Predicate { $0.progressSeconds > 10 },
                sortBy: [SortDescriptor(\.lastUpdated, order: .reverse)],
            )
            let items = (try context.fetch(descriptor))
            return items.filter { item in
                // A merged source's title is resumed through its primary (ADR-0020).
                guard item.mergedIntoID == nil else { return false }
                guard item.totalDurationSeconds > 0 else { return true }
                return item.progressSeconds / item.totalDurationSeconds < 0.95
            }

        }
    }

    func removeProgress(id: String) throws {
        try withMutation(shared: false) { context in
            let descriptor = FetchDescriptor<StoredMediaItem>(predicate: #Predicate { $0.id == id })
            for item in (try context.fetch(descriptor)) {
                item.progressSeconds = 0
            }
            try save(context: context)
        }
    }

    /// Captured on the click's actor turn, before a task can be delayed by a
    /// profile switch. Never retain a SwiftData object across the request.
    struct ResumeRequest: Equatable {
        let owner: ProfileOperationContext
        let itemID: String
        let title: String
        let mediaType: String
        let provider: String
        let url: String
        let episodeData: String?
        let season: Int?
        let episode: Int?
        let audio: String?
        let position: Double
        let updatedAt: Date?
    }

    @ObservationIgnored private var resumeTasks: [UUID: Task<Void, Never>] = [:]

    func cancelProfileOperations() {
        resumeTasks.values.forEach { $0.cancel() }
    }

    func resumeRequest(for item: StoredMediaItem) throws -> ResumeRequest {
        let owner = try captureProfileOperation()
        guard item.modelContext === context else { throw CancellationError() }
        return ResumeRequest(owner: owner, itemID: item.id, title: item.title, mediaType: item.mediaType, provider: item.providerKey,
            url: item.providerURL, episodeData: item.lastEpisodeData, season: item.lastSeason,
            episode: item.lastEpisode, audio: item.lastAudio, position: item.progressSeconds, updatedAt: item.progressUpdatedAt)
    }

    /// Application-owned requests also cover Dock, menu-bar and Shortcut entry
    /// points. Locking/switching cancels them; ownership fences late responses.
    func startResume(item: StoredMediaItem, appState: AppState) {
        guard !AppLock.shared.isLocked else { return }
        let request: ResumeRequest
        do { request = try resumeRequest(for: item) }
        catch is CancellationError { return }
        catch { appState.presentError("Couldn't resume: \(error.localizedDescription)"); return }
        let local = request.mediaType == "Download"
        guard local || appState.isEngineBootstrapped else {
            appState.presentError("The engine is still preparing providers. Try again when it is ready.")
            return
        }
        let engine = appState.connection.generation
        let lock = AppLock.shared.generation
        let id = UUID()
        // The player window opens now; details load behind its spinner.
        let pending = appState.player.beginPending(title: request.title)
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.resumeTasks.removeValue(forKey: id) }
            // No-op once `play()` took over; otherwise the spinner would stay.
            defer { if let pending { appState.player.endPending(pending) } }
            await self.resume(request: request,
                isAuthorized: { !AppLock.shared.isLocked && AppLock.shared.generation == lock
                    && (local || (appState.isEngineBootstrapped && appState.connection.generation == engine)) },
                loadDetails: { try await DaemonClient.shared.details(provider: $0, url: $1) },
                play: { details, episode, position in
                    // The user closed the pending window meanwhile.
                    if let pending, !appState.player.isPending(pending) { return }
                    await appState.player.play(details: details, episode: episode,
                        resumeAt: position, preferences: UserPreferences.shared,
                        localMediaURL: details.type == "Download" ? URL(fileURLWithPath: details.url) : nil)
                }, reportError: {
                    // Close first: the alert must not sit behind a spinner window.
                    if let pending { appState.player.endPending(pending) }
                    appState.presentError($0)
                })
        }
        resumeTasks[id] = task
    }

    func resume(request: ResumeRequest, isAuthorized: @escaping @MainActor () -> Bool,
                loadDetails: @MainActor (String, String) async throws -> DetailsDto,
                play: @MainActor (DetailsDto, EpisodeDto?, Double?) async -> Void,
                reportError: @MainActor (String) -> Void) async {
        let current = { !Task.isCancelled && self.owns(request.owner) && isAuthorized() }
        guard current() else { return }
        do {
            let details: DetailsDto
            if request.mediaType == "Download" {
                details = try localResumeDetails(for: request)
            } else {
                details = try await loadDetails(request.provider, request.url)
                // Provider output cannot acquire the application's local-file
                // privilege merely by claiming to be a downloaded title.
                guard details.type != "Download", details.localDownloadID == nil else {
                    throw ResumeError.invalidRemoteDetails
                }
            }
            guard current() else { return }
            // A privacy clear, deletion, or a newer playback intent while details
            // were loading cannot restore the old resume position.
            guard let item = try item(id: request.itemID), try resumeRequest(for: item) == request else { return }
            let episode: EpisodeDto?
            if request.mediaType == "Download" {
                episode = nil
            } else if !details.episodes.isEmpty || request.episodeData != nil
                || Self.seriesMediaTypes.contains(request.mediaType.lowercased()) {
                episode = try Self.resumeEpisode(in: details, data: request.episodeData,
                    season: request.season, episode: request.episode, audio: request.audio)
            } else { episode = nil }
            guard current() else { return }
            await play(details, episode, request.position > 5 ? request.position : nil)
        } catch {
            guard current(), !(error is CancellationError) else { return }
            reportError("Couldn't resume \(request.title): \(error.localizedDescription)")
        }
    }

    private func localResumeDetails(for request: ResumeRequest) throws -> DetailsDto {
        guard let id = LibraryIdentity.downloadID(from: request.itemID),
              request.url.hasPrefix("/"),
              let record = try downloadRecord(id: id), record.statusRaw == 4,
              record.destinationPath == request.url,
              let item = try item(id: request.itemID), try resumeRequest(for: item) == request else {
            throw ResumeError.downloadUnavailable
        }
        let url = URL(fileURLWithPath: record.destinationPath)
        guard FileManager.default.isReadableFile(atPath: url.path),
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw ResumeError.downloadUnavailable
        }
        return detailsPreview(for: item)
    }

    enum ResumeError: LocalizedError {
        case episodeUnavailable, downloadUnavailable, invalidRemoteDetails
        var errorDescription: String? {
            switch self {
            case .episodeUnavailable:
                return "The saved episode is unavailable or ambiguous. Open the title to choose an episode."
            case .downloadUnavailable:
                return "The completed download is unavailable or no longer matches this title. Open Downloads to locate it."
            case .invalidRemoteDetails:
                return "The provider returned an unsupported title type. Reload the title to try again."
            }
        }
    }

    /// Exact stream identity wins over coordinates. The coordinate fallback
    /// requires both values, the saved edition when one is known, and one
    /// candidate; nils or sub/dub ambiguity cannot select an unrelated episode
    /// or enter movie playback.
    static func resumeEpisode(in details: DetailsDto, data: String?, season: Int?, episode: Int?, audio: String? = nil) throws -> EpisodeDto {
        if let data, !data.isEmpty, let exact = details.episodes.first(where: { $0.data == data }) { return exact }
        if let season, let episode {
            var candidates = details.episodes.filter { $0.season == season && $0.episode == episode }
            if let audio { candidates = candidates.filter { $0.audio == audio } }
            if candidates.count == 1, let candidate = candidates.first { return candidate }
        }
        throw ResumeError.episodeUnavailable
    }

    // MARK: - Per-episode history (Offline-Features-Plan Phase 1)

    /// Updates a history row. Returns true when its watched flag flipped (a
    /// structural change views must see).
    private func recordHistory(row: EpisodeProgress, position: Double, duration: Double, updatedAt: Date) throws -> Bool {
        let wasWatched = row.watched
        row.positionSeconds = position
        if duration > 0 { row.durationSeconds = duration }
        // Watched is sticky during playback: scrubbing back to re-watch a
        // scene must not un-tick the episode. Only an explicit "Mark as
        // Unwatched" clears it.
        if !row.watched, WatchProgressPolicy.isWatched(position: position, duration: row.durationSeconds) {
            row.watched = true
        }
        row.updatedAt = updatedAt
        return row.watched != wasWatched
    }

    private func episodeRow(itemID: String, episode: EpisodeDto, in context: ModelContext) throws -> EpisodeProgress {
        let key = EpisodeProgress.key(itemID: itemID, episodeData: episode.data)
        let descriptor = FetchDescriptor<EpisodeProgress>(predicate: #Predicate { $0.id == key })
        if let existing = (try context.fetch(descriptor)).first {
            existing.audio = existing.audio ?? episode.audio
            return existing
        }
        let row = EpisodeProgress(itemID: itemID, episodeData: episode.data, season: episode.season, episode: episode.episode, audio: episode.audio)
        context.insert(row)
        return row
    }

    private func movieRow(itemID: String, in context: ModelContext) throws -> EpisodeProgress {
        let key = EpisodeProgress.key(itemID: itemID, episodeData: EpisodeProgress.moviePlaybackData)
        if let existing = try context.fetch(FetchDescriptor<EpisodeProgress>(predicate: #Predicate { $0.id == key })).first {
            return existing
        }
        let row = EpisodeProgress(movieItemID: itemID)
        context.insert(row)
        return row
    }

    /// Library bookkeeping Android users expect: starting a Plan-to-Watch
    /// title moves it to Watching; finishing the last unwatched episode (or a
    /// movie) moves a library entry to Completed. Only titles the user filed
    /// into the library are touched. Returns true when the status changed.
    private func applyLibraryAutoPromotion(
        item: StoredMediaItem?,
        details: DetailsDto,
        episode: EpisodeDto?,
        position: Double,
        duration: Double,
        in context: ModelContext,
    ) throws -> Bool {
        guard let item, let current = item.watchType, autoUpdateLibraryStatus else { return false }

        let finished: Bool
        if details.isSeries {
            let itemID = item.id
            let rows = try context.fetch(FetchDescriptor<EpisodeProgress>(predicate: #Predicate { $0.itemID == itemID }))
            let progress = Dictionary(rows.map { ($0.episodeData, $0.snapshot) }, uniquingKeysWith: { $0.updatedAt >= $1.updatedAt ? $0 : $1 })
            let relevant = details.episodes.filter { $0.audio == episode?.audio }
            finished = !relevant.isEmpty && relevant.allSatisfy { progress[$0.data]?.watched == true }
        } else {
            finished = WatchProgressPolicy.isWatched(position: position, duration: duration)
        }

        if finished, current != .completed {
            item.watchType = .completed
            stamp(item, \.watchTypeUpdatedAt)
            return true
        }
        if current == .planToWatch, position >= WatchProgressPolicy.minimumResumeSeconds {
            item.watchType = .watching
            stamp(item, \.watchTypeUpdatedAt)
            return true
        }
        return false
    }

    /// Settings ▸ Library "Update status automatically". Read through the
    /// shared preferences; tests flip it on the store directly.
    var autoUpdateLibraryStatusOverride: Bool?
    private var autoUpdateLibraryStatus: Bool {
        autoUpdateLibraryStatusOverride ?? UserPreferences.shared.autoUpdateLibraryStatus
    }

    /// One fetch per detail page, keyed by `EpisodeDto.data`.
    func episodeProgress(itemID: String) throws -> [String: EpisodeProgressSnapshot] {
        guard let context else { throw ImportError.storeUnavailable }
        try persistenceFault?(.queryRead)
        let descriptor = FetchDescriptor<EpisodeProgress>(predicate: #Predicate { $0.itemID == itemID })
        let rows = (try context.fetch(descriptor))
        return Dictionary(rows.map { ($0.episodeData, $0.snapshot) }, uniquingKeysWith: { lhs, rhs in
            lhs.updatedAt >= rhs.updatedAt ? lhs : rhs
        })
    }

    func episodeProgress(details: DetailsDto) throws -> [String: EpisodeProgressSnapshot] {
        try episodeProgress(itemID: persistedItemID(for: details))
    }

    /// Explicit watched/unwatched marking (episode context menu, season menu,
    /// "Mark All Previous"). Unwatching also clears the position so the
    /// episode starts from the beginning next time.
    func setEpisodesWatched(details: DetailsDto, episodes: [EpisodeDto], watched: Bool) throws {
        try withMutation(shared: false) { context in
            guard !episodes.isEmpty else { return }
            let item = try ensureItem(for: details, in: context)
            // One fetch for the title's rows, not one per episode (Phase 10:
            // "mark season watched" on 1 000-episode shows).
            let itemID = item.id
            let existing = (try context.fetch(FetchDescriptor<EpisodeProgress>(predicate: #Predicate { $0.itemID == itemID })))
            var rows = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { lhs, _ in lhs })
            for episode in episodes where !episode.data.isEmpty {
                let key = EpisodeProgress.key(itemID: itemID, episodeData: episode.data)
                let row = rows[key] ?? {
                    let created = EpisodeProgress(itemID: itemID, episodeData: episode.data, season: episode.season, episode: episode.episode, audio: episode.audio)
                    context.insert(created)
                    rows[key] = created
                    return created
                }()
                row.watched = watched
                if !watched { row.positionSeconds = 0 }
                row.updatedAt = Date()
            }
            // The title-level resume pointer must not keep offering a position in
            // an episode the user just declared watched.
            if watched, let pointer = item.lastEpisodeData, episodes.contains(where: { $0.data == pointer }) {
                item.progressSeconds = 0
                stamp(item, \.progressUpdatedAt)
            }
            _ = try applyLibraryAutoPromotion(item: item, details: details, episode: episodes.last, position: 0, duration: 0, in: context)
            item.lastUpdated = max(item.lastUpdated, mutationClock())
            try save(context: context)
        }
    }

    /// Marks every episode before `episode` (in the given playback order) watched.
    func markPreviousWatched(details: DetailsDto, orderedEpisodes: [EpisodeDto], upTo episode: EpisodeDto, inclusive: Bool = false) throws {
        guard let index = orderedEpisodes.firstIndex(of: episode) else { return }
        let end = inclusive ? index + 1 : index
        guard end > 0 else { return }
        try setEpisodesWatched(details: details, episodes: Array(orderedEpisodes[..<end]), watched: true)
    }

    private func retainsIndependentUserData(_ item: StoredMediaItem, in context: ModelContext) throws -> Bool {
        if item.watchType != nil || item.isFavorite || item.userNote != nil || item.userRating > 0 || item.mediaType == "Download"
            || item.noteUpdatedAt != nil || item.ratingUpdatedAt != nil || item.favoriteUpdatedAt != nil || item.watchTypeUpdatedAt != nil { return true }
        let id = item.id
        return try context.fetchCount(FetchDescriptor<TitlePlaybackPrefs>(predicate: #Predicate { $0.itemID == id })) > 0
    }

    /// Clears every episode's history and the title's resume position.
    func clearWatchHistory(itemID: String) throws {
        try withMutation(shared: false) { context in
            let descriptor = FetchDescriptor<EpisodeProgress>(predicate: #Predicate { $0.itemID == itemID })
            for row in (try context.fetch(descriptor)) {
                context.delete(row)
            }
            let itemDescriptor = FetchDescriptor<StoredMediaItem>(predicate: #Predicate { $0.id == itemID })
            if let item = (try context.fetch(itemDescriptor)).first {
                item.progressSeconds = 0
                if try !retainsIndependentUserData(item, in: context) { context.delete(item) }
                else { stamp(item, \.progressUpdatedAt) }
            }
            try save(context: context)
        }
    }

    /// Chronological history (most recent first) for the History view.
    func watchHistory(limit: Int = 500) throws -> [EpisodeProgress] {
        guard let context else { throw ImportError.storeUnavailable }
        try persistenceFault?(.queryRead)
        var descriptor = FetchDescriptor<EpisodeProgress>(
            predicate: #Predicate { $0.positionSeconds > 0 || $0.watched },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)],
        )
        descriptor.fetchLimit = limit
        return (try context.fetch(descriptor))
    }

    func item(id: String) throws -> StoredMediaItem? {
        guard let context else { throw ImportError.storeUnavailable }
        try persistenceFault?(.queryRead)
        if let current = try mutationItem(id: id, in: context) { return current }
        let migrationName = "provider-identity-v2"
        if let marker = try context.fetch(FetchDescriptor<LibraryMigrationRecord>(predicate: #Predicate { $0.name == migrationName })).first,
           !marker.keyMappingData.isEmpty,
           let target = try JSONDecoder().decode([String: String].self, from: marker.keyMappingData)[id],
           let current = try mutationItem(id: target, in: context) { return current }
        let matches = try context.fetch(FetchDescriptor<StoredMediaItem>(predicate: #Predicate { $0.legacyItemID == id }))
        guard matches.count <= 1 else { throw ImportError.identityConflict("This legacy link has more than one owner.") }
        return matches.first
    }

    /// Removes one history row. When it is the title's current resume pointer,
    /// the pointer moves to the latest remaining row or clears in the same
    /// transaction; a newer different episode's pointer is left alone.
    func deleteHistoryEntry(id: String) throws {
        try withMutation(shared: false) { context in
            guard let row = try context.fetch(FetchDescriptor<EpisodeProgress>(predicate: #Predicate { $0.id == id })).first else { return }
            let itemID = row.itemID
            let wasMovie = row.isMovie
            let data = row.episodeData
            context.delete(row)
            if let item = try mutationItem(id: itemID, in: context),
               wasMovie ? (item.lastEpisodeData ?? "").isEmpty : item.lastEpisodeData == data {
                let remaining = try context.fetch(FetchDescriptor<EpisodeProgress>(
                    predicate: #Predicate { $0.itemID == itemID },
                    sortBy: [SortDescriptor(\.updatedAt, order: .reverse)],
                )).first { $0.id != id && ($0.positionSeconds > 0 || $0.watched) }
                item.lastEpisodeData = remaining.flatMap { $0.isMovie ? nil : $0.episodeData }
                item.lastSeason = remaining?.season
                item.lastEpisode = remaining?.episode
                item.lastAudio = remaining?.audio
                item.progressSeconds = remaining.map { $0.watched ? 0 : $0.positionSeconds } ?? 0
                item.totalDurationSeconds = remaining?.durationSeconds ?? 0
                if remaining == nil, try !retainsIndependentUserData(item, in: context) { context.delete(item) }
                else { stamp(item, \.progressUpdatedAt) }
            }
            try save(context: context)
        }
    }

    /// Wipes all episode history and every resume position (Settings ▸ Privacy).
    func clearAllWatchHistory() throws {
        try withMutation(shared: false) { context in
            for row in try context.fetch(FetchDescriptor<EpisodeProgress>()) { context.delete(row) }
            for item in (try context.fetch(FetchDescriptor<StoredMediaItem>())) {
                item.progressSeconds = 0
                if try !retainsIndependentUserData(item, in: context) { context.delete(item) }
                else { stamp(item, \.progressUpdatedAt) }
            }
            try save(context: context)
        }
    }

    struct WatchStats: Equatable {
        var titles = 0
        var episodesWatched = 0
        var moviesWatched = 0
        var secondsWatched: Double = 0
        /// Played rows whose title record is missing (legacy or imported).
        var unownedEntries = 0
    }

    /// Counts the same rows History shows: played or watched, with a title.
    func watchStats() throws -> WatchStats {
        guard let context else { throw ImportError.storeUnavailable }
        try persistenceFault?(.queryRead)
        var stats = WatchStats()
        let played = try context.fetch(FetchDescriptor<EpisodeProgress>(predicate: #Predicate { $0.positionSeconds > 0 || $0.watched }))
        let titles = Set(try context.fetch(FetchDescriptor<StoredMediaItem>()).map(\.id))
        let rows = played.filter { titles.contains($0.itemID) }
        stats.unownedEntries = played.count - rows.count
        stats.episodesWatched = rows.filter { $0.watched && !$0.isMovie }.count
        stats.moviesWatched = rows.filter { $0.watched && $0.isMovie }.count
        stats.secondsWatched = rows.reduce(0) { total, row in
            total + (row.watched && row.durationSeconds > 0 ? row.durationSeconds : row.positionSeconds)
        }
        stats.titles = Set(rows.map(\.itemID)).count
        return stats
    }

    /// Identifies the currently open durable owner without exposing a live model.
    var identityOwnerToken: ObjectIdentifier? { (profileContainer ?? container).map(ObjectIdentifier.init) }

    /// A value report can be inspected before applying any durable change.
    func identityMigrationPlan(providers: [LibraryIdentityMigration.Provider]) throws -> LibraryIdentityMigration.Report {
        guard let context else { throw ImportError.storeUnavailable }
        try persistenceFault?(.queryRead)
        return try identityPlan(in: context, providers: providers)
    }

    private func identityPlan(in context: ModelContext, providers: [LibraryIdentityMigration.Provider], assignments: [String: LibraryIdentityMigration.Provider] = [:]) throws -> LibraryIdentityMigration.Report {
        let rows = try context.fetch(FetchDescriptor<StoredMediaItem>())
        let downloads: [LibraryIdentityMigration.Download]
        if assignments.isEmpty, rows.contains(where: { $0.mediaType == "Download" }) {
            downloads = try downloadRecords().map { .init(id: $0.id, path: $0.destinationPath) }
        } else { downloads = [] }
        var report = LibraryIdentityMigration.plan(items: rows.map {
            .init(id: $0.id, providerID: $0.providerID, providerName: $0.providerName,
                  url: $0.providerURL, isDownload: $0.mediaType == "Download")
        }, providers: providers, assignments: assignments, downloads: downloads)
        guard !report.changes.isEmpty || !report.localChanges.isEmpty else { return report }
        let mapping = Dictionary(uniqueKeysWithValues: report.changes.map { ($0.oldID, $0.newID) } + report.localChanges.map { ($0.oldID, $0.newID) })
        var episodeKeys = Set<String>()
        for row in try context.fetch(FetchDescriptor<EpisodeProgress>()) {
            let key = EpisodeProgress.key(itemID: mapping[row.itemID] ?? row.itemID, episodeData: row.episodeData)
            if !episodeKeys.insert(key).inserted { report.conflicts.append("History records resolve to the same episode identity.") }
        }
        var preferenceKeys = Set<String>()
        for row in try context.fetch(FetchDescriptor<TitlePlaybackPrefs>()) {
            if !preferenceKeys.insert(mapping[row.itemID] ?? row.itemID).inserted {
                report.conflicts.append("Playback settings resolve to the same title identity.")
            }
        }
        return report
    }

    /// The installed provider catalog from the last identity reconcile; the
    /// evidence for binding a legacy title when it is used (Remediation 4.3).
    @ObservationIgnored var installedProviders: [LibraryIdentityMigration.Provider] = []

    /// A verified physical store copy precedes the one atomic rekey commit.
    /// Unresolved legacy rows are retained and can be retried with a new catalog.
    @discardableResult
    func migrateProviderIdentities(providers: [LibraryIdentityMigration.Provider]) throws -> LibraryIdentityMigration.Report {
        installedProviders = providers
        do {
            let report = try performIdentityMigration(providers: providers)
            identityMigrationFailure = nil
            try markUnresolvedLegacy(Set(report.unresolved.keys))
            return report
        } catch {
            identityMigrationFailure = error.localizedDescription
            throw error
        }
    }

    /// Records which legacy rows the last pass could not resolve, so the state
    /// is visible in backups and diagnostics; a later pass that finds a single
    /// candidate still resolves them (Remediation 4.3).
    private func markUnresolvedLegacy(_ ids: Set<String>) throws {
        guard !ids.isEmpty else { return }
        try withMutation(shared: false) { context in
            var changed = false
            for row in try context.fetch(FetchDescriptor<StoredMediaItem>(predicate: #Predicate { $0.identityResolution == "legacy" }))
            where ids.contains(row.id) {
                row.identityResolution = "legacy_unresolved"
                changed = true
            }
            if changed { try save(context: context, notify: false) }
        }
    }

    /// Explicit consent resolves only this row: one whose installation was
    /// never recorded, or whose recorded installation is no longer in the
    /// catalog (removed, or reinstalled under a new identity). The catalog
    /// must contain the selected installation; names are never used as
    /// authority.
    @discardableResult
    func reassignProvider(itemID: String, providerID: String,
                          providers: [LibraryIdentityMigration.Provider]) throws -> LibraryIdentityMigration.Report {
        try reassignProvider(itemIDs: [itemID], providerID: providerID, providers: providers)
    }

    /// The same explicit choice for several rows at once (see
    /// `reassignableSiblings`). Every row must qualify on its own; one that
    /// does not fails the whole request and nothing is changed.
    @discardableResult
    func reassignProvider(itemIDs: [String], providerID: String,
                          providers: [LibraryIdentityMigration.Provider]) throws -> LibraryIdentityMigration.Report {
        guard let context else { throw ImportError.storeUnavailable }
        try persistenceFault?(.queryRead)
        let unavailable = ImportError.identityConflict("This title or selected provider is no longer available for reassignment.")
        guard !itemIDs.isEmpty, Set(itemIDs).count == itemIDs.count,
              let selected = providers.first(where: { $0.id == providerID && !$0.id.isEmpty }) else { throw unavailable }
        for itemID in itemIDs {
            guard let row = try mutationItem(id: itemID, in: context),
                  Self.isReassignable(row, providers: providers) else { throw unavailable }
        }
        do {
            let report = try performIdentityMigration(providers: providers,
                assignments: Dictionary(uniqueKeysWithValues: itemIDs.map { ($0, selected) }))
            identityMigrationFailure = nil
            return report
        } catch {
            identityMigrationFailure = error.localizedDescription
            throw error
        }
    }

    private static func isReassignable(_ row: StoredMediaItem, providers: [LibraryIdentityMigration.Provider]) -> Bool {
        row.mediaType != "Download"
            && (row.providerID?.isEmpty != false || !providers.contains(where: { $0.id == row.providerID }))
    }

    /// What an explicit choice for one title may also cover: the other
    /// reassignable titles saved under the same provider name whose address
    /// is on the same host. Two installations can share a name and serve
    /// different hosts, so the host is part of the group. Titles that would
    /// collide with an existing identity under `providerID` are left out.
    struct ReassignmentGroup: Sendable, Equatable {
        var providerName: String
        var host: String?
        var url: String
        var siblings: [String]
    }

    func reassignmentGroup(itemID: String, providers: [LibraryIdentityMigration.Provider]) throws -> ReassignmentGroup {
        guard let context else { throw ImportError.storeUnavailable }
        try persistenceFault?(.queryRead)
        guard let row = try mutationItem(id: itemID, in: context) else {
            throw ImportError.identityConflict("This title is no longer available for reassignment.")
        }
        let host = URLComponents(string: row.providerURL)?.host?.lowercased()
        let siblings = try context.fetch(FetchDescriptor<StoredMediaItem>()).filter {
            $0.id != row.id && $0.providerName == row.providerName && Self.isReassignable($0, providers: providers)
                && URLComponents(string: $0.providerURL)?.host?.lowercased() == host
        }.map(\.id).sorted()
        return ReassignmentGroup(providerName: row.providerName, host: host, url: row.providerURL, siblings: siblings)
    }

    /// `itemID` first, then the siblings whose new identity under
    /// `providerID` is free. A sibling already saved under that identity
    /// stays as it is rather than failing the others.
    func reassignableBatch(itemID: String, siblings: [String], providerID: String) throws -> [String] {
        guard let context else { throw ImportError.storeUnavailable }
        try persistenceFault?(.queryRead)
        let rows = try context.fetch(FetchDescriptor<StoredMediaItem>())
        let urls = Dictionary(rows.map { ($0.id, $0.providerURL) }, uniquingKeysWith: { first, _ in first })
        var taken = Set(rows.map(\.id))
        var batch: [String] = []
        for id in [itemID] + siblings where !batch.contains(id) {
            guard let url = urls[id] else { continue }
            let target = LibraryIdentity.remote(providerID: providerID, url: url)
            let free = taken.insert(target).inserted
            if id == itemID || target == id || free { batch.append(id) }
        }
        return batch
    }

    private func performIdentityMigration(providers: [LibraryIdentityMigration.Provider], assignments: [String: LibraryIdentityMigration.Provider] = [:]) throws -> LibraryIdentityMigration.Report {
        guard !isImporting else { throw ImportError.restoreInProgress }
        try flushPendingProgress()
        guard let owner = profileContainer ?? container, let facade = context else { throw ImportError.storeUnavailable }
        guard !facade.hasChanges, sharedContext?.hasChanges != true else { throw ImportError.pendingChanges }
        let transaction = ModelContext(owner)
        transaction.autosaveEnabled = false
        defer { if transaction.hasChanges { transaction.rollback() } }
        var report = try identityPlan(in: transaction, providers: providers, assignments: assignments)
        guard report.canApply else { throw ImportError.identityConflict(report.conflicts.joined(separator: " ")) }
        guard !report.changes.isEmpty || !report.localChanges.isEmpty else { return report }
        if !inMemory {
            try persistenceFault?(.identitySnapshot)
            guard let configuration = owner.configurations.first else { throw ImportError.storeUnavailable }
            report.recoverySnapshot = try SQLiteRecoverySnapshot.create(source: configuration.url,
                directory: configuration.url.deletingLastPathComponent().appendingPathComponent("IdentityRecovery", isDirectory: true),
                reason: "provider-identity-v2")
        }
        let mapping = Dictionary(uniqueKeysWithValues: report.changes.map { ($0.oldID, $0.newID) } + report.localChanges.map { ($0.oldID, $0.newID) })
        let rows = try transaction.fetch(FetchDescriptor<StoredMediaItem>())
        let changes = Dictionary(uniqueKeysWithValues: report.changes.map { ($0.oldID, $0) })
        let localChanges = Dictionary(uniqueKeysWithValues: report.localChanges.map { ($0.oldID, $0) })
        for row in rows {
            if let change = localChanges[row.id] {
                row.legacyItemID = row.legacyItemID ?? row.id
                row.id = change.newID
                row.providerID = nil
                row.identityVersion = LibraryIdentity.version
                row.identityResolution = "local_download"
                continue
            }
            guard let change = changes[row.id] else { continue }
            row.legacyItemID = row.legacyItemID ?? row.id
            row.id = change.newID
            row.providerID = change.providerID
            if let selected = assignments[change.oldID] { row.providerName = selected.name }
            row.identityVersion = LibraryIdentity.version
            row.identityResolution = "resolved"
        }
        for row in try transaction.fetch(FetchDescriptor<EpisodeProgress>()) {
            guard let itemID = mapping[row.itemID] else { continue }
            row.itemID = itemID
            row.id = EpisodeProgress.key(itemID: itemID, episodeData: row.episodeData)
        }
        for row in try transaction.fetch(FetchDescriptor<TitlePlaybackPrefs>()) {
            if let itemID = mapping[row.itemID] { row.itemID = itemID }
        }
        let renamed = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        for entry in try transaction.fetch(FetchDescriptor<LibraryPageEntry>()) {
            guard let itemID = mapping[entry.itemID] else { continue }
            entry.itemID = itemID
            entry.id = LibraryPageEntry.key(pageID: entry.pageID, itemID: itemID, episodeData: entry.episodeData)
            if let row = renamed[itemID] { entry.providerID = row.providerID; entry.providerName = row.providerName }
        }
        let migrationName = "provider-identity-v2"
        let marker = try transaction.fetch(FetchDescriptor<LibraryMigrationRecord>(predicate: #Predicate { $0.name == migrationName })).first
            ?? LibraryMigrationRecord(name: migrationName)
        if marker.modelContext == nil { transaction.insert(marker) }
        var aliases = marker.keyMappingData.isEmpty ? [:] : try JSONDecoder().decode([String: String].self, from: marker.keyMappingData)
        for (old, current) in aliases { if let replacement = mapping[current] { aliases[old] = replacement } }
        aliases.merge(mapping) { _, latest in latest }
        marker.keyMappingData = try JSONEncoder().encode(aliases)
        marker.completedAt = Date()
        marker.recoverySnapshotPath = report.recoverySnapshot?.path
        if let configuration = owner.configurations.first,
           let schemaRecovery = schemaRecoverySnapshots[configuration.url.path] {
            marker.schemaRecoverySnapshotPath = schemaRecovery.path
        }
        marker.unresolvedCount = report.unresolved.count
        try persistenceFault?(.identityCommit)
        try transaction.save()
        libraryContext = ModelContext(owner)
        libraryContext?.autosaveEnabled = false
        version += 1
        return report
    }

    static func itemID(for details: DetailsDto) -> String {
        details.id
    }

    /// Lookup without durable rekey or display-name inference. Existing known
    /// stable IDs retain their old dependent keys until the migration gate.
    private func resolvedItemID(for details: DetailsDto, in context: ModelContext) throws -> String {
        let desired = Self.itemID(for: details)
        if try mutationItem(id: desired, in: context) != nil { return desired }
        if details.type == "Download" {
            let url = details.url
            let matches = try context.fetch(FetchDescriptor<StoredMediaItem>(predicate: #Predicate {
                $0.mediaType == "Download" && $0.providerURL == url
            }))
            guard matches.count <= 1 else { throw ImportError.identityConflict("Multiple local titles have this file path.") }
            if let existing = matches.first {
                if let explicit = details.localDownloadID {
                    if let known = existing.downloadRecordID { return known == explicit ? existing.id : desired }
                    let candidates = Set(try downloadRecords().filter { $0.destinationPath == url }.map(\.id))
                    guard candidates == [explicit] else { return desired }
                }
                return existing.id
            }
            return desired
        }
        guard let providerID = details.providerId, !providerID.isEmpty else { return desired }
        let url = details.url
        let matches = try context.fetch(FetchDescriptor<StoredMediaItem>(predicate: #Predicate {
            $0.providerID == providerID && $0.providerURL == url
        }))
        guard matches.count <= 1 else { throw ImportError.identityConflict("Multiple stored titles have the same provider identity.") }
        if let existing = matches.first { return existing.id }
        // A name alone never assigns a legacy owner: two installations can
        // share a name and serve the same address. The legacy row for this
        // exact address is bound on use only with the evidence the identity
        // migration accepts: exactly one installed provider has its name, and
        // it is the one in use (Remediation 4.3). Otherwise a separate record
        // is created; a title with a known year is folded into one by the
        // strong-match merge (ADR-0020), and an explicit choice binds the row.
        let name = details.provider
        let candidates = Set(installedProviders.filter { $0.name == name && !$0.id.isEmpty }.map(\.id))
        guard candidates == [providerID] else { return desired }
        let legacy = try context.fetch(FetchDescriptor<StoredMediaItem>(predicate: #Predicate {
            $0.providerURL == url && $0.providerName == name && $0.mediaType != "Download"
        })).filter { $0.providerID?.isEmpty != false }
        guard legacy.count == 1, let twin = legacy.first else { return desired }
        twin.providerID = providerID
        twin.identityResolution = "resolved_by_use"
        DaemonLog.client("library.legacy_title_bound")
        return twin.id
    }

    func persistedItemID(for details: DetailsDto) throws -> String {
        guard let context else { throw ImportError.storeUnavailable }
        try persistenceFault?(.queryRead)
        return try resolvedItemID(for: details, in: context)
    }

    func playbackPrefs(details: DetailsDto) throws -> TitlePlaybackSnapshot? {
        try playbackPrefs(itemID: persistedItemID(for: details))
    }

    func updatePlaybackPrefs(details: DetailsDto, _ mutate: (inout TitlePlaybackSnapshot) -> Void) throws {
        try updatePlaybackPrefs(itemID: persistedItemID(for: details), mutate)
    }

    func clearWatchHistory(details: DetailsDto) throws {
        try clearWatchHistory(itemID: persistedItemID(for: details))
    }

    private func ensureItem(for details: DetailsDto, in context: ModelContext) throws -> StoredMediaItem {
        let id = try resolvedItemID(for: details, in: context)
        let descriptor = FetchDescriptor<StoredMediaItem>(predicate: #Predicate { $0.id == id })
        if let existing = (try context.fetch(descriptor)).first {
            existing.providerID = existing.providerID ?? details.providerId
            absorbMetadata(existing, from: details)
            return existing
        }
        let item = newItem(id: id, from: details)
        context.insert(item)
        return item
    }

    static let historyMigrationName = "history-backfill-v2"
    private static let seriesMediaTypes: Set<String> = ["tvseries", "anime", "cartoon", "asiandrama", "ova"]

    /// One-time history migration per profile store. Its marker commits with
    /// its rows, so history the user later deletes is never reconstructed.
    /// Stores created before per-episode history get one row per title's last
    /// episode (only while no history exists, as before); existing movie
    /// resume positions get their movie row.
    private func backfillEpisodeProgressIfNeeded() throws {
        try withMutation(shared: false) { context in
            let name = Self.historyMigrationName
            guard try context.fetchCount(FetchDescriptor<LibraryMigrationRecord>(predicate: #Predicate { $0.name == name })) == 0 else { return }
            let hadHistory = try context.fetchCount(FetchDescriptor<EpisodeProgress>()) > 0
            var created = 0
            for item in try context.fetch(FetchDescriptor<StoredMediaItem>(predicate: #Predicate { $0.lastEpisodeData != nil || $0.progressSeconds > 0 })) {
                let row: EpisodeProgress
                if let data = item.lastEpisodeData, !data.isEmpty {
                    guard !hadHistory else { continue }
                    row = EpisodeProgress(itemID: item.id, episodeData: data, season: item.lastSeason, episode: item.lastEpisode)
                } else if item.progressSeconds > 0, !Self.seriesMediaTypes.contains(item.mediaType.lowercased()) {
                    row = EpisodeProgress(movieItemID: item.id)
                } else { continue }
                row.positionSeconds = item.progressSeconds
                row.durationSeconds = item.totalDurationSeconds
                row.watched = WatchProgressPolicy.isWatched(position: item.progressSeconds, duration: item.totalDurationSeconds)
                row.updatedAt = item.lastUpdated
                context.insert(row)
                created += 1
            }
            context.insert(LibraryMigrationRecord(name: name))
            try save(context: context, notify: false)
            if created > 0 { DaemonLog.client("store.history_backfill", fields: ["count": String(created)]) }
        }
    }

    // MARK: - Per-title playback memory (Phase 4.3)

    func playbackPrefs(itemID: String) throws -> TitlePlaybackSnapshot? {
        guard let context else { throw ImportError.storeUnavailable }
        try persistenceFault?(.queryRead)
        let descriptor = FetchDescriptor<TitlePlaybackPrefs>(predicate: #Predicate { $0.itemID == itemID })
        return (try context.fetch(descriptor)).first?.snapshot
    }

    /// Read-modify-write of a title's playback memory. Silent: it changes
    /// nothing any library view displays.
    func updatePlaybackPrefs(itemID: String, _ mutate: (inout TitlePlaybackSnapshot) -> Void) throws {
        try withMutation(shared: false) { context in
            let descriptor = FetchDescriptor<TitlePlaybackPrefs>(predicate: #Predicate { $0.itemID == itemID })
            let row: TitlePlaybackPrefs
            if let existing = (try context.fetch(descriptor)).first {
                row = existing
            } else {
                row = TitlePlaybackPrefs(itemID: itemID)
                row.updatedAt = .distantPast
                context.insert(row)
            }
            var snapshot = row.snapshot
            mutate(&snapshot)
            row.audioLanguage = snapshot.audioLanguage
            row.subtitleLanguage = snapshot.subtitleLanguage
            row.subtitlesOff = snapshot.subtitlesOff
            row.subtitleDelay = snapshot.subtitleDelay
            row.speed = snapshot.speed
            row.introStart = snapshot.introStart
            row.introEnd = snapshot.introEnd
            row.source = snapshot.source
            row.sourceQuality = snapshot.sourceQuality
            row.updatedAt = min(.distantFuture, max(mutationClock(), row.updatedAt.addingTimeInterval(0.001)))
            try save(context: context, notify: false)
        }
    }

    // MARK: - New-episode tracking (Phase 6)

    /// Distinct episodes a provider lists (sub and dub of one episode count once).
    static func episodeCount(_ details: DetailsDto) -> Int {
        struct Key: Hashable { let season: Int?; let episode: Int?; let data: String? }
        let keys = details.episodes.map { episode in
            episode.episode == nil
                ? Key(season: nil, episode: nil, data: episode.data)
                : Key(season: episode.season, episode: episode.episode, data: nil)
        }
        return Set(keys).count
    }

    /// The user opened the title: record what the provider lists now and
    /// clear its "new" badge. Movies only pick up missing provider facts.
    func acknowledgeEpisodes(details: DetailsDto) throws {
        try withMutation(shared: false) { context in
            guard let item = try mutationItem(id: try resolvedItemID(for: details, in: context), in: context) else { return }
            var changed = absorbMetadata(item, from: details)
            guard details.isSeries || changed else { return }
            if details.isSeries {
                let count = Self.episodeCount(details)
                changed = changed || item.knownEpisodeCount != count || item.newEpisodeCount != 0
                item.knownEpisodeCount = count
                item.newEpisodeCount = 0
                item.lastEpisodeCheck = mutationClock()
            }
            try save(context: context, notify: changed)
        }
    }

    /// Background check result. Returns how many episodes are new since the
    /// previous check (0 for a first baseline).
    @discardableResult
    func recordEpisodeCheck(details: DetailsDto, itemID: String? = nil) throws -> Int {
        return try withMutation(shared: false) { context in
            guard let item = try mutationItem(id: try itemID ?? resolvedItemID(for: details, in: context), in: context) else { return 0 }
            let count = Self.episodeCount(details)
            let previous = item.knownEpisodeCount
            item.lastEpisodeCheck = mutationClock()
            let learned = absorbMetadata(item, from: details)
            guard previous > 0 else {
                item.knownEpisodeCount = count
                try save(context: context, notify: learned)
                return 0
            }
            let added = max(0, count - previous)
            item.knownEpisodeCount = count
            if added > 0 || learned {
                item.newEpisodeCount += added
                try save(context: context)
            } else {
                try save(context: context, notify: false)
            }
            return added
        }
    }

    /// Records that an episode check was attempted for `itemID`, updating `lastEpisodeCheck`
    /// so provider failures or dead titles don't starve the background check queue.
    func recordEpisodeCheckAttempt(itemID: String) throws {
        try withMutation(shared: false) { context in
            guard let item = try mutationItem(id: itemID, in: context) else { return }
            item.lastEpisodeCheck = mutationClock()
            try save(context: context, notify: false)
        }
    }

    /// Series the user is watching, least recently checked first.
    func titlesDueForEpisodeCheck(olderThan interval: TimeInterval, limit: Int) throws -> [StoredMediaItem] {
        let cutoff = Date().addingTimeInterval(-interval)
        return try items(withWatchType: .watching)
            .filter { ["tvseries", "anime", "cartoon", "asiandrama", "ova", "documentary"].contains($0.mediaType.lowercased()) }
            .filter { ($0.lastEpisodeCheck ?? .distantPast) < cutoff }
            .sorted { ($0.lastEpisodeCheck ?? .distantPast) < ($1.lastEpisodeCheck ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Notes & rating (Phase 6)

    func setUserNote(details: DetailsDto, note: String?) throws {
        try withMutation(shared: false) { context in
            let item = try titleEntry(ensureItem(for: details, in: context), in: context)
            let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
            item.userNote = (trimmed?.isEmpty ?? true) ? nil : trimmed
            stamp(item, \.noteUpdatedAt)
            try save(context: context)
        }
    }

    func setUserRating(details: DetailsDto, rating: Int) throws {
        try withMutation(shared: false) { context in
            let item = try titleEntry(ensureItem(for: details, in: context), in: context)
            item.userRating = min(5, max(0, rating))
            stamp(item, \.ratingUpdatedAt)
            try save(context: context)
        }
    }

    // MARK: - Bulk library edits (Phase 6)

    func setWatchType(itemIDs: Set<String>, watchType: WatchType?) throws {
        try withMutation(shared: false) { context in
            guard !itemIDs.isEmpty else { return }
            for id in itemIDs {
                let descriptor = FetchDescriptor<StoredMediaItem>(predicate: #Predicate { $0.id == id })
                guard let item = (try context.fetch(descriptor)).first else { continue }
                item.watchType = watchType
                stamp(item, \.watchTypeUpdatedAt)
            }
            try save(context: context)
        }
    }

    /// Saves a hand-arranged order: `itemIDs` front to back, for Favorites
    /// or for the titles' watch-status collection. An arrangement is not
    /// activity, so "Recent Activity" does not move.
    func setCustomOrder(itemIDs: [String], favorites: Bool) throws {
        try withMutation(shared: false) { context in
            let positions = Dictionary(itemIDs.enumerated().map { ($1, Double($0)) }, uniquingKeysWith: { first, _ in first })
            var changed = false
            for item in try context.fetch(FetchDescriptor<StoredMediaItem>()) {
                guard let position = positions[item.id] else { continue }
                let keyPath: ReferenceWritableKeyPath<StoredMediaItem, Double?> = favorites ? \.favoriteSortPosition : \.sortPosition
                if item[keyPath: keyPath] != position {
                    item[keyPath: keyPath] = position
                    changed = true
                }
            }
            if changed { try save(context: context) }
        }
    }

    // MARK: - Backup & restore (Phase 7)

    struct LibrarySnapshot: Sendable {
        var items: [BackupDocument.Item]
        var episodes: [BackupDocument.Episode]
        var playback: [BackupDocument.Playback]
        var formatVersion: Int = BackupDocument.currentVersion
        /// nil: the source predates pages, so a restore leaves local pages alone.
        var pages: [BackupDocument.Page]? = nil
    }

    /// Everything the library holds, as plain values. Download placeholder
    /// entries ("Download" type, local paths) are machine-specific and skipped.
    func exportSnapshot() throws -> LibrarySnapshot {
        guard let context else { throw ImportError.storeUnavailable }
        // An earlier failed save must not be exported as committed state.
        guard !context.hasChanges, pendingProgress.isEmpty else { throw ImportError.pendingChanges }
        try persistenceFault?(.snapshotRead)
        return try Self.snapshot(in: context)
    }

    /// Snapshot of a profile that is not necessarily selected, read through
    /// its own context: the visible profile is not switched.
    func exportSnapshot(profileStoreName storeName: String) throws -> LibrarySnapshot {
        if storeName == activeProfileStoreName { return try exportSnapshot() }
        try persistenceFault?(.snapshotRead)
        return try withOwnedProfileContext(storeName: storeName) { try Self.snapshot(in: $0) }
    }

    private static func snapshot(in context: ModelContext) throws -> LibrarySnapshot {
        let stored = try context.fetch(FetchDescriptor<StoredMediaItem>())
        // History and settings of local downloads stay on this Mac with them.
        let local = Set(stored.filter { $0.mediaType == "Download" }.map(\.id))
        let items = stored
            .filter { $0.mediaType != "Download" }
            .map { item in
                BackupDocument.Item(
                    id: item.id, title: item.title, posterURL: item.posterURL, bannerURL: item.bannerURL,
                    providerName: item.providerName, providerURL: item.providerURL, mediaType: item.mediaType,
                    watchTypeRaw: item.watchTypeRaw, isFavorite: item.isFavorite, lastEpisodeData: item.lastEpisodeData,
                    lastSeason: item.lastSeason, lastEpisode: item.lastEpisode, progressSeconds: item.progressSeconds,
                    totalDurationSeconds: item.totalDurationSeconds, lastUpdated: item.lastUpdated, createdAt: item.createdAt,
                    knownEpisodeCount: item.knownEpisodeCount, userNote: item.userNote, userRating: item.userRating,
                    providerID: item.providerID, identityVersion: item.identityVersion,
                    legacyItemID: item.legacyItemID, identityResolution: item.identityResolution,
                    noteUpdatedAt: item.noteUpdatedAt, ratingUpdatedAt: item.ratingUpdatedAt,
                    favoriteUpdatedAt: item.favoriteUpdatedAt, watchTypeUpdatedAt: item.watchTypeUpdatedAt,
                    progressUpdatedAt: item.progressUpdatedAt, lastAudio: item.lastAudio,
                    releaseYear: item.releaseYear,
                    sortPosition: item.sortPosition, favoriteSortPosition: item.favoriteSortPosition,
                    mergedIntoID: item.mergedIntoID,
                )
            }
        let episodes = (try context.fetch(FetchDescriptor<EpisodeProgress>())).filter { !local.contains($0.itemID) }.map { row in
            BackupDocument.Episode(
                itemID: row.itemID, episodeData: row.episodeData, season: row.season, episode: row.episode,
                positionSeconds: row.positionSeconds, durationSeconds: row.durationSeconds, watched: row.watched,
                updatedAt: row.updatedAt, kind: row.kind, audio: row.audio,
            )
        }
        let playback = (try context.fetch(FetchDescriptor<TitlePlaybackPrefs>())).filter { !local.contains($0.itemID) }.map { row in
            BackupDocument.Playback(
                itemID: row.itemID, audioLanguage: row.audioLanguage, subtitleLanguage: row.subtitleLanguage,
                subtitlesOff: row.subtitlesOff, subtitleDelay: row.subtitleDelay, speed: row.speed,
                introStart: row.introStart, introEnd: row.introEnd, updatedAt: row.updatedAt == .distantPast ? nil : row.updatedAt,
                source: row.source, sourceQuality: row.sourceQuality,
            )
        }
        return LibrarySnapshot(items: items, episodes: episodes, playback: playback, pages: try pageSnapshot(in: context))
    }

    /// Pages with their portable entries; downloaded files stay on this Mac.
    private static func pageSnapshot(in context: ModelContext) throws -> [BackupDocument.Page] {
        let entries = Dictionary(grouping: try context.fetch(FetchDescriptor<LibraryPageEntry>(sortBy: [SortDescriptor(\.addedAt), SortDescriptor(\.id)]))
            .filter { $0.mediaType != "Download" }, by: \.pageID)
        return try context.fetch(pageOrder).map { page in
            BackupDocument.Page(id: page.id, name: page.name, createdAt: page.createdAt, sortPosition: page.sortPosition,
                entries: (entries[page.id] ?? []).map { entry in
                    BackupDocument.PageEntry(
                        itemID: entry.itemID, title: entry.title, posterURL: entry.posterURL, bannerURL: entry.bannerURL,
                        providerName: entry.providerName, providerID: entry.providerID, providerURL: entry.providerURL,
                        mediaType: entry.mediaType, episodeData: entry.episodeData, season: entry.season, episode: entry.episode,
                        episodeName: entry.episodeName, episodeThumbnailURL: entry.episodeThumbnailURL, audio: entry.audio,
                        addedAt: entry.addedAt)
                })
        }
    }

    enum ImportMode: Sendable {
        /// Keep existing data; for conflicts the more recently changed side wins.
        case merge
        /// Replace library, history and playback memory with the backup.
        case replace
    }

    enum ImportError: LocalizedError {
        case storeUnavailable
        case pendingChanges
        case restoreInProgress
        case saveFailed(String)
        case identityConflict(String)

        var errorDescription: String? {
            switch self {
            case .storeUnavailable: return "The library database isn't available."
            case .pendingChanges: return "The library has changes that could not be saved. Retry saving before creating a backup."
            case .restoreInProgress: return "A restore is still being applied. Try again when it finishes."
            case .saveFailed(let detail): return "Nothing was changed — saving failed: \(detail)"
            case .identityConflict(let detail): return "The library has conflicting provider identities. \(detail)"
            }
        }
    }

    struct ImportReport: Sendable {
        var equalTimestampConflicts = 0
        var unversionedFieldsPreserved = 0
        /// History/settings entries whose title is in neither the backup nor the library.
        var unownedEntries = 0
        var warnings: [String] {
            var result: [String] = []
            if unownedEntries > 0 { result.append("Kept \(unownedEntries) history or playback entries whose title is missing. They stay hidden until that title is added again.") }
            if equalTimestampConflicts > 0 { result.append("Kept local values for \(equalTimestampConflicts) conflicting fields with equal edit times.") }
            if unversionedFieldsPreserved > 0 { result.append("Kept local values for \(unversionedFieldsPreserved) fields whose edit order could not be established. Replace can apply the complete backup instead.") }
            return result
        }
    }

    nonisolated private static func shouldMerge<T: Equatable>(_ incoming: T, over local: T, updatedAt: Date?, localUpdatedAt: Date?,
                                                              report: inout ImportReport) -> Bool {
        guard let updatedAt, let localUpdatedAt else {
            // Legacy title recency cannot establish a note/rating/progress or
            // playback edit time. Unknown is not an invented oldest timestamp.
            if incoming != local { report.unversionedFieldsPreserved += 1 }
            return false
        }
        if updatedAt > localUpdatedAt { return true }
        if updatedAt == localUpdatedAt, incoming != local { report.equalTimestampConflicts += 1 }
        return false
    }

    /// Applies a snapshot in one transaction: on any failure nothing changes.
    @discardableResult
    func importSnapshot(_ snapshot: LibrarySnapshot, mode: ImportMode) throws -> ImportReport {
        let container = try prepareImport(snapshot)
        let report = try Self.applySnapshot(snapshot, mode: mode, container: container, fault: persistenceFault)
        finishImport(container)
        return report
    }

    /// The same transaction as `importSnapshot`, run off the main thread so a
    /// large restore does not freeze the app (10,000 titles with 50,000
    /// history rows take about twelve seconds). Until it returns, this
    /// profile's library refuses other writes and profile changes; playback
    /// positions recorded meanwhile are kept and saved afterwards.
    @discardableResult
    func importSnapshotInBackground(_ snapshot: LibrarySnapshot, mode: ImportMode) async throws -> ImportReport {
        let container = try prepareImport(snapshot)
        isImporting = true
        // The fault seam is nil outside tests, which set it before an import
        // starts and never change it while one runs.
        struct FaultSeam: @unchecked Sendable {
            let call: ((PersistenceBoundary) throws -> Void)?
        }
        let fault = FaultSeam(call: persistenceFault)
        let outcome = await Task.detached(priority: .userInitiated) {
            Result { try Self.applySnapshot(snapshot, mode: mode, container: container, fault: fault.call) }
        }.value
        isImporting = false
        if case .success = outcome { finishImport(container) }
        // Positions played meanwhile are saved whether or not the restore
        // succeeded; a failure stays retained and visible like any other.
        do { try flushOwnedProgress(notifyObservers: true) }
        catch { DaemonLog.client("store.progress_after_restore_failed", fields: ["error": error.localizedDescription]) }
        return try outcome.get()
    }

    private func prepareImport(_ snapshot: LibrarySnapshot) throws -> ModelContainer {
        guard !isImporting else { throw ImportError.restoreInProgress }
        guard libraryContext != nil, let container = profileContainer ?? container else { throw ImportError.storeUnavailable }
        try BackupDocument(version: snapshot.formatVersion, createdAt: Date(), appVersion: "restore", items: snapshot.items,
            episodes: snapshot.episodes, playback: snapshot.playback, preferences: [:],
            repositories: [], disabledProviders: [], pages: snapshot.pages).validate()
        try flushPendingProgress()
        return container
    }

    /// The committed restore becomes visible through a fresh context.
    /// Positions retained during a background restore move to it.
    private func finishImport(_ container: ModelContainer) {
        let fresh = ModelContext(container)
        fresh.autosaveEnabled = false
        libraryContext = fresh
        let retained = pendingProgress.values.sorted { $0.order < $1.order }
        pendingProgress.removeAll()
        for pending in retained {
            let key = ProgressKey(owner: ObjectIdentifier(fresh), item: Self.itemID(for: pending.details), episode: pending.episode?.data)
            pendingProgress[key] = PendingProgress(context: fresh, details: pending.details, episode: pending.episode,
                position: pending.position, duration: pending.duration, recordedAt: pending.recordedAt, order: pending.order, notify: true)
        }
        version += 1
        // A restored backup or an Android import follows the same rule as the library (ADR-0020).
        mergeStrongMatchesLogged()
    }

    /// Runs on whichever thread calls it, with a context of its own: every
    /// read and change belongs to this restore alone, so rollback can never
    /// discard another context's progress, preferences or downloads.
    nonisolated private static func applySnapshot(_ snapshot: LibrarySnapshot, mode: ImportMode, container: ModelContainer,
                                                  fault: ((PersistenceBoundary) throws -> Void)?) throws -> ImportReport {
        var report = ImportReport()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        // All reads and mutations belong to this restore alone; rollback may
        // never discard another context's progress, preferences or downloads.
        defer { if context.hasChanges { context.rollback() } }
        try fault?(.restoreRead)
        if mode == .replace {
            // Per-object deletes (not batch deletes) so a failed save can
            // roll the whole restore back.
            for row in try context.fetch(FetchDescriptor<EpisodeProgress>()) { context.delete(row) }
            for row in try context.fetch(FetchDescriptor<TitlePlaybackPrefs>()) { context.delete(row) }
            for item in try context.fetch(FetchDescriptor<StoredMediaItem>()) where item.mediaType != "Download" {
                context.delete(item)
            }
            if snapshot.pages != nil {
                for row in try context.fetch(FetchDescriptor<LibraryPageEntry>()) { context.delete(row) }
                for row in try context.fetch(FetchDescriptor<LibraryPage>()) { context.delete(row) }
            }
        }

        var existingItems: [String: StoredMediaItem] = [:]
        var existingStableItems: [String: StoredMediaItem] = [:]
        if mode == .merge {
            for item in try context.fetch(FetchDescriptor<StoredMediaItem>()) {
                existingItems[item.id] = item
                if let providerID = item.providerID, !providerID.isEmpty, item.mediaType != "Download" {
                    let stable = LibraryIdentity.remote(providerID: providerID, url: item.providerURL)
                    guard existingStableItems[stable] == nil else {
                        throw ImportError.identityConflict("Multiple stored titles have the same provider identity.")
                    }
                    existingStableItems[stable] = item
                }
            }
        }
        var importedItemIDs: [String: String] = [:]
        var insertedFromBackup = Set<String>()
        for entry in snapshot.items where !entry.id.isEmpty {
            let stableMatch = entry.providerID.flatMap {
                existingStableItems[LibraryIdentity.remote(providerID: $0, url: entry.providerURL)]
            }
            // A backup's known installation cannot claim an unknown legacy
            // owner merely because their old display-name key is the same.
            var targetID = stableMatch?.id ?? entry.id
            if stableMatch == nil, let providerID = entry.providerID,
               let existing = existingItems[entry.id], existing.providerID == nil {
                targetID = LibraryIdentity.remote(providerID: providerID, url: entry.providerURL)
            }
            importedItemIDs[entry.id] = targetID
            if let item = existingItems[targetID] {
                guard entry.providerID != nil || item.providerID == nil else {
                    throw ImportError.identityConflict("This legacy backup does not identify the provider owning an existing title. Its data cannot be merged into that identified title.")
                }
                guard item.providerURL == entry.providerURL,
                      item.providerID == nil || entry.providerID == nil || item.providerID == entry.providerID else {
                    throw ImportError.identityConflict("The backup key belongs to a different title or provider.")
                }
                // A v1 import cannot erase a stable identity already known locally.
                item.providerID = item.providerID ?? entry.providerID
                let originalDate = item.lastUpdated
                let versioned = snapshot.formatVersion >= 2
                let noteDate = versioned ? entry.noteUpdatedAt : nil
                let ratingDate = versioned ? entry.ratingUpdatedAt : nil
                let favoriteDate = versioned ? entry.favoriteUpdatedAt : nil
                let watchDate = versioned ? entry.watchTypeUpdatedAt : nil
                if Self.shouldMerge(entry.userNote, over: item.userNote, updatedAt: noteDate, localUpdatedAt: item.noteUpdatedAt, report: &report) {
                    item.userNote = entry.userNote
                    item.noteUpdatedAt = noteDate
                }
                if Self.shouldMerge(entry.userRating ?? 0, over: item.userRating, updatedAt: ratingDate, localUpdatedAt: item.ratingUpdatedAt, report: &report) {
                    item.userRating = entry.userRating ?? 0
                    item.ratingUpdatedAt = ratingDate
                }
                if Self.shouldMerge(entry.isFavorite, over: item.isFavorite, updatedAt: favoriteDate, localUpdatedAt: item.favoriteUpdatedAt, report: &report) {
                    item.isFavorite = entry.isFavorite
                    item.favoriteUpdatedAt = favoriteDate
                }
                if Self.shouldMerge(entry.watchTypeRaw, over: item.watchTypeRaw, updatedAt: watchDate, localUpdatedAt: item.watchTypeUpdatedAt, report: &report) {
                    item.watchTypeRaw = entry.watchTypeRaw
                    item.watchTypeUpdatedAt = watchDate
                }
                let progressDate = versioned ? entry.progressUpdatedAt : nil
                let differs = item.progressSeconds != entry.progressSeconds || item.totalDurationSeconds != entry.totalDurationSeconds
                    || item.lastEpisodeData != entry.lastEpisodeData || item.lastSeason != entry.lastSeason || item.lastEpisode != entry.lastEpisode
                if let progressDate, let localDate = item.progressUpdatedAt {
                    if progressDate > localDate {
                        item.progressSeconds = entry.progressSeconds
                        item.totalDurationSeconds = entry.totalDurationSeconds
                        item.lastEpisodeData = entry.lastEpisodeData
                        item.lastSeason = entry.lastSeason
                        item.lastEpisode = entry.lastEpisode
                        item.lastAudio = entry.lastAudio
                        item.progressUpdatedAt = progressDate
                    } else if progressDate == localDate, differs { report.equalTimestampConflicts += 1 }
                } else if differs { report.unversionedFieldsPreserved += 1 }
                if targetID == entry.id {
                    item.identityVersion = entry.identityVersion ?? item.identityVersion
                    item.legacyItemID = entry.legacyItemID ?? item.legacyItemID
                    item.identityResolution = entry.identityResolution ?? item.identityResolution
                }
                item.lastUpdated = max(originalDate, [item.noteUpdatedAt, item.ratingUpdatedAt, item.favoriteUpdatedAt,
                    item.watchTypeUpdatedAt, item.progressUpdatedAt].compactMap { $0 }.max() ?? originalDate)
                item.createdAt = min(item.createdAt, entry.createdAt)
                item.posterURL = item.posterURL ?? entry.posterURL
                item.bannerURL = item.bannerURL ?? entry.bannerURL
                item.releaseYear = item.releaseYear ?? entry.releaseYear
                if item.watchTypeRaw == entry.watchTypeRaw { item.sortPosition = item.sortPosition ?? entry.sortPosition }
                item.favoriteSortPosition = item.favoriteSortPosition ?? entry.favoriteSortPosition
            } else {
                let item = StoredMediaItem(
                    id: targetID, title: entry.title, posterURL: entry.posterURL, bannerURL: entry.bannerURL,
                    providerName: entry.providerName, providerID: entry.providerID, providerURL: entry.providerURL, mediaType: entry.mediaType,
                    watchType: WatchType(rawValue: entry.watchTypeRaw), isFavorite: entry.isFavorite,
                )
                if targetID == entry.id {
                    item.identityVersion = entry.identityVersion ?? item.identityVersion
                    item.identityResolution = entry.identityResolution ?? item.identityResolution
                }
                item.legacyItemID = entry.legacyItemID ?? (targetID != entry.id ? entry.id : nil)
                item.lastEpisodeData = entry.lastEpisodeData
                item.lastSeason = entry.lastSeason
                item.lastEpisode = entry.lastEpisode
                item.lastAudio = entry.lastAudio
                item.progressSeconds = max(0, entry.progressSeconds)
                item.totalDurationSeconds = max(0, entry.totalDurationSeconds)
                item.lastUpdated = entry.lastUpdated
                item.createdAt = entry.createdAt
                item.releaseYear = entry.releaseYear
                item.sortPosition = entry.sortPosition
                item.favoriteSortPosition = entry.favoriteSortPosition
                // Resolved below, once every imported title has its local ID.
                item.mergedIntoID = entry.mergedIntoID
                item.knownEpisodeCount = max(0, entry.knownEpisodeCount ?? 0)
                item.userNote = entry.userNote
                item.userRating = min(5, max(0, entry.userRating ?? 0))
                if snapshot.formatVersion >= 2 {
                    item.noteUpdatedAt = entry.noteUpdatedAt
                    item.ratingUpdatedAt = entry.ratingUpdatedAt
                    item.favoriteUpdatedAt = entry.favoriteUpdatedAt
                    item.watchTypeUpdatedAt = entry.watchTypeUpdatedAt
                    item.progressUpdatedAt = entry.progressUpdatedAt
                }
                context.insert(item)
                existingItems[targetID] = item
                insertedFromBackup.insert(targetID)
            }
        }

        // A merged source points at its title's local ID; a dangling link
        // (the title is not in this library) leaves the source standalone.
        for id in insertedFromBackup {
            guard let item = existingItems[id], let link = item.mergedIntoID else { continue }
            let target = importedItemIDs[link] ?? link
            item.mergedIntoID = target != item.id && existingItems[target] != nil ? target : nil
        }

        // Dependent rows are kept even without a title: they may be legacy
        // data the user can recover, so they are reported instead of pruned.
        var owners = Set(existingItems.keys)
        if mode == .replace {
            for item in try context.fetch(FetchDescriptor<StoredMediaItem>()) where item.mediaType == "Download" { owners.insert(item.id) }
        }
        var existingRows: [String: EpisodeProgress] = [:]
        if mode == .merge {
            for row in try context.fetch(FetchDescriptor<EpisodeProgress>()) { existingRows[row.id] = row }
        }
        for entry in snapshot.episodes where !entry.episodeData.isEmpty && !entry.itemID.isEmpty {
            let itemID = importedItemIDs[entry.itemID] ?? entry.itemID
            if !owners.contains(itemID) { report.unownedEntries += 1 }
            let key = EpisodeProgress.key(itemID: itemID, episodeData: entry.episodeData)
            let row: EpisodeProgress
            if let existing = existingRows[key] {
                guard entry.updatedAt > existing.updatedAt else {
                    if entry.updatedAt == existing.updatedAt,
                       entry.positionSeconds != existing.positionSeconds || entry.durationSeconds != existing.durationSeconds || entry.watched != existing.watched {
                        report.equalTimestampConflicts += 1
                    }
                    continue
                }
                row = existing
            } else {
                row = EpisodeProgress(itemID: itemID, episodeData: entry.episodeData, season: entry.season, episode: entry.episode)
                context.insert(row)
                existingRows[key] = row
            }
            row.kind = entry.kind ?? EpisodeProgress.episodeKind
            row.audio = entry.audio ?? row.audio
            row.positionSeconds = max(0, entry.positionSeconds)
            row.durationSeconds = max(0, entry.durationSeconds)
            row.watched = entry.watched
            row.updatedAt = entry.updatedAt
        }

        var existingPrefs: [String: TitlePlaybackPrefs] = [:]
        if mode == .merge {
            for row in try context.fetch(FetchDescriptor<TitlePlaybackPrefs>()) { existingPrefs[row.itemID] = row }
        }
        for entry in snapshot.playback where !entry.itemID.isEmpty {
            let itemID = importedItemIDs[entry.itemID] ?? entry.itemID
            if !owners.contains(itemID) { report.unownedEntries += 1 }
            let incomingDate = snapshot.formatVersion >= 2 ? entry.updatedAt : nil
            if let existing = existingPrefs[itemID] {
                let incoming = TitlePlaybackSnapshot(audioLanguage: entry.audioLanguage, subtitleLanguage: entry.subtitleLanguage,
                    subtitlesOff: entry.subtitlesOff, subtitleDelay: entry.subtitleDelay, speed: entry.speed,
                    introStart: entry.introStart, introEnd: entry.introEnd,
                    source: entry.source, sourceQuality: entry.sourceQuality)
                guard Self.shouldMerge(incoming, over: existing.snapshot, updatedAt: incomingDate,
                    localUpdatedAt: existing.updatedAt == .distantPast ? nil : existing.updatedAt,
                    report: &report) else { continue }
            }
            let row = existingPrefs[itemID] ?? TitlePlaybackPrefs(itemID: itemID)
            if row.modelContext == nil { context.insert(row); existingPrefs[itemID] = row }
            row.audioLanguage = entry.audioLanguage
            row.subtitleLanguage = entry.subtitleLanguage
            row.subtitlesOff = entry.subtitlesOff
            row.subtitleDelay = entry.subtitleDelay
            row.speed = entry.speed
            row.introStart = entry.introStart
            row.introEnd = entry.introEnd
            row.source = entry.source.map(LinkRanker.sourceKey)
            row.sourceQuality = entry.sourceQuality
            row.updatedAt = incomingDate ?? .distantPast
        }

        try applyPages(snapshot.pages ?? [], itemIDs: importedItemIDs, replacing: mode == .replace, in: context)

        do {
            try fault?(.restoreCommit)
            try context.save()
        } catch {
            context.rollback()
            throw ImportError.saveFailed(error.localizedDescription)
        }
        return report
    }
}

// MARK: - Merged titles (ADR-0020)

extension LibraryStore {
    /// The entry a source's title-level state (status, favourite, rating,
    /// note, custom order) lives on: its primary when the source was merged.
    fileprivate func titleEntry(_ item: StoredMediaItem, in context: ModelContext) throws -> StoredMediaItem {
        guard let primaryID = item.mergedIntoID, primaryID != item.id else { return item }
        return try mutationItem(id: primaryID, in: context) ?? item
    }

    /// Every source of the title [itemID] belongs to, its primary first.
    func titleSources(itemID: String) throws -> [StoredMediaItem] {
        let context = context
        guard let context else { throw ImportError.storeUnavailable }
        try persistenceFault?(.queryRead)
        guard let item = try mutationItem(id: itemID, in: context) else { return [] }
        let primary = try titleEntry(item, in: context)
        let primaryID = primary.id
        let merged = try context.fetch(FetchDescriptor<StoredMediaItem>(
            predicate: #Predicate { $0.mergedIntoID == primaryID },
            sortBy: [SortDescriptor(\.lastUpdated, order: .reverse)],
        ))
        return [primary] + merged.filter { $0.id != primaryID }
    }

    func titleSources(details: DetailsDto) throws -> [StoredMediaItem] {
        try titleSources(itemID: persistedItemID(for: details))
    }

    /// Merges the selected titles into one (Library ▸ Select ▸ Merge). The
    /// most recently played or changed source becomes the primary.
    func mergeTitles(itemIDs: [String]) throws {
        try withMutation(shared: false) { context in
            var titles: [StoredMediaItem] = []
            for id in Set(itemIDs) {
                guard let item = try mutationItem(id: id, in: context), item.mediaType != "Download" else { continue }
                let title = try titleEntry(item, in: context)
                if !titles.contains(where: { $0.id == title.id }) { titles.append(title) }
            }
            guard titles.count > 1 else { return }
            try merge(titles, in: context)
            try save(context: context)
        }
    }

    /// Takes one source out of its title again. It keeps a copy of the
    /// title's status so it reappears in the same collection.
    func separateSource(itemID: String) throws {
        try withMutation(shared: false) { context in
            guard let item = try mutationItem(id: itemID, in: context), let primaryID = item.mergedIntoID,
                  let primary = try mutationItem(id: primaryID, in: context) else { return }
            item.mergedIntoID = nil
            item.watchTypeRaw = primary.watchTypeRaw
            stamp(item, \.watchTypeUpdatedAt)
            try save(context: context)
        }
    }

    /// Merges every strong match already in the library (each launch and
    /// after a restore): same normalised title, same type, same known year.
    /// Returns the number of sources merged.
    @discardableResult
    func mergeStrongMatches() throws -> Int {
        var merged = 0
        try withMutation(shared: false) { context in
            let candidates = try context.fetch(FetchDescriptor<StoredMediaItem>(
                predicate: #Predicate { $0.mergedIntoID == nil && $0.releaseYear != nil && ($0.watchTypeRaw != -1 || $0.isFavorite) },
            ))
            let groups = Dictionary(grouping: candidates.compactMap { item in Self.strongMatchKey(item).map { ($0, item) } }, by: \.0)
            for (_, members) in groups where members.count > 1 {
                try merge(members.map(\.1), in: context)
                merged += members.count - 1
            }
            if merged > 0 { try save(context: context) }
        }
        if merged > 0 { DaemonLog.client("library.titles_merged", fields: ["sources": String(merged)]) }
        return merged
    }

    /// Merging is housekeeping: a failure is logged and never blocks opening or restoring a library.
    fileprivate func mergeStrongMatchesLogged() {
        do { try mergeStrongMatches() }
        catch { DaemonLog.client("library.merge_failed", fields: ["error": error.localizedDescription]) }
    }

    /// Merges [item] with the library titles it strongly matches, if any.
    fileprivate func autoMerge(_ item: StoredMediaItem, in context: ModelContext) throws {
        guard item.mergedIntoID == nil, item.watchTypeRaw != -1 || item.isFavorite,
              let key = Self.strongMatchKey(item), let year = item.releaseYear else { return }
        let itemID = item.id
        let matches = try context.fetch(FetchDescriptor<StoredMediaItem>(
            predicate: #Predicate { $0.id != itemID && $0.mergedIntoID == nil && $0.releaseYear == year && ($0.watchTypeRaw != -1 || $0.isFavorite) },
        )).filter { Self.strongMatchKey($0) == key }
        guard !matches.isEmpty else { return }
        try merge([item] + matches, in: context)
    }

    /// Folds [titles] (each a primary) into the one most recently used.
    private func merge(_ titles: [StoredMediaItem], in context: ModelContext) throws {
        func activity(_ item: StoredMediaItem) -> Date { max(item.lastUpdated, item.progressUpdatedAt ?? .distantPast) }
        guard let primary = titles.max(by: { activity($0) < activity($1) }) else { return }
        for source in titles where source.id != primary.id {
            Self.absorbTitleState(of: source, into: primary)
            for field: ReferenceWritableKeyPath<StoredMediaItem, Date?> in [\.watchTypeUpdatedAt, \.favoriteUpdatedAt, \.ratingUpdatedAt, \.noteUpdatedAt] {
                stamp(primary, field)
                stamp(source, field)
            }
            try repoint(from: source.id, to: primary.id, in: context)
            source.mergedIntoID = primary.id
        }
    }

    /// Recording progress on a merged source makes it the title's primary.
    fileprivate func promote(_ source: StoredMediaItem, in context: ModelContext) throws {
        guard let oldID = source.mergedIntoID else { return }
        source.mergedIntoID = nil
        guard let old = try mutationItem(id: oldID, in: context), old.id != source.id else { return }
        source.watchTypeRaw = old.watchTypeRaw
        source.watchTypeUpdatedAt = old.watchTypeUpdatedAt
        source.isFavorite = old.isFavorite
        source.favoriteUpdatedAt = old.favoriteUpdatedAt
        source.userRating = old.userRating
        source.ratingUpdatedAt = old.ratingUpdatedAt
        source.userNote = old.userNote
        source.noteUpdatedAt = old.noteUpdatedAt
        source.sortPosition = old.sortPosition
        source.favoriteSortPosition = old.favoriteSortPosition
        source.createdAt = min(source.createdAt, old.createdAt)
        source.releaseYear = source.releaseYear ?? old.releaseYear
        Self.clearTitleState(old)
        try repoint(from: old.id, to: source.id, in: context)
        old.mergedIntoID = source.id
    }

    private func repoint(from oldID: String, to newID: String, in context: ModelContext) throws {
        for sibling in try context.fetch(FetchDescriptor<StoredMediaItem>(predicate: #Predicate { $0.mergedIntoID == oldID })) {
            sibling.mergedIntoID = newID
        }
    }

    /// Conflict rules of ADR-0020: the most active status, favourite if any
    /// source is, the most recently changed rating, both notes.
    static func absorbTitleState(of source: StoredMediaItem, into primary: StoredMediaItem) {
        if statusRank(source.watchTypeRaw) < statusRank(primary.watchTypeRaw) {
            primary.watchTypeRaw = source.watchTypeRaw
            primary.sortPosition = nil
        }
        if source.isFavorite, !primary.isFavorite {
            primary.isFavorite = true
            primary.favoriteSortPosition = primary.favoriteSortPosition ?? source.favoriteSortPosition
        }
        if source.userRating > 0, primary.userRating == 0 || (source.ratingUpdatedAt ?? .distantPast) > (primary.ratingUpdatedAt ?? .distantPast) {
            primary.userRating = source.userRating
        }
        switch (primary.userNote, source.userNote) {
        case (nil, let note?): primary.userNote = note
        case (let mine?, let theirs?) where mine != theirs: primary.userNote = mine + "\n\n" + theirs
        default: break
        }
        primary.createdAt = min(primary.createdAt, source.createdAt)
        primary.releaseYear = primary.releaseYear ?? source.releaseYear
        primary.posterURL = primary.posterURL ?? source.posterURL
        primary.bannerURL = primary.bannerURL ?? source.bannerURL
        clearTitleState(source)
    }

    /// A merged source shows nowhere on its own: every library query keys on these.
    static func clearTitleState(_ item: StoredMediaItem) {
        item.watchTypeRaw = -1
        item.isFavorite = false
        item.userRating = 0
        item.userNote = nil
        item.sortPosition = nil
        item.favoriteSortPosition = nil
    }

    /// Watching > On Hold > Plan to Watch > Completed > Dropped > not in the library.
    nonisolated static func statusRank(_ raw: Int) -> Int {
        switch WatchType(rawValue: raw) {
        case .watching: return 0
        case .onHold: return 1
        case .planToWatch: return 2
        case .completed: return 3
        case .dropped: return 4
        case nil: return 5
        }
    }

    /// Same normalised title, type family and known year; nil when a title
    /// cannot be matched strongly (no year, a download, a live channel).
    static func strongMatchKey(_ item: StoredMediaItem) -> String? {
        guard let year = item.releaseYear, year > 0, let family = typeFamily(item.mediaType) else { return nil }
        let title = normalizedTitle(item.title)
        return title.isEmpty ? nil : "\(title)|\(year)|\(family)"
    }

    nonisolated static func typeFamily(_ mediaType: String) -> String? {
        switch mediaType.lowercased() {
        case "movie", "animemovie": return "movie"
        case "tvseries", "anime", "ova", "cartoon", "asiandrama", "documentary": return "series"
        default: return nil
        }
    }

    /// Case, accents, punctuation and a trailing "(2009)" do not tell titles apart.
    nonisolated static func normalizedTitle(_ title: String) -> String {
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
        var words = folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        if words.count > 1, let last = words.last, last.count == 4, let year = Int(last), (1900...2100).contains(year) {
            words.removeLast()
        }
        return words.joined(separator: " ")
    }
}

// MARK: - Library pages (ADR-0021)

extension LibraryStore {
    /// Restores pages into [context]. A page already here (same ID, or else
    /// the same name) gains the entries it lacks; any other page is added
    /// after the local ones. Entries follow their title's local ID.
    nonisolated fileprivate static func applyPages(_ pages: [BackupDocument.Page], itemIDs: [String: String],
                                                   replacing: Bool, in context: ModelContext) throws {
        guard !pages.isEmpty else { return }
        // A replace has already deleted the local pages in this transaction.
        let local = replacing ? [] : try context.fetch(FetchDescriptor<LibraryPage>())
        var byID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        var byName = Dictionary(local.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var keys = replacing ? [] : Set(try context.fetch(FetchDescriptor<LibraryPageEntry>()).map(\.id))
        var position = local.map(\.sortPosition).max() ?? 0
        for incoming in pages {
            let page: LibraryPage
            if let existing = byID[incoming.id] ?? byName[incoming.name.lowercased()] {
                page = existing
            } else {
                position += 1
                page = LibraryPage(id: incoming.id, name: incoming.name, createdAt: incoming.createdAt, sortPosition: position)
                context.insert(page)
                byID[page.id] = page
                byName[page.name.lowercased()] = page
            }
            for entry in incoming.entries {
                let itemID = itemIDs[entry.itemID] ?? entry.itemID
                let key = LibraryPageEntry.key(pageID: page.id, itemID: itemID, episodeData: entry.episodeData)
                guard keys.insert(key).inserted else { continue }
                let row = LibraryPageEntry(pageID: page.id, itemID: itemID, details: DetailsDto(
                    provider: entry.providerName, providerId: entry.providerID, url: entry.providerURL, name: entry.title,
                    type: entry.mediaType, posterUrl: entry.posterURL, backgroundPosterUrl: entry.bannerURL, logoUrl: nil,
                    plot: nil, year: nil, durationMinutes: nil, score: nil, tags: [], actors: [], contentRating: nil,
                    comingSoon: false, episodes: [], movieData: nil,
                ), episode: entry.episodeData.map {
                    EpisodeDto(data: $0, name: entry.episodeName, season: entry.season, episode: entry.episode,
                               posterUrl: entry.episodeThumbnailURL, description: nil, score: nil, date: nil,
                               runTimeMinutes: nil, audio: entry.audio)
                }, addedAt: entry.addedAt)
                context.insert(row)
            }
        }
    }

    enum PageError: LocalizedError, Equatable {
        case emptyName
        case duplicateName(String)
        case pageNotFound
        case localTitle

        var errorDescription: String? {
            switch self {
            case .emptyName: return "Give the page a name."
            case .duplicateName(let name): return "You already have a page named “\(name)”."
            case .pageNotFound: return "That page no longer exists."
            case .localTitle: return "Downloaded files can't be added to pages. Add the title from its provider instead."
            }
        }
    }

    /// Pages in sidebar order, with how many titles and episodes each holds.
    func pages() throws -> [LibraryPageSummary] {
        let context = context
        guard let context else { throw ImportError.storeUnavailable }
        try persistenceFault?(.queryRead)
        return try context.fetch(Self.pageOrder).map { try summary(of: $0, in: context) }
    }

    func page(id: String) throws -> LibraryPageSummary? {
        let context = context
        guard let context else { throw ImportError.storeUnavailable }
        try persistenceFault?(.queryRead)
        return try pageRow(id: id, in: context).map { try summary(of: $0, in: context) }
    }

    /// A page's entries, most recently added first.
    func pageEntries(pageID: String) throws -> [LibraryPageEntry] {
        let context = context
        guard let context else { throw ImportError.storeUnavailable }
        try persistenceFault?(.queryRead)
        return try context.fetch(FetchDescriptor<LibraryPageEntry>(
            predicate: #Predicate { $0.pageID == pageID },
            sortBy: [SortDescriptor(\.addedAt, order: .reverse), SortDescriptor(\.id)],
        ))
    }

    /// Creates a page at the end of the sidebar and returns its ID.
    @discardableResult
    func createPage(named rawName: String) throws -> String {
        try withMutation(shared: false) { context in
            let name = try uniqueName(rawName, excluding: nil, in: context)
            let last = try context.fetch(Self.pageOrder).last?.sortPosition ?? 0
            let page = LibraryPage(name: name, sortPosition: last + 1)
            context.insert(page)
            try save(context: context)
            return page.id
        }
    }

    func renamePage(id: String, to rawName: String) throws {
        try withMutation(shared: false) { context in
            guard let page = try pageRow(id: id, in: context) else { throw PageError.pageNotFound }
            let name = try uniqueName(rawName, excluding: id, in: context)
            guard name != page.name else { return }
            page.name = name
            try save(context: context)
        }
    }

    /// Deletes the page and its entries. The titles themselves, their
    /// history and status are untouched.
    func deletePage(id: String) throws {
        try withMutation(shared: false) { context in
            guard let page = try pageRow(id: id, in: context) else { return }
            for entry in try context.fetch(FetchDescriptor<LibraryPageEntry>(predicate: #Predicate { $0.pageID == id })) {
                context.delete(entry)
            }
            context.delete(page)
            try save(context: context)
        }
    }

    /// Sidebar drag-to-reorder: `List.onMove` semantics.
    func movePages(fromOffsets source: IndexSet, toOffset destination: Int) throws {
        try withMutation(shared: false) { context in
            var pages = try context.fetch(Self.pageOrder)
            pages.move(fromOffsets: source, toOffset: destination)
            for (index, page) in pages.enumerated() where page.sortPosition != Double(index + 1) {
                page.sortPosition = Double(index + 1)
            }
            guard context.hasChanges else { return }
            try save(context: context)
        }
    }

    /// IDs of the pages that hold this title (`episode` nil) or this episode.
    func pageIDs(containing details: DetailsDto, episode: EpisodeDto? = nil) throws -> Set<String> {
        let context = context
        guard let context else { throw ImportError.storeUnavailable }
        try persistenceFault?(.queryRead)
        let itemID = try resolvedItemID(for: details, in: context)
        let data = episode?.data
        let entries = try context.fetch(FetchDescriptor<LibraryPageEntry>(predicate: #Predicate {
            $0.itemID == itemID && $0.episodeData == data
        }))
        return Set(entries.map(\.pageID))
    }

    /// Adds the title (`episode` nil) or the episode to a page, or removes it.
    func setPageMembership(pageID: String, details: DetailsDto, episode: EpisodeDto? = nil, isMember: Bool) throws {
        guard details.type != "Download", details.localDownloadID == nil else { throw PageError.localTitle }
        try withMutation(shared: false) { context in
            guard try pageRow(id: pageID, in: context) != nil else { throw PageError.pageNotFound }
            let itemID = try resolvedItemID(for: details, in: context)
            let key = LibraryPageEntry.key(pageID: pageID, itemID: itemID, episodeData: episode?.data)
            let existing = try context.fetch(FetchDescriptor<LibraryPageEntry>(predicate: #Predicate { $0.id == key })).first
            switch (isMember, existing) {
            case (true, nil):
                context.insert(LibraryPageEntry(pageID: pageID, itemID: itemID, details: details, episode: episode))
            case (false, let entry?):
                context.delete(entry)
            default:
                return
            }
            try save(context: context)
        }
    }

    func removePageEntry(id: String) throws {
        try withMutation(shared: false) { context in
            guard let entry = try context.fetch(FetchDescriptor<LibraryPageEntry>(predicate: #Predicate { $0.id == id })).first else { return }
            context.delete(entry)
            try save(context: context)
        }
    }

    /// The details a page entry opens and plays: its saved title, without
    /// loading the provider's page.
    func detailsPreview(for entry: LibraryPageEntry) -> DetailsDto {
        DetailsDto(
            provider: entry.providerName, providerId: entry.providerID, url: entry.providerURL, name: entry.title,
            type: entry.mediaType, posterUrl: entry.posterURL, backgroundPosterUrl: entry.bannerURL, logoUrl: nil,
            plot: nil, year: nil, durationMinutes: nil, score: nil, tags: [], actors: [], contentRating: nil,
            comingSoon: false, episodes: [], movieData: nil,
        )
    }

    /// Plays a saved episode, resuming it when it was left part-way through.
    /// The player opens at once and the provider's episode list loads behind
    /// its spinner; a renamed episode is found again by season and number.
    func playPageEpisode(_ entry: LibraryPageEntry, appState: AppState) {
        guard !AppLock.shared.isLocked, let data = entry.episodeData else { return }
        guard appState.isEngineBootstrapped else {
            appState.presentError("The engine is still preparing providers. Try again when it is ready.")
            return
        }
        let owner: ProfileOperationContext
        do { owner = try captureProfileOperation() }
        catch { appState.presentError("Couldn't play: \(error.localizedDescription)"); return }
        let (title, provider, url, itemID) = (entry.title, entry.providerID ?? entry.providerName, entry.providerURL, entry.itemID)
        let (season, number, audio) = (entry.season, entry.episode, entry.audio)
        let engine = appState.connection.generation
        let lock = AppLock.shared.generation
        let id = UUID()
        let pending = appState.player.beginPending(title: title)
        resumeTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.resumeTasks.removeValue(forKey: id) }
            defer { if let pending { appState.player.endPending(pending) } }
            let current = { !Task.isCancelled && self.owns(owner) && !AppLock.shared.isLocked && AppLock.shared.generation == lock
                && appState.isEngineBootstrapped && appState.connection.generation == engine }
            do {
                let details = try await DaemonClient.shared.details(provider: provider, url: url)
                guard details.type != "Download", details.localDownloadID == nil else { throw ResumeError.invalidRemoteDetails }
                let episode = try Self.resumeEpisode(in: details, data: data, season: season, episode: number, audio: audio)
                guard current() else { return }
                let progress = try self.episodeProgress(itemID: itemID)[episode.data]
                if let pending, !appState.player.isPending(pending) { return }
                await appState.player.play(details: details, episode: episode,
                    resumeAt: progress?.isResumable == true ? progress?.positionSeconds : nil, preferences: UserPreferences.shared)
            } catch {
                guard current(), !(error is CancellationError) else { return }
                if let pending { appState.player.endPending(pending) }
                appState.presentError("Couldn't play \(title): \(error.localizedDescription)")
            }
        }
    }

    private static var pageOrder: FetchDescriptor<LibraryPage> {
        FetchDescriptor(sortBy: [SortDescriptor(\.sortPosition), SortDescriptor(\.createdAt)])
    }

    private func pageRow(id: String, in context: ModelContext) throws -> LibraryPage? {
        try context.fetch(FetchDescriptor<LibraryPage>(predicate: #Predicate { $0.id == id })).first
    }

    private func summary(of page: LibraryPage, in context: ModelContext) throws -> LibraryPageSummary {
        let id = page.id
        let titles = try context.fetchCount(FetchDescriptor<LibraryPageEntry>(predicate: #Predicate { $0.pageID == id && $0.episodeData == nil }))
        let all = try context.fetchCount(FetchDescriptor<LibraryPageEntry>(predicate: #Predicate { $0.pageID == id }))
        return LibraryPageSummary(id: id, name: page.name, titleCount: titles, episodeCount: all - titles)
    }

    /// Page names are unique, ignoring case, so the sidebar and menus are unambiguous.
    private func uniqueName(_ rawName: String, excluding pageID: String?, in context: ModelContext) throws -> String {
        guard let name = LibraryPage.normalizedName(rawName) else { throw PageError.emptyName }
        let clash = try context.fetch(FetchDescriptor<LibraryPage>()).contains {
            $0.id != pageID && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
        if clash { throw PageError.duplicateName(name) }
        return name
    }
}
