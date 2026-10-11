import Foundation

/// Canonical subtitle-color presets shared by Settings and the player popover.
///
/// mpv's `sub-color`/`sub-back-color` expect `#RRGGBBAA`. Builds ≤ 1.1 stored
/// ARGB, which mpv parses as RGB+alpha — "Yellow" rendered as transparent
/// white and "Cyan" as opaque magenta. The known legacy values are migrated
/// on load (see `migratingLegacy`); `#FFFFFFFF` (white) is identical in both
/// orders and needs no migration.
enum SubtitleColor {
    static let white = "#FFFFFFFF"
    static let yellow = "#FFFF00FF"
    static let cyan = "#00FFFFFF"
    static let green = "#00FF00FF"

    static let presets: [(name: String, color: String)] = [
        ("White", white),
        ("Yellow", yellow),
        ("Cyan", cyan),
        ("Green", green),
    ]

    /// Maps a legacy ARGB preference value to its canonical RGBA form.
    /// Unknown values pass through untouched — we cannot tell ARGB from RGBA
    /// for arbitrary colors, and white is already canonical.
    static func migratingLegacy(_ raw: String?) -> String? {
        guard let raw else { return nil }
        switch raw.uppercased() {
        case "#FFFFFF00": return yellow // ARGB yellow (alpha 00 — invisible)
        case "#FF00FFFF": return cyan // ARGB cyan (mpv parsed it as magenta)
        case "#FF00FF00": return green // ARGB green (mpv parsed it as magenta)
        default: return raw
        }
    }
}

/// One subtitle styling bundle: what Settings sliders/popover edit and what
/// `MetalVideoView.setSubtitleStyle` forwards to mpv. Colors are canonical
/// `#RRGGBBAA` strings by the time they get here.
struct SubtitleStyle: Equatable, Sendable {
    var fontSize: Double
    var outlineWidth: Double
    var textColor: String?
    var backgroundColor: String?

    static let defaultFontSize: Double = 55
    static let defaultOutlineWidth: Double = 3

    init(
        fontSize: Double? = nil,
        outlineWidth: Double? = nil,
        textColor: String? = nil,
        backgroundColor: String? = nil,
    ) {
        self.fontSize = fontSize ?? Self.defaultFontSize
        self.outlineWidth = outlineWidth ?? Self.defaultOutlineWidth
        self.textColor = textColor
        self.backgroundColor = backgroundColor
    }
}
