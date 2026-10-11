import Foundation

/// CloudStream for Mac backup file (Offline-Features-Plan Phase 7).
///
/// Versioned JSON: library entries, per-episode history, per-title playback
/// memory, non-sensitive preferences, and the extension setup (repository
/// URLs + disabled providers). Never contains credentials, tokens, cookies or
/// file paths to downloads.
struct BackupDocument: Codable, Sendable, Equatable {
    static let formatIdentifier = "cloudstream-macos-backup"
    static let currentVersion = 2
    /// Refuse absurd inputs before decoding them into memory.
    static let maxFileBytes = 64 * 1024 * 1024
    static let maxRecords = 200_000

    var format: String = BackupDocument.formatIdentifier
    var version: Int = BackupDocument.currentVersion
    var createdAt: Date
    var appVersion: String
    var items: [Item]
    var episodes: [Episode]
    var playback: [Playback]
    var preferences: [String: BackupValue]
    var repositories: [String]
    var disabledProviders: [String]
    /// Additive v1 metadata; old backups remain decodable.
    var profileID: UUID? = nil
    var reason: String? = nil
    /// Stable IDs of disabled providers (v2). `disabledProviders` keeps the
    /// display names for older backups and is matched only when unambiguous.
    var disabledProviderIDs: [String]? = nil
    /// When the extension setup above was read from the engine. nil means it
    /// was not available: the backup holds the library, not a complete setup.
    var extensionSetupCapturedAt: Date? = nil
    /// The profile's own library pages (ADR-0021). nil in backups made
    /// before pages existed: a restore then leaves the local pages alone.
    var pages: [Page]? = nil

    struct Item: Codable, Sendable, Equatable {
        var id: String
        var title: String
        var posterURL: String?
        var bannerURL: String?
        var providerName: String
        var providerURL: String
        var mediaType: String
        var watchTypeRaw: Int
        var isFavorite: Bool
        var lastEpisodeData: String?
        var lastSeason: Int?
        var lastEpisode: Int?
        var progressSeconds: Double
        var totalDurationSeconds: Double
        var lastUpdated: Date
        var createdAt: Date
        var knownEpisodeCount: Int?
        var userNote: String?
        var userRating: Int?
        var providerID: String? = nil
        var identityVersion: Int? = nil
        var legacyItemID: String? = nil
        var identityResolution: String? = nil
        var noteUpdatedAt: Date? = nil
        var ratingUpdatedAt: Date? = nil
        var favoriteUpdatedAt: Date? = nil
        var watchTypeUpdatedAt: Date? = nil
        var progressUpdatedAt: Date? = nil
        var lastAudio: String? = nil
        var releaseYear: Int? = nil
        var sortPosition: Double? = nil
        var favoriteSortPosition: Double? = nil
        /// The title this source was merged into (ADR-0020); older apps ignore it.
        var mergedIntoID: String? = nil
    }

    struct Episode: Codable, Sendable, Equatable {
        var itemID: String
        var episodeData: String
        var season: Int?
        var episode: Int?
        var positionSeconds: Double
        var durationSeconds: Double
        var watched: Bool
        var updatedAt: Date
        /// nil in older backups means an episode row.
        var kind: String? = nil
        var audio: String? = nil
    }

    struct Page: Codable, Sendable, Equatable {
        var id: String
        var name: String
        var createdAt: Date
        var sortPosition: Double
        var entries: [PageEntry]
    }

    struct PageEntry: Codable, Sendable, Equatable {
        var itemID: String
        var title: String
        var posterURL: String?
        var bannerURL: String?
        var providerName: String
        var providerID: String?
        var providerURL: String
        var mediaType: String
        /// nil when the entry is the whole title.
        var episodeData: String?
        var season: Int?
        var episode: Int?
        var episodeName: String?
        var episodeThumbnailURL: String?
        var audio: String?
        var addedAt: Date
    }

