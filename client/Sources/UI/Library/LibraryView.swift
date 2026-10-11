import SwiftUI

/// Library view: one collection, filtered by the window's global search field, real sort picker, and
/// an adaptive poster grid whose cards fill their cells.
struct LibraryView: View {
    let collection: LibraryCollection

    @Environment(WindowSession.self) private var windowSession
    @Environment(AppState.self) private var appState
    @State private var providerAssignment: ProviderAssignment?
    /// Non-nil while bulk-selecting.
    @State private var selection: Set<String>?
    @State private var confirmBulkRemove = false
    /// The card being dragged to a new place.
    @State private var draggedID: String?
    /// The arrangement being tried during a drag; saved once when it ends.
    @State private var dragOrder: [String]?
    /// When the cards last shifted: lets that animation settle before the
    /// card now passing under the pointer can trigger another shift.
    @State private var lastShift = Date.distantPast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrangement = Arrangement()

    typealias SortOrder = LibrarySortOrder

    /// The collection as last read and arranged, reused until the library,
    /// the collection's options or the search change: selecting, dragging
    /// and hovering re-render the body, and reading and sorting 10,000
    /// titles each time froze the window.
    @MainActor
    final class Arrangement {
        struct Key: Equatable {
            var version: UInt64
            var collection: LibraryCollection
            var options: LibraryViewOptions
            var query: String
        }

        private var key: Key?
        private(set) var all: [StoredMediaItem] = []
        private(set) var arranged: [StoredMediaItem] = []

        func update(_ key: Key, _ make: () -> (all: [StoredMediaItem], arranged: [StoredMediaItem])) {
            guard key != self.key else { return }
            (all, arranged) = make()
            self.key = key
        }
    }

    /// Sort and filters persist per collection (`UserPreferences`).
    private var options: LibraryViewOptions {
        appState.preferences.libraryViewOptions[collection.rawValue] ?? LibraryViewOptions()
    }

    private func option<Value>(_ keyPath: WritableKeyPath<LibraryViewOptions, Value>) -> Binding<Value> {
        Binding(
            get: { options[keyPath: keyPath] },
            set: { value in
                var updated = options
                updated[keyPath: keyPath] = value
                appState.preferences.libraryViewOptions[collection.rawValue] = updated
            },
        )
    }

    /// A remembered filter only applies while the collection still has
    /// titles it can match; otherwise it would hide everything unseen.
    private func activeFilters(in items: [StoredMediaItem]) -> (category: MediaCategory?, provider: String?) {
        let options = options
        let category = options.category.flatMap(MediaCategory.init(rawValue:))
            .flatMap { wanted in items.contains { MediaCategory.of($0.mediaType) == wanted } ? wanted : nil }
        let provider = options.provider
            .flatMap { wanted in items.contains { $0.providerName == wanted } ? wanted : nil }
        return (category, provider)
    }

    /// Observation hook — see LibraryStore.version.
    private var storeVersion: UInt64 { LibraryStore.shared.version }

