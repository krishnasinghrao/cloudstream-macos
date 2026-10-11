import Foundation

/// Validation and provenance at the last privileged media boundary. Returning
/// the original URL string preserves signed query bytes; this is deliberately
/// separate from tracking cleanup and URL display/redaction.
enum MediaResourcePolicy {
    enum Rejection: LocalizedError, Equatable {
        case unsupportedURL
        case invalidHeader(String)
        case invalidPlaylist
        case unauthorizedLocalFile
        /// A split stream whose audio needs request headers the single
        /// native request-header set cannot scope to it. The player then
        /// asks the engine to relay each resource with its own headers; this
        /// is shown only when that could not be set up.
        case unsupportedSplitHeaders
        /// A stream sent with credentials (cookies, authorization) is read
        /// through the engine relay, so they never reach other hosts its
        /// playlist or redirects name; shown only when that failed.
        case credentialedStream
        case invalidDecryptionKey

        var errorDescription: String? {
            switch self {
            case .invalidDecryptionKey: return "The provider returned an invalid decryption key."
            case .credentialedStream:
                return "This source needs sign-in data that couldn’t be kept to its own server. Try another source."
            case .unsupportedSplitHeaders:
                return "This source keeps its audio behind different request headers than its video, and separate requests couldn’t be set up for it. Try another source, or download it."
            case .unsupportedURL: return "The provider returned an unsupported or invalid media URL."
            case .invalidHeader(let name): return "The provider returned an invalid request header (\(name))."
            case .invalidPlaylist: return "The provider returned an invalid media playlist."
            case .unauthorizedLocalFile: return "Local playback requires an explicitly selected or downloaded file."
            }
        }
    }

    @discardableResult
    static func remoteURL(_ raw: String) throws -> String {
        guard !raw.isEmpty, !raw.unicodeScalars.contains(where: {
            $0.value <= 32 || CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
        }),
              let components = URLComponents(string: raw),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.url != nil else { throw Rejection.unsupportedURL }
        // Foundation may repair malformed percent escapes; native consumers
        // must receive an already valid URI rather than a repaired spelling.
        let bytes = Array(raw.utf8)
        for index in bytes.indices where bytes[index] == 37 {
            guard index + 2 < bytes.count, isHex(bytes[index + 1]), isHex(bytes[index + 2]) else {
                throw Rejection.unsupportedURL
            }
        }
        return raw
    }

    /// The native player sends one header set to every resource of a merged
    /// split stream. That is only correct when each audio track would get the
    /// same headers anyway, and it must never carry the video's credentials
    /// to a different audio origin.
    static func validateSplitHeaders(video: String, headers: [String: String], audio: [AudioTrackDto]) throws {
        let videoHeaders = folded(headers)
        let videoOrigin = origin(video)
        for track in audio {
            let own = folded(track.headers)
            if own == videoHeaders { continue }
            // Different headers of its own cannot be expressed at all.
            guard own.isEmpty else { throw Rejection.unsupportedSplitHeaders }
            // No headers of its own: the video's set reaches it. Allowed for
            // the same origin, or when nothing in the set is a credential.
            if origin(track.url) != videoOrigin, !Set(videoHeaders.keys).isSubset(of: shareableHeaders) {
                throw Rejection.unsupportedSplitHeaders
            }
        }
    }

    /// Header names that are credentials.
    static let credentialHeaders: Set<String> = ["authorization", "cookie", "proxy-authorization"]

    /// Whether the link or one of its audio tracks is requested with
    /// credentials. Native players send one header set to every host a
    /// playlist, manifest or redirect names; such links go through the relay.
    static func carriesCredentials(_ link: StreamLinkDto) -> Bool {
        func credentialed(_ headers: [String: String]) -> Bool { headers.keys.contains { credentialHeaders.contains($0.lowercased()) } }
        return credentialed(link.headers) || link.audioTracks.contains { credentialed($0.headers) }
    }

