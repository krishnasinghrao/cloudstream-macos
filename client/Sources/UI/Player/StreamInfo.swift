import Foundation

/// What is playing, as mpv reports it: resolution, codec, colour primaries,
/// transfer and HDR type, decoder and renderer. Shown on request in the
/// player, so a pale or oddly coloured stream can be checked against what it
/// actually is (for example BT.2020 with PQ for HDR10).
struct StreamInfo: Equatable, Sendable {
    var width: Int64 = 0
    var height: Int64 = 0
    var codec: String?
    var primaries: String?
    var transfer: String?
    var decoder: String?
    var renderer: String?
    var dolbyVisionProfile: Int64?

    /// mpv properties this model is built from (observed by MetalVideoView).
    static let observedStringProperties = ["video-codec", "video-params/primaries", "video-params/gamma", "hwdec-current"]
    static let observedIntegerProperties = ["current-tracks/video/dolby-vision-profile"]

    var dynamicRange: String {
        if let dolbyVisionProfile, dolbyVisionProfile > 0 { return "Dolby Vision \(dolbyVisionProfile)" }
        switch transfer {
        case "pq": return "HDR10"
        case "hlg": return "HLG"
        case nil: return "—"
        default: return "SDR"
        }
    }

    /// One line, for example "3840×2160 · HEVC · BT.2020 / PQ · HDR10 · VideoToolbox · GPU".
    var summary: String {
        var parts: [String] = []
        if width > 0, height > 0 { parts.append("\(width)×\(height)") }
        if let codec { parts.append(Self.shortCodec(codec)) }
        if primaries != nil || transfer != nil {
            parts.append("\(Self.label(primaries)) / \(Self.label(transfer))")
        }
        parts.append(dynamicRange)
        parts.append(Self.decoderLabel(decoder))
        if let renderer { parts.append(renderer == "gpu" ? "GPU" : "Software renderer") }
        return parts.joined(separator: " · ")
    }

    /// Applies one observed property; returns whether anything changed.
    @discardableResult
    mutating func apply(_ name: String, _ value: MpvValue) -> Bool {
        let before = self
        let text = value.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        switch name {
        case "dwidth": width = value.int64Value ?? 0
        case "dheight": height = value.int64Value ?? 0
        case "video-codec": codec = text
        case "video-params/primaries": primaries = text
        case "video-params/gamma": transfer = text
        case "hwdec-current": decoder = text
        case "current-tracks/video/dolby-vision-profile": dolbyVisionProfile = value.int64Value.flatMap { $0 > 0 ? $0 : nil }
        default: return false
        }
        return self != before
    }

    /// mpv describes codecs in prose ("H.265 / HEVC …", "Google VP9"): the
    /// well-known name, else the first word.
    static func shortCodec(_ codec: String) -> String {
        let known = ["H.264", "H.265", "HEVC", "AVC", "VP9", "VP8", "AV1", "MPEG-2", "MPEG-4", "VC-1", "ProRes"]
        let upper = codec.uppercased()
        if let match = known.first(where: { upper.contains($0.uppercased()) }) {
            return match == "HEVC" ? "H.265" : match == "AVC" ? "H.264" : match
        }
        return (codec.split(separator: " ").first.map(String.init) ?? codec).uppercased()
    }

    static func label(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "?" }
        return value.hasPrefix("bt.") ? "BT." + value.dropFirst(3) : value.uppercased()
    }

    static func decoderLabel(_ decoder: String?) -> String {
        switch decoder {
        case nil, "", "no": return "Software decode"
        case let value? where value.hasPrefix("videotoolbox"): return "VideoToolbox"
        case let value?: return value
        }
    }
}