    static let episodeKind = "episode"
    static let movieKind = "movie"
    static let moviePlaybackData = "cloudstream.movie-playback.v1"

    struct Playback: Codable, Sendable, Equatable {
        var itemID: String
        var audioLanguage: String?
        var subtitleLanguage: String?
        var subtitlesOff: Bool
        var subtitleDelay: Double
        var speed: Double
        var introStart: Double?
        var introEnd: Double?
        var updatedAt: Date? = nil
        var source: String? = nil
        var sourceQuality: Int? = nil
    }

    struct Summary: Equatable, Sendable {
        var items = 0
        var libraryEntries = 0
        var favorites = 0
        var episodes = 0
        var repositories = 0
        var pages = 0
    }

    var summary: Summary {
        Summary(
            items: items.count,
            libraryEntries: items.filter { $0.watchTypeRaw >= 0 }.count,
            favorites: items.filter(\.isFavorite).count,
            episodes: episodes.count,
            repositories: repositories.count,
            pages: pages?.count ?? 0,
        )
    }

    enum ValidationError: LocalizedError, Equatable {
        case notABackup
        case newerVersion(Int)
        case tooLarge
        case corrupt(String)

        var errorDescription: String? {
            switch self {
            case .notABackup: return "This file isn't a CloudStream backup."
            case .newerVersion(let version): return "This backup was made by a newer CloudStream (format \(version)). Update the app to restore it."
            case .tooLarge: return "The backup file is too large to restore."
            case .corrupt(let detail): return "The backup file is damaged: \(detail)"
            }
        }
    }

