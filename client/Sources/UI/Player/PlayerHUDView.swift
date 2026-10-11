import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Floating glass HUD over the video (media-overlay context — clear glass
/// over a scrim is correct here, per the Liquid Glass media rule).
///
/// Observation discipline (Player-Remediation-Plan U1): this body never reads
/// the playback clock. Only `ClockedTimelineScrubber` observes
/// `PlaybackClock`, so the 4 Hz progress ticks re-evaluate the scrubber alone —
/// not the transport, menus, and episode list.
struct PlayerHUDView: View {
    let session: PlayerViewModel.Session
    @Bindable var player: PlayerViewModel
    @State private var subtitleStylePopover = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
                .allowsHitTesting(false)

            hudContainer
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
        .allowsHitTesting(player.hudVisible)
        .onChange(of: subtitleStylePopover) { _, open in
            player.isInteractingWithHUD = open
        }
        .popover(isPresented: $subtitleStylePopover) {
            SubtitleStylePopover(player: player)
        }
    }

    // MARK: - Container

    private var hudContainer: some View {
        VStack(spacing: 12) {
            if player.showsStreamInfo {
                Text(player.streamInfo.summary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Stream info: \(player.streamInfo.summary)")
            }
            ClockedTimelineScrubber(clock: player.clock, player: player)

            // Controls sit side by side (never layered), and the bar falls
            // back to a compact set when the window is too narrow for all of
            // them, so they can never overlap.
            ViewThatFits(in: .horizontal) {
                regularControls
                compactControls
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: 720)
        .modifier(PlayerHUDSurface(cornerRadius: 18))
        .onHover { hovering in
            player.isInteractingWithHUD = hovering
        }
    }

    /// Volume leading, transport centered, menus trailing.
    private var regularControls: some View {
        HStack(alignment: .center, spacing: 12) {
            VolumeControlPill(player: player)
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .leading)
            centerTransportSection
                .fixedSize()
            trailingControlsSection
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// Small windows: play/pause, subtitles, an overflow menu, full screen.
    private var compactControls: some View {
        HStack(alignment: .center, spacing: 8) {
            playPauseButton
            Spacer(minLength: 8)
            captionsMenu
            overflowMenu
            fullScreenButton
        }
    }

    private var overflowMenu: some View {
        Menu {
            if session.details.isSeries {
                Button("Previous Episode") { player.playPreviousEpisode() }
                    .disabled(!player.hasPreviousEpisode)
                Button("Next Episode") { player.playNextEpisode() }
                    .disabled(!player.hasNextEpisode)
                if !session.details.episodes.isEmpty {
                    Menu("Episodes") {
                        PlayerEpisodeMenuContent(session: session, player: player)
                    }
                }
                Divider()
            }
            Button(player.isMuted ? "Unmute" : "Mute") { player.toggleMute() }
            Menu("Playback Speed") {
                PlayerSpeedPicker(player: player)
            }
            Menu("Aspect Ratio") {
                PlayerAspectPicker(player: player)
            }
            if session.links.count > 1 {
                Menu("Quality & Mirrors") {
                    PlayerMirrorPicker(session: session, player: player)
                }
            }
            Divider()
            PlayerToolsMenuContent(player: player)
        } label: {
            hudIcon("ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More Options")
    }

    // MARK: - Center Transport

    private var centerTransportSection: some View {
        HStack(spacing: 16) {
            if session.details.isSeries {
                transportButton("backward.end.fill", size: 13, label: "Previous Episode") {
                    player.playPreviousEpisode()
                }
                .disabled(!player.hasPreviousEpisode)
            }

            let step = Int(player.preferences.seekStepSeconds)
            transportButton(Self.seekSymbol("gobackward", step), size: 18, label: "Rewind \(step) Seconds", help: "Rewind \(step) seconds (←)") {
                player.seek(by: -player.preferences.seekStepSeconds)
            }

            playPauseButton

            transportButton(Self.seekSymbol("goforward", step), size: 18, label: "Forward \(step) Seconds", help: "Forward \(step) seconds (→)") {
                player.seek(by: player.preferences.seekStepSeconds)
            }

            if session.details.isSeries {
                transportButton("forward.end.fill", size: 13, label: "Next Episode", help: "Next Episode (N)") {
                    player.playNextEpisode()
                }
                .disabled(!player.hasNextEpisode)
            }
        }
    }

    /// SF Symbols ship numbered variants for common steps only.
    static func seekSymbol(_ base: String, _ step: Int) -> String {
        [5, 10, 15, 30, 45, 60, 75, 90].contains(step) ? "\(base).\(step)" : base
    }

    private var playPauseButton: some View {
        Button {
            player.togglePlayPause()
        } label: {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color.white.opacity(0.16), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(player.isPlaying ? "Pause (Space)" : "Play (Space)")
        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
    }

    private func transportButton(
        _ symbol: String,
        size: CGFloat,
        label: String,
        help: String? = nil,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlayerIconButtonStyle())
        .help(help ?? label)
        .accessibilityLabel(label)
    }

    // MARK: - Trailing Controls

    /// Audio & subtitles, episodes, speed, aspect ratio, mirrors, full screen.
    /// Every menu uses `Picker` so selection renders as native menu
    /// checkmarks (D5).
    private var trailingControlsSection: some View {
        HStack(spacing: 8) {
            captionsMenu

            if session.details.isSeries && !session.details.episodes.isEmpty {
                Menu {
                    PlayerEpisodeMenuContent(session: session, player: player)
                } label: {
                    hudIcon("list.bullet.rectangle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Episodes")
                .accessibilityLabel("Episodes")
            }

            Menu {
                PlayerSpeedPicker(player: player)
            } label: {
                Text(PlayerSpeedPicker.shortLabel(player.speed))
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.1), in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Playback Speed")
            .accessibilityLabel("Playback Speed")

            Menu {
                PlayerAspectPicker(player: player)
            } label: {
                hudIcon("aspectratio")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Aspect Ratio")
            .accessibilityLabel("Aspect Ratio")

            if session.links.count > 1 {
                Menu {
                    PlayerMirrorPicker(session: session, player: player)
                } label: {
                    hudIcon("slider.horizontal.3")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Quality & Mirrors")
                .accessibilityLabel("Quality and Mirrors")
            }

            Menu {
                PlayerToolsMenuContent(player: player)
            } label: {
                hudIcon(player.sleepTimer == nil ? "ellipsis" : "moon.zzz.fill")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(player.sleepTimer == nil ? "More" : "More — sleep timer on")
            .accessibilityLabel("More Options")

            fullScreenButton
        }
    }

    private var captionsMenu: some View {
        Menu {
            PlayerTrackMenuContent(player: player)

            Divider()

            Button("Subtitle Appearance…") {
                subtitleStylePopover = true
            }
        } label: {
            hudIcon("captions.bubble.fill")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Audio & Subtitles")
        .accessibilityLabel("Audio and Subtitles")
    }

    private var fullScreenButton: some View {
        Button {
            player.toggleFullScreen()
        } label: {
            hudIcon(player.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        }
        .buttonStyle(.plain)
        .help(player.isFullScreen ? "Exit Full Screen (F)" : "Enter Full Screen (F)")
        .accessibilityLabel(player.isFullScreen ? "Exit Full Screen" : "Enter Full Screen")
    }

    private func hudIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: 28, height: 28)
            .background(Color.white.opacity(0.08), in: Circle())
            .contentShape(Circle())
    }
}

// MARK: - HUD surface

/// Clear glass on macOS 26+, a dark material before it, and an opaque dark
/// surface under Reduce Transparency (D6).
struct PlayerHUDSurface: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            content
                .background(Color.black.opacity(0.9), in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
        } else if #available(macOS 26.0, *) {
            content
                .glassEffect(.clear, in: shape)
                .overlay {
                    if contrast == .increased {
                        shape.strokeBorder(Color.white.opacity(0.5), lineWidth: 1)
                    }
                }
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(contrast == .increased ? 0.5 : 0.14), lineWidth: contrast == .increased ? 1 : 0.5))
        }
    }
}

/// Plain icon button with hover and pressed feedback (no scaling).
struct PlayerIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PlayerIconButton(configuration: configuration)
    }

    private struct PlayerIconButton: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(.white.opacity(isEnabled ? (configuration.isPressed ? 0.6 : 0.92) : 0.25))
                .background(
                    Circle().fill(Color.white.opacity(isHovering && isEnabled ? 0.12 : 0)),
                )
                .onHover { isHovering = $0 }
        }
    }
}

