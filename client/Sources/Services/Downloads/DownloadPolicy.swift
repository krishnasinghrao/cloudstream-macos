import Foundation

/// Pure, side-effect-free download policy: failure taxonomy, retry
/// disposition, mirror ordering, header/URL hygiene, and file naming.
/// Everything here is `nonisolated` and unit-tested in isolation from the
/// queue orchestration in `DownloadService`.
enum DownloadPolicy {
    // MARK: - Volume capacity

    struct VolumeCapacity: Equatable, Sendable {
        var name: String?
        var free: Int64
        var total: Int64
        var isInternal: Bool
    }

    /// `volumeAvailableCapacityForImportantUsage` is only meaningful on
    /// APFS; exFAT/HFS+/NTFS/network volumes report 0 (or nil) for it even
    /// when they are nearly empty. Fall back to the plain capacity there.
    nonisolated static func freeBytes(importantUsage: Int64?, available: Int64?) -> Int64? {
        if let importantUsage, importantUsage > 0 { return importantUsage }
        return available ?? importantUsage
    }

    /// Capacity of the volume holding `url`, or nil when it cannot be read
    /// (missing folder, unplugged drive).
    nonisolated static func volumeCapacity(for url: URL) -> VolumeCapacity? {
        // Read fresh values: URL caches resource values per instance.
        var url = url
        url.removeAllCachedResourceValues()
        guard let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
            .volumeTotalCapacityKey, .volumeLocalizedNameKey, .volumeIsInternalKey,
        ]) else { return nil }
        guard let free = freeBytes(
            importantUsage: values.volumeAvailableCapacityForImportantUsage,
            available: values.volumeAvailableCapacity.map(Int64.init),
        ) else { return nil }
        return VolumeCapacity(
            name: values.volumeLocalizedName,
            free: free,
            total: Int64(values.volumeTotalCapacity ?? 0),
            isInternal: values.volumeIsInternal ?? true,
        )
    }

    // MARK: - Failure taxonomy

    /// What the queue should do after a failed attempt (Android
    /// `DownloadStatus` parity: retrySame / tryNext / invalid input).
    enum Disposition: Equatable {
        /// Transient (network blip, stall, truncated transfer): re-resolve and
        /// retry the same mirror once before moving on.
        case retrySameMirror
        /// Mirror-specific (403/404, bad media, unsupported protocol): skip
        /// to the next mirror.
        case nextMirror
        /// Local or permanent (disk full, unwritable folder, missing
        /// provider): trying other mirrors cannot help.
        case terminal
    }

    enum FailureReason: Equatable, Sendable {
        case forbidden
        case notFound
        case httpStatus(Int)
        case protocolUnsupported
        case diskFull
        case permissionDenied
        case destinationUnavailable(String)
        case incompatibleContainer
        case invalidMedia
        case truncated
        case stalled
        case network(String)
        case noLinks
        case providerUnavailable(provider: String, reason: String?)
        case linkResolution(String)
        /// The transfer finished, but the part file could not be renamed to
        /// its final name. The part is kept and the rename retried (audit M2).
        case finalizeFailed(String)
        /// A credentialed stream could not be routed through the engine relay;
        /// its credentials are never handed to ffmpeg instead (audit A2).
        case relayUnavailable
        case unknown(String)

        var label: String {
            switch self {
            case .forbidden: return "Access denied by host (403)"
            case .notFound: return "Stream not found (404)"
            case .httpStatus(let code): return "Host returned HTTP \(code)"
            case .protocolUnsupported: return "Unsupported stream protocol"
            case .diskFull: return "Disk is full"
            case .permissionDenied: return "No permission to write to the download folder"
            case .destinationUnavailable(let detail): return "Download folder unavailable — \(detail)"
            case .incompatibleContainer: return "Stream format could not be saved"
            case .invalidMedia: return "Host did not return a playable video"
            case .truncated: return "Transfer ended early (incomplete file)"
            case .stalled: return "Download stalled (no data received)"
            case .network(let detail): return "Network error — \(detail)"
            case .noLinks: return "No downloadable links found"
            case .providerUnavailable(let name, let reason): return reason ?? "Provider “\(name)” is not installed or is disabled"
            case .linkResolution(let detail): return "Couldn't resolve links — \(detail)"
            case .finalizeFailed(let detail): return "Couldn’t move the finished file into place — \(detail)"
            case .relayUnavailable: return "Couldn’t prepare a protected stream for download"
            case .unknown(let detail): return detail
            }
        }

        var disposition: Disposition {
            switch self {
            case .diskFull, .permissionDenied, .destinationUnavailable, .providerUnavailable, .noLinks, .finalizeFailed:
                return .terminal
            case .truncated, .stalled, .network, .incompatibleContainer, .relayUnavailable:
                return .retrySameMirror
            case .httpStatus(let code) where code == 429 || code >= 500:
                return .retrySameMirror
            case .forbidden, .notFound, .httpStatus, .protocolUnsupported, .invalidMedia,
                 .linkResolution, .unknown:
                return .nextMirror
            }
        }
    }

    /// Classifies ffmpeg's stderr. Patterns are anchored to ffmpeg's actual
    /// messages ("Server returned 403 Forbidden", "HTTP error 404 Not Found")
    /// — bare substrings like "403" would match bitrates ("1403 kb/s") and
    /// "not found" would match "Encoder not found".
    nonisolated static func classifyFFmpegFailure(exitStatus: Int32, stderrTail: String) -> FailureReason {
        let text = stderrTail.lowercased()

        // Local, terminal conditions first: no mirror can fix them.
        if text.contains("no space left on device") || text.contains("disk quota exceeded") {
            return .diskFull
        }
        if text.contains("permission denied") || text.contains("operation not permitted")
            || text.contains("read-only file system") {
            return .permissionDenied
        }
        if text.contains("file name too long") {
            return .destinationUnavailable("file name too long")
        }

        // Stream → container mismatch: retried once as Matroska.
        if text.contains("could not find tag for codec") || text.contains("not currently supported in container")
            || text.contains("could not write header") {
            return .incompatibleContainer
        }

        if text.contains("protocol not found") || text.contains("unsupported protocol")
            || text.contains("not on whitelist") {
            return .protocolUnsupported
        }

        if let status = httpStatus(in: text) {
            switch status {
            case 403: return .forbidden
            case 404: return .notFound
            default: return .httpStatus(status)
            }
        }

        if text.contains("invalid data found when processing input") || text.contains("does not contain any stream")
            || text.contains("matches no streams") || text.contains("output file does not contain any stream") {
            return .invalidMedia
        }

        let networkMarkers = [
            "connection timed out", "operation timed out", "connection reset", "connection refused",
            "network is unreachable", "network is down", "i/o error", "input/output error",
            "failed to resolve hostname", "broken pipe", "end of file",
        ]
        if let marker = networkMarkers.first(where: text.contains) {
            return .network(marker)
        }

        return .unknown("ffmpeg exit \(exitStatus)")
    }

    /// Extracts the HTTP status from ffmpeg's two HTTP error phrasings.
    nonisolated static func httpStatus(in loweredText: String) -> Int? {
        for prefix in ["server returned ", "http error "] {
            var searchRange = loweredText.startIndex..<loweredText.endIndex
            while let range = loweredText.range(of: prefix, range: searchRange) {
                let digits = loweredText[range.upperBound...].prefix(3)
                if digits.count == 3, digits.allSatisfy(\.isNumber), let code = Int(digits), (400...599).contains(code) {
                    return code
                }
                searchRange = range.upperBound..<loweredText.endIndex
            }
        }
        return nil
    }

    // MARK: - Link selection

    /// Link types a file download can handle. Torrents/magnets need a
    /// different client entirely; playlists are the player's concern.
    nonisolated static func isDownloadable(_ link: StreamLinkDto) -> Bool {
        guard !link.isPlaylist, isAllowedRemoteURL(link.url) else { return false }
        do { try MediaResourcePolicy.validate(link) } catch { return false }
        switch link.type.uppercased() {
        case "TORRENT", "MAGNET": return false
        default: return true
        }
    }

    /// Direct files use the resumable HTTP downloader; everything else
    /// (HLS, DASH) is remuxed by ffmpeg.
    nonisolated static func isDirectFile(_ link: StreamLinkDto) -> Bool {
        guard link.type.uppercased() == "VIDEO", link.audioTracks.isEmpty else { return false }
        let path = (URL(string: link.url)?.path ?? "").lowercased()
        return !(path.hasSuffix(".m3u8") || path.hasSuffix(".m3u") || path.hasSuffix(".mpd"))
    }

    /// Candidate order: preferred quality first (closest at-or-below, then
    /// the rest by descending quality), unknown qualities last. `0` means
    /// "best available". Stable for equal qualities (provider order kept).
    /// The user's source priority (Settings ▸ Playback ▸ Sources) ranks
    /// first; avoided sources go last but are kept as fallbacks.
    nonisolated static func orderedCandidates(
        _ links: [StreamLinkDto],
        preferredQuality: Int,
        sources: SourcePreferences = .none,
        choice: SourceChoice? = nil,
    ) -> [StreamLinkDto] {
        var prefs = sources
        prefs.maxQuality = preferredQuality
        let ranked = LinkRanker.rank(links.filter(isDownloadable), prefs)
        guard let choice else { return ranked }
        // The user's pick goes first (closest match leading); everything
        // else keeps its automatic order as the fallback chain.
        return ranked.enumerated().sorted { lhs, rhs in
            let l = choice.matchRank(lhs.element) ?? Int.max
            let r = choice.matchRank(rhs.element) ?? Int.max
            return l != r ? l < r : lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// A source the user picked for a download. Stored by identity, never by
    /// URL: links are re-resolved just in time and CDN URLs rotate. For a
    /// season the pick comes from one episode and is matched loosely on the
    /// others.
    struct SourceChoice: Codable, Hashable, Sendable {
        var source: String
        var name: String
        var quality: Int

        init(source: String, name: String, quality: Int) {
            self.source = source
            self.name = name
            self.quality = quality
        }

        init(_ link: StreamLinkDto) {
            self.init(source: link.source, name: link.name, quality: link.quality)
        }

        /// 0 = same source, name and quality; 1 = same source and name;
        /// 2 = same source; nil = a different source.
        func matchRank(_ link: StreamLinkDto) -> Int? {
            guard LinkRanker.sourceKey(link) == LinkRanker.sourceKey(source.isEmpty ? name : source) else { return nil }
            guard LinkRanker.sourceKey(link.name) == LinkRanker.sourceKey(name) else { return 2 }
            return link.quality == quality ? 0 : 1
        }

        /// Persisted form (`DownloadRecord.preferredSource`).
        var storage: String? {
            (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
        }

        init?(storage: String?) {
            guard let data = storage?.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(SourceChoice.self, from: data) else { return nil }
            self = decoded
        }
    }

    /// Stable identity of a mirror across re-resolutions: CDN URLs rotate
    /// tokens on every resolve, but source/name/quality stay put. Repeated
    /// identities are disambiguated by occurrence.
    nonisolated static func mirrorKeys(for links: [StreamLinkDto]) -> [String] {
        var seen: [String: Int] = [:]
        return links.map { link in
            let base = "\(link.source)|\(link.name)|\(link.quality)|\(link.type.uppercased())"
            let occurrence = seen[base, default: 0]
            seen[base] = occurrence + 1
            return "\(base)#\(occurrence)"
        }
    }

    // MARK: - URL & header hygiene

    /// Only plain web URLs may reach ffmpeg or URLSession: `file:`,
    /// `concat:`, `subfile:`, `pipe:` etc. would let a malicious page or
    /// plugin read local files or open raw sockets.
    nonisolated static func isAllowedRemoteURL(_ raw: String) -> Bool {
        do { try MediaResourcePolicy.remoteURL(raw); return true }
        catch { return false }
    }

    /// Protocols ffmpeg may open for the input and anything it references
    /// (HLS segments, keys). `data` carries inline bytes only (DASH
    /// initialization segments and keys written into the manifest, which the
    /// DASH demuxer needs, Remediation 3.2); it reaches no file or host, so it
    /// widens nothing a playlist could not already serve over http. Excludes
    /// `file`, `concat`, `subfile`, `pipe`, `udp`, `rtmp`…
    nonisolated static let ffmpegProtocolWhitelist = "http,https,tls,tcp,crypto,httpproxy,data"

    /// HLS demuxer options. Scraped playlists often disguise segments as
    /// `.jpg`, `.png` or `.html`, which FFmpeg 7.1+ refuses by default
    /// (`extension_picky`). Accepting any extension does not widen what can
    /// be opened: the protocol whitelist still confines every segment and key
    /// to http(s), and mpv keeps `load-unsafe-playlists=no`.
    nonisolated static let hlsDemuxerOptions = [
        ("allowed_extensions", "ALL"),
        ("allowed_segment_extensions", "ALL"),
        ("extension_picky", "0"),
    ]

    /// ``hlsDemuxerOptions`` as ffmpeg command-line input options.
    nonisolated static let ffmpegHLSInputOptions = hlsDemuxerOptions.flatMap { ["-\($0.0)", $0.1] }

    /// Whether ffmpeg will open this input with its HLS demuxer.
    nonisolated static func isHLS(url: String, type: String?) -> Bool {
        if type?.uppercased() == "M3U8" { return true }
        let path = (URL(string: url)?.path ?? url).lowercased()
        return path.hasSuffix(".m3u8") || path.hasSuffix(".m3u")
    }

    /// The same rejecting header boundary used by native/external playback.
    nonisolated static func sanitizedHeaders(_ headers: [String: String]) throws -> [(name: String, value: String)] {
        try MediaResourcePolicy.headers(headers)
    }

    /// Case-insensitive header lookup ("Referer", "referer", "REFERER").
    nonisolated static func header(_ name: String, in headers: [(name: String, value: String)]) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    // MARK: - File naming

    /// Longest base name in UTF-8 bytes. APFS allows 255 bytes per component;
    /// the rest is budget for " (99)", ".part", ".en.vtt" and friends.
    nonisolated static let maxBaseNameBytes = 180

    nonisolated static func sanitizedFileName(_ raw: String) -> String {
        var name = raw
            .replacing("/", with: "_")
            .replacing(":", with: " -")
        name = name.components(separatedBy: .newlines.union(.controlCharacters)).joined(separator: " ")
        // A leading dot would make the file invisible in Finder (".hack//Sign").
        while name.hasPrefix(".") || name.hasPrefix(" ") {
            name.removeFirst()
        }
        name = truncatedToUTF8(name, maxBytes: maxBaseNameBytes)
        while name.hasSuffix(".") || name.hasSuffix(" ") {
            name.removeLast()
        }
        return name.isEmpty ? "Download" : name
    }

    /// Truncates on a Character boundary so multi-byte glyphs never split.
    nonisolated static func truncatedToUTF8(_ string: String, maxBytes: Int) -> String {
        guard string.utf8.count > maxBytes else { return string }
        var result = ""
        var bytes = 0
        for character in string {
            let size = String(character).utf8.count
            if bytes + size > maxBytes { break }
            result.append(character)
            bytes += size
        }
        return result
    }

    /// Video extensions a finished download may carry; used for collision
    /// checks so "Show.mkv" also blocks a new "Show.mp4".
    nonisolated static let videoExtensions = ["mp4", "mkv", "webm", "m4v", "mov", "ts", "avi"]
    nonisolated static let subtitleExtensions = ["vtt", "srt", "ass", "ssa"]

    /// Final extension for a direct file from its URL, then its MIME type.
    nonisolated static func directFileExtension(url: URL?, mimeType: String?) -> String {
        if let ext = url?.pathExtension.lowercased(), videoExtensions.contains(ext) {
            return ext
        }
        switch mimeType?.lowercased() {
        case "video/x-matroska": return "mkv"
        case "video/webm": return "webm"
        case "video/quicktime": return "mov"
        case "video/mp2t": return "ts"
        case "video/x-msvideo": return "avi"
        default: return "mp4"
        }
    }

    /// Picks up to `limit` subtitles in the preferred language (code prefix
    /// or label match), mirroring Android's language-filtered sidecar
    /// download. Only http(s) sources are accepted.
    nonisolated static func subtitlesToDownload(_ subtitles: [SubtitleDto], preferredLanguage: String, limit: Int = 3) -> [SubtitleDto] {
        let wanted = preferredLanguage.lowercased().trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return [] }
        let englishName = Locale(identifier: "en").localizedString(forLanguageCode: wanted)?.lowercased()
        var seen = Set<String>()
        return subtitles.filter { sub in
            guard isAllowedRemoteURL(sub.url), seen.insert(sub.url).inserted else { return false }
            let language = sub.language.lowercased()
            let label = (sub.label ?? "").lowercased()
            if language == wanted || language.hasPrefix(wanted + "-") || language.hasPrefix(wanted + "_") {
                return true
            }
            if let englishName, language.contains(englishName) || label.contains(englishName) {
                return true
            }
            return false
        }
        .prefix(limit)
        .map { $0 }
    }

    /// Extension for a subtitle sidecar from MIME type or URL.
    nonisolated static func subtitleExtension(for subtitle: SubtitleDto) -> String {
        switch subtitle.mimeType?.lowercased() {
        case "application/x-subrip", "text/srt": return "srt"
        case "text/vtt": return "vtt"
        default: break
        }
        let ext = (URL(string: subtitle.url)?.pathExtension ?? "").lowercased()
        return subtitleExtensions.contains(ext) ? ext : "vtt"
    }

    // MARK: - ffmpeg stderr parsing

    /// Input duration from ffmpeg's "Duration: 01:02:03.45" banner line;
    /// nil for live streams ("Duration: N/A").
    nonisolated static func parseInputDuration(_ text: String) -> Double? {
        guard let range = text.range(of: "Duration: ") else { return nil }
        let token = text[range.upperBound...].prefix(while: { $0 != "," && !$0.isNewline })
        let parts = token.split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2]) else { return nil }
        let total = hours * 3600 + minutes * 60 + seconds
        return total > 0 ? total : nil
    }

    /// A transfer that stopped well short of the source's own duration is
    /// truncated (e.g. an HLS playlist that 404'd mid-way but ffmpeg still
    /// exited 0). Tolerance covers rounding and trailing short segments.
    nonisolated static func isTruncated(written: Double, expected: Double?) -> Bool {
        guard let expected, expected > 60 else { return false }
        return written < expected * 0.97 && expected - written > 5
    }
}