    /// ISO 8601 with milliseconds: readable, and precise enough that merge
    /// ("newer side wins") comparisons survive a round trip.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(try BackupDocument.timestamp(date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted)) {
                return date
            }
            if let date = try? Date(text, strategy: .iso8601) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date \(text)")
        }
        return decoder
    }()

    /// "2026-09-30T09:33:15.799Z". Milliseconds are *rounded* from the
    /// double, so decode → encode is byte-stable (formatting truncates, and
    /// 15.799 parses back as 15.79899…).
    static func timestamp(_ date: Date) throws -> String {
        guard let millis = Int64(exactly: (date.timeIntervalSince1970 * 1000).rounded()) else {
            throw ValidationError.corrupt("Date is outside the supported timestamp range.")
        }
        let (seconds, fraction) = millis.quotientAndRemainder(dividingBy: 1000)
        let whole = Date(timeIntervalSince1970: TimeInterval(fraction < 0 ? seconds - 1 : seconds))
        let base = whole.formatted(.iso8601)
        return String(base.dropLast()) + String(format: ".%03dZ", fraction < 0 ? fraction + 1000 : fraction)
    }

    func encoded() throws -> Data {
        try validate()
        return try Self.encoder.encode(self)
    }

    /// Also used for programmatically prepared/Android restore plans, so read
    /// validation cannot be bypassed by constructing Pending directly.
    func validate() throws {
        guard format == Self.formatIdentifier else { throw ValidationError.notABackup }
        guard version > 0, version <= Self.currentVersion else {
            if version > Self.currentVersion { throw ValidationError.newerVersion(version) }
            throw ValidationError.corrupt("Unsupported format version.")
        }
        let pageEntries = (pages ?? []).reduce(0) { $0 + $1.entries.count }
        guard items.count + episodes.count + playback.count + pageEntries <= Self.maxRecords else { throw ValidationError.tooLarge }
        _ = try BackupPreferencePolicy.validated(preferences)
        func check(_ condition: Bool, _ field: String) throws {
            if !condition { throw ValidationError.corrupt("Invalid \(field).") }
        }
        func validSeconds(_ value: Double) -> Bool {
            // UI timestamps use integer seconds; finite alone is insufficient
            // for values such as 1e100, which would still trap during display.
            value.isFinite && value >= 0 && Int(exactly: value.rounded(.towardZero)) != nil
        }
        func validDate(_ date: Date) -> Bool {
            date.timeIntervalSince1970.isFinite && date >= .distantPast && date <= .distantFuture
        }
        try check(validDate(createdAt), "createdAt")
        try check(extensionSetupCapturedAt.map(validDate) ?? true, "extension setup timestamp")
        try check(repositories.count <= 256 && disabledProviders.count <= 4096 && (disabledProviderIDs?.count ?? 0) <= 4096
                  && (repositories + disabledProviders + (disabledProviderIDs ?? [])).allSatisfy { $0.utf8.count <= 8192 }, "extension setup")
        var itemIDs = Set<String>()
        var stableIdentities = Set<String>()
        for item in items {
            try check(!item.id.isEmpty && itemIDs.insert(item.id).inserted, "duplicate/empty item identity")
            try check(item.mediaType != "Download" && !item.id.hasPrefix("local-download-v2:"), "local download in portable backup")
            try check((-1...4).contains(item.watchTypeRaw), "watch status")
            try check(validSeconds(item.progressSeconds) && validSeconds(item.totalDurationSeconds), "title position/duration")
            try check(item.lastSeason.map { $0 >= 0 } ?? true, "season")
            try check(item.lastEpisode.map { $0 >= 0 } ?? true, "episode")
            try check(item.knownEpisodeCount.map { $0 >= 0 } ?? true, "episode count")
            try check(item.userRating.map { (0...5).contains($0) } ?? true, "rating")
            try check(validDate(item.createdAt) && validDate(item.lastUpdated), "title timestamp")
            for timestamp in [item.noteUpdatedAt, item.ratingUpdatedAt, item.favoriteUpdatedAt, item.watchTypeUpdatedAt, item.progressUpdatedAt] {
                try check(timestamp.map { validDate($0) && $0 <= item.lastUpdated } ?? true, "field edit timestamp")
            }
            try check(item.ratingUpdatedAt == nil || item.userRating != nil, "rating edit metadata")
            if let providerID = item.providerID {
                try check(!providerID.isEmpty, "provider identity")
                let identity = LibraryIdentity.remote(providerID: providerID, url: item.providerURL)
                try check(stableIdentities.insert(identity).inserted, "duplicate stable provider identity")
                if item.identityVersion == LibraryIdentity.version {
                    try check(item.id == identity, "stable item key")
                }
                if item.id.hasPrefix("remote-v2:") {
                    try check(item.id == identity, "stable item key")
                    try check(item.identityVersion == nil || item.identityVersion == LibraryIdentity.version, "stable identity version")
                }
            }
            if item.identityVersion == LibraryIdentity.version || item.id.hasPrefix("remote-v2:") {
                try check(item.providerID != nil, "missing stable provider identity")
            }
            try check(item.identityVersion.map { (0...LibraryIdentity.version).contains($0) } ?? true, "identity version")
        }
        var episodeIDs = Set<String>()
        for episode in episodes {
            let key = "\(episode.itemID.utf8.count):\(episode.itemID)\(episode.episodeData)"
            try check(!episode.itemID.isEmpty && !episode.episodeData.isEmpty && episodeIDs.insert(key).inserted, "episode identity")
            try check(validSeconds(episode.positionSeconds) && validSeconds(episode.durationSeconds), "episode position/duration")
            try check(episode.season.map { $0 >= 0 } ?? true, "season")
            try check(episode.episode.map { $0 >= 0 } ?? true, "episode")
            try check(validDate(episode.updatedAt), "history timestamp")
            try check(!episode.itemID.hasPrefix("local-download-v2:"), "local download in portable backup")
            try check([nil, Self.episodeKind, Self.movieKind].contains(episode.kind), "history kind")
            try check((episode.kind == Self.movieKind) == (episode.episodeData == Self.moviePlaybackData), "movie history identity")
        }
        var playbackIDs = Set<String>()
        for entry in playback {
            try check(!entry.itemID.isEmpty && playbackIDs.insert(entry.itemID).inserted, "playback identity")
            try check(!entry.itemID.hasPrefix("local-download-v2:"), "local download in portable backup")
            try check(entry.updatedAt.map(validDate) ?? true, "playback timestamp")
            // Native mpv declares speed 0.01...100 and sub-delay as Float.
            // Preserve signed offsets and speeds outside the UI presets, but
            // reject values that the native types cannot represent safely.
            try check(entry.subtitleDelay.isFinite && abs(entry.subtitleDelay) <= Double(Float.greatestFiniteMagnitude)
                      && entry.speed.isFinite && (0.01...100).contains(entry.speed), "playback speed/delay")
            try check(entry.introStart.map(validSeconds) ?? true, "intro start")
            try check(entry.introEnd.map(validSeconds) ?? true, "intro end")
            if let start = entry.introStart, let end = entry.introEnd {
                try check(end >= start, "intro interval")
            }
        }
        try validatePages(check, validDate: validDate)
    }

    /// Pages: unique IDs and names, usable names, and entries that name a
    /// portable title once each.
    private func validatePages(_ check: (Bool, String) throws -> Void, validDate: (Date) -> Bool) throws {
        guard let pages else { return }
        try check(pages.count <= 1_000, "page count")
        var pageIDs = Set<String>()
        var names = Set<String>()
        for page in pages {
            try check(!page.id.isEmpty && page.id.utf8.count <= 128 && pageIDs.insert(page.id).inserted, "page identity")
            try check(LibraryPagePolicy.normalizedName(page.name) == page.name
                      && names.insert(page.name.lowercased()).inserted, "page name")
            try check(validDate(page.createdAt) && page.sortPosition.isFinite, "page metadata")
            var keys = Set<String>()
            for entry in page.entries {
                try check(!entry.itemID.isEmpty && !entry.providerURL.isEmpty, "page entry identity")
                try check(entry.mediaType != "Download" && !entry.itemID.hasPrefix("local-download-v2:"), "local download in portable backup")
                try check(entry.episodeData.map { !$0.isEmpty } ?? true, "page episode identity")
                try check(entry.season.map { $0 >= 0 } ?? true, "season")
                try check(entry.episode.map { $0 >= 0 } ?? true, "episode")
                try check(validDate(entry.addedAt), "page entry timestamp")
                try check(keys.insert(LibraryPagePolicy.entryKey(pageID: page.id, itemID: entry.itemID, episodeData: entry.episodeData)).inserted,
                          "duplicate page entry")
            }
        }
    }

    /// Decodes and validates a macOS backup.
    static func decode(_ data: Data) throws -> BackupDocument {
        guard data.count <= maxFileBytes else { throw ValidationError.tooLarge }
        struct Header: Decodable { let format: String?; let version: Int? }
        guard let header = try? decoder.decode(Header.self, from: data), header.format == formatIdentifier else {
            throw ValidationError.notABackup
        }
        if let version = header.version, version > currentVersion { throw ValidationError.newerVersion(version) }
        let document: BackupDocument
        do {
            document = try decoder.decode(BackupDocument.self, from: data)
        } catch {
            throw ValidationError.corrupt(error.localizedDescription)
        }
        try document.validate()
        return document
    }
}

/// JSON-safe preference value.
enum BackupValue: Codable, Sendable, Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case strings([String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String].self) { self = .strings(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported preference value") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .strings(let value): try container.encode(value)
        }
    }

    init?(any value: Any) {
        switch value {
        case let value as Bool where type(of: value) == Bool.self: self = .bool(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() { self = .bool(value.boolValue) }
            else if CFNumberIsFloatType(value) { self = .double(value.doubleValue) }
            else { self = .int(value.intValue) }
        case let value as String: self = .string(value)
        case let value as [String]: self = .strings(value)
        default: return nil
        }
    }
}
