import AVKit
import MediaPlayer

/// macOS Control Center + hardware media key integration
/// (Architecture.md §2.1). Bridges libmpv playback state to
/// `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter`.
@MainActor
final class NowPlayingService {
    static let shared = NowPlayingService()

    private let center = MPNowPlayingInfoCenter.default()
    private let commandCenter = MPRemoteCommandCenter.shared()
    private var commandsInstalled = false

    private var playHandler: (() -> Void)?
    private var pauseHandler: (() -> Void)?
    private var toggleHandler: (() -> Void)?
    private var seekHandler: ((Double) -> Void)?
    private var skipHandler: ((Double) -> Void)?
    private var nextHandler: (() -> Void)?
    private var previousHandler: (() -> Void)?

    /// Skip interval advertised to Control Center / media keys; matches the
    /// player's ←/→ step.
    static let skipInterval: Double = 10

    /// Artwork fetched per URL exactly once — `updateNowPlaying` fires on
    /// every throttled progress tick, and re-downloading the poster each time
    /// was pure network waste.
    /// Artwork for the current title only; one entry, so a long session of
    /// different titles cannot accumulate images. Bytes come from ImageCache.
    private var currentArtwork: (url: String, artwork: MPMediaItemArtwork)?
    private var artworkTask: (url: String, token: UInt64, task: Task<Void, Never>)?
    private var artworkToken: UInt64 = 0
    private let loadArtwork: @MainActor (String) async -> NSImage?

    init(loadArtwork: @escaping @MainActor (String) async -> NSImage? = { await ImageCache.shared.image(for: $0) }) {
        self.loadArtwork = loadArtwork
    }

    func installCommands(
        onPlay: @escaping () -> Void,
        onPause: @escaping () -> Void,
        onToggle: @escaping () -> Void,
        onSeek: @escaping (Double) -> Void,
        onSkip: @escaping (Double) -> Void,
        onNextEpisode: @escaping () -> Void,
        onPreviousEpisode: @escaping () -> Void,
    ) {
        // Handlers are refreshed on every session; targets are added once.
        playHandler = onPlay
        pauseHandler = onPause
        toggleHandler = onToggle
        seekHandler = onSeek
        skipHandler = onSkip
        nextHandler = onNextEpisode
        previousHandler = onPreviousEpisode

        guard !commandsInstalled else { return }
        commandsInstalled = true

        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.playHandler?()
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pauseHandler?()
            return .success
        }
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.toggleHandler?()
            return .success
        }
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.nextHandler?()
            return .success
        }
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.previousHandler?()
            return .success
        }
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            self?.skipHandler?(Self.skipInterval)
            return .success
        }
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            self?.skipHandler?(-Self.skipInterval)
            return .success
        }
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self?.seekHandler?(positionEvent.positionTime)
            return .success
        }
    }

    /// Removes remote-command handlers when playback ends so Control Center
    /// stops targeting a closed session.
    func clearCommands() {
        guard commandsInstalled else { return }
        commandsInstalled = false
        playHandler = nil
        pauseHandler = nil
        toggleHandler = nil
        seekHandler = nil
        skipHandler = nil
        nextHandler = nil
        previousHandler = nil
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)
    }

    func updateNowPlaying(
        title: String,
        subtitle: String?,
        duration: Double,
        elapsed: Double,
        rate: Double,
        isPlaying: Bool,
        artworkURL: String?,
    ) {
        // macOS routes media keys and the Now Playing widget by
        // `playbackState`; the info dictionary alone is not enough (N1).
        center.playbackState = isPlaying ? .playing : .paused
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = title
        if let subtitle {
            info[MPMediaItemPropertyArtist] = subtitle
        }
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        if let artworkURL, let currentArtwork, currentArtwork.url == artworkURL {
            info[MPMediaItemPropertyArtwork] = currentArtwork.artwork
        }
        center.nowPlayingInfo = info

        guard let artworkURL else {
            cancelArtwork()
            currentArtwork = nil
            return
        }
        if currentArtwork?.url == artworkURL { return }
        if artworkTask?.url == artworkURL { return } // this fetch is already running
        cancelArtwork()
        currentArtwork = nil

        artworkToken &+= 1
        let token = artworkToken
        let loadArtwork = loadArtwork
        let task = Task { [weak self] in
            let image = await loadArtwork(artworkURL)
            // Only the fetch that still owns the token may publish or clear it.
            guard let self, self.artworkTask?.token == token else { return }
            self.artworkTask = nil
            guard let image, !Task.isCancelled, var info = self.center.nowPlayingInfo,
                  let artwork = Self.createArtwork(from: image) else { return }
            self.currentArtwork = (artworkURL, artwork)
            info[MPMediaItemPropertyArtwork] = artwork
            self.center.nowPlayingInfo = info
        }
        artworkTask = (artworkURL, token, task)
    }

    private func cancelArtwork() {
        artworkTask?.task.cancel()
        artworkTask = nil
    }

    /// The artwork URL whose image is currently published (tests).
    var publishedArtworkURL: String? {
        center.nowPlayingInfo?[MPMediaItemPropertyArtwork] == nil ? nil : currentArtwork?.url
    }

    nonisolated private static func createArtwork(from image: NSImage) -> MPMediaItemArtwork? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        return MPMediaItemArtwork(boundsSize: size) { _ in
            image
        }
    }

    func clearNowPlaying() {
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
        clearCommands()
        cancelArtwork()
        currentArtwork = nil
    }
}

// Picture-in-Picture: the placebo toggle is removed (UI-Remediation-Plan
// DP-5). A real detachable PiP window needs its own window-management
// feature work (tracked in Implementation-Plan N-12).