// MARK: - Menu contents (native checkmarks)

struct PlayerTrackMenuContent: View {
    let player: PlayerViewModel

    var body: some View {
        if player.audioTracks.isEmpty {
            Section("Audio") {
                Text("Default Audio Track")
            }
        } else {
            Picker("Audio", selection: Binding(
                get: { player.activeAudioTrackId ?? 0 },
                set: { player.selectAudioTrack($0) },
            )) {
                ForEach(player.audioTracks) { track in
                    Text(track.label).tag(track.id)
                }
            }
            .pickerStyle(.inline)
        }

        Picker("Subtitles", selection: Binding(
            get: { max(0, player.activeSubtitleTrackId ?? 0) },
            set: { player.selectSubtitleTrack($0) },
        )) {
            Text("Off").tag(Int64(0))
            ForEach(player.subtitleTracks) { track in
                Text(track.label).tag(track.id)
            }
        }
        .pickerStyle(.inline)

        Button("Add Subtitle File…") {
            Self.chooseSubtitleFile(for: player)
        }

        Section("Subtitle Delay: \(PlayerTrackMenuContent.delayLabel(player.subtitleDelay))") {
            Button("Earlier by 0.1 s (Z)") { player.adjustSubtitleDelay(by: -0.1) }
            Button("Later by 0.1 s (X)") { player.adjustSubtitleDelay(by: 0.1) }
            Button("Earlier by 1 s") { player.adjustSubtitleDelay(by: -1) }
            Button("Later by 1 s") { player.adjustSubtitleDelay(by: 1) }
            Button("Reset Delay") { player.setSubtitleDelay(0) }
                .disabled(player.subtitleDelay == 0)
        }
    }

