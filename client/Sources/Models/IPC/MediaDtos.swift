import Foundation

// IPC JSON values mirrored by the engine (ipc-api.md, contract v6).

struct SearchResultDto: Codable, Sendable, Identifiable, Hashable {
    let name: String
    let url: String
    let provider: String
    /// Stable provider identity (IPC v4). Use `providerKey` for requests.
    var providerId: String? = nil
    let type: String
    let posterUrl: String?
    let quality: String?
    let score: Int?
    let language: String?
    let episodes: Int?
    let year: Int?
    let isMovie: Bool
    /// IPC v3; optional so v2 payloads and memberwise call sites keep working.
    var posterHeaders: [String: String]? = nil

    var id: String { LibraryIdentity.key(providerID: providerId, providerName: provider, url: url) }
    /// Unambiguous provider reference for follow-up requests.
    var providerKey: String { providerId ?? provider }
}

struct EpisodeDto: Codable, Sendable, Identifiable, Hashable {
    let data: String
    let name: String?
    let season: Int?
    let episode: Int?
    let posterUrl: String?
    let description: String?
    let score: Int?
    let date: Int?
    let runTimeMinutes: Int?
    let audio: String?

    var id: String { data }

    var isDub: Bool { audio == "dub" }
}

struct ActorDto: Codable, Sendable, Hashable {
    let name: String
    let role: String?
    let image: String?
    var voiceActor: String? = nil
    var voiceActorImage: String? = nil
}

struct DetailsDto: Codable, Sendable, Identifiable {
    let provider: String
    var providerId: String? = nil
    let url: String
    let name: String
    let type: String
    let posterUrl: String?
    let backgroundPosterUrl: String?
    let logoUrl: String?
    let plot: String?
    let year: Int?
    let durationMinutes: Int?
    let score: Int?
    let tags: [String]
    let actors: [ActorDto]
    let contentRating: String?
    let comingSoon: Bool
    let episodes: [EpisodeDto]
    let movieData: String?

    // IPC v3 (Offline-Features-Plan Phase 2) — all optional so the memberwise
    // initialiser and older payloads stay valid.
    var recommendations: [SearchResultDto]? = nil
    var trailers: [TrailerDto]? = nil
    /// "Ongoing" | "Completed"
    var showStatus: String? = nil
    var nextAiring: NextAiringDto? = nil
    var seasonNames: [SeasonNameDto]? = nil
    /// Cross-site identifiers, stored for future sync — never called.
    var syncIds: [String: String]? = nil
    var posterHeaders: [String: String]? = nil
    var uniqueUrl: String? = nil

    /// Application-owned downloaded media; absent from remote provider details.
    var localDownloadID: UUID? = nil
    var id: String {
        if type == "Download", let localDownloadID { return LibraryIdentity.localDownload(localDownloadID) }
        return LibraryIdentity.key(providerID: providerId, providerName: provider, url: url)
    }

    /// Unambiguous provider reference for follow-up requests.
    var providerKey: String { providerId ?? provider }

    var isSeries: Bool { !episodes.isEmpty }

    var isAnime: Bool { episodes.contains { $0.audio != nil } }

    var seasons: [Int] {
        Array(Set(episodes.compactMap(\.season))).sorted()
    }
}

struct AudioTrackDto: Codable, Sendable, Identifiable, Hashable {
    let url: String
    let label: String?
    let language: String?
    let headers: [String: String]

    var id: String { url }

    init(url: String, label: String? = nil, language: String? = nil, headers: [String: String] = [:]) {
        self.url = url
        self.label = label
        self.language = language
        self.headers = headers
    }
}

struct StreamLinkDto: Codable, Sendable, Identifiable, Hashable {
    let url: String
    let name: String
    let source: String
    let quality: Int
    let type: String
    let headers: [String: String]
    let extractorData: String?
    let isPlaylist: Bool
    let playlist: [String]
    let audioTracks: [AudioTrackDto]
    /// ClearKey content key for an encrypted stream (L4); nil when unencrypted.
    let drm: ClearKeyDto?

    var id: String { "\(source)|\(url)" }

    enum CodingKeys: String, CodingKey {
        case url, name, source, quality, type, headers, extractorData, isPlaylist, playlist, audioTracks, drm
    }

    init(
        url: String,
        name: String,
        source: String,
        quality: Int,
        type: String,
        headers: [String: String] = [:],
        extractorData: String? = nil,
        isPlaylist: Bool = false,
        playlist: [String] = [],
        audioTracks: [AudioTrackDto] = [],
        drm: ClearKeyDto? = nil
    ) {
        self.url = url
        self.name = name
        self.source = source
        self.quality = quality
        self.type = type
        self.headers = headers
        self.extractorData = extractorData
        self.isPlaylist = isPlaylist
        self.playlist = playlist
        self.audioTracks = audioTracks
        self.drm = drm
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        name = try container.decode(String.self, forKey: .name)
        source = try container.decode(String.self, forKey: .source)
        quality = try container.decode(Int.self, forKey: .quality)
        type = try container.decode(String.self, forKey: .type)
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        extractorData = try container.decodeIfPresent(String.self, forKey: .extractorData)
        isPlaylist = try container.decodeIfPresent(Bool.self, forKey: .isPlaylist) ?? false
        playlist = try container.decodeIfPresent([String].self, forKey: .playlist) ?? []
        audioTracks = try container.decodeIfPresent([AudioTrackDto].self, forKey: .audioTracks) ?? []
        drm = try container.decodeIfPresent(ClearKeyDto.self, forKey: .drm)
    }