    var body: some View {
        // At most one store read per library change: the menu, the filters
        // and every card's context menu share it.
        let _ = arrangement.update(.init(version: storeVersion, collection: collection, options: options,
                                         query: windowSession.libraryFilter)) {
            let all = unfilteredItems()
            return (all, filteredAndSortedItems(all))
        }
        let all = arrangement.all
        let rearrangeable = canRearrange(in: all)
        let items = Self.applying(dragOrder, to: arrangement.arranged)
        let searchQuery = windowSession.libraryFilter

        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if !items.isEmpty {
                        Text("\(items.count) \(items.count == 1 ? "title" : "titles")")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    viewOptionsMenu(all)

                    Button(selection == nil ? "Select" : "Done") {
                        selection = selection == nil ? [] : nil
                    }
                    .disabled(items.isEmpty && selection == nil)
                }

                if let selection {
                    bulkBar(selection: selection, items: items)
                }

                if items.isEmpty {
                    ContentUnavailableView(
                        searchQuery.isEmpty
                            ? "No titles in \(collection.title)"
                            : "No matches for “\(searchQuery)”",
                        systemImage: searchQuery.isEmpty ? collection.icon : "magnifyingglass",
                        description: Text(
                            searchQuery.isEmpty
                                ? collection.emptyMessage
                                : "Check your spelling or clear the filter.",
                        ),
                    )
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 20)],
                        spacing: 24,
                    ) {
                        ForEach(items) { item in
                            Button {
                                if selection != nil {
                                    toggleSelection(item.id)
                                } else {
                                    windowSession.openLibraryItem(
                                        id: item.id,
                                        provider: item.providerName,
                                        providerID: item.providerID,
                                        url: item.providerURL,
                                    )
                                }
                            } label: {
                                PosterCard(
                                    title: item.title,
                                    subtitle: subtitle(for: item),
                                    posterURL: item.posterURL ?? item.bannerURL,
                                    progressFraction: item.displayProgress,
                                    highlightBadge: item.newEpisodeCount > 0 ? "\(item.newEpisodeCount) NEW" : nil,
                                    isSelected: selection.map { $0.contains(item.id) },
                                )
                            }
                            .buttonStyle(.plain)
                            // The lifted card travels with the pointer; its slot stays open.
                            .opacity(draggedID == item.id ? 0 : 1)
                            .onDrag {
                                guard canRearrange else { return NSItemProvider() }
                                draggedID = item.id
                                return NSItemProvider(object: item.id as NSString)
                            } preview: {
                                PosterCard(
                                    title: item.title,
                                    subtitle: subtitle(for: item),
                                    posterURL: item.posterURL ?? item.bannerURL,
                                )
                                .frame(width: 170)
                            }
                            .onDrop(of: [.text], delegate: CardReorderDelegate(
                                targetID: item.id,
                                draggedID: draggedID,
                                move: { dragged in move(dragged, onto: item.id, in: items) },
                                finish: finishDrag,
                            ))
                            .contextMenu {
                                Menu("Watch Status") {
                                    ForEach(WatchType.allCases) { type in
                                        Button(type.label) {
                                            setWatchType(type, on: item)
                                        }
                                    }
                                }
                                Button {
                                    toggleFavorite(item)
                                } label: {
                                    Label(item.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                                          systemImage: item.isFavorite ? "heart.slash" : "heart")
                                }
                                AddToPageMenu(details: LibraryStore.shared.detailsPreview(for: item))
                                if item.mediaType != "Download", appState.isProviderMissing(item.providerID) {
                                    Button("Choose Provider…") {
                                        providerAssignment = ProviderAssignment(id: item.id, title: item.title,
                                            profileID: ProfileStore.shared.activeID,
                                            owner: LibraryStore.shared.identityOwnerToken)
                                    }
                                }
                                if rearrangeable, items.count > 1 {
                                    Divider()
                                    Button("Move to Beginning") { place(item, atFront: true, in: items) }
                                        .disabled(items.first?.id == item.id)
                                    Button("Move to End") { place(item, atFront: false, in: items) }
                                        .disabled(items.last?.id == item.id)
                                }
                                Divider()
                                Button("Remove from Library", role: .destructive) {
                                    remove(item)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 16)
            .padding(.bottom, 48)
        }
        // A release in the gaps between cards still lands.
        .onDrop(of: [.text], delegate: CardReorderDelegate(targetID: nil, draggedID: draggedID, move: { _ in }, finish: finishDrag))
        // SwiftUI reports no end for a drag released where nothing accepts
        // it (outside the window): the button coming up is the end.
        .task(id: draggedID) {
            guard draggedID != nil else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    finishDrag()
                    return
                }
            }
        }
        .onChange(of: collection) { _, _ in
            selection = nil
        }
        .sheet(item: $providerAssignment) { assignment in
            ProviderAssignmentSheet(assignment: assignment)
        }
        .onExitCommand { selection = nil }
        .confirmationDialog(
            "Remove \(selection?.count ?? 0) titles from the library?",
            isPresented: $confirmBulkRemove,
        ) {
            Button("Remove", role: .destructive) {
                LibraryStore.shared.perform { try LibraryStore.shared.setWatchType(itemIDs: selection ?? [], watchType: nil) }
                selection = []
            }
        } message: {
            Text("Resume positions and favorites are kept.")
        }
    }

    // MARK: - Filters & bulk actions

    /// Single compact menu combining sort order and type/provider filters.
    private func viewOptionsMenu(_ all: [StoredMediaItem]) -> some View {
        let categories = Set(all.map { MediaCategory.of($0.mediaType) })
        let providers = Set(all.map(\.providerName)).sorted()
        let filters = activeFilters(in: all)
        let active = filters.category != nil || filters.provider != nil
        let directions = options.sort.directionTitles
        let categoryFilter = Binding<MediaCategory?>(
            get: { filters.category },
            set: { option(\.category).wrappedValue = $0?.rawValue },
        )
        let providerFilter = Binding<String?>(
            get: { filters.provider },
            set: { option(\.provider).wrappedValue = $0 },
        )
        return Menu {
            Picker("Sort By", selection: option(\.sort)) {
                ForEach(SortOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
            .pickerStyle(.inline)
            if let directions {
                Picker("Order", selection: option(\.reversed)) {
                    Text(directions.natural).tag(false)
                    Text(directions.reversed).tag(true)
                }
                .pickerStyle(.inline)
            }
            Divider()
            Picker("Type", selection: categoryFilter) {
                Text("All Types").tag(MediaCategory?.none)
                ForEach(MediaCategory.allCases.filter(categories.contains)) { category in
                    Label(category.rawValue, systemImage: category.symbolName).tag(MediaCategory?.some(category))
                }
            }
            .pickerStyle(.inline)
            if providers.count > 1 {
                Picker("Provider", selection: providerFilter) {
                    Text("All Providers").tag(String?.none)
                    ForEach(providers, id: \.self) { provider in
                        Text(provider).tag(String?.some(provider))
                    }
                }
                .pickerStyle(.inline)
            }
            if active {
                Divider()
                Button("Clear Filters") {
                    categoryFilter.wrappedValue = nil
                    providerFilter.wrappedValue = nil
                }
            }
        } label: {
            Image(systemName: active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .imageScale(.large)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Sort and Filter")
        .help("Sort and filter")
    }

    private func bulkBar(selection: Set<String>, items: [StoredMediaItem]) -> some View {
        HStack(spacing: 12) {
            Text(selection.isEmpty ? "Select titles" : "\(selection.count) selected")
                .font(.callout.weight(.medium))
            Button(selection.count == items.count ? "Deselect All" : "Select All") {
                self.selection = selection.count == items.count ? [] : Set(items.map(\.id))
            }
            .buttonStyle(.borderless)
            Spacer()
            Menu("Change Status") {
                ForEach(WatchType.allCases) { type in
                    Button(type.label) {
                        LibraryStore.shared.perform { try LibraryStore.shared.setWatchType(itemIDs: selection, watchType: type) }
                        self.selection = []
                    }
                }
            }
            .fixedSize()
            .disabled(selection.isEmpty)
            Button("Merge") {
                LibraryStore.shared.perform { try LibraryStore.shared.mergeTitles(itemIDs: Array(selection)) }
                self.selection = []
            }
            .disabled(selection.count < 2)
            .help("Combine these titles into one entry with several sources, for the same show saved from different providers.")
            Button("Remove…", role: .destructive) { confirmBulkRemove = true }
                .disabled(selection.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.cardSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func toggleSelection(_ id: String) {
        guard var current = selection else { return }
        if current.contains(id) { current.remove(id) } else { current.insert(id) }
        selection = current
    }

    // MARK: - Query & Sort Helpers

    private func unfilteredItems() -> [StoredMediaItem] {
        let _ = storeVersion
        return Self.items(in: collection)
    }

    /// Every title of a collection, unsorted (the Home shelf reads the same).
    static func items(in collection: LibraryCollection) -> [StoredMediaItem] {
        let store = LibraryStore.shared
        switch collection {
        case .watching: return store.readForDisplay(or: [], { try store.items(withWatchType: .watching) })
        case .planToWatch: return store.readForDisplay(or: [], { try store.items(withWatchType: .planToWatch) })
        case .completed: return store.readForDisplay(or: [], { try store.items(withWatchType: .completed) })
        case .onHold: return store.readForDisplay(or: [], { try store.items(withWatchType: .onHold) })
        case .dropped: return store.readForDisplay(or: [], { try store.items(withWatchType: .dropped) })
        case .favorites: return store.readForDisplay(or: [], { try store.favorites })
        }
    }

    private func filteredAndSortedItems(_ all: [StoredMediaItem]) -> [StoredMediaItem] {
        var raw = all
        let filters = activeFilters(in: raw)
        if let category = filters.category {
            raw = raw.filter { MediaCategory.of($0.mediaType) == category }
        }
        if let provider = filters.provider {
            raw = raw.filter { $0.providerName == provider }
        }
        return Self.arranged(raw, query: windowSession.libraryFilter, options: options, collection: collection)
    }

    /// A collection's titles in its remembered sort (the Home shelf shows
    /// the same order as the collection's own page).
    static func arranged(_ items: [StoredMediaItem], query: String = "", options: LibraryViewOptions,
                         collection: LibraryCollection) -> [StoredMediaItem] {
        filterAndSort(items, query: query, order: options.sort, reversed: options.reversed,
                      customPosition: collection == .favorites ? \.favoriteSortPosition : \.sortPosition)
    }

    // MARK: - Drag to rearrange

    /// Cards can be rearranged while every title of the collection is shown;
    /// a filtered or searched subset has no complete order to save.
    private var canRearrange: Bool { canRearrange(in: arrangement.all) }

    private func canRearrange(in all: [StoredMediaItem]) -> Bool {
        let filters = activeFilters(in: all)
        return selection == nil && filters.category == nil && filters.provider == nil
            && windowSession.libraryFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static let shiftDuration = 0.28

    /// Slides the dragged card into the target's place, starting from
    /// whatever order is shown. Nothing is saved until the drag ends.
    private func move(_ dragged: String, onto target: String, in items: [StoredMediaItem]) {
        guard canRearrange, Date().timeIntervalSince(lastShift) > Self.shiftDuration,
              let order = Self.reordered(items.map(\.id), moving: dragged, onto: target) else { return }
        lastShift = Date()
        withAnimation(reduceMotion ? nil : .smooth(duration: Self.shiftDuration)) { dragOrder = order }
    }

    /// Saves the tried arrangement as the collection's custom order.
    private func finishDrag() {
        guard draggedID != nil || dragOrder != nil else { return }
        if let dragOrder {
            let store = LibraryStore.shared
            if store.perform({ try store.setCustomOrder(itemIDs: dragOrder, favorites: collection == .favorites) }),
               options.sort != .custom {
                option(\.sort).wrappedValue = .custom
            }
        }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) { draggedID = nil }
        dragOrder = nil
    }

    /// The keyboard and VoiceOver route to the same arrangement as dragging.
    private func place(_ item: StoredMediaItem, atFront: Bool, in items: [StoredMediaItem]) {
        let order = (atFront ? [item.id] : []) + items.map(\.id).filter { $0 != item.id } + (atFront ? [] : [item.id])
        let store = LibraryStore.shared
        guard store.perform({ try store.setCustomOrder(itemIDs: order, favorites: collection == .favorites) }) else { return }
        withAnimation(reduceMotion ? nil : .smooth(duration: Self.shiftDuration)) {
            if options.sort != .custom { option(\.sort).wrappedValue = .custom }
        }
    }

    /// Pure: `items` in the order of `ids`; titles the order does not name keep
    /// their relative order at the end.
    static func applying(_ ids: [String]?, to items: [StoredMediaItem]) -> [StoredMediaItem] {
        guard let ids else { return items }
        let rank = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return items.enumerated().sorted { lhs, rhs in
            (rank[lhs.element.id] ?? Int.max, lhs.offset) < (rank[rhs.element.id] ?? Int.max, rhs.offset)
        }.map(\.element)
    }

    /// Pure: `ids` with `dragged` moved to where `target` is (nil = no change).
    static func reordered(_ ids: [String], moving dragged: String, onto target: String) -> [String]? {
        guard dragged != target, let from = ids.firstIndex(of: dragged), let to = ids.firstIndex(of: target) else { return nil }
        var result = ids
        result.remove(at: from)
        result.insert(dragged, at: to)
        return result
    }

    /// Pure: text filter + sort (unit-tested).
    /// Ties fall back to recent activity; `reversed` flips the primary key
    /// only, and titles without a release year stay last either way.
    static func filterAndSort(_ items: [StoredMediaItem], query rawQuery: String, order: SortOrder,
                              reversed: Bool = false,
                              customPosition: KeyPath<StoredMediaItem, Double?> = \.sortPosition) -> [StoredMediaItem] {
        var raw = items
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            raw = raw.filter { $0.title.localizedStandardContains(query) || ($0.userNote?.localizedStandardContains(query) ?? false) }
        }
        // Each title's keys are read once: reading a SwiftData property inside
        // the comparator cost ~0.8 s for 10,000 titles.
        /// `primary`: negative when `lhs` leads in the natural direction.
        func sorted<Key>(_ items: [StoredMediaItem], by key: (StoredMediaItem) -> Key,
                         _ primary: (Key, Key) -> Int) -> [StoredMediaItem] {
            items.map { (item: $0, key: key($0), updated: $0.lastUpdated, id: $0.id) }
                .sorted { lhs, rhs in
                    let result = primary(lhs.key, rhs.key)
                    if result != 0 { return reversed ? result > 0 : result < 0 }
                    if lhs.updated != rhs.updated { return lhs.updated > rhs.updated }
                    return lhs.id < rhs.id
                }
                .map(\.item)
        }
        func descending<Value: Comparable>(_ lhs: Value, _ rhs: Value) -> Int { lhs == rhs ? 0 : (lhs > rhs ? -1 : 1) }
        func alphabetical(_ lhs: String, _ rhs: String) -> Int {
            switch lhs.localizedStandardCompare(rhs) {
            case .orderedAscending: return -1
            case .orderedDescending: return 1
            case .orderedSame: return 0
            }
        }
        switch order {
        case .recentActivity:
            return sorted(raw, by: \.lastUpdated, descending)
        case .dateAdded:
            return sorted(raw, by: \.createdAt, descending)
        case .releaseYear:
            let years = raw.map { (item: $0, year: $0.releaseYear) }
            let undated = years.filter { $0.year == nil }.map { (item: $0.item, title: $0.item.title) }
            return sorted(years.filter { $0.year != nil }.map(\.item), by: { $0.releaseYear ?? 0 }, descending)
                + undated.sorted { alphabetical($0.title, $1.title) < 0 }.map(\.item)
        case .alphabetical:
            return sorted(raw, by: \.title, alphabetical)
        case .rating:
            return sorted(raw, by: \.userRating, descending)
        case .newEpisodes:
            return sorted(raw, by: \.newEpisodeCount, descending)
        case .custom:
            // Titles not placed yet (added since the last arrangement) lead,
            // newest first; the rest keep the order the user gave them.
            let keyed = raw.map { (item: $0, position: $0[keyPath: customPosition], created: $0.createdAt, id: $0.id) }
            return keyed.filter { $0.position == nil }.sorted { ($0.created, $0.id) > ($1.created, $1.id) }.map(\.item)
                + keyed.filter { $0.position != nil }.sorted { ($0.position ?? 0, $0.id) < ($1.position ?? 0, $1.id) }.map(\.item)
        }
    }

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

    private func toggleFavorite(_ item: StoredMediaItem) {
        let store = LibraryStore.shared
        store.perform { try store.toggleFavorite(details: store.detailsPreview(for: item)) }
    }

    private func remove(_ item: StoredMediaItem) {
        let store = LibraryStore.shared
        store.perform { try store.removeFromLibrary(details: store.detailsPreview(for: item)) }
    }
}


/// Live reordering: a dragged card resting on another one takes its place.
/// `targetID` nil = the space around the cards, which only accepts the drop.
private struct CardReorderDelegate: DropDelegate {
    let targetID: String?
    let draggedID: String?
    let move: (String) -> Void
    let finish: () -> Void

    func validateDrop(info: DropInfo) -> Bool { draggedID != nil }

    func dropEntered(info: DropInfo) { shift() }

    /// Pointer movement keeps asking, so a card that slid under the pointer
    /// while another shift was settling is still acted on.
    func dropUpdated(info: DropInfo) -> DropProposal? {
        shift()
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        finish()
        return true
    }

    private func shift() {
        guard let draggedID, let targetID, draggedID != targetID else { return }
        move(draggedID)
    }
}

struct ProviderAssignment: Identifiable {
    let id: String
    let title: String
    let profileID: UUID
    let owner: ObjectIdentifier?
}

/// An explicit choice for entries whose installation was never recorded or
/// is no longer installed. The store performs the same snapshot-backed
/// atomic rekey. The choice can cover the other unresolved titles saved from
/// the same provider name and host, and is checked against the engine first.
struct ProviderAssignmentSheet: View {
    let assignment: ProviderAssignment
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID = ""
    @State private var failure: String?
    @State private var group: LibraryStore.ReassignmentGroup?
    @State private var includeSiblings = true
    @State private var isChecking = false
    /// The provider whose check failed; saving it again is the user's call.
    @State private var uncheckedID: String?

    private var providers: [LibraryIdentityMigration.Provider] {
        let catalog = LibraryIdentityMigration.catalog(plugins: appState.providers)
        var seen = Set<String>()
        return catalog.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
            .sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
    }

    /// Providers that share a name are told apart by their extension.
    private func label(_ provider: LibraryIdentityMigration.Provider) -> String {
        guard let plugin = appState.providers.first(where: { $0.providerIds?.contains(provider.id) == true }) else {
            return "\(provider.name) — \(provider.id)"
        }
        let language = plugin.language.map { ", \($0.uppercased())" } ?? ""
        return "\(provider.name) — \(plugin.name) v\(plugin.version)\(language)"
    }

    private var siblings: [String] { includeSiblings ? group?.siblings ?? [] : [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose Provider").font(.title2)
            Text("Choose the installed provider for “\(assignment.title)”. Your notes, watch history, and playback settings will be kept.")
            if providers.isEmpty {
                Text("Install a provider from Extensions, then return here.").foregroundStyle(.secondary)
            } else {
                Picker("Provider", selection: $selectedID) {
                    Text("Choose a provider").tag("")
                    ForEach(providers, id: \.id) { provider in
                        Text(label(provider)).tag(provider.id)
                    }
                }
            }
            if let group, !group.siblings.isEmpty {
                Toggle(isOn: $includeSiblings) {
                    Text("Also apply to \(group.siblings.count) other \(group.siblings.count == 1 ? "title" : "titles") saved from “\(group.providerName)”\(group.host.map { " at \($0)" } ?? "")")
                }
            }
            if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if isChecking { ProgressView().controlSize(.small); Text("Checking the provider…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(uncheckedID == selectedID && !selectedID.isEmpty ? "Save Anyway" : "Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedID.isEmpty || isChecking || !appState.isEngineBootstrapped || AppLock.shared.isLocked)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { group = try? LibraryStore.shared.reassignmentGroup(itemID: assignment.id, providers: providers) }
        .onChange(of: AppLock.shared.isLocked) { _, locked in if locked { dismiss() } }
        .onChange(of: ProfileStore.shared.activeID) { _, _ in dismiss() }
        .onChange(of: LibraryStore.shared.identityOwnerToken) { _, _ in dismiss() }
    }

    private var isCurrent: Bool {
        !AppLock.shared.isLocked && appState.isEngineBootstrapped
            && assignment.profileID == ProfileStore.shared.activeID
            && assignment.owner == LibraryStore.shared.identityOwnerToken
    }

    private func save() async {
        let providerID = selectedID
        guard isCurrent else {
            failure = "The library changed. Close this dialog and choose the title again."
            return
        }
        // The chosen provider must actually load this title before the
        // choice is recorded; a second Save overrides a failed check.
        if uncheckedID != providerID, let url = group?.url, !url.isEmpty {
            isChecking = true
            defer { isChecking = false }
            do {
                _ = try await DaemonClient.shared.details(provider: providerID, url: url)
            } catch {
                guard selectedID == providerID else { return }
                uncheckedID = providerID
                failure = "This provider couldn’t load “\(assignment.title)”: \(error.localizedDescription) Choose another provider, or save anyway."
                return
            }
            guard selectedID == providerID, isCurrent else {
                failure = "The library changed. Close this dialog and choose the title again."
                return
            }
        }
        do {
            let store = LibraryStore.shared
            let batch = try store.reassignableBatch(itemID: assignment.id, siblings: siblings, providerID: providerID)
            try store.reassignProvider(itemIDs: batch, providerID: providerID, providers: providers)
            dismiss()
        } catch { failure = error.localizedDescription }
    }
}
