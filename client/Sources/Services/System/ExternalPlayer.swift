import AppKit

/// "Open in IINA / VLC / mpv" (Android `VideoClickAction` parity, Phase 9).
/// Streams often need a Referer / User-Agent; each player gets them in its
/// own command-line form. Arguments are passed as an argv array (no shell).
enum ExternalPlayer: String, CaseIterable, Identifiable {
    case iina = "IINA"
    case vlc = "VLC"
    case mpv = "mpv"
    case quickTime = "QuickTime Player"

    var id: String { rawValue }

    var bundleIdentifier: String? {
        switch self {
        case .iina: return "com.colliderli.iina"
        case .vlc: return "org.videolan.vlc"
        case .quickTime: return "com.apple.QuickTimePlayerX"
        case .mpv: return "io.mpv"
        }
    }

    /// Executable to launch with arguments; nil = open through Launch Services.
    var executable: URL? {
        switch self {
        case .iina:
            return appURL?.appendingPathComponent("Contents/MacOS/iina-cli")
        case .vlc:
            return appURL?.appendingPathComponent("Contents/MacOS/VLC")
        case .mpv:
            let candidates = ["/opt/homebrew/bin/mpv", "/usr/local/bin/mpv", "/opt/local/bin/mpv"]
            if let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) {
                return URL(fileURLWithPath: path)
            }
            return appURL?.appendingPathComponent("Contents/MacOS/mpv")
        case .quickTime:
            return nil
        }
    }

    var appURL: URL? {
        bundleIdentifier.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    var isInstalled: Bool {
        switch self {
        case .quickTime: return appURL != nil
        default: return executable.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false
        }
    }

    /// Headers that never go on a player's command line, where other processes could read them.
    static let credentialHeaders: Set<String> = ["authorization", "cookie", "proxy-authorization"]

    /// Headers a player may receive on its command line: only these two,
    /// which identify no one. Anything else may be a secret under any name.
    static let argumentHeaders: Set<String> = ["referer", "user-agent"]

    /// Whether [link] must reach this player through the engine relay: it
    /// needs headers the player cannot be given safely (any header for
    /// QuickTime, which takes none; anything beyond Referer/User-Agent for the
    /// others). The player then opens a loopback address with no headers, and
    /// the relay adds them only towards the provider's own origin.
    func needsRelay(_ link: StreamLinkDto) -> Bool {
        let names = link.headers.keys.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return self == .quickTime ? !names.isEmpty : names.contains { !Self.argumentHeaders.contains($0) }
    }

    /// VLC and QuickTime can't open multi-segment EDL playlists, and an EDL
    /// playlist cannot be relayed as one resource.
    func supports(_ link: StreamLinkDto) -> Bool {
        let edl = link.isPlaylist || !link.playlist.isEmpty || link.url.lowercased().hasPrefix("edl://")
        if edl && (self == .quickTime || self == .vlc) { return false }
        if edl && needsRelay(link) { return false }
        return true
    }

    static var installed: [ExternalPlayer] { allCases.filter(\.isInstalled) }

    /// argv for the player (without the executable).
    func arguments(url: String, headers: [String: String], title: String?, startAt: Double?) throws -> [String] {
        try arguments(resource: .remote(url), headers: headers, title: title, startAt: startAt)
    }

    func arguments(resource: PlaybackResource, headers: [String: String], title: String?, startAt: Double?) throws -> [String] {
        _ = try MediaResourcePolicy.headers(headers)
        // Fail closed: any process of this user can read argv, so only the two
        // identifying-nothing headers may go there. Everything else reaches the
        // player only through the relay (`needsRelay`).
        if let other = headers.keys.first(where: { !Self.argumentHeaders.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }) {
            throw MediaResourcePolicy.Rejection.invalidHeader(other)
        }
        let url = resource.url
        let referer = headers.first { $0.key.caseInsensitiveCompare("Referer") == .orderedSame }?.value
        let userAgent = headers.first { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame }?.value
        let start = startAt.flatMap { $0.isFinite && $0 > 1 ? String(format: "%.0f", $0.rounded(.towardZero)) : nil }
        // A remote stream may only pull further remote resources: the same
        // nested-protocol limits the built-in player uses, for the players
        // that accept them. A file the user chose is not restricted.
        let confinement = resource.origin == .authorizedLocal ? [] : Self.mpvConfinement
        switch self {
        case .iina:
            var args = [url] + confinement.map { "--mpv-" + $0 }
            if let referer { args.append("--mpv-referrer=\(referer)") }
            if let userAgent { args.append("--mpv-user-agent=\(userAgent)") }
            if let title { args.append("--mpv-force-media-title=\(title)") }
            if let start { args.append("--mpv-start=\(start)") }
            return args
        case .mpv:
            var args = confinement.map { "--" + $0 }
            if let referer { args.append("--referrer=\(referer)") }
            if let userAgent { args.append("--user-agent=\(userAgent)") }
            if let title { args.append("--force-media-title=\(title)") }
            if let start { args.append("--start=\(start)") }
            return args + ["--", url]
        case .vlc:
            var args: [String] = []
            if let referer { args.append("--http-referrer=\(referer)") }
            if let userAgent { args.append("--http-user-agent=\(userAgent)") }
            if let title { args.append("--meta-title=\(title)") }
            if let start { args.append("--start-time=\(start)") }
            return args + ["--", url]
        case .quickTime:
            return [url]
        }
    }

    /// mpv options (without the leading dashes) that keep a remote stream
    /// from opening local files or other protocols through nested playlists,
    /// manifests or redirects. VLC and QuickTime Player take no equivalent
    /// arguments; they apply their own policy to nested resources.
    static let mpvConfinement = [
        "load-unsafe-playlists=no",
        "demuxer-lavf-o=" + MetalVideoView.demuxerOptions,
    ]

    /// Whether this player can be told to confine nested resources.
    var confinesNestedResources: Bool { self == .mpv || self == .iina }

    enum LaunchError: LocalizedError {
        case notInstalled(String)
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled(let name): return "\(name) isn't installed."
            case .unsupported(let name): return "\(name) can't open this stream because it needs custom request headers."
            }
        }
    }

    /// [relayedURL]: the engine relay's loopback address for [link] when
    /// `needsRelay(link)`; the player then gets that address and no headers.
    @MainActor
    func open(_ link: StreamLinkDto, title: String?, startAt: Double?, authorizedLocal: PlaybackResource? = nil,
              relayedURL: String? = nil) throws {
        let resource: PlaybackResource
        var headers = link.headers
        if let relayedURL {
            guard authorizedLocal == nil, !link.isPlaylist, URLComponents(string: relayedURL).map({ $0.scheme == "http" && $0.host == "127.0.0.1" }) == true else {
                throw MediaResourcePolicy.Rejection.unsupportedURL
            }
            try MediaResourcePolicy.validate(link)
            resource = try .remote(relayedURL)
            headers = [:]
        } else if let authorizedLocal {
            guard authorizedLocal.origin == .authorizedLocal, authorizedLocal.url == link.url, link.headers.isEmpty,
                  link.audioTracks.isEmpty, link.playlist.isEmpty else {
                throw MediaResourcePolicy.Rejection.unauthorizedLocalFile
            }
            resource = authorizedLocal
        } else {
            try MediaResourcePolicy.validate(link)
            if link.isPlaylist {
                resource = try .playlist(link.playlist)
            } else { resource = try .remote(link.url) }
        }
        guard isInstalled else { throw LaunchError.notInstalled(rawValue) }
        // Fail closed: a stream whose headers this player can't be given goes only through the relay.
        guard supports(link), relayedURL != nil || !needsRelay(link) else { throw LaunchError.unsupported(rawValue) }
        if let executable {
            let process = Process()
            process.executableURL = executable
            process.arguments = try arguments(resource: resource, headers: headers, title: title, startAt: startAt)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        } else if let remote = resource.origin == .authorizedLocal ? URL(fileURLWithPath: resource.url) : URL(string: resource.url), let appURL {
            NSWorkspace.shared.open([remote], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        }
        DaemonLog.client("player.external_open", fields: ["player": rawValue])
    }
}