    /// Human-readable quality label — Android `Qualities` mapping parity
    /// (Implementation-Plan WS: exact buckets, no invented ranges).
    var qualityLabel: String {
        switch quality {
        case 0: return name
        case 144, 240, 360, 480, 720, 1080: return "\(quality)p"
        case 1440: return "1440p"
        case 2160: return "4K"
        default: return name
        }
    }
}

/// A ClearKey content key, lowercase hex, as FFmpeg's decryption options take
/// it. `kid` is nil when the provider gave only a default key.
struct ClearKeyDto: Codable, Sendable, Hashable {
    let kid: String?
    let key: String
}

struct SubtitleDto: Codable, Sendable, Hashable {
    let url: String
    let language: String
    let label: String?
    let mimeType: String?
}

struct LinksResponseDto: Codable, Sendable {
    let provider: String
    var providerId: String? = nil
    let links: [StreamLinkDto]
    let subtitles: [SubtitleDto]
    var failures: [OperationFailureDto]? = nil
    var outcome: String? = nil
}

/// One NDJSON line of POST /links/stream (Player-Remediation-Plan A2).
struct LinksStreamEventDto: Codable, Sendable {
    let type: String // "link" | "subtitle" | "done" | "error"
    let link: StreamLinkDto?
    let subtitle: SubtitleDto?
    let error: String?
    var failures: [OperationFailureDto]? = nil
    var outcome: String? = nil
}

struct LinksRequestDto: Encodable, Sendable {
    let plugin: String
    let data: String
}

/// POST /extract (IPC v3): extractor-only resolution for a single URL.
struct ExtractRequestDto: Encodable, Sendable {
    let url: String
    let referer: String?
}

/// POST /links/verify/start — keeps an extractor link alive while in use.
struct VerifierStartRequestDto: Encodable, Sendable {
    let source: String
    let extractorData: String
}

struct VerifierStartResponseDto: Decodable, Sendable {
    /// Nil when the provider has no verifier (the common case).
    let jobId: String?
}

struct VerifierStopRequestDto: Encodable, Sendable {
    let jobId: String
}

/// One resource of a relayed split stream (audit A35): the headers reach
/// this URL only.
struct MediaRelayResourceDto: Encodable, Sendable, Equatable {
    let url: String
    let headers: [String: String]
}

struct MediaRelayRequestDto: Encodable, Sendable {
    let resources: [MediaRelayResourceDto]
}

struct MediaRelayResponseDto: Decodable, Sendable {
    let sessionId: String
    let paths: [String]
}

struct MediaRelayRevokeRequestDto: Encodable, Sendable {
    let sessionId: String
}

/// One NDJSON line of the /search/stream response.
struct SearchStreamEventDto: Codable, Sendable {
    let type: String // "provider_result" | "provider_error" | "done"
    let provider: String?
    var providerId: String? = nil
    let results: [SearchResultDto]
    let error: String?
    var failure: OperationFailureDto? = nil
}

struct HomePageListDto: Codable, Sendable, Hashable, Identifiable {
    let name: String
    let isHorizontal: Bool
    let items: [SearchResultDto]
    var id: String { name }
}

struct HomePageDto: Codable, Sendable {
    let provider: String
    var providerId: String? = nil
    let page: Int
    let hasNext: Bool
    let lists: [HomePageListDto]
    var failures: [OperationFailureDto]? = nil
    var outcome: String? = nil
}

struct TrailerDto: Codable, Sendable, Hashable {
    let url: String
    let referer: String?
    let raw: Bool
    let headers: [String: String]

    /// Headers mpv needs to open the trailer.
    var requestHeaders: [String: String] {
        var result = headers
        if let referer, !referer.isEmpty, result["Referer"] == nil {
            result["Referer"] = referer
        }
        return result
    }
}

struct NextAiringDto: Codable, Sendable, Hashable {
    let episode: Int
    /// Unix seconds.
    let unixTime: Int
    let season: Int?

    var date: Date { Date(timeIntervalSince1970: TimeInterval(unixTime)) }
}

struct SeasonNameDto: Codable, Sendable, Hashable {
    let season: Int
    let name: String?
    let displaySeason: Int?
}

extension DetailsDto {
    /// Android's season label rules: "Season {display} {name}", or just the
    /// name when the provider gives no display number.
    func seasonTitle(_ season: Int) -> String {
        guard let entry = seasonNames?.first(where: { $0.season == season }) else {
            return "Season \(season)"
        }
        let name = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let number = entry.displaySeason ?? season
        if name.isEmpty { return "Season \(number)" }
        if entry.displaySeason == nil, entry.name != nil { return name }
        return "Season \(number) · \(name)"
    }
}
