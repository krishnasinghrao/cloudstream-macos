/// Library collection types matching CloudStream's canonical watch states —
/// every state a title can be given is reachable here (nothing strands data).
enum LibraryCollection: String, CaseIterable, Hashable, Identifiable, Sendable {
    case watching
    case planToWatch
    case completed
    case onHold
    case dropped
    case favorites

    var id: String { title }

    init(_ watchType: WatchType) {
        switch watchType {
        case .watching: self = .watching
        case .planToWatch: self = .planToWatch
        case .completed: self = .completed
        case .onHold: self = .onHold
        case .dropped: self = .dropped
        }
    }

    var title: String {
        switch self {
        case .watching: return "Watching"
        case .planToWatch: return "Plan to Watch"
        case .completed: return "Completed"
        case .onHold: return "On Hold"
        case .dropped: return "Dropped"
        case .favorites: return "Favorites"
        }
    }

    var icon: String {
        switch self {
        case .watching: return "play.circle"
        case .planToWatch: return "bookmark"
        case .completed: return "checkmark.circle"
        case .onHold: return "pause.circle"
        case .dropped: return "xmark.circle"
        case .favorites: return "heart"
        }
    }

    var emptyMessage: String {
        switch self {
        case .watching:
            return "Mark titles as Watching from their details screen to track your progress."
        case .planToWatch:
            return "Save titles you want to watch later from their details screen."
        case .completed:
            return "Finished shows and movies will appear here."
        case .onHold:
            return "Park titles here — they stay in your library until you resume them."
        case .dropped:
            return "Titles you've decided against will appear here."
        case .favorites:
            return "Favorite your most-loved titles to quickly access them."
        }
    }
}

/// What the Home screen's library row shows: a built-in collection or one
/// of the user's pages (ADR-0021).
enum HomeShelf: Hashable, Sendable {
    case collection(LibraryCollection)
    case page(id: String)

    static let defaultCollection = LibraryCollection.planToWatch
    static let `default` = HomeShelf.collection(defaultCollection)

    /// Stored form: the collection's raw value, or `page:<id>`.
    var storageValue: String {
        switch self {
        case .collection(let collection): collection.rawValue
        case .page(let id): Self.pagePrefix + id
        }
    }

    init?(storageValue: String) {
        if storageValue.hasPrefix(Self.pagePrefix) {
            let id = String(storageValue.dropFirst(Self.pagePrefix.count))
            guard !id.isEmpty else { return nil }
            self = .page(id: id)
        } else if let collection = LibraryCollection(rawValue: storageValue) {
            self = .collection(collection)
        } else {
            return nil
        }
    }

    private static let pagePrefix = "page:"
}

enum LibrarySortOrder: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Last change of any kind: playback, status, rating, note, favorite.
    case recentActivity
    case dateAdded
    case releaseYear
    case alphabetical
    case rating
    case newEpisodes
    /// The user's drag-and-drop arrangement.
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentActivity: return "Recent Activity"
        case .dateAdded: return "Date Added"
        case .releaseYear: return "Release Year"
        case .alphabetical: return "Name"
        case .rating: return "My Rating"
        case .newEpisodes: return "New Episodes"
        case .custom: return "Custom Order"
        }
    }

    /// Menu labels for the natural direction and its reverse; a hand-made
    /// arrangement has no direction.
    var directionTitles: (natural: String, reversed: String)? {
        switch self {
        case .custom: return nil
        case .recentActivity, .dateAdded, .releaseYear: return ("Newest First", "Oldest First")
        case .alphabetical: return ("A to Z", "Z to A")
        case .rating: return ("Highest First", "Lowest First")
        case .newEpisodes: return ("Most First", "Fewest First")
        }
    }
}

/// What a library collection remembers between visits and launches.
struct LibraryViewOptions: Codable, Equatable, Sendable {
    var sort: LibrarySortOrder = .recentActivity
    var reversed = false
    /// `MediaCategory.rawValue`.
    var category: String?
    var provider: String?

    init() {}

    /// Tolerant: a value this build does not know falls back to its default.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sort = (try? container.decode(LibrarySortOrder.self, forKey: .sort)) ?? .recentActivity
        reversed = (try? container.decode(Bool.self, forKey: .reversed)) ?? false
        category = try? container.decodeIfPresent(String.self, forKey: .category)
        provider = try? container.decodeIfPresent(String.self, forKey: .provider)
    }
}
