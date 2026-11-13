import Foundation

// MARK: - Live playback (ADR-0022)

/// What the catalogue says a title is. Deliberately not derived from the
/// stream: a rolling broadcast can report a positive duration and cached
/// seek ranges, and a finite video can be served as a growing playlist.
enum PlaybackKind: String, Equatable, Sendable {
    case unknown, vod, live

    static func catalogue(_ type: String) -> Self {
        let key = type.lowercased().replacingOccurrences(of: " ", with: "")
        if key == "live" || key == "livestream" { return .live }
        return key.isEmpty ? .unknown : .vod
    }
}

/// A stretch of a stream that can be seeked, in the file's own time.
struct PlaybackRange: Equatable, Sendable {
    let start: Double
    let end: Double

    /// `target` if a range holds it, else the nearest edge of any range;
    /// nil when there is nothing to seek in.
    static func clamped(_ target: Double, to ranges: [Self]) -> Double? {
        guard target.isFinite else { return nil }
        let valid = ranges.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
        if valid.contains(where: { $0.start...$0.end ~= target }) { return target }
        return valid.flatMap { [$0.start, $0.end] }.min { abs($0 - target) < abs($1 - target) }
    }
}

/// One interruption of a live stream shares a deadline, a number of loads
/// and one fresh link resolution. A first frame does not refill it: only
/// `PlaybackHealthWindow` reporting sustained playback does (`reset`).
struct PlaybackRecoveryBudget {
    var duration: Duration = .seconds(45)
    var maximumLoads = 3
    private(set) var deadline: ContinuousClock.Instant?
    private(set) var loads = 0
    private(set) var refreshed = false

    mutating func begin(now: ContinuousClock.Instant = .now) {
        if deadline == nil { deadline = now.advanced(by: duration) }
    }

    mutating func takeLoad(now: ContinuousClock.Instant = .now) -> Bool {
        begin(now: now)
        guard let deadline, now < deadline, loads < maximumLoads else { return false }
        loads += 1
        return true
    }

    mutating func takeRefresh(now: ContinuousClock.Instant = .now) -> Bool {
        begin(now: now)
        guard let deadline, now < deadline, !refreshed else { return false }
        refreshed = true
        return true
    }

    mutating func reset() { deadline = nil; loads = 0; refreshed = false }
}

/// Clock samples arrive a few times a second. Playback counts as healthy
/// again after `required` of uninterrupted advancing samples; a pause,
/// buffering, a seek, a backward step or a gap starts the window over.
struct PlaybackHealthWindow {
    var required: Duration = .seconds(30)
    var maximumGap: Duration = .seconds(2)
    private var startedAt: ContinuousClock.Instant?
    private var lastProgressAt: ContinuousClock.Instant?

    mutating func interrupt() { startedAt = nil; lastProgressAt = nil }

    /// True once, when the window completes.
    mutating func recordProgress(now: ContinuousClock.Instant = .now) -> Bool {
        if let last = lastProgressAt, now < last || now - last > maximumGap { interrupt() }
        if startedAt == nil { startedAt = now }
        lastProgressAt = now
        guard let startedAt, now - startedAt >= required else { return false }
        interrupt()
        return true
    }
}

// Pure playback policies (Offline-Features-Plan Phase 4). No UI, no engine,
// no persistence — everything here is deterministic and unit-tested.

// MARK: - Skip segments

struct SkipSegment: Equatable, Sendable {
    enum Kind: String, Sendable {
        case intro, recap, credits, preview

        var buttonTitle: String {
            switch self {
            case .intro: return "Skip Intro"
            case .recap: return "Skip Recap"
            case .credits: return "Skip Credits"
            case .preview: return "Skip Preview"
            }
        }
    }

    let kind: Kind
    let start: Double
    let end: Double

    func contains(_ time: Double) -> Bool {
        // Hide the button in the last second: the jump would be a no-op.
        time >= start && time < end - 1
    }
}

/// Turns mpv chapter titles into skippable segments (no external API: this
/// works for any file whose chapters are named, as many anime releases are).
enum ChapterClassifier {
    private static let patterns: [(SkipSegment.Kind, [String])] = [
        (.recap, ["recap", "previously"]),
        (.intro, ["intro", "opening", "op", "title sequence", "theme song", "cold open end"]),
        (.credits, ["credits", "ending", "ed", "outro", "end credits", "closing"]),
        (.preview, ["preview", "next episode", "next time", "eyecatch preview"]),
    ]