    @MainActor
    static func chooseSubtitleFile(for player: PlayerViewModel) {
        let panel = NSOpenPanel()
        panel.title = "Add Subtitle File"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = PlayerViewModel.subtitleFileExtensions.compactMap { UTType(filenameExtension: $0) }
        player.isInteractingWithHUD = true
        defer { player.isInteractingWithHUD = false }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        player.addLocalSubtitleFile(url)
    }

    static func delayLabel(_ seconds: Double) -> String {
        seconds == 0 ? "0 s" : String(format: "%+.1f s", seconds)
    }
}

/// Episodes of the current season only — a full anime run can be 1000+
/// items, far too many for a menu (D12).
struct PlayerEpisodeMenuContent: View {
    let session: PlayerViewModel.Session
    let player: PlayerViewModel

    var body: some View {
        let season = session.episode?.season
        let episodes = session.details.episodes.filter { season == nil || $0.season == season }
        Picker(season.map { "Season \($0)" } ?? "Episodes", selection: Binding(
            get: { session.episode?.id ?? "" },
            set: { id in
                if let episode = episodes.first(where: { $0.id == id }), episode != session.episode {
                    player.playEpisode(episode)
                }
            },
        )) {
            ForEach(episodes) { episode in
                Text(PlayerEpisodeMenuContent.title(for: episode)).tag(episode.id)
            }
        }
        .pickerStyle(.inline)
    }

    static func title(for episode: EpisodeDto) -> String {
        let number = episode.episode.map { "\($0). " } ?? ""
        return number + (episode.name ?? "Episode \(episode.episode ?? 1)")
    }
}

struct PlayerSpeedPicker: View {
    let player: PlayerViewModel
    static let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        Picker("Playback Speed", selection: Binding(
            get: { player.speed },
            set: { player.setSpeed($0) },
        )) {
            ForEach(Self.speeds, id: \.self) { speed in
                Text(speed == 1.0 ? "Normal" : Self.shortLabel(speed)).tag(speed)
            }
        }
        .pickerStyle(.inline)
    }

    static func shortLabel(_ speed: Double) -> String {
        let formatted = speed.formatted(.number.precision(.fractionLength(0...2)))
        return "\(formatted)×"
    }
}

struct PlayerAspectPicker: View {
    let player: PlayerViewModel
    static let options: [(value: String, title: String)] = [
        ("-1", "Original"),
        ("16:9", "16:9 (Widescreen)"),
        ("4:3", "4:3 (Classic)"),
        ("21:9", "21:9 (Ultrawide)"),
    ]

