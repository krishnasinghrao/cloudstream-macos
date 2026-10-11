import Foundation

// MARK: - Source & quality priority

/// Android `source_priority` parity: users rank extractor sources and cap
/// quality; the ranked order is both the autoplay choice and the failover
/// order. Nothing is ever dropped — avoided sources just go last, so a
/// ranking can never leave the user with no stream at all.
struct SourcePreferences: Sendable, Equatable {
    /// Preferred sources, most preferred first (normalised keys).
    var priority: [String] = []
    /// Sources to use only after everything else failed.
    var avoided: Set<String> = []
    /// Highest quality to pick automatically; 0 = best available.
    var maxQuality: Int = 0

    static let none = SourcePreferences()
}

/// The mirror a user picked for one title (`TitlePlaybackPrefs`).
struct RememberedSource: Sendable, Equatable {
    /// `LinkRanker.sourceKey`.
    var key: String
    /// Quality of the picked link; nil = any.
    var quality: Int?
}

enum LinkRanker {
    /// Stable, case-insensitive identity of a link's source (extractor name).
    static func sourceKey(_ link: StreamLinkDto) -> String {
        sourceKey(link.source.isEmpty ? link.name : link.source)
    }

    static func sourceKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 0 = preferred sources (by list position), then unranked, then avoided.
    static func sourceTier(_ link: StreamLinkDto, _ prefs: SourcePreferences) -> (Int, Int) {
        let key = sourceKey(link)
        if prefs.avoided.contains(key) { return (2, 0) }
        if let index = prefs.priority.firstIndex(of: key) { return (0, index) }
        return (1, 0)
    }

    /// Closest quality at-or-below the cap first, then above it (ascending),
    /// unknown (0) qualities last. Cap 0 = highest first.
    static func qualityRank(_ quality: Int, cap: Int) -> (Int, Int) {
        guard quality > 0 else { return (2, 0) }
        guard cap > 0 else { return (0, -quality) }
        if quality <= cap { return (0, cap - quality) }
        return (1, quality - cap)
    }

    /// A Dolby Vision stream without an HDR10 base layer (profile 5). The
    /// player's renderer does not apply Dolby Vision reshaping, so these show
    /// green or purple; they go after the other links of the same source tier.
    /// Recognised by the link name ("DV", "DoVi", "Dolby Vision") without an
    /// HDR/HDR10 marker, since DV releases with an HDR10 base play correctly.
    static func isDolbyVisionOnly(_ link: StreamLinkDto) -> Bool {
        let tokens = Set("\(link.name) \(link.source)".lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "+" }).map(String.init))
        let dolbyVision = tokens.contains("dv") || tokens.contains("dovi")
            || (tokens.contains("dolby") && tokens.contains("vision"))
        let hdrBase = tokens.contains { $0 == "hdr" || $0.hasPrefix("hdr10") }
        return dolbyVision && !hdrBase
    }

    /// Stable: equal links keep provider/arrival order.
    static func rank(_ links: [StreamLinkDto], _ prefs: SourcePreferences) -> [StreamLinkDto] {
        // Normalize source names and classify HDR once per link, rather than
        // repeating that work for every comparison in the sort.
        links.enumerated().map { offset, link in
            let tier = sourceTier(link, prefs)
            let quality = qualityRank(link.quality, cap: prefs.maxQuality)
            let key = (tier.0, tier.1, isDolbyVisionOnly(link) ? 1 : 0, quality.0, quality.1, offset)
            return (link: link, key: key)
        }.sorted { $0.key < $1.key }.map(\.link)
    }

    /// The ranked order with a title's remembered source moved to the front:
    /// its link of the remembered quality first, then its other links. An
    /// explicit pick for one title outranks the global order (even an avoided
    /// source); when the source is not offered the order is unchanged.
    static func rank(_ links: [StreamLinkDto], _ prefs: SourcePreferences, remembered: RememberedSource?) -> [StreamLinkDto] {
        let ranked = rank(links, prefs)
        guard let remembered else { return ranked }
        var exact: [StreamLinkDto] = []
        var sameSource: [StreamLinkDto] = []
        var others: [StreamLinkDto] = []
        for link in ranked {
            if sourceKey(link) != remembered.key { others.append(link) }
            else if link.quality == remembered.quality { exact.append(link) }
            else { sameSource.append(link) }
        }
        return exact + sameSource + others
    }
}