    static func kind(for title: String?) -> SkipSegment.Kind? {
        guard let title, !title.isEmpty else { return nil }
        let normalized = title.lowercased()
        let words = Set(normalized.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        for (kind, needles) in patterns {
            for needle in needles {
                if needle.contains(" ") {
                    if normalized.contains(needle) { return kind }
                } else if words.contains(needle)
                    // "OP1", "ED2", "Opening 2"
                    || words.contains(where: { $0.hasPrefix(needle) && $0.dropFirst(needle.count).allSatisfy(\.isNumber) }) {
                    return kind
                }
            }
        }
        return nil
    }

    static func segments(from chapters: [MpvChapter], duration: Double) -> [SkipSegment] {
        let sorted = chapters.sorted { $0.time < $1.time }
        var result: [SkipSegment] = []
        for (index, chapter) in sorted.enumerated() {
            guard let kind = kind(for: chapter.title) else { continue }
            let end = index + 1 < sorted.count ? sorted[index + 1].time : duration
            // Ignore degenerate or absurd segments (mislabelled chapters).
            guard end > chapter.time + 3, end - chapter.time < 600 || kind == .credits else { continue }
            result.append(SkipSegment(kind: kind, start: chapter.time, end: end))
        }
        return result
    }
}

// MARK: - Playback sequence

/// The episode order and edition one viewing session follows. Details,
/// resume, next/previous, prefetch and autoplay all read this value, so the
/// player cannot drift into provider collection order or another edition.
struct PlaybackSequence: Equatable, Sendable {
    let episodes: [EpisodeDto]
    /// The sub/dub edition the sequence was filtered to; nil when unfiltered.
    let edition: String?

    /// Season, then episode number; episodes without coordinates keep their
    /// provider order after numbered ones. An edition with no episodes is not
    /// applied, so a title that lacks it stays playable.
    init(episodes: [EpisodeDto], edition: String?) {
        var pool = episodes
        var applied: String?
        if let edition {
            let filtered = pool.filter { $0.audio == edition }
            if !filtered.isEmpty { pool = filtered; applied = edition }
        }
        self.edition = applied
        self.episodes = pool.enumerated().sorted { lhs, rhs in
            let l = (lhs.element.season ?? 0, lhs.element.episode ?? Int.max, lhs.offset)
            let r = (rhs.element.season ?? 0, rhs.element.episode ?? Int.max, rhs.offset)
            return l < r
        }.map(\.element)
    }

    /// The sequence a session started on `episode` follows: that episode's own
    /// edition, so an alternate edition the user picked is kept afterwards.
    init(details: DetailsDto, containing episode: EpisodeDto?) {
        self.init(episodes: episode == nil ? [] : details.episodes, edition: details.isAnime ? episode?.audio : nil)
    }

    private func index(of episode: EpisodeDto?) -> Int? {
        guard let episode else { return nil }
        // Exact stream identity first; equal DTOs can repeat in provider lists.
        return episodes.firstIndex { $0.data == episode.data && $0 == episode } ?? episodes.firstIndex(of: episode)
    }

    func previous(before episode: EpisodeDto?) -> EpisodeDto? {
        guard let index = index(of: episode), index > 0 else { return nil }
        return episodes[index - 1]
    }

    func next(after episode: EpisodeDto?) -> EpisodeDto? {
        guard let index = index(of: episode), episodes.indices.contains(index + 1) else { return nil }
        return episodes[index + 1]
    }
}

// MARK: - Up next

enum UpNextPolicy {
    /// When the countdown should start: at the credits segment if the file
    /// has one, otherwise `countdown` seconds before the end. nil = never.
    static func countdownStart(duration: Double, countdown: Int, creditsStart: Double?) -> Double? {
        guard countdown > 0, duration > 60 else { return nil }
        let fallback = duration - Double(countdown)
        guard let creditsStart, creditsStart > duration * 0.5, creditsStart < fallback else { return fallback }
        return creditsStart
    }
}

// MARK: - Track selection

/// Normalises the language labels providers and containers use ("en",
/// "eng", "en-US", "English", "English (CC)") to ISO 639-1 codes.
enum LanguageMatcher {
    private static let englishNames: [String: String] = {
        let english = Locale(identifier: "en")
        var map: [String: String] = [:]
        for code in Locale.LanguageCode.isoLanguageCodes {
            guard let alpha2 = code.identifier(.alpha2),
                  let name = english.localizedString(forLanguageCode: alpha2)?.lowercased() else { continue }
            map[name] = alpha2
        }
        return map
    }()

