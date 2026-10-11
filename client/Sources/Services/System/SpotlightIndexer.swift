import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

@MainActor
protocol SpotlightIndexClient {
    func removeLibrary() async throws
    func index(_ items: [CSSearchableItem]) async throws
}

@MainActor
private struct SystemSpotlightIndex: SpotlightIndexClient {
    func removeLibrary() async throws {
        try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [SpotlightIndexer.domain])
    }
    func index(_ items: [CSSearchableItem]) async throws {
        try await CSSearchableIndex.default().indexSearchableItems(items)
    }
}

/// One ordered writer for the active profile's Spotlight domain. Cancellation
/// cannot undo an OS index call, so newer removal waits behind in-flight writes.
@MainActor
@Observable
final class SpotlightIndexer {
    static let shared = SpotlightIndexer()
    static let domain = "com.lagradost.cloudstream.library"
    static let debounce: Duration = .seconds(5)

    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let preferences: UserPreferences
    @ObservationIgnored private let client: any SpotlightIndexClient
    @ObservationIgnored private let available: Bool
    @ObservationIgnored private let debounceDuration: Duration
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var writer: Task<Void, Never>?
    @ObservationIgnored private var desired: Work?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var lastIndexedKey: Key?
    private(set) var lastFailure: String?

    private struct Key: Equatable {
        let owner: LibraryStore.ProfileOperationContext
        let version: UInt64
    }
    private struct Snapshot {
        let key: Key
        let items: [CSSearchableItem]
    }
    private struct Work {
        let generation: UInt64
        /// nil means remove the domain; snapshots contain no SwiftData objects.
        let snapshot: Snapshot?
        let clearFailureOnSuccess: Bool
    }

    init(library: LibraryStore = .shared, preferences: UserPreferences = .shared,
         client: (any SpotlightIndexClient)? = nil, debounce: Duration = SpotlightIndexer.debounce) {
        self.library = library
        self.preferences = preferences
        self.client = client ?? SystemSpotlightIndex()
        self.available = client != nil || !AppEnvironment.isIsolated()
        self.debounceDuration = debounce
        preferences.spotlightPreferenceChanged = { [weak self] in self?.invalidateAndSchedule() }
    }

    deinit { pending?.cancel() }

    /// Indexing stops, and the domain is removed, whenever a lock applies: the
    /// global app lock as well as a locked profile (audit L4).
    private var indexingAllowed: Bool {
        preferences.indexInSpotlight && !preferences.requireUnlock && !ProfileStore.shared.active.requiresUnlock
    }

    func scheduleReindex() {
        guard available else { return }
        guard indexingAllowed else {
            Task { await removeAll() }
            return
        }
        let owner: LibraryStore.ProfileOperationContext
        do { owner = try library.captureProfileOperation() }
        catch {
            _ = submit(nil, clearFailureOnSuccess: false)
            recordFailure(error)
            return
        }
        pending?.cancel()
        let delay = debounceDuration
        pending = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, !Task.isCancelled, self.library.owns(owner), self.indexingAllowed else { return }
            await self.reindex()
        }
    }

    /// Called synchronously when the selected profile or preference changes,
    /// invalidating old work before the debounced replacement is requested.
    func invalidateAndSchedule() {
        guard available else { return }
        pending?.cancel()
        lastIndexedKey = nil
        _ = submit(nil)
        if indexingAllowed { scheduleReindex() }
        else { Task { await removeAll() } }
    }

    func reindex() async {
        guard available else { return }
        guard indexingAllowed else { await removeAll(); return }
        do {
            let key = Key(owner: try library.captureProfileOperation(), version: library.version)
            guard lastIndexedKey != key || lastFailure != nil else { return }
            let snapshot = Snapshot(key: key, items: Self.searchableItems(
                for: try library.allEntries() + library.favorites + library.continueWatching))
            await submit(snapshot).value
        } catch {
            let cleanup = submit(nil, clearFailureOnSuccess: false)
            recordFailure(error)
            await cleanup.value
        }
    }

    func removeAll() async {
        guard available else { return }
        pending?.cancel()
        lastIndexedKey = nil
        await submit(nil).value
    }

    func retry() async {
        if indexingAllowed { await reindex() }
        else { await removeAll() }
    }

    /// Only the newest queued state is retained; an already executing OS call
    /// must finish before its replacement can delete/index the domain.
    private func submit(_ snapshot: Snapshot?, clearFailureOnSuccess: Bool = true) -> Task<Void, Never> {
        generation &+= 1
        desired = Work(generation: generation, snapshot: snapshot, clearFailureOnSuccess: clearFailureOnSuccess)
        if let writer { return writer }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.drain()
        }
        writer = task
        return task
    }

    private func isCurrent(_ work: Work) -> Bool {
        guard work.generation == generation else { return false }
        guard let snapshot = work.snapshot else { return true }
        return preferences.indexInSpotlight && library.owns(snapshot.key.owner)
    }

    private func drain() async {
        while let work = desired {
            desired = nil
            do {
                lastIndexedKey = nil
                try await client.removeLibrary()
                guard isCurrent(work) else { continue }
                if let snapshot = work.snapshot, !snapshot.items.isEmpty {
                    try await client.index(snapshot.items)
                    guard isCurrent(work) else {
                        // Direct store changes also need cleanup even if their
                        // caller did not explicitly submit a replacement.
                        if desired == nil { desired = Work(generation: generation, snapshot: nil, clearFailureOnSuccess: false) }
                        continue
                    }
                }
                lastIndexedKey = work.snapshot?.key
                if work.clearFailureOnSuccess { lastFailure = nil }
            } catch {
                if isCurrent(work) { recordFailure(error) }
                // A failed OS index call may have inserted a partial batch.
                if work.snapshot != nil, !isCurrent(work), desired == nil {
                    desired = Work(generation: generation, snapshot: nil, clearFailureOnSuccess: false)
                }
            }
        }
        writer = nil
    }

    private func recordFailure(_ error: Error) {
        lastIndexedKey = nil
        lastFailure = error.localizedDescription
        DaemonLog.client("spotlight.index_failed", fields: ["error": error.localizedDescription])
    }

    static func searchableItems(for entries: [StoredMediaItem]) -> [CSSearchableItem] {
        var seen = Set<String>()
        return entries.filter { $0.mediaType != "Download" && seen.insert($0.id).inserted }.map { item in
            let attributes = CSSearchableItemAttributeSet(contentType: .movie)
            attributes.title = item.title
            attributes.displayName = item.title
            var parts = [MediaTypeDisplay.name(for: item.mediaType), item.providerName]
            if let status = item.watchType?.label { parts.insert(status, at: 0) }
            attributes.contentDescription = parts.joined(separator: " · ")
            attributes.keywords = [item.providerName, MediaTypeDisplay.name(for: item.mediaType), "CloudStream"]
            return CSSearchableItem(uniqueIdentifier: item.id, domainIdentifier: domain, attributeSet: attributes)
        }
    }
}
