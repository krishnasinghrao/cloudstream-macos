import SwiftUI

/// Home: Continue Watching rail plus a library row the user picks: a watch
/// status, Favorites or one of their pages, in the same order as its own
/// Library screen.
struct HomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var windowSession

    /// Reading the store version registers observation: any library mutation
    /// invalidates this body. No `.id()` identity nukes.
    private var storeVersion: UInt64 { LibraryStore.shared.version }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 32) {
                continueWatchingSection
                if appState.preferences.showDiscoverOnHome {
                    DiscoverSection()
                }
                customCollectionSection
            }
            .padding(.vertical, 24)
        }
    }

    // MARK: - Continue Watching

    private var continueWatchingSection: some View {
        let _ = storeVersion
        let items = LibraryStore.shared.readForDisplay(or: [], { try LibraryStore.shared.continueWatching })

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Continue Watching")
                    .font(.title3.weight(.semibold))
                if !items.isEmpty {
                    Text("\(items.count)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 28)

            if items.isEmpty {
                ContentUnavailableView(
                    "No titles in progress",
                    systemImage: "play.circle",
                    description: Text("Start watching any movie or episode to pick up where you left off."),
                )
                .frame(height: 180)
                .padding(.horizontal, 28)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 16) {
                        ForEach(items) { item in
                            ContinueWatchingCard(
                                item: item,
                                onPlay: {
                                    LibraryStore.shared.startResume(item: item, appState: appState)
                                },
                                onMarkWatched: {
                                    LibraryStore.shared.perform { try LibraryStore.shared.markWatched(itemID: item.id) }
                                },
                                onRemove: {
                                    LibraryStore.shared.perform { try LibraryStore.shared.removeProgress(id: item.id) }
                                },
                            )
                            .frame(width: 168)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 6)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    // MARK: - Library Shelf

    /// What the chosen row holds, read once per render.
    private enum ShelfContent {
        case titles(LibraryCollection, [StoredMediaItem])
        case page(LibraryPageSummary, LibraryPageView.Content)

        var count: Int {
            switch self {
            case .titles(_, let items): items.count
            case .page(let page, _): page.count
            }
        }
    }

    private var customCollectionSection: some View {
        let _ = storeVersion
        let preferences = appState.preferences
        let store = LibraryStore.shared
        let pages = store.readForDisplay(or: [], { try store.pages() })
        let shelf: HomeShelf
        let content: ShelfContent
        if case .page(let id) = preferences.homeShelf, let page = pages.first(where: { $0.id == id }) {
            shelf = .page(id: id)
            content = .page(page, LibraryPageView.content(store.readForDisplay(or: [], { try store.pageEntries(pageID: id) }),
                query: "", options: preferences.libraryViewOptions["page:\(id)"] ?? LibraryViewOptions()))
        } else {
            // A deleted page (or one of another profile) shows the default row.
            let collection: LibraryCollection = if case .collection(let chosen) = preferences.homeShelf { chosen } else { HomeShelf.defaultCollection }
            shelf = .collection(collection)
            content = .titles(collection, LibraryView.arranged(LibraryView.items(in: collection),
                options: preferences.libraryViewOptions[collection.rawValue] ?? LibraryViewOptions(), collection: collection))
        }

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Picker("Library Row", selection: Binding(get: { shelf }, set: { preferences.homeShelf = $0 })) {
                    ForEach(WatchType.allCases) { type in
                        Label(type.label, systemImage: type.symbolName).tag(HomeShelf.collection(LibraryCollection(type)))
                    }
                    Divider()
                    Label(LibraryCollection.favorites.title, systemImage: LibraryCollection.favorites.icon)
                        .tag(HomeShelf.collection(.favorites))
                    if !pages.isEmpty {
                        Divider()
                        ForEach(pages) { page in
                            Label(page.name, systemImage: "rectangle.stack").tag(HomeShelf.page(id: page.id))
                        }
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .font(.title3.weight(.semibold))
                .fixedSize()
                .help("Choose what this row shows")

                if content.count > 0 {
                    Text("\(content.count)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 28)

            switch content {
            case .titles(let collection, let items) where items.isEmpty:
                emptyShelf("No titles in \(collection.title)", systemImage: collection.icon, message: collection.emptyMessage)
            case .titles(_, let items):
                shelfRow {
                    ForEach(items) { item in
                        Button {
                            windowSession.openLibraryItem(id: item.id, provider: item.providerName,
                                                          providerID: item.providerID, url: item.providerURL)
                        } label: {
                            PosterCard(title: item.title, subtitle: subtitle(for: item), posterURL: item.posterURL ?? item.bannerURL)
                        }
                        .buttonStyle(.plain)
                        .frame(width: 168)
                        .contextMenu { titleMenu(item) }
                    }
                }
            case .page(let page, let entries) where entries.isEmpty:
                emptyShelf("Nothing on \(page.name) yet", systemImage: "rectangle.stack",
                           message: "Right-click a title or an episode and choose Add to Page.")
            case .page(_, let entries):
                shelfRow {
                    ForEach(entries.titles, id: \.id) { PageEntryCard(entry: $0, progress: nil).frame(width: 168) }
                    ForEach(entries.episodes, id: \.id) { PageEntryCard(entry: $0, progress: entries.progress[$0.id]).frame(width: 280) }
                }
            }
        }
    }

    private func emptyShelf(_ title: String, systemImage: String, message: String) -> some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
            .frame(height: 180)
            .padding(.horizontal, 28)
    }

    private func shelfRow(@ViewBuilder _ cards: () -> some View) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 16) { cards() }
                .padding(.horizontal, 28)
                .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func titleMenu(_ item: StoredMediaItem) -> some View {
        Menu("Watch Status") {
            ForEach(WatchType.allCases) { type in
                Button(type.label) { setWatchType(type, on: item) }
            }
        }
        Button(item.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
            let store = LibraryStore.shared
            store.perform { try store.toggleFavorite(details: store.detailsPreview(for: item)) }
        }
        AddToPageMenu(details: LibraryStore.shared.detailsPreview(for: item))
        Divider()
        Button("Remove from Library", role: .destructive) { remove(item) }
    }

    // MARK: - Helpers

    private func subtitle(for item: StoredMediaItem) -> String? {
        if let season = item.lastSeason, let episode = item.lastEpisode {
            return "S\(season):E\(episode)"
        }
        return MediaTypeDisplay.name(for: item.mediaType)
    }

    private func setWatchType(_ type: WatchType, on item: StoredMediaItem) {
        let store = LibraryStore.shared
        store.perform { try store.upsertLibraryEntry(details: store.detailsPreview(for: item), watchType: type) }
    }

    private func remove(_ item: StoredMediaItem) {
        let store = LibraryStore.shared
        store.perform { try store.removeFromLibrary(details: store.detailsPreview(for: item)) }
    }
}

// MARK: - Discover (provider homepage)

/// The selected provider's homepage shelves (Android's Home screen).
struct DiscoverSection: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var windowSession
    @Environment(\.openSettings) private var openSettings
    private var store: DiscoverStore { DiscoverStore.shared }

    var body: some View {
        @Bindable var preferences = appState.preferences
        let homepages = store.homepageProviders

        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Text("Discover")
                    .font(.title3.weight(.semibold))

                if !homepages.isEmpty {
                    Picker("Provider", selection: $preferences.discoverProvider) {
                        ForEach(homepages) { provider in
                            Text(provider.needsVPN ? "\(provider.name) (VPN)" : provider.name).tag(provider.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .help("Homepage source")
                }

                Spacer()

                if !store.rows.isEmpty {
                    Button {
                        if let item = store.randomItem() { windowSession.openDetails(item) }
                    } label: {
                        Label("Surprise Me", systemImage: "shuffle")
                    }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .help("Open a random title from this homepage (⇧⌘R)")
                }

                Button {
                    store.load(provider: preferences.discoverProvider, force: true, configuration: appState.providerDataGeneration)
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .disabled(store.state == .loading || preferences.discoverProvider.isEmpty)
                .help("Reload homepage")
            }
            .padding(.horizontal, 28)

            content
        }
        .task(id: appState.isEngineBootstrapped) {
            guard appState.isEngineBootstrapped else { return }
            await store.refreshProviders(preferences: appState.preferences)
            store.load(provider: appState.preferences.discoverProvider, configuration: appState.providerDataGeneration)
        }
        .onChange(of: appState.preferences.discoverProvider) { _, provider in
            store.load(provider: provider, configuration: appState.providerDataGeneration)
        }
        .onChange(of: appState.extensions.providerGeneration) { _, _ in
            guard appState.isEngineBootstrapped else { return }
            store.load(provider: appState.preferences.discoverProvider, configuration: appState.providerDataGeneration)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !appState.isEngineBootstrapped {
            SkeletonShelves()
        } else if store.homepageProviders.isEmpty {
            ContentUnavailableView {
                Label("No homepages yet", systemImage: "square.grid.2x2")
            } description: {
                Text("Install an extension whose provider has a homepage to browse it here.")
            } actions: {
                Button("Browse Extensions") { windowSession.navigateTo(.extensions) }
            }
            .frame(height: 200)
        } else if store.rows.isEmpty, store.state == .loading {
            SkeletonShelves()
        } else if store.rows.isEmpty, case .failed(let message) = store.state {
            ContentUnavailableView {
                Label("Couldn't load \(store.displayName(for: appState.preferences.discoverProvider))", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { store.load(provider: appState.preferences.discoverProvider, force: true) }
                Button("Network Settings…") { openSettings() }
            }
            .frame(height: 220)
        } else {
            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(store.rows) { row in
                    shelf(row)
                }
                if store.hasNextPage {
                    HStack {
                        Spacer()
                        Button(store.isLoadingMore ? "Loading…" : "Load More") { store.loadMore() }
                            .disabled(store.isLoadingMore)
                        Spacer()
                    }
                }
            }
        }
    }

    private func shelf(_ row: HomePageListDto) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(row.name)
                .font(.headline)
                .padding(.horizontal, 28)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(row.items) { item in
                        Button {
                            windowSession.openDetails(item)
                        } label: {
                            PosterCard(
                                title: item.name,
                                subtitle: [item.year.map(String.init), item.quality, MediaTypeDisplay.name(for: item.type)].compactMap { $0 }.first,
                                posterURL: item.posterUrl,
                                posterHeaders: item.posterHeaders,
                            )
                        }
                        .buttonStyle(.plain)
                        .frame(width: 150)
                        .contextMenu { DiscoverItemMenu(item: item) }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
        }
    }
}

/// Context actions for a browse/search result that isn't in the library yet.
struct DiscoverItemMenu: View {
    @Environment(WindowSession.self) private var windowSession
    let item: SearchResultDto

    var body: some View {
        Button("Open") { windowSession.openDetails(item) }
        Menu("Add to Library") {
            ForEach(WatchType.allCases) { type in
                Button(type.label) {
                    LibraryStore.shared.perform { try LibraryStore.shared.upsertLibraryEntry(details: LibraryStore.shared.detailsPreview(for: item), watchType: type) }
                }
            }
        }
        AddToPageMenu(details: LibraryStore.shared.detailsPreview(for: item))
        Button("Search All Providers") {
            windowSession.searchQuery = item.name
            windowSession.navigateTo(.search)
            windowSession.commitSearch()
        }
    }
}

/// Placeholder shelves while a homepage loads (no spinners on Home).
/// Placeholder shelves while the homepage loads. The pulse is driven by a
/// task that exists only while this view is on screen in an active window,
/// and it settles after `maximumPulses` (Remediation 1.1): a load that never
/// finishes, or a window in the background, no longer repaints forever.
struct SkeletonShelves: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive
    @State private var pulse = false
    static let pulseInterval: Duration = .milliseconds(900)
    static let maximumPulses = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.cardSurface).frame(width: 160, height: 16)
                    HStack(spacing: 16) {
                        ForEach(0..<6, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.cardSurface)
                                .frame(width: 150, height: 225)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 28)
        .opacity(pulse ? 0.55 : 1)
        // Restarted when the window becomes active; cancelled when it is not or the view goes away.
        .task(id: appearsActive && !reduceMotion) {
            guard appearsActive, !reduceMotion else {
                pulse = false
                return
            }
            for _ in 0..<Self.maximumPulses {
                withAnimation(.easeInOut(duration: 0.9)) { pulse.toggle() }
                do { try await Task.sleep(for: Self.pulseInterval) } catch { break }
            }
            withAnimation(.easeOut(duration: 0.3)) { pulse = false }
        }
        .accessibilityLabel("Loading")
    }
}

