import CryptoKit
import Foundation
import SwiftData

/// Per-episode watch history (Offline-Features-Plan Phase 1).
///
/// `StoredMediaItem` keeps a single denormalised resume pointer per title so
/// Continue Watching stays a single fetch; this model records every episode's
/// position and watched flag so the detail page can show ticks, progress bars
/// and pick the next unwatched episode — Android's `DataStoreHelper`
/// `video_pos_dur` / `result_watch_state` parity.
///
/// Schema evolution is additive-only (see docs/adr/0006): new properties must
/// carry defaults so SwiftData lightweight-migrates existing stores.
@Model
final class EpisodeProgress {
    /// `"\(itemID)|\(sha256(episodeData))"` — episode data strings can be
    /// multi-KB JSON blobs; hashing keeps the unique index small.
    @Attribute(.unique) var id: String
    /// `StoredMediaItem.id` ("provider|url").
    var itemID: String
    var episodeData: String
    var season: Int?
    var episode: Int?
    var positionSeconds: Double
    var durationSeconds: Double
    var watched: Bool
    var updatedAt: Date
    /// "episode" or "movie". Old rows default to episodes.
    var kind: String = EpisodeProgress.episodeKind
    /// Edition (sub/dub) the row was played in; nil when unknown.
    var audio: String?

    static let episodeKind = "episode"
    static let movieKind = "movie"
    /// A movie's row is keyed by its title alone: `movieData` links rotate.
    static let moviePlaybackData = "cloudstream.movie-playback.v1"

    init(itemID: String, episodeData: String, season: Int?, episode: Int?, audio: String? = nil) {
        self.id = Self.key(itemID: itemID, episodeData: episodeData)
        self.itemID = itemID
        self.episodeData = episodeData
        self.season = season
        self.episode = episode
        self.audio = audio
        self.positionSeconds = 0
        self.durationSeconds = 0
        self.watched = false
        self.updatedAt = Date()
    }

    convenience init(movieItemID itemID: String) {
        self.init(itemID: itemID, episodeData: Self.moviePlaybackData, season: nil, episode: nil)
        self.kind = Self.movieKind
    }

    @Transient var isMovie: Bool { kind == Self.movieKind }

    static func key(itemID: String, episodeData: String) -> String {
        let digest = SHA256.hash(data: Data(episodeData.utf8))
        return itemID + "|" + digest.map { String(format: "%02x", $0) }.joined()
    }

    var snapshot: EpisodeProgressSnapshot {
        EpisodeProgressSnapshot(
            episodeData: episodeData,
            positionSeconds: positionSeconds,
            durationSeconds: durationSeconds,
            watched: watched,
            updatedAt: updatedAt,
        )
    }
}

/// Value copy handed to views: managed objects must not outlive their context
/// or be read during SwiftUI body evaluation across saves.
struct EpisodeProgressSnapshot: Sendable, Hashable {
    let episodeData: String
    let positionSeconds: Double
    let durationSeconds: Double
    let watched: Bool
    let updatedAt: Date

    /// 0…1, nil when the duration is unknown or nothing was played.
    var fraction: Double? {
        guard durationSeconds > 0, positionSeconds > 0 else { return nil }
        return min(1, positionSeconds / durationSeconds)
    }

    /// Partially watched and worth offering a resume for.
    var isResumable: Bool {
        !watched && positionSeconds >= WatchProgressPolicy.minimumResumeSeconds
    }

    var remainingSeconds: Double? {
        guard durationSeconds > 0 else { return nil }
        return max(0, durationSeconds - positionSeconds)
    }
}

/// Thresholds shared by the store, the player and the tests.
enum WatchProgressPolicy {
    /// Below this, a play was a mis-click — nothing worth resuming.
    static let minimumResumeSeconds: Double = 10
    /// Android marks an episode watched at ~90 %.
    static let watchedFraction: Double = 0.9
    /// End credits: this close to the end counts as watched for anything
    /// longer than `creditsMinimumRuntime`.
    static let creditsWindowSeconds: Double = 120
    static let creditsMinimumRuntime: Double = 600

    static func isWatched(position: Double, duration: Double) -> Bool {
        guard duration > 0, position > 0 else { return false }
        if position / duration >= watchedFraction { return true }
        return duration >= creditsMinimumRuntime && duration - position <= creditsWindowSeconds
    }

    /// "12m left" / "1h 4m left" / "<1m left".
    static func remainingLabel(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes == 0 { return "<1m left" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m left" }
        return "\(minutes)m left"
    }

    /// "34:12" / "1:02:07".
    static func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Picks what the primary "Play" button should start (pure; unit-tested).
enum NextEpisodeResolver {
    struct Pick: Equatable {
        let episode: EpisodeDto
        /// Non-nil when the pick is a partially watched episode.
        let resumeAt: Double?
    }

    /// - Parameters:
    ///   - episodes: episodes in playback order (already filtered to the
    ///     user's sub/dub preference).
    ///   - progress: per-episode history keyed by `EpisodeDto.data`.
    ///   - lastEpisodeData: the title's resume pointer (most recently played).
    static func pick(
        episodes: [EpisodeDto],
        progress: [String: EpisodeProgressSnapshot],
        lastEpisodeData: String?,
    ) -> Pick? {
        guard !episodes.isEmpty else { return nil }

        // 1. The most recently played episode, if it is still in progress.
        if let lastEpisodeData,
           let last = episodes.first(where: { $0.data == lastEpisodeData }),
           let snapshot = progress[last.data], snapshot.isResumable {
            return Pick(episode: last, resumeAt: snapshot.positionSeconds)
        }

        // 2. The episode after the furthest watched one.
        if let furthestWatched = episodes.lastIndex(where: { progress[$0.data]?.watched == true }) {
            let next = episodes.index(after: furthestWatched)
            if episodes.indices.contains(next) {
                let episode = episodes[next]
                let resume = progress[episode.data].flatMap { $0.isResumable ? $0.positionSeconds : nil }
                return Pick(episode: episode, resumeAt: resume)
            }
            // Everything watched: offer a rewatch from the start.
            return Pick(episode: episodes[0], resumeAt: nil)
        }

        // 3. Any partially watched episode (most recent first).
        if let partial = episodes
            .compactMap({ episode in progress[episode.data].map { (episode, $0) } })
            .filter({ $0.1.isResumable })
            .max(by: { $0.1.updatedAt < $1.1.updatedAt }) {
            return Pick(episode: partial.0, resumeAt: partial.1.positionSeconds)
        }

        return Pick(episode: episodes[0], resumeAt: nil)
    }
}
