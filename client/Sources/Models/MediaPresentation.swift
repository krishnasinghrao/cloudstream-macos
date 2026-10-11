import Foundation

/// Coarse filter buckets over CloudStream's `TvType` names (search chips,
/// library filter).
enum MediaCategory: String, CaseIterable, Identifiable, Sendable {
    case movies = "Movies"
    case series = "Series"
    case anime = "Anime"
    case cartoons = "Cartoons"
    case asianDrama = "Asian Drama"
    case documentaries = "Documentaries"
    case live = "Live"
    case other = "Other"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .movies: return "film"
        case .series: return "tv"
        case .anime: return "sparkles.tv"
        case .cartoons: return "paintpalette"
        case .asianDrama: return "theatermasks"
        case .documentaries: return "globe"
        case .live: return "dot.radiowaves.left.and.right"
        case .other: return "square.grid.2x2"
        }
    }

    static func of(_ rawType: String) -> MediaCategory {
        switch rawType.lowercased().replacing(" ", with: "") {
        case "movie", "torrent": return .movies
        case "tvseries", "series": return .series
        case "anime", "animemovie", "ova": return .anime
        case "cartoon": return .cartoons
        case "asiandrama": return .asianDrama
        case "documentary": return .documentaries
        case "live", "livestream": return .live
        default: return .other
        }
    }
}

enum MediaTypeDisplay {
    static func name(for rawType: String) -> String {
        switch rawType.lowercased() {
        case "movie": return "Movie"
        case "tvseries", "series": return "Series"
        case "anime": return "Anime"
        case "anime movie", "animemovie": return "Anime Movie"
        case "asiandrama": return "Asian Drama"
        case "audiobook": return "Audiobook"
        case "custommedia": return "Other"
        case "ova": return "OVA"
        case "others", "other": return "Other"
        case "novel": return "Novel"
        case "manga": return "Manga"
        case "livestream", "live": return "Live"
        case "audio": return "Audio"
        case "torrent": return "Torrent"
        default: return rawType.capitalized
        }
    }

    /// `minutes` is already unit-normalized by the daemon (RuntimeNormalizer).
    static func duration(minutes: Int) -> String {
        if minutes >= 60 {
            let hours = minutes / 60
            let remainder = minutes % 60
            return remainder > 0 ? "\(hours)h \(remainder)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }
}
