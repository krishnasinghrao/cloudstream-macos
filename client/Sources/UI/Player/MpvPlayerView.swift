import SwiftUI

/// SwiftUI binding to the MetalVideoView libmpv viewport.
///
/// The single load path (Player-Remediation-Plan T3): the engine loads a
/// stream exactly once per `StreamLoadRequest.id` — at creation, or when the
/// view model issues a new request (episode change, mirror failover). Engine
/// state flows back into the view model through read-only handlers; there is
/// no binding that writes it back to mpv (T2).
struct MpvPlayerView: NSViewRepresentable {
    let player: PlayerViewModel
    let request: StreamLoadRequest

    func makeNSView(context: Context) -> MetalVideoView {
        let view = MetalVideoView(frame: .zero)
        let player = player
        let coordinator = context.coordinator
        player.videoView = view
        coordinator.player = player
        coordinator.lastRequestID = request.id

        view.onPropertyChange = { [weak view, weak player] name, value in
            guard let view, let player else { return }
            switch name {
            case "time-pos":
                view.currentElapsed = value.doubleValue ?? 0
                // Coarse clock updates only (4 Hz), discontinuities immediately.
                if view.shouldForwardTimePos(now: view.currentElapsed) {
                    player.handleProgress(elapsed: view.currentElapsed, duration: view.currentDuration)
                }
            case "duration":
                view.currentDuration = value.doubleValue ?? 0
                player.handleProgress(elapsed: view.currentElapsed, duration: view.currentDuration)
            case "pause":
                if let paused = value.boolValue {
                    player.handleEnginePause(paused)
                }
            case "seekable":
                if let seekable = value.boolValue {
                    player.handleSeekable(seekable)
                }
            case "paused-for-cache":
                player.handleBuffering(value.boolValue ?? false)
            case "cache-buffering-state":
                player.handleBufferingProgress(value.int64Value ?? 0)
            case "volume":
                if let volume = value.doubleValue, volume != player.volume {
                    player.volume = volume
                }
            case "mute":
                if let muted = value.boolValue, muted != player.isMuted {
                    player.isMuted = muted
                }
            case "aid":
                if let aid = value.int64Value {
                    player.activeAudioTrackId = aid
                }
            case "sid":
                if let sid = value.int64Value {
                    player.activeSubtitleTrackId = sid
                }
            case "dwidth", "dheight":
                coordinator.updateVideoSize(name: name, value: value.int64Value ?? 0)
                player.updateStreamInfo(name, value)
            default:
                player.updateStreamInfo(name, value)
            }
        }
        view.onEndOfFile = { [weak player] in player?.handleEndOfFile() }
        view.onPlaybackFailed = { [weak player] in player?.handlePlaybackError() }
        view.onEngineFailed = { [weak player] stage in player?.handleEngineFailure(stage) }
        view.onCommandReply = { [weak player] reply in player?.handleCommandReply(reply) }
        view.onTracksChanged = { [weak player] tracks in player?.updateTracks(tracks) }
        view.onChaptersChanged = { [weak player] chapters in player?.updateChapters(chapters) }
        view.onPlaybackRestart = { [weak player] in player?.handlePlaybackRestart() }
        view.onScrollSeek = { [weak player] seconds in
            player?.seek(by: seconds)
            player?.showHUD()
        }
        view.onScrollVolume = { [weak player] delta in
            guard let player else { return }
            player.setVolume(player.volume + delta)
            player.showHUD()
        }

        view.setup(
            resource: request.resource,
            headers: request.headers,
            subtitles: request.subtitles,
            audioTracks: request.audioTracks,
            startAt: request.startAt,
            decryption: request.decryption,
        )
        player.setRenderer(view.rendererName)
        player.applySubtitleStyle()
        player.applyVideoFill()
        player.applySessionPreferences()
        return view
    }

    func updateNSView(_ nsView: MetalVideoView, context: Context) {
        if player.videoView !== nsView {
            player.videoView = nsView
        }
        guard context.coordinator.lastRequestID != request.id else { return }
        context.coordinator.lastRequestID = request.id
        context.coordinator.resetVideoSize()
        nsView.loadStream(
            resource: request.resource,
            headers: request.headers,
            subtitles: request.subtitles,
            audioTracks: request.audioTracks,
            startAt: request.startAt,
            usesQueuedNext: request.usesQueuedNext,
            decryption: request.decryption,
        )
    }

    static func dismantleNSView(_ nsView: MetalVideoView, coordinator: Coordinator) {
        if coordinator.player?.videoView === nsView {
            coordinator.player?.videoView = nil
        }
        nsView.shutdown()
        coordinator.player = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        weak var player: PlayerViewModel?
        var lastRequestID: Int?
        private var videoWidth: Int64 = 0
        private var videoHeight: Int64 = 0

        func updateVideoSize(name: String, value: Int64) {
            if name == "dwidth" { videoWidth = value } else { videoHeight = value }
            if videoWidth > 0, videoHeight > 0 {
                player?.handleVideoSize(width: videoWidth, height: videoHeight)
            }
        }

        func resetVideoSize() {
            videoWidth = 0
            videoHeight = 0
        }
    }
}