    var body: some View {
        Toggle("Fill Screen", isOn: Binding(
            get: { player.fillsScreen },
            set: { player.setFillsScreen($0) },
        ))

        Divider()

        Picker("Aspect Ratio", selection: Binding(
            get: { player.aspectRatio },
            set: { player.setAspectRatio($0) },
        )) {
            ForEach(Self.options, id: \.value) { option in
                Text(option.title).tag(option.value)
            }
        }
        .pickerStyle(.inline)
    }
}

struct PlayerMirrorPicker: View {
    let session: PlayerViewModel.Session
    let player: PlayerViewModel

    var body: some View {
        Picker("Quality & Mirrors", selection: Binding(
            get: { session.selectedLinkIndex },
            set: { player.selectMirror($0) },
        )) {
            ForEach(Array(session.links.enumerated()), id: \.offset) { index, link in
                Text("\(link.qualityLabel) — \(link.name)").tag(index)
            }
        }
        .pickerStyle(.inline)
    }
}

// MARK: - Scrubber

/// The only HUD view that observes the playback clock (U1).
struct ClockedTimelineScrubber: View {
    let clock: PlaybackClock
    let player: PlayerViewModel

    var body: some View {
        PlayerTimelineScrubber(
            elapsed: clock.elapsed,
            duration: clock.duration,
            onScrubStart: {
                player.isInteractingWithHUD = true
            },
            onScrubEnd: { targetSeconds in
                player.seek(to: targetSeconds)
                player.isInteractingWithHUD = false
            },
        )
    }
}

struct PlayerTimelineScrubber: View {
    let elapsed: Double
    let duration: Double
    var onScrubStart: () -> Void
    var onScrubEnd: (Double) -> Void

    @State private var isDragging = false
    @State private var isHovering = false
    @State private var hoverFraction: Double?
    @State private var dragPositionSeconds: Double = 0

    private var currentPosition: Double {
        isDragging ? dragPositionSeconds : elapsed
    }

    /// False until the engine reports the media's length; the timeline is
    /// then shown as unknown rather than against a guessed duration.
    private var isDurationKnown: Bool { duration > 0 && duration.isFinite }

    private var progressFraction: Double {
        guard isDurationKnown else { return 0 }
        return max(0, min(1, currentPosition / duration))
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(Self.timeString(currentPosition))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
                .frame(minWidth: 48, alignment: .leading)

            GeometryReader { geometry in
                let width = max(1, geometry.size.width)
                let trackHeight: CGFloat = (isHovering || isDragging) ? 5 : 3.5

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.2))
                        .frame(height: trackHeight)

                    Capsule()
                        .fill(Color.white)
                        .frame(width: max(0, width * progressFraction), height: trackHeight)

                    Circle()
                        .fill(Color.white)
                        .frame(width: 11, height: 11)
                        .shadow(color: .black.opacity(0.4), radius: 3)
                        .offset(x: max(0, min(width - 11, width * progressFraction - 5.5)))
                        .opacity((isHovering || isDragging) ? 1.0 : 0.0)

                    if let hoverFraction, isHovering, !isDragging {
                        let hoverSeconds = duration * hoverFraction
                        let tipOffset = max(20, min(width - 20, width * hoverFraction))

                        Text(Self.timeString(hoverSeconds))
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(Color.black.opacity(0.75), in: Capsule())
                            .position(x: tipOffset, y: -14)
                    }
                }
                .frame(height: 18)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !isDragging {
                                isDragging = true
                                onScrubStart()
                            }
                            let fraction = max(0, min(1, value.location.x / width))
                            dragPositionSeconds = fraction * duration
                        }
                        .onEnded { value in
                            let fraction = max(0, min(1, value.location.x / width))
                            let target = fraction * duration
                            dragPositionSeconds = target
                            isDragging = false
                            onScrubEnd(target)
                        },
                )
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        isHovering = true
                        hoverFraction = max(0, min(1, location.x / width))
                    case .ended:
                        isHovering = false
                        hoverFraction = nil
                    }
                }
            }
            .frame(height: 18)
            .allowsHitTesting(isDurationKnown)
            .animation(.easeInOut(duration: 0.15), value: isHovering)
            .accessibilityElement()
            .accessibilityLabel("Playback position")
            .accessibilityValue(
                isDurationKnown
                    ? Self.timeString(currentPosition) + " of " + Self.timeString(duration)
                    : Self.timeString(currentPosition)
            )
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    guard isDurationKnown else { return }
                    onScrubEnd(min(duration, currentPosition + 10))
                case .decrement:
                    guard isDurationKnown else { return }
                    onScrubEnd(max(0, currentPosition - 10))
                @unknown default:
                    break
                }
            }

            Text(isDurationKnown ? "-\(Self.timeString(max(0, duration - currentPosition)))" : "--:--")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.6))
                .frame(minWidth: 52, alignment: .trailing)
        }
    }

    static func timeString(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}

