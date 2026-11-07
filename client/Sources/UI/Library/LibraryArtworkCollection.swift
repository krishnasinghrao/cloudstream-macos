import Observation
import SwiftUI

enum LibraryArtworkCategory: String, CaseIterable, Identifiable {
    case landscape, portrait, square, unclassified
    var id: String { rawValue }
    var title: String {
        switch self {
        case .landscape: "Landscape"
        case .portrait: "Portrait"
        case .square: "Square"
        case .unclassified: "Unclassified"
        }
    }

    init(geometry: ArtworkGeometry?) {
        guard let geometry else { self = .unclassified; return }
        if geometry.isLandscape { self = .landscape }
        else if geometry.isPortrait { self = .portrait }
        else { self = .square }
    }

    var minimumWidth: CGFloat {
        switch self {
        case .landscape: 240
        case .square: 190
        case .portrait, .unclassified: 160
        }
    }
}

/// Plain layout inputs are captured with the library's arrangement, not read
/// repeatedly from SwiftData as individual images arrive or cards hover.
struct LibraryArtworkItem: Identifiable, Hashable {
    let id: String
    let request: ArtworkRequest?

    init(id: String, url: String?) {
        self.id = id
        request = ArtworkRequest(url: url)
    }
}

@MainActor @Observable
final class LibraryArtworkCatalog {
    private var geometries: [String: ArtworkGeometry] = [:]
    private(set) var isPrepared = false
    @ObservationIgnored private var active: [String: LibraryArtworkItem] = [:]
    @ObservationIgnored private var requests: [String: ArtworkRequest] = [:]
    @ObservationIgnored private var pending: [String: (request: ArtworkRequest, geometry: ArtworkGeometry)] = [:]
    @ObservationIgnored private var publish: Task<Void, Never>?

    func geometry(for entry: LibraryArtworkItem) -> ArtworkGeometry? {
        guard requests[entry.id] == entry.request else { return nil }
        return geometries[entry.id]
    }

    func snapshot(for entries: [LibraryArtworkItem]) -> [String: ArtworkGeometry] {
        let known = geometries
        return Dictionary(entries.compactMap { entry in
            guard requests[entry.id] == entry.request, let geometry = known[entry.id] else { return nil }
            return (entry.id, geometry)
        }, uniquingKeysWith: { first, _ in first })
    }

    func prepare(_ entries: [LibraryArtworkItem], cache: ImageCache) async {
        isPrepared = false
        active = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        await cache.prepareGeometryIndex()
        guard !Task.isCancelled else { return }
        var updated: [String: ArtworkGeometry] = [:]
        var nextRequests: [String: ArtworkRequest] = [:]
        for entry in entries {
            guard let request = entry.request else { continue }
            nextRequests[entry.id] = request
            if let geometry = cache.geometry(for: request) ?? geometry(for: entry) {
                updated[entry.id] = geometry
            }
        }
        requests = nextRequests
        if updated != geometries { geometries = updated }
        isPrepared = true
    }

    func record(_ geometry: ArtworkGeometry, for entry: LibraryArtworkItem) {
        guard let request = entry.request, active[entry.id]?.request == request else { return }
        guard requests[entry.id] != request || geometries[entry.id] != geometry else { return }
        pending[entry.id] = (request, geometry)
        guard publish == nil else { return }
        // One layout update for a group of image completions. No global cache
        // observation, eager network prefetch, or full-library bitmap retention.
        publish = Task {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            var updated = geometries
            for (id, value) in pending where active[id]?.request == value.request {
                requests[id] = value.request
                updated[id] = value.geometry
            }
            if updated != geometries { geometries = updated }
            pending.removeAll()
            publish = nil
        }
    }
}

/// Justified rows: every card in a row shares one height and the row is
/// filled edge to edge, so each artwork keeps its true shape. A 16:9 card is
/// as tall as the posters beside it and correspondingly wider, instead of
/// being squeezed into a poster-width column. Reading order is the sort order,
/// left to right, row by row.
enum LibraryGalleryLayout {
    static let spacing: CGFloat = 18
    static let rowSpacing: CGFloat = 24
    /// A full row may stretch at most this far above the target height; past
    /// that the next card joins the row instead.
    static let maximumStretch: CGFloat = 1.4

