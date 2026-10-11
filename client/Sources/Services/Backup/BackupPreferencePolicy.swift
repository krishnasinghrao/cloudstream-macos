import Foundation

/// One schema for exported keys and pre-commit restore validation. Unknown
/// keys (including paths/secrets) never travel into application preferences.
enum BackupPreferencePolicy {
    static let downloadConcurrencyRange = 1...8

    private enum Kind: Sendable {
        case bool, string, strings
        case integer(ClosedRange<Int>)
        case number(ClosedRange<Double>)
        case choice(Set<String>)
    }

    private static let schema: [String: Kind] = {
        var result: [String: Kind] = [:]
        for key in ["continuousPlayback", "videoFillsScreen", "autoAddDownloadsToLibrary",
                    "autoUpdateLibraryStatus", "rememberPlaybackPerTitle", "autoSelectSubtitles",
                    "subtitleBold", "showDiscoverOnHome", "checkForNewEpisodes", "notifyNewEpisodes",
                    "autoBackupEnabled", "indexInSpotlight", "showMenuBarExtra", "showDockBadge"] {
            result[key] = .bool
        }
        for key in ["subtitleLanguage", "subtitleTextColor", "subtitleBackgroundColor", "subtitleFont", "discoverProvider"] {
            result[key] = .string
        }
        for key in ["sourcePriority", "avoidedSources", "knownSources", "preferredSubtitleLanguages"] {
            result[key] = .strings
        }
        result["maxConcurrentDownloads"] = .integer(downloadConcurrencyRange)
        result["maxDownloadsPerProvider"] = .integer(downloadConcurrencyRange)
        result["preferredQuality"] = .integer(0...Int.max)
        result["playbackMaxQuality"] = .integer(0...Int.max)
        result["nextEpisodeCountdown"] = .integer(0...120)
        result["subtitlePosition"] = .integer(0...150)
        result["subtitleFontSize"] = .number(10...200)
        result["subtitleOutlineWidth"] = .number(0...20)
        result["subtitleShadowOffset"] = .number(0...10)
        result["seekStepSeconds"] = .number(Double.leastNonzeroMagnitude...300)
        result["manualSkipSeconds"] = .number(Double.leastNonzeroMagnitude...600)
        result["resumeBehavior"] = .choice(["ask", "alwaysResume", "alwaysStartOver"])
        return result
    }()

    static var keys: [String] { schema.keys.sorted() }

    /// Converts exact integer-valued JSON doubles safely. Reject every known
    /// invalid field before applying any field; preserve unknown-key support.
    static func validated(_ values: [String: BackupValue]) throws -> [String: BackupValue] {
        var patch: [String: BackupValue] = [:]
        for (key, value) in values {
            guard let kind = schema[key] else { continue }
            let normalized: BackupValue?
            switch (kind, value) {
            case (.bool, .bool), (.string, .string), (.strings, .strings): normalized = value
            case (.choice(let allowed), .string(let text)):
                normalized = allowed.contains(text) ? value : nil
            case (.integer(let range), .int(let number)):
                normalized = range.contains(number) ? value : nil
            case (.integer(let range), .double(let number)):
                if number.isFinite, let exact = Int(exactly: number), range.contains(exact) {
                    normalized = .int(exact)
                } else { normalized = nil }
            case (.number(let range), .double(let number)):
                normalized = number.isFinite && range.contains(number) ? value : nil
            case (.number(let range), .int(let number)):
                let converted = Double(number)
                normalized = range.contains(converted) ? .double(converted) : nil
            default: normalized = nil
            }
            guard let normalized else {
                throw BackupDocument.ValidationError.corrupt("Invalid preference '\(key)'.")
            }
            patch[key] = normalized
        }
        return patch
    }
}
