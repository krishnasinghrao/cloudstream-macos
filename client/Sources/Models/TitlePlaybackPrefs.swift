import Foundation
import SwiftData

/// Per-title playback memory (Offline-Features-Plan Phase 4.3): the audio and
/// subtitle languages, subtitle offset and speed chosen for a show are
/// re-applied to its next episode, plus a user-marked intro window for
/// "Skip Intro" on files without chapters. Additive schema (ADR 0006).
@Model
final class TitlePlaybackPrefs {
    /// `StoredMediaItem.id` ("provider|url").
    @Attribute(.unique) var itemID: String
    var audioLanguage: String?
    var subtitleLanguage: String?
    /// true = user turned subtitles off for this title.
    var subtitlesOff: Bool = false
    var subtitleDelay: Double = 0
    var speed: Double = 1
    var introStart: Double?
    var introEnd: Double?
    /// The source (`LinkRanker.sourceKey`) and quality the user picked in the
    /// player's mirror menu; tried first the next time the title plays.
    var source: String?
    var sourceQuality: Int?
    var updatedAt: Date = Date()

    init(itemID: String) {
        self.itemID = itemID
    }

    var snapshot: TitlePlaybackSnapshot {
        TitlePlaybackSnapshot(
            audioLanguage: audioLanguage,
            subtitleLanguage: subtitleLanguage,
            subtitlesOff: subtitlesOff,
            subtitleDelay: subtitleDelay,
            speed: speed,
            introStart: introStart,
            introEnd: introEnd,
            source: source,
            sourceQuality: sourceQuality,
        )
    }
}

struct TitlePlaybackSnapshot: Sendable, Equatable {
    var audioLanguage: String?
    var subtitleLanguage: String?
    var subtitlesOff = false
    var subtitleDelay: Double = 0
    var speed: Double = 1
    var introStart: Double?
    var introEnd: Double?
    var source: String?
    var sourceQuality: Int?

    var rememberedSource: RememberedSource? {
        guard let source, !source.isEmpty else { return nil }
        return RememberedSource(key: source, quality: sourceQuality)
    }

    /// The learned intro as a skip segment, when it is sane.
    var introSegment: SkipSegment? {
        guard let introStart, let introEnd, introEnd - introStart >= 5, introEnd - introStart <= 300 else { return nil }
        return SkipSegment(kind: .intro, start: introStart, end: introEnd)
    }
}
