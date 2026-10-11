import SwiftUI

/// One of the user's library pages (ADR-0021): whole titles as posters and
/// single episodes as 16:9 cards, filtered by the window's search field.
struct LibraryPageView: View {
    let pageID: String

    @Environment(WindowSession.self) private var windowSession
    @Environment(AppState.self) private var appState
    @State private var cache = Cache()

    /// The page as last read, reused until the library, the sort or the
    /// filter changes: hovering re-renders the body.
    @MainActor
    final class Cache {
        struct Key: Equatable {
            var version: UInt64
            var pageID: String
            var options: LibraryViewOptions
            var query: String
        }

        private var key: Key?
        private(set) var page: LibraryPageSummary?
        private(set) var content = Content()

        func update(_ key: Key, _ make: () -> (LibraryPageSummary?, Content)) {
            guard key != self.key else { return }
            (page, content) = make()
            self.key = key
        }
    }

    /// A page's entries split for display, with each episode's history.
    struct Content {
        var titles: [LibraryPageEntry] = []
        var episodes: [LibraryPageEntry] = []
        var progress: [String: EpisodeProgressSnapshot] = [:]

        var isEmpty: Bool { titles.isEmpty && episodes.isEmpty }
    }

    private var optionsKey: String { "page:\(pageID)" }

    private var options: LibraryViewOptions {
        appState.preferences.libraryViewOptions[optionsKey] ?? LibraryViewOptions()
    }