    /// The per-resource requests of a split stream that the single native
    /// header set cannot express: the video first, then `orderedAudio`. A
    /// track with headers of its own gets exactly those; one without gets
    /// the video's, minus credentials when it lives on another origin.
    static func relayResources(video: String, headers: [String: String], orderedAudio: [AudioTrackDto]) -> [MediaRelayResourceDto] {
        let videoOrigin = origin(video)
        return [MediaRelayResourceDto(url: video, headers: headers)] + orderedAudio.map { track in
            if !track.headers.isEmpty { return MediaRelayResourceDto(url: track.url, headers: track.headers) }
            let inherited = origin(track.url) == videoOrigin ? headers : headers.filter { shareableHeaders.contains($0.key.lowercased()) }
            return MediaRelayResourceDto(url: track.url, headers: inherited)
        }
    }

    /// Not credentials: fine to repeat to another origin.
    static let shareableHeaders: Set<String> = ["user-agent", "referer", "origin", "accept", "accept-language", "accept-encoding"]

    private static func folded(_ raw: [String: String]) -> [String: String] {
        Dictionary(raw.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    static func origin(_ raw: String) -> String? {
        guard let parts = URLComponents(string: raw), let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased() else { return nil }
        return "\(scheme)://\(host):\(parts.port ?? (scheme == "https" ? 443 : 80))"
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }

    private static let prohibitedHeaders: Set<String> = [
        "host", "content-length", "transfer-encoding", "connection", "proxy-connection",
        "upgrade", "trailer", "te", "proxy-authorization",
    ]

    /// Reject the entire request rather than silently repairing or dropping an
    /// unsafe header. Legitimate resource-scoped auth/referer/UA stay intact.
    static func headers(_ raw: [String: String]) throws -> [(name: String, value: String)] {
        let punctuation = Set("!#$%&'*+-.^_`|~".utf8)
        var seen = Set<String>()
        return try raw.map { name, value in
            let folded = name.lowercased()
            guard !name.isEmpty, name.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || punctuation.contains($0)
            }), !prohibitedHeaders.contains(folded), seen.insert(folded).inserted,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }) else {
                // Never include the value: it may contain credentials.
                throw Rejection.invalidHeader(name.unicodeScalars.filter { $0.value >= 32 && $0.value < 127 }.prefix(64).map(String.init).joined())
            }
            return (name, value)
        }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    static let maximumPlaylistSegments = 500
    static let maximumAudioTracks = 32

    static func validate(_ link: StreamLinkDto) throws {
        try remoteURL(link.url)
        _ = try headers(link.headers)
        guard link.playlist.count <= maximumPlaylistSegments, link.audioTracks.count <= maximumAudioTracks,
              !link.isPlaylist || !link.playlist.isEmpty else { throw Rejection.invalidPlaylist }
        for segment in link.playlist { try remoteURL(segment) }
        for audio in link.audioTracks {
            try remoteURL(audio.url)
            _ = try headers(audio.headers)
        }
        if let drm = link.drm {
            guard isHexKey(drm.key), drm.kid.map(isHexKey) ?? true else { throw Rejection.invalidDecryptionKey }
        }
    }

    /// A 128-bit key or key ID as lowercase hex. Anything else could smuggle
    /// separators into FFmpeg's option string.
    static func isHexKey(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// Native pseudo-protocols can only originate in an application-generated
/// plan. A provider URL can never acquire local-file or generated provenance.
struct PlaybackResource: Equatable, Sendable {
    enum Origin: Equatable, Sendable { case providerRemote, generatedRemote, authorizedLocal }
    let url: String
    let origin: Origin

    private init(url: String, origin: Origin) { self.url = url; self.origin = origin }

    static func remote(_ raw: String) throws -> Self {
        Self(url: try MediaResourcePolicy.remoteURL(raw), origin: .providerRemote)
    }

    /// Only these builders can create trusted pseudo-protocols. Callers supply
    /// validated media components, never a preassembled manifest or closure.
    static func playlist(_ segments: [String]) throws -> Self {
        guard !segments.isEmpty, segments.count <= MediaResourcePolicy.maximumPlaylistSegments else {
            throw MediaResourcePolicy.Rejection.invalidPlaylist
        }
        for segment in segments { try MediaResourcePolicy.remoteURL(segment) }
        return Self(url: "edl://" + segments.map(edlQuoted).joined(separator: ";"), origin: .generatedRemote)
    }

    /// - Parameter relayed: engine relay addresses for the video followed by
    ///   each audio track, when the resources need separate request headers.
    ///   Track metadata and the codec guess still come from the provider's
    ///   own descriptions.
    static func split(video: String, orderedAudio: [AudioTrackDto], relayed: [String]? = nil) throws -> Self {
        try MediaResourcePolicy.remoteURL(video)
        guard orderedAudio.count <= MediaResourcePolicy.maximumAudioTracks else {
            throw MediaResourcePolicy.Rejection.invalidPlaylist
        }
        if let relayed {
            guard relayed.count == orderedAudio.count + 1,
                  relayed.allSatisfy({ URLComponents(string: $0).map { $0.scheme == "http" && $0.host == "127.0.0.1" } == true }) else {
                throw MediaResourcePolicy.Rejection.invalidPlaylist
            }
            for address in relayed { try MediaResourcePolicy.remoteURL(address) }
        }
        guard !orderedAudio.isEmpty else { return try .remote(relayed?[0] ?? video) }
        var parts = ["!no_clip", "!no_chapters", edlQuoted(relayed?[0] ?? video)]
        for (index, track) in orderedAudio.enumerated() {
            try MediaResourcePolicy.remoteURL(track.url)
            _ = try MediaResourcePolicy.headers(track.headers)
            parts += ["!new_stream", "!no_clip", "!no_chapters"]
            if index > 0 { parts.append("!delay_open,media_type=audio,codec=" + audioCodecGuess(track)) }
            var metadata: [String] = []
            if let language = track.language, !language.isEmpty { metadata.append("lang=" + edlQuoted(language)) }
            if let label = track.label, !label.isEmpty { metadata.append("title=" + edlQuoted(label)) }
            if !metadata.isEmpty { parts.append((["!track_meta"] + metadata).joined(separator: ",")) }
            parts.append(edlQuoted(relayed?[index + 1] ?? track.url))
        }
        guard !parts.contains(where: { $0.contains("\0") }) else { throw MediaResourcePolicy.Rejection.invalidPlaylist }
        return Self(url: "edl://" + parts.joined(separator: ";"), origin: .generatedRemote)
    }

    static func edlQuoted(_ value: String) -> String { "%\(value.utf8.count)%\(value)" }

    static func audioCodecGuess(_ track: AudioTrackDto) -> String {
        let text = ((track.label ?? "") + " " + (track.url.removingPercentEncoding ?? track.url)).lowercased()
        if text.contains("opus") || text.contains("audio/webm") || text.contains(".webm") { return "opus" }
        if text.contains("vorbis") || text.contains(".ogg") { return "vorbis" }
        if text.contains("flac") { return "flac" }
        if text.contains("mp3") || text.contains("mpeg") { return "mp3" }
        return "aac"
    }

    static func authorizedLocal(_ file: URL) throws -> Self {
        guard file.isFileURL, !file.path.isEmpty, !file.path.contains("\0"),
              file.host == nil || file.host == "" || file.host == "localhost" else {
            throw MediaResourcePolicy.Rejection.unauthorizedLocalFile
        }
        return Self(url: file.path, origin: .authorizedLocal)
    }
}

struct PlaybackSubtitle: Equatable, Sendable {
    let dto: SubtitleDto
    let resource: PlaybackResource

    static func remote(_ dto: SubtitleDto) throws -> Self {
        Self(dto: dto, resource: try .remote(dto.url))
    }

    static func authorizedLocal(_ dto: SubtitleDto, file: URL) throws -> Self {
        let resource = try PlaybackResource.authorizedLocal(file)
        guard dto.url == resource.url || dto.url == file.absoluteString else {
            throw MediaResourcePolicy.Rejection.unauthorizedLocalFile
        }
        return Self(dto: dto, resource: resource)
    }
}

struct PlaybackAudio: Equatable, Sendable {
    let dto: AudioTrackDto
    let resource: PlaybackResource

    static func remote(_ dto: AudioTrackDto) throws -> Self {
        _ = try MediaResourcePolicy.headers(dto.headers)
        return Self(dto: dto, resource: try .remote(dto.url))
    }

    static func authorizedLocal(_ dto: AudioTrackDto, file: URL) throws -> Self {
        let resource = try PlaybackResource.authorizedLocal(file)
        guard dto.headers.isEmpty, dto.url == resource.url || dto.url == file.absoluteString else {
            throw MediaResourcePolicy.Rejection.unauthorizedLocalFile
        }
        return Self(dto: dto, resource: resource)
    }
}