// MARK: - Volume

/// Always-visible compact volume control (D10): discoverable without hover,
/// and reachable with ↑/↓ and the Playback menu.
struct VolumeControlPill: View {
    @Bindable var player: PlayerViewModel

    var body: some View {
        HStack(spacing: 6) {
            Button {
                player.toggleMute()
            } label: {
                Image(systemName: volumeIcon)
                    .font(.callout.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlayerIconButtonStyle())
            .help(player.isMuted ? "Unmute (M)" : "Mute (M)")
            .accessibilityLabel(player.isMuted ? "Unmute" : "Mute")

            Slider(
                value: Binding(
                    get: { player.isMuted ? 0 : player.volume },
                    set: { player.setVolume($0) },
                ),
                in: 0...100,
            )
            .controlSize(.mini)
            .tint(.white)
            .frame(width: 72)
            .accessibilityLabel("Volume")
            .accessibilityValue("\(Int(player.isMuted ? 0 : player.volume)) percent")
        }
    }

    private var volumeIcon: String {
        if player.isMuted || player.volume == 0 {
            return "speaker.slash.fill"
        } else if player.volume < 33 {
            return "speaker.wave.1.fill"
        } else if player.volume < 66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }
}

// MARK: - Subtitle Styling Popover

/// In-player twin of Settings ▸ Subtitles; both consume `SubtitleColor` so
/// the preset list exists exactly once.
struct SubtitleStylePopover: View {
    @Bindable var player: PlayerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Subtitle Appearance")
                .font(.headline)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Font Size")
                        .font(.callout)
                    Spacer()
                    Text("\(Int(player.preferences.subtitleFontSize ?? SubtitleStyle.defaultFontSize)) pt")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { player.preferences.subtitleFontSize ?? SubtitleStyle.defaultFontSize },
                        set: {
                            player.preferences.subtitleFontSize = $0
                            player.applySubtitleStyle()
                        },
                    ),
                    in: 28...90,
                )
                .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Border Stroke")
                        .font(.callout)
                    Spacer()
                    Text(String(format: "%.1f pt", player.preferences.subtitleOutlineWidth ?? SubtitleStyle.defaultOutlineWidth))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { player.preferences.subtitleOutlineWidth ?? SubtitleStyle.defaultOutlineWidth },
                        set: {
                            player.preferences.subtitleOutlineWidth = $0
                            player.applySubtitleStyle()
                        },
                    ),
                    in: 0...6,
                )
                .controlSize(.small)
            }

            Picker("Color", selection: Binding(
                get: { player.preferences.subtitleTextColor ?? SubtitleColor.white },
                set: {
                    player.preferences.subtitleTextColor = $0
                    player.applySubtitleStyle()
                },
            )) {
                ForEach(SubtitleColor.presets, id: \.color) { preset in
                    Text(preset.name).tag(preset.color)
                }
            }
            .labelsHidden()
            .frame(width: 120)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Vertical Position")
                        .font(.callout)
                    Spacer()
                    Text("\(player.preferences.subtitlePosition)%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(player.preferences.subtitlePosition) },
                        set: {
                            player.preferences.subtitlePosition = Int($0.rounded())
                            player.applySubtitleStyle()
                        },
                    ),
                    in: 50...100,
                )
                .controlSize(.small)
            }

            Toggle("Bold", isOn: Binding(
                get: { player.preferences.subtitleBold },
                set: {
                    player.preferences.subtitleBold = $0
                    player.applySubtitleStyle()
                },
            ))
            .controlSize(.small)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 260)
    }
}
