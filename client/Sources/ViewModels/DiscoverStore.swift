import Foundation

/// Provider homepages on Home (Offline-Features-Plan Phase 6 — Android's
/// main Home screen, which macOS lacked). Rows are loaded per provider and
/// paginated; a failed load keeps whatever was already shown.
@MainActor
@Observable
final class DiscoverStore {
    static let shared = DiscoverStore()

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var providers: [ProviderInfoDto] = []
    private(set) var rows: [HomePageListDto] = []
    private(set) var state: LoadState = .idle
    private(set) var hasNextPage = false
    private(set) var isLoadingMore = false
    private(set) var loadedProvider: String?

    typealias HomeLoader = @Sendable (_ provider: String, _ page: Int) async throws -> HomePageDto

    @ObservationIgnored private var page = 1
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var moreTask: Task<Void, Never>?
    /// Advanced by every clear, provider change and refresh; a response is
    /// applied only by the load that still owns the current generation.
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var loadedAt: Date?
    /// Engine/provider configuration the shown rows were loaded under.
    @ObservationIgnored private var loadedConfiguration: [UInt64] = []
    @ObservationIgnored private let loadHome: HomeLoader

    init(loadHome: @escaping HomeLoader = { try await DaemonClient.shared.home(provider: $0, page: $1) }) {
        self.loadHome = loadHome
    }

    /// Homepages are cached in memory this long before a revisit reloads.
    static let freshness: TimeInterval = 10 * 60

    /// Providers that actually have a homepage.
    var homepageProviders: [ProviderInfoDto] { providers.filter(\.hasMainPage) }

    /// Provider list from the daemon; picks the saved (or first) homepage.
    func refreshProviders(preferences: UserPreferences) async {
        do {
            providers = try await DaemonClient.shared.providerInfo()
        } catch {
            // Keep the previous list; the rows section reports load errors.
            return
        }
        let homepages = homepageProviders
        // Selections are stable provider IDs; migrate a saved name when it is unambiguous.
        if !homepages.contains(where: { $0.id == preferences.discoverProvider }) {
            let byName = homepages.filter { $0.name == preferences.discoverProvider }
            preferences.discoverProvider = (byName.count == 1 ? byName.first : homepages.first)?.id ?? ""
        }
    }

    /// Human-readable name for a stored provider selection.
    func displayName(for providerKey: String) -> String {
        providers.first { $0.id == providerKey }?.name ?? providerKey
    }

    /// Loads page 1 of `provider`'s homepage unless a fresh copy is shown. A
    /// copy loaded under another engine/provider `configuration` is not fresh.
    func load(provider: String, force: Bool = false, configuration: [UInt64] = []) {
        guard !provider.isEmpty else {
            invalidateLoads()
            rows = []
            state = .idle
            loadedProvider = nil
            loadedAt = nil
            return
        }
        if !force, provider == loadedProvider, state == .loaded, configuration == loadedConfiguration,
           let loadedAt, Date().timeIntervalSince(loadedAt) < Self.freshness {
            return
        }
        let generation = invalidateLoads()
        if provider != loadedProvider { rows = [] }
        state = .loading
        let loadHome = loadHome
        loadTask = Task { [weak self] in
            do {
                let home = try await loadHome(provider, 1)
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.rows = Self.merge([], with: home.lists)
                self.page = 1
                self.hasNextPage = home.hasNext
                self.loadedProvider = provider
                self.loadedAt = Date()
                self.loadedConfiguration = configuration
                self.state = home.lists.isEmpty ? .failed("\(provider) returned an empty homepage.") : .loaded
            } catch {
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                // Rows kept from an earlier load belong to this same provider.
                self.loadedProvider = provider
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    /// Next page, appended into the existing rows (same-named shelves grow).
    func loadMore() {
        guard hasNextPage, !isLoadingMore, state == .loaded, let provider = loadedProvider else { return }
        isLoadingMore = true
        let generation = generation
        let next = page + 1
        let loadHome = loadHome
        moreTask = Task { [weak self] in
            let home = try? await loadHome(provider, next)
            // A superseded load already reset the busy flag for its successor.
            guard let self, self.generation == generation else { return }
            self.isLoadingMore = false
            self.moreTask = nil
            guard let home, !Task.isCancelled, self.loadedProvider == provider, self.page + 1 == next else { return }
            self.rows = Self.merge(self.rows, with: home.lists)
            self.page = next
            self.hasNextPage = home.hasNext
        }
    }

    /// Cancels both owned loads and resets pagination for a new generation.
    @discardableResult
    private func invalidateLoads() -> UInt64 {
        generation &+= 1
        loadTask?.cancel()
        loadTask = nil
        moreTask?.cancel()
        moreTask = nil
        isLoadingMore = false
        hasNextPage = false
        page = 1
        return generation
    }

    /// A random title from the loaded rows ("Surprise Me").
    func randomItem() -> SearchResultDto? {
        rows.flatMap(\.items).randomElement()
    }

    /// Merges paged shelves: items join the shelf with the same name,
    /// duplicates (same provider+url) are dropped, order is preserved.
    static func merge(_ existing: [HomePageListDto], with incoming: [HomePageListDto]) -> [HomePageListDto] {
        var result = existing
        for list in incoming {
            if let index = result.firstIndex(where: { $0.name == list.name }) {
                var seen = Set(result[index].items.map(\.id))
                let fresh = list.items.filter { seen.insert($0.id).inserted }
                result[index] = HomePageListDto(name: list.name, isHorizontal: result[index].isHorizontal, items: result[index].items + fresh)
            } else {
                var seen = Set<String>()
                let unique = list.items.filter { seen.insert($0.id).inserted }
                guard !unique.isEmpty else { continue }
                result.append(HomePageListDto(name: list.name, isHorizontal: list.isHorizontal, items: unique))
            }
        }
        return result
    }
}