    var body: some View {
        let query = windowSession.libraryFilter
        let _ = cache.update(.init(version: LibraryStore.shared.version, pageID: pageID, options: options, query: query)) {
            let store = LibraryStore.shared
            let page = store.readForDisplay(or: nil, { try store.page(id: pageID) })
            let entries = store.readForDisplay(or: [], { try store.pageEntries(pageID: pageID) })
            return (page, Self.content(entries, query: query, options: options))
        }
        let content = cache.content

        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                if let page = cache.page {
                    header(page)
                    if content.isEmpty {
                        ContentUnavailableView(
                            query.isEmpty ? "Nothing on \(page.name) yet" : "No matches for “\(query)”",
                            systemImage: query.isEmpty ? "rectangle.stack" : "magnifyingglass",
                            description: Text(query.isEmpty
                                ? "Right-click a title or an episode anywhere in CloudStream and choose Add to Page."
                                : "Check your spelling or clear the filter."),
                        )
                        .frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        sections(content)
                    }
                } else {
                    ContentUnavailableView("Page Not Found", systemImage: "rectangle.stack",
                                           description: Text("This page was deleted."))
                        .frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 16)
            .padding(.bottom, 48)
        }
        .navigationTitle(cache.page?.name ?? "Page")
    }

    // MARK: - Layout

    private func header(_ page: LibraryPageSummary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if page.count > 0 {
                Text(Self.countLabel(page))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            sortMenu
            Menu {
                Button("Rename Page…") {
                    windowSession.pageEditor = PageEditorRequest(mode: .rename(pageID: page.id, currentName: page.name))
                }
                Button("Delete Page…", role: .destructive) { windowSession.pageToDelete = page }
            } label: {
                Image(systemName: "ellipsis.circle").imageScale(.large)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Page Actions")
            .help("Rename or delete this page")
        }
    }

    private var sortMenu: some View {
        let byName = Binding(
            get: { options.sort == .alphabetical },
            set: { update(\.sort, $0 ? .alphabetical : .dateAdded) },
        )
        return Menu {
            Picker("Sort By", selection: byName) {
                Text(LibrarySortOrder.dateAdded.title).tag(false)
                Text(LibrarySortOrder.alphabetical.title).tag(true)
            }
            .pickerStyle(.inline)
            let directions = (byName.wrappedValue ? LibrarySortOrder.alphabetical : .dateAdded).directionTitles
            if let directions {
                Picker("Order", selection: Binding(get: { options.reversed }, set: { update(\.reversed, $0) })) {
                    Text(directions.natural).tag(false)
                    Text(directions.reversed).tag(true)
                }
                .pickerStyle(.inline)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down.circle").imageScale(.large)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Sort")
        .help("Sort this page")
    }

    @ViewBuilder
    private func sections(_ content: Content) -> some View {
        if !content.titles.isEmpty {
            section("Titles", count: content.titles.count) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 20)], spacing: 24) {
                    ForEach(content.titles, id: \.id) { entry in
                        PageEntryCard(entry: entry, progress: nil)
                    }
                }
            }
        }
        if !content.episodes.isEmpty {
            section("Episodes", count: content.episodes.count) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 20)], spacing: 24) {
                    ForEach(content.episodes, id: \.id) { entry in
                        PageEntryCard(entry: entry, progress: content.progress[entry.id])
                    }
                }
            }
        }
    }

    private func section(_ title: String, count: Int, @ViewBuilder grid: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.title3.weight(.semibold))
                Text("\(count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            grid()
        }
    }

    private func update<Value>(_ keyPath: WritableKeyPath<LibraryViewOptions, Value>, _ value: Value) {
        var updated = options
        updated[keyPath: keyPath] = value
        appState.preferences.libraryViewOptions[optionsKey] = updated
    }

    // MARK: - Pure helpers (unit-tested)

    /// "2 titles · 5 episodes".
    static func countLabel(_ page: LibraryPageSummary) -> String {
        [page.titleCount > 0 ? "\(page.titleCount) \(page.titleCount == 1 ? "title" : "titles")" : nil,
         page.episodeCount > 0 ? "\(page.episodeCount) \(page.episodeCount == 1 ? "episode" : "episodes")" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// Filters by title or episode name and sorts: newest first by default,
    /// or by name (episodes by show, then season and number).
    static func content(_ entries: [LibraryPageEntry], query rawQuery: String, options: LibraryViewOptions) -> Content {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = query.isEmpty ? entries : entries.filter {
            $0.title.localizedStandardContains(query) || ($0.episodeName?.localizedStandardContains(query) ?? false)
        }
        let byName = options.sort == .alphabetical
        func ordered(_ lhs: LibraryPageEntry, _ rhs: LibraryPageEntry) -> Bool {
            if byName {
                switch lhs.title.localizedStandardCompare(rhs.title) {
                case .orderedAscending: return !options.reversed
                case .orderedDescending: return options.reversed
                case .orderedSame:
                    let left = (lhs.season ?? 0, lhs.episode ?? 0), right = (rhs.season ?? 0, rhs.episode ?? 0)
                    if left != right { return options.reversed ? left > right : left < right }
                }
            } else if lhs.addedAt != rhs.addedAt {
                return options.reversed ? lhs.addedAt < rhs.addedAt : lhs.addedAt > rhs.addedAt
            }
            return lhs.id < rhs.id
        }
        let sorted = matching.sorted(by: ordered)
        let episodes = sorted.filter(\.isEpisode)
        var progress: [String: EpisodeProgressSnapshot] = [:]
        for (itemID, group) in Dictionary(grouping: episodes, by: \.itemID) {
            let history = LibraryStore.shared.readForDisplay(or: [:], { try LibraryStore.shared.episodeProgress(itemID: itemID) })
            for entry in group { if let data = entry.episodeData { progress[entry.id] = history[data] } }
        }
        return Content(titles: sorted.filter { !$0.isEpisode }, episodes: episodes, progress: progress)
    }
}

/// A page entry as a card: a poster that opens the title, or a 16:9
/// episode card that plays the episode. Used on pages and the Home row.
struct PageEntryCard: View {
    let entry: LibraryPageEntry
    let progress: EpisodeProgressSnapshot?
    @Environment(WindowSession.self) private var windowSession
    @Environment(AppState.self) private var appState

    var body: some View {
        Button {
            if entry.isEpisode { LibraryStore.shared.playPageEpisode(entry, appState: appState) } else { openTitle() }
        } label: {
            if entry.isEpisode {
                EpisodeCard(title: [entry.episodeLabel, entry.episodeName].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "Episode",
                            showTitle: entry.title,
                            thumbnailURL: entry.episodeThumbnailURL ?? entry.bannerURL ?? entry.posterURL,
                            isDub: entry.audio == "dub", progress: progress)
            } else {
                PosterCard(title: entry.title, subtitle: MediaTypeDisplay.name(for: entry.mediaType),
                           posterURL: entry.posterURL ?? entry.bannerURL)
            }
        }
        .buttonStyle(.plain)
        .help(entry.isEpisode ? "Play this episode" : "Open \(entry.title)")
        .contextMenu {
            let details = LibraryStore.shared.detailsPreview(for: entry)
            if entry.isEpisode {
                Button("Play Episode") { LibraryStore.shared.playPageEpisode(entry, appState: appState) }
                Button("Open Show", action: openTitle)
            } else {
                Button("Open", action: openTitle)
            }
            AddToPageMenu(details: details, episode: entry.episodeDto)
            Divider()
            Button("Remove from Page", role: .destructive) {
                LibraryStore.shared.perform { try LibraryStore.shared.removePageEntry(id: entry.id) }
            }
        }
    }

    private func openTitle() {
        windowSession.openLibraryItem(id: entry.itemID, provider: entry.providerName,
                                      providerID: entry.providerID, url: entry.providerURL)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
