import SwiftUI

/// Navigation, search and presentation belong to a main window. Engine,
/// playback, downloads and durable data remain application-scoped.
@MainActor
@Observable
final class WindowSession {
    let id = UUID()
    // Navigation
    var selection: AppDestination = .home
    var detailPath: [DetailCoordinate] = []
    /// Kept current by WindowSessionAnchor. In full screen the toolbar stays
    /// visible on a solid background, so artwork starts below it.
    var isFullScreen = false

    /// Sidebar/menu navigation: switches destination and unwinds any pushed
    /// details so the new screen starts clean.
    func navigateTo(_ destination: AppDestination) {
        detailPath.removeAll()
        if destination != selection {
            libraryFilter = ""
        }
        selection = destination
    }

    /// Title filter for the Library collection on screen; driven by the
    /// window's global search field and cleared when leaving the collection.
    var libraryFilter = ""

    var searchQuery = ""
    var searchResults: [SearchResultDto] = []
    var searchProviderErrors: [String: String] = [:]
    var isSearching = false
    var searchError: String?
    /// Confirmed repository-add presentation remains private to its receiving window.
    var pendingRepoAdd: String?
    var showShortcuts = false
    /// The New Page / Rename Page sheet over this window (ADR-0021).
    var pageEditor: PageEditorRequest?
    /// The page waiting for delete confirmation.
    var pageToDelete: LibraryPageSummary?
    @ObservationIgnored private let searchStream: (String) -> AsyncThrowingStream<SearchStreamEventDto, Error>

    init(searchStream: @escaping (String) -> AsyncThrowingStream<SearchStreamEventDto, Error> = {
        DaemonClient.shared.searchStream($0, plugins: nil)
    }) { self.searchStream = searchStream }

    // MARK: - Search

    func performSearch(immediate: Bool = false) {
        searchTask?.cancel()
        searchGeneration &+= 1
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            searchResults = []
            isSearching = false
            searchError = nil
            return
        }

        isSearching = true
        searchError = nil
        let generation = searchGeneration
        searchTask = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(for: .milliseconds(250)) // debounce typing
                guard !Task.isCancelled else { return }
            }
            guard let self, generation == searchGeneration else { return }

            // Progressive NDJSON stream: results appear per provider as each
            // finishes its barrier (Rules.md §4.3). Parallel search across all active providers.
            searchResults = []
            searchProviderErrors = [:]
            var buffer: [SearchResultDto] = []
            var seenIDs = Set<String>()
            var lastFlushTime = DispatchTime.now()

            do {
                for try await event in searchStream(query) {
                    guard !Task.isCancelled, generation == searchGeneration else { return }
                    switch event.type {
                    case "provider_result":
                        var hasNew = false
                        for result in event.results {
                            if !seenIDs.contains(result.id) {
                                seenIDs.insert(result.id)
                                buffer.append(result)
                                hasNew = true
                            }
                        }
                        let now = DispatchTime.now()
                        let elapsedMs = Double(now.uptimeNanoseconds - lastFlushTime.uptimeNanoseconds) / 1_000_000
                        if hasNew && (elapsedMs > 50 || searchResults.isEmpty) {
                            searchResults = buffer
                            lastFlushTime = now
                        }
                    case "provider_error":
                        if let provider = event.provider {
                            searchProviderErrors[provider] = event.error ?? "failed"
                        }
                    case "done":
                        searchResults = buffer
                        isSearching = false
                        return
                    default:
                        break
                    }
                }
                guard !Task.isCancelled, generation == searchGeneration else { return }
                searchResults = buffer
                isSearching = false
            } catch {
                guard !Task.isCancelled, generation == searchGeneration else { return }
                // Results that arrived before the failure stay visible next to it (audit M1).
                searchResults = buffer
                searchError = error.localizedDescription
                isSearching = false
            }
        }
    }

    func commitSearch() {
        performSearch(immediate: true)
    }

    func clearSearch() {
        searchTask?.cancel()
        searchGeneration &+= 1
        if !searchQuery.isEmpty {
            searchQuery = ""
        }
        searchResults = []
        isSearching = false
        searchError = nil
        searchProviderErrors = [:]
    }

    @ObservationIgnored private var searchTask: Task<Void, Never>?
    private var searchGeneration: UInt64 = 0

    // MARK: - Details navigation

    /// Pushes a details coordinate; the destination view loads the DTO.
    func openDetails(_ result: SearchResultDto) {
        detailPath.append(.result(result))
    }

    func openLibraryItem(id: String, provider: String, providerID: String? = nil, url: String) {
        detailPath.append(.libraryItem(id: id, provider: provider, providerID: providerID, url: url))
    }

    func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchGeneration &+= 1
        isSearching = false
    }

}

// MARK: - Deep links

extension WindowSession {
    /// `cloudstreamrepo://` / `cloudstream://` / `cs.repo://` / `cs3://` open
    /// the confirmed repo-add flow in Extensions (normalized by the one
    /// canonical implementation in `DaemonClient.normalizeRepoUrl`).
    /// `cloudstreamapp://` / `cloudstreamplayer://<query>` route to search.
    func handleDeepLink(_ url: URL) {
        perform(DeepLinkRouter.route(url))
    }

    /// Executes a route from a URL, Spotlight, Handoff, App Intents or the
    /// Dock/menu bar menus (Phase 9).
    func perform(_ route: DeepLinkRoute) {
        // Links, Spotlight, Shortcuts and the menus must not reach the
        // library while it is locked; the lock screen is showing instead.
        if AppLock.shared.isLocked, route != .ignored {
            DaemonLog.client("deeplink.blocked_locked")
            return
        }
        switch route {
        case .addRepository(let target):
            pendingRepoAdd = target
            navigateTo(.extensions)
        case .search(let query):
            navigateTo(.search)
            searchQuery = query
            commitSearch()
        case .openTitle(let provider, let providerID, let url):
            navigateTo(.home)
            openLibraryItem(id: LibraryIdentity.key(providerID: providerID, providerName: provider, url: url),
                            provider: provider, providerID: providerID, url: url)
        case .continueWatching:
            let rows: [StoredMediaItem]
            do { rows = try LibraryStore.shared.continueWatching }
            catch { AppState.shared.presentError("Couldn’t read Continue Watching: \(error.localizedDescription)"); return }
            guard let item = rows.first else {
                navigateTo(.home)
                return
            }
            LibraryStore.shared.startResume(item: item, appState: AppState.shared)
        case .navigate(let destination):
            navigateTo(destination)
        case .ignored:
            break
        }
    }
}