    struct Slot: Equatable, Identifiable {
        let id: String
        let width: CGFloat
    }

    struct Row: Equatable, Identifiable {
        let slots: [Slot]
        /// Height of the artwork; captions sit below it.
        let height: CGFloat
        var id: String { slots.first?.id ?? "" }
    }

    /// The row height the layout aims for: posters a little larger than in
    /// the grid, growing gently with the window.
    static func targetHeight(width: CGFloat) -> CGFloat {
        guard width.isFinite, width > 0 else { return 240 }
        return min(320, max(220, width / 4))
    }

    /// The shape a card is laid out with: the measured ratio, bounded like the
    /// cards themselves, or a poster's 2:3 while it is unknown.
    static func ratio(_ value: CGFloat?) -> CGFloat {
        guard let value, value.isFinite, value > 0 else { return 2 / 3 }
        return min(2.2, max(0.55, value))
    }

    /// Which cards share a row. Greedy and deterministic: a row closes at the
    /// card count whose height lands closest to the target.
    static func rowMembership(ids: [String], ratios: [String: CGFloat], width: CGFloat,
                              targetHeight: CGFloat, spacing: CGFloat = spacing) -> [[String]] {
        guard width.isFinite, width > 0, targetHeight > 0 else { return ids.map { [$0] } }
        func height(_ sum: CGFloat, count: Int) -> CGFloat {
            max(1, width - CGFloat(count - 1) * spacing) / sum
        }
        var rows: [[String]] = []
        var current: [String] = []
        var sum: CGFloat = 0
        for id in ids {
            let next = ratio(ratios[id])
            let filled = height(sum + next, count: current.count + 1)
            if filled > targetHeight {
                current.append(id)
                sum += next
                continue
            }
            // Adding this card fills the row. Close without it when that row
            // is nearer the target and not stretched too far.
            let without = current.isEmpty ? .infinity : height(sum, count: current.count)
            if without <= targetHeight * maximumStretch, without / targetHeight < targetHeight / filled {
                rows.append(current)
                current = [id]
                sum = next
                if height(sum, count: 1) <= targetHeight {
                    rows.append(current)
                    current = []
                    sum = 0
                }
            } else {
                rows.append(current + [id])
                current = []
                sum = 0
            }
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    /// Sizes for fixed membership. Full rows fill the width exactly; the last
    /// row keeps the target height and stays leading-aligned.
    static func rows(membership: [[String]], ratios: [String: CGFloat], width: CGFloat,
                     targetHeight: CGFloat, spacing: CGFloat = spacing) -> [Row] {
        membership.enumerated().map { index, ids in
            let shapes = ids.map { ratio(ratios[$0]) }
            let available = max(1, width - CGFloat(ids.count - 1) * spacing)
            let fitted = available / shapes.reduce(0, +)
            let height = index == membership.count - 1 ? min(targetHeight, fitted) : fitted
            return Row(slots: zip(ids, shapes).map { Slot(id: $0, width: $1 * height) }, height: height)
        }
    }
}

/// Row membership is kept while the cards and width stay the same, so an
/// image that finishes loading resizes its own row without moving any card
/// into a different row.
@MainActor
final class LibraryGalleryArrangement {
    private var ids: [String] = []
    private var width: CGFloat = 0
    private(set) var membership: [[String]] = []

    func update(_ entries: [LibraryArtworkItem], width: CGFloat, catalog: LibraryArtworkCatalog) -> [LibraryGalleryLayout.Row] {
        let ratios = catalog.snapshot(for: entries).mapValues(\.cardAspectRatio)
        let target = LibraryGalleryLayout.targetHeight(width: width)
        let nextIDs = entries.map(\.id)
        // Whole points: sub-point resize noise must not regroup the rows.
        let nextWidth = width.rounded(.down)
        if ids != nextIDs || self.width != nextWidth {
            ids = nextIDs
            self.width = nextWidth
            membership = LibraryGalleryLayout.rowMembership(ids: ids, ratios: ratios, width: nextWidth, targetHeight: target)
        }
        return LibraryGalleryLayout.rows(membership: membership, ratios: ratios, width: nextWidth, targetHeight: target)
    }
}

struct LibraryLayoutPicker: View {
    @Binding var selection: LibraryDisplayMode

    var body: some View {
        Menu {
            Picker("Layout", selection: $selection) {
                ForEach(LibraryDisplayMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(selection.title, systemImage: selection.symbol)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Library Layout")
        .accessibilityValue(selection.title)
        .help("Choose a grid, artwork categories, or a gallery that keeps each artwork's shape")
    }
}

/// Shared by watch-state collections and the titles on custom pages. The
/// gallery's rows are lazy; ten thousand titles do not instantiate ten
/// thousand image loaders. The card owns loading and reports its measured geometry.
struct LibraryArtworkCollection<Card: View>: View {
    let entries: [LibraryArtworkItem]
    let mode: LibraryDisplayMode
    var imageCache: ImageCache = .shared
    let card: (LibraryArtworkItem, ArtworkGeometry?, LibraryArtworkCatalog) -> Card

    init(entries: [LibraryArtworkItem], mode: LibraryDisplayMode, imageCache: ImageCache = .shared,
         catalog: LibraryArtworkCatalog? = nil, @ViewBuilder card: @escaping (LibraryArtworkItem, ArtworkGeometry?, LibraryArtworkCatalog) -> Card) {
        self.entries = entries
        self.mode = mode
        self.imageCache = imageCache
        _catalog = State(initialValue: catalog ?? LibraryArtworkCatalog())
        self.card = card
    }

    @State private var catalog = LibraryArtworkCatalog()
    @State private var gallery = LibraryGalleryArrangement()
    /// nil until measured: grouping gallery rows at a guessed width would
    /// regroup every row a frame later.
    @State private var width: CGFloat?

    var body: some View {
        Group {
            if mode != .grid && (!catalog.isPrepared || (mode == .gallery && width == nil)) {
                ProgressView("Loading Library…").frame(maxWidth: .infinity, minHeight: 180)
            } else {
                switch mode {
                case .grid:
                    grid(entries, minimum: 160)
                case .categorized:
                    categorized
                case .gallery:
                    galleryRows
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task(id: entries) { await catalog.prepare(entries, cache: imageCache) }
    }

    private func grid(_ items: [LibraryArtworkItem], minimum: CGFloat) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum, maximum: minimum == 160 ? 200 : minimum * 1.4), spacing: 20, alignment: .top)], spacing: 24) {
            ForEach(items) { entry in card(entry, catalog.geometry(for: entry), catalog) }
        }
    }

    private var categorized: some View {
        let known = catalog.snapshot(for: entries)
        let groups = Dictionary(grouping: entries) { LibraryArtworkCategory(geometry: known[$0.id]) }
        return LazyVStack(alignment: .leading, spacing: 32) {
            ForEach(LibraryArtworkCategory.allCases) { category in
                if let items = groups[category], !items.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(category.title).font(.title3.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        if category == .unclassified {
                            Text("Artwork is grouped as its dimensions become available.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        grid(items, minimum: category.minimumWidth)
                    }
                }
            }
        }
    }

    private var galleryRows: some View {
        let rows = gallery.update(entries, width: width ?? 0, catalog: catalog)
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return LazyVStack(alignment: .leading, spacing: LibraryGalleryLayout.rowSpacing) {
            ForEach(rows) { row in
                HStack(alignment: .top, spacing: LibraryGalleryLayout.spacing) {
                    ForEach(row.slots) { slot in
                        if let entry = byID[slot.id] {
                            card(entry, catalog.geometry(for: entry), catalog)
                                .frame(width: slot.width)
                                .environment(\.artworkCardShape, .natural)
                        }
                    }
                }
            }
        }
    }
}
