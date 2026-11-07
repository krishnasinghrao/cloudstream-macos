import Foundation

/// Quietly fills the release year into saved titles that were filed without
/// one (from a card whose provider listed none, or by an older version), so
/// the Release Year sort orders the whole library instead of parking those
/// titles at the end until each page is opened by hand.
///
/// Same discipline as `EpisodeUpdateChecker`: installed providers only, a
/// small batch per run, requests spaced out, and every suspension fenced by
/// the captured profile, lock generation and engine generation.
@MainActor
final class LibraryMetadataHydrator {
    static let shared = LibraryMetadataHydrator()

    static let batchSize = 20
    static let spacing: Duration = .seconds(3)
    /// After the episode checker's first run, so the two never overlap at launch.
    static let launchDelay: Duration = .seconds(150)
    static let runInterval: Duration = .seconds(30 * 60)

    private let library: LibraryStore
    private let loadDetails: @MainActor (String, String) async throws -> DetailsDto
    private let authorization: @MainActor () -> UInt64?
    private let spacingDuration: Duration
    private var loop: Task<Void, Never>?
    private var run: Task<Void, Never>?
    /// Titles already tried this session, by row ID: a title whose provider is
    /// gone or lists no year is not asked again until the next launch.
    private(set) var attempted: Set<String> = []
    var isRunning: Bool { run != nil }

    init(library: LibraryStore = .shared,
         spacing: Duration = LibraryMetadataHydrator.spacing,
         authorization: @escaping @MainActor () -> UInt64? = {
             AppLock.shared.isLocked ? nil : AppLock.shared.generation
         },
         loadDetails: @escaping @MainActor (String, String) async throws -> DetailsDto = {
             try await DaemonClient.shared.details(provider: $0, url: $1)
         }) {
        self.library = library
        self.spacingDuration = spacing
        self.authorization = authorization
        self.loadDetails = loadDetails
    }

    func start(appState: AppState) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            do { try await Task.sleep(for: Self.launchDelay) } catch { return }
            while !Task.isCancelled {
                await self?.runOnce(appState: appState)
                do { try await Task.sleep(for: Self.runInterval) } catch { return }
            }
        }
    }

    func cancelCurrentRun() { run?.cancel() }

    func stop() {
        loop?.cancel()
        loop = nil
        cancelCurrentRun()
    }

    /// A profile switch starts over: the other profile's rows are different.
    func resetAttempts() { attempted.removeAll() }

    func runOnce(appState: AppState) async {
        // Never compete with the user's own provider requests or the
        // episode checker for the same providers.
        await runOnce(canRun: {
            appState.isEngineBootstrapped && ConnectivityMonitor.shared.isOnline
                && appState.player.session == nil && !EpisodeUpdateChecker.shared.isRunning
        }, engineGeneration: { appState.connection.generation })
    }

    func runOnce(canRun: @escaping @MainActor () -> Bool, engineGeneration: @escaping @MainActor () -> UInt64) async {
        guard run == nil, canRun(), let lockGeneration = authorization() else { return }
        let owner: LibraryStore.ProfileOperationContext
        let due: [Candidate]
        do {
            owner = try library.captureProfileOperation()
            due = try library.titlesMissingReleaseYear(excluding: attempted, limit: Self.batchSize)
                .map { Candidate(id: $0.id, provider: $0.providerKey, url: $0.providerURL) }
        } catch { return }
        guard !due.isEmpty else { return }
        let engine = engineGeneration()
        let current = {
            !Task.isCancelled && self.library.owns(owner) && self.authorization() == lockGeneration
                && canRun() && engineGeneration() == engine
        }
        let task = Task {
            var learned = 0
            for (index, item) in due.enumerated() {
                guard current() else { break }
                if index > 0 {
                    do { try await Task.sleep(for: self.spacingDuration) } catch { break }
                    guard current() else { break }
                }
                self.attempted.insert(item.id)
                guard let details = try? await self.loadDetails(item.provider, item.url), current() else { continue }
                // Only the captured row is written; a provider payload cannot
                // redirect the update to another title.
                if (try? self.library.absorbMetadata(details: details, itemID: item.id)) == true { learned += 1 }
            }
            if learned > 0 { DaemonLog.client("library.metadata_hydrated", fields: ["titles": String(learned)]) }
        }
        run = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        run = nil
    }

    private struct Candidate {
        let id: String
        let provider: String
        let url: String
    }
}