    static func code(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        let head = String(text.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " || $0 == "(" }).first ?? "")
        if (2...3).contains(head.count), head.allSatisfy(\.isLetter) {
            return Locale.LanguageCode(head).identifier(.alpha2) ?? head
        }
        if let exact = englishNames[text] { return exact }
        // "English (CC)", "Spanish - Latin America"
        return englishNames.first { text.hasPrefix($0.key) }?.value
    }

    static func matches(_ trackLanguage: String?, _ wanted: String?) -> Bool {
        guard let lhs = code(trackLanguage), let rhs = code(wanted) else { return false }
        return lhs == rhs
    }
}

enum TrackSelectionPolicy {
    struct Plan: Equatable {
        var audioTrack: Int64?
        /// 0 = subtitles off.
        var subtitleTrack: Int64?
        /// False while a wanted language has not appeared yet (late subtitles).
        var isComplete: Bool
    }

    static func plan(
        audio: [MpvTrack],
        subtitles: [MpvTrack],
        remembered: TitlePlaybackSnapshot?,
        preferredSubtitleLanguages: [String],
        autoSelectSubtitles: Bool,
    ) -> Plan {
        var plan = Plan(audioTrack: nil, subtitleTrack: nil, isComplete: true)

        if let key = remembered?.audioTrackKey, let exact = audio.first(where: { $0.preferenceKey == key }) {
            // The exact track picked for this title (role, codec, channels),
            // not just its language: a stereo dub is not the 5.1 original.
            plan.audioTrack = exact.id
        } else if let wanted = remembered?.audioLanguage {
            // The language's main track: never commentary or audio
            // description when a main track exists; the default one first.
            if let track = audio.filter({ LanguageMatcher.matches($0.lang, wanted) }).sorted(by: { lhs, rhs in
                let lhsAlternate = lhs.isCommentary || lhs.isAudioDescription
                let rhsAlternate = rhs.isCommentary || rhs.isAudioDescription
                if lhsAlternate != rhsAlternate { return !lhsAlternate }
                return lhs.isDefault && !rhs.isDefault
            }).first {
                plan.audioTrack = track.id
            } else {
                // Keep looking: external audio tracks arrive after the file opens.
                plan.isComplete = false
            }
        } else if let selected = audio.first(where: { $0.isSelected && ($0.isCommentary || $0.isAudioDescription) }),
                  let main = audio.filter({ !$0.isCommentary && !$0.isAudioDescription }).sorted(by: { lhs, rhs in
                      let lhsLanguage = LanguageMatcher.matches(lhs.lang, selected.lang)
                      let rhsLanguage = LanguageMatcher.matches(rhs.lang, selected.lang)
                      if lhsLanguage != rhsLanguage { return lhsLanguage }
                      return lhs.isDefault && !rhs.isDefault
                  }).first {
            // Nothing remembered, but the file opened on commentary or audio
            // description: switch to a main track, same language first.
            plan.audioTrack = main.id
        }

        if remembered?.subtitlesOff == true {
            plan.subtitleTrack = 0
            return plan
        }
        let wishes: [String]
        if let remembered = remembered?.subtitleLanguage {
            wishes = [remembered]
        } else if autoSelectSubtitles {
            wishes = preferredSubtitleLanguages
        } else {
            wishes = []
        }
        guard !wishes.isEmpty else { return plan }
        for wish in wishes {
            if let track = subtitles.first(where: { LanguageMatcher.matches($0.lang, wish) || LanguageMatcher.matches($0.title, wish) }) {
                plan.subtitleTrack = track.id
                return plan
            }
        }
        plan.isComplete = false
        return plan
    }
}
