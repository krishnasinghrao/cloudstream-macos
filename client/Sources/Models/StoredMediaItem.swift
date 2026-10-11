import Foundation
import SwiftData

/// Local library + watch history persistence (SwiftData).
@Model
final class StoredMediaItem {
    @Attribute(.unique) var id: String
    /// Old durable keys stay intact until an explicit snapshot-backed rekey.
    var identityVersion: Int = 0
    var legacyItemID: String?
    var identityResolution: String = "legacy"
    var title: String
    var posterURL: String?
    var bannerURL: String?
    var providerName: String
    /// Stable provider identity (IPC v4); nil for items saved by older versions.
    var providerID: String?
    var providerURL: String
    var mediaType: String
    var watchTypeRaw: Int // WatchType.rawValue; -1 = not in library
    var isFavorite: Bool = false
    var lastEpisodeData: String?
    var lastSeason: Int?
    var lastEpisode: Int?
    /// Edition (sub/dub) of the resume pointer; nil for old rows and movies.
    var lastAudio: String?
    var progressSeconds: Double
    var totalDurationSeconds: Double
    var lastUpdated: Date
    /// When the entry entered the library ("Date Added" sort). New property
    /// with a default — SwiftData lightweight-migrates existing stores.
    var createdAt: Date = Date()
    /// Release year the provider reports ("Release Year" sort); nil until a
    /// details page or search result that carries one has been seen.
    var releaseYear: Int?
    /// Place in the user's hand-arranged order ("Custom Order" sort) of the
    /// title's watch-status collection and of Favorites; lower comes first,
    /// nil = not placed yet (shown first, newest first).
    var sortPosition: Double?
    var favoriteSortPosition: Double?
    /// Episodes the provider listed at the last check (Phase 6 new-episode
    /// badges). 0 = never checked.
    var knownEpisodeCount: Int = 0
    /// Episodes that appeared since the user last opened the title.
    var newEpisodeCount: Int = 0
    var lastEpisodeCheck: Date?
    /// Personal note and 1–5 star rating (0 = unrated).
    var userNote: String?
    var userRating: Int = 0
    /// Missing dates mean legacy/unknown order; migration never invents edits.
    var noteUpdatedAt: Date?
    var ratingUpdatedAt: Date?
    var favoriteUpdatedAt: Date?
    var watchTypeUpdatedAt: Date?
    var progressUpdatedAt: Date?
    /// The entry this source was merged into (ADR-0020); nil for a title's
    /// primary source or a standalone entry. A merged source keeps its own
    /// progress, history and playback settings; its title-level state lives
    /// on the primary.
    var mergedIntoID: String?

    init(
        id: String,
        title: String,
        posterURL: String? = nil,
        bannerURL: String? = nil,
        providerName: String,
        providerID: String? = nil,
        providerURL: String,
        mediaType: String,
        watchType: WatchType? = nil,
        isFavorite: Bool = false
    ) {
        self.id = id
        self.title = title
        self.posterURL = posterURL
        self.bannerURL = bannerURL
        self.providerName = providerName
        self.providerID = providerID
        if mediaType == "Download", LibraryIdentity.downloadID(from: id) != nil {
            self.providerID = nil
            self.identityVersion = LibraryIdentity.version
            self.identityResolution = "local_download"
        } else if let providerID, !providerID.isEmpty,
           id == LibraryIdentity.remote(providerID: providerID, url: providerURL) {
            self.identityVersion = LibraryIdentity.version
            self.identityResolution = "resolved"
        } else if providerID != nil { self.identityResolution = "resolved_legacy" }
        self.providerURL = providerURL
        self.mediaType = mediaType
        self.watchTypeRaw = watchType?.rawValue ?? -1
        self.isFavorite = isFavorite
        self.progressSeconds = 0
        self.totalDurationSeconds = 0
        self.lastUpdated = Date()
        self.createdAt = Date()
    }

    /// Local ownership is a separate namespace, never a remote installation ID.
    @Transient var downloadRecordID: UUID? {
        mediaType == "Download" ? LibraryIdentity.downloadID(from: id) : nil
    }

    /// Provider reference for daemon requests: the stable ID when known.
    @Transient var providerKey: String { providerID ?? providerName }

    @Transient var watchType: WatchType? {
        get { WatchType(rawValue: watchTypeRaw) }
        set {
            let raw = newValue?.rawValue ?? -1
            // A place among one collection's titles means nothing in another.
            if raw != watchTypeRaw { sortPosition = nil }
            watchTypeRaw = raw
        }
    }

    /// nil when the total duration is unknown — a progress fraction against
    /// an unknown length is not a fraction.
    var displayProgress: Double? {
        guard totalDurationSeconds > 0 else { return nil }
        return min(1, progressSeconds / totalDurationSeconds)
    }

    /// nil when unknown; sub-minute remains render as "<1m" instead of the
    /// dishonest "0m".
    var remainingLabel: String? {
        guard totalDurationSeconds > 0 else { return nil }
        let remaining = max(0, totalDurationSeconds - progressSeconds)
        let minutes = Int(remaining / 60)
        if minutes == 0 { return "<1m" }
        if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m"
        }
        return "\(minutes)m"
    }
}
