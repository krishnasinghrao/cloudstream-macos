import Foundation
import SwiftData

/// A page the user makes in their library (ADR-0021), such as "Favourite
/// Episodes". It holds whole titles and single episodes. Pages belong to the
/// profile whose store they live in.
@Model
final class LibraryPage {
    @Attribute(.unique) var id: String
    var name: String
    var createdAt: Date
    /// Place in the sidebar; lower comes first.
    var sortPosition: Double

    init(id: String = UUID().uuidString, name: String, createdAt: Date = Date(), sortPosition: Double) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.sortPosition = sortPosition
    }

    /// Longest name a page may have, in characters.
    static let maxNameLength = LibraryPagePolicy.maxNameLength

    /// Trimmed, single-line and bounded; nil when nothing usable is left.
    static func normalizedName(_ raw: String) -> String? {
        LibraryPagePolicy.normalizedName(raw)
    }
}

/// One title or one episode on a page. Entries keep what they need to be
/// shown and opened, so a page stays intact when the title leaves the
/// library or its history is cleared.
@Model
final class LibraryPageEntry {
    /// `LibraryPageEntry.key(pageID:itemID:episodeData:)`.
    @Attribute(.unique) var id: String
    var pageID: String
    /// `StoredMediaItem.id` of the title.
    var itemID: String
    var title: String
    var posterURL: String?
    var bannerURL: String?
    var providerName: String
    var providerID: String?
    var providerURL: String
    var mediaType: String
    /// Episode identity; nil when the entry is the whole title.
    var episodeData: String?
    var season: Int?
    var episode: Int?
    var episodeName: String?
    var episodeThumbnailURL: String?
    /// Edition (sub/dub) of the episode.
    var audio: String?
    var addedAt: Date

    init(pageID: String, itemID: String, details: DetailsDto, episode: EpisodeDto?, addedAt: Date = Date()) {
        self.id = Self.key(pageID: pageID, itemID: itemID, episodeData: episode?.data)
        self.pageID = pageID
        self.itemID = itemID
        self.title = details.name
        self.posterURL = details.posterUrl
        self.bannerURL = details.backgroundPosterUrl
        self.providerName = details.provider
        self.providerID = details.providerId
        self.providerURL = details.url
        self.mediaType = details.type
        self.episodeData = episode?.data
        self.season = episode?.season
        self.episode = episode?.episode
        self.episodeName = episode?.name
        self.episodeThumbnailURL = episode?.posterUrl
        self.audio = episode?.audio
        self.addedAt = addedAt
    }

    @Transient var isEpisode: Bool { episodeData != nil }

    /// Episode data strings can be multi-KB JSON blobs; hashing keeps the
    /// unique index small (as `EpisodeProgress.key` does).
    static func key(pageID: String, itemID: String, episodeData: String?) -> String {
        LibraryPagePolicy.entryKey(pageID: pageID, itemID: itemID, episodeData: episodeData)
    }

    /// The saved episode, for menus and playback lookups; nil for a whole title.
    @Transient var episodeDto: EpisodeDto? {
        episodeData.map {
            EpisodeDto(data: $0, name: episodeName, season: season, episode: episode, posterUrl: episodeThumbnailURL,
                       description: nil, score: nil, date: nil, runTimeMinutes: nil, audio: audio)
        }
    }

    /// "S1 · E4", "E4" or nil.
    @Transient var episodeLabel: String? {
        guard let episode else { return nil }
        return season.map { "S\($0) · E\(episode)" } ?? "E\(episode)"
    }
}

/// A page as views show it: plain values, safe to keep across saves.
struct LibraryPageSummary: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let titleCount: Int
    let episodeCount: Int

    var count: Int { titleCount + episodeCount }
}
