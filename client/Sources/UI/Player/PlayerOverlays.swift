import SwiftUI

// Offline-Features-Plan Phase 4 overlays: Skip pill, Up Next card and the
// player tools menu. They sit above the video independent of the HUD's
// auto-hide, like the streaming apps users know.

/// "Skip Intro" / "Skip Credits" — shown while the playhead is inside a
/// skippable chapter (or the show's learned intro).
struct SkipSegmentPill: View {
    let segment: SkipSegment
    let player: PlayerViewModel

    var body: some View {
        Button {
            player.skipActiveSegment()
        } label: {
            HStack(spacing: 6) {
                Text(segment.kind.buttonTitle)
                Image(systemName: "forward.fill")
                    .font(.caption)
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .modifier(PlayerHUDSurface(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help("\(segment.kind.buttonTitle) (S)")
        .accessibilityLabel(segment.kind.buttonTitle)
    }
}

/// Next-episode countdown with Play Now / Cancel (Android + streaming parity).
struct UpNextCard: View {
    let upNext: PlayerViewModel.UpNext
    let player: PlayerViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let progress = upNext.total > 0 ? 1 - player.upNextRemaining / upNext.total : 1
        HStack(spacing: 14) {
            ZStack {
                PosterImage(url: upNext.posterUrl)
                    .frame(width: 128, height: 72)
                    .clipShape(.rect(cornerRadius: 8, style: .continuous))
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 34, height: 34)
                    .animation(reduceMotion ? nil : .linear(duration: 0.25), value: progress)
                Text("\(Int(player.upNextRemaining.rounded(.up)))")
                    .font(.callout.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Up Next · \(upNext.label)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                if let title = upNext.title, !title.isEmpty {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    Button("Play Now") { player.playUpNextNow() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .keyboardShortcut(.return, modifiers: [])
                    Button("Cancel") { player.dismissUpNext() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: 420, alignment: .leading)
        .modifier(PlayerHUDSurface(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Up next, \(upNext.label), starts in \(Int(player.upNextRemaining.rounded(.up))) seconds")
    }
}

/// Skip / intro marking / sleep timer / screenshot / frame step.
struct PlayerToolsMenuContent: View {
    let player: PlayerViewModel

    var body: some View {
        Button("Skip \(Int(player.preferences.manualSkipSeconds)) Seconds") { player.manualSkip() }
        Button(player.showsStreamInfo ? "Hide Stream Info" : "Show Stream Info") { player.showsStreamInfo.toggle() }

        if player.session?.details.isSeries == true, player.session?.persistsProgress == true {
            Menu("Intro for This Show") {
                Button("Set Intro Start Here") { player.markIntro(start: true) }
                Button("Set Intro End Here") { player.markIntro(start: false) }
                if player.hasLearnedIntro {
                    Divider()
                    Button("Forget Saved Intro", role: .destructive) { player.clearLearnedIntro() }
                }
            }
        }

        Divider()

        Menu("Sleep Timer") {
            Picker("Sleep Timer", selection: Binding(
                get: { Self.tag(for: player.sleepTimer) },
                set: { tag in
                    switch tag {
                    case -1: player.setSleepAtEndOfEpisode()
                    case 0: player.setSleepTimer(minutes: nil)
                    default: player.setSleepTimer(minutes: tag)
                    }
                },
            )) {
                Text("Off").tag(0)
                Text("End of Episode").tag(-1)
                ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                    Text("\(minutes) Minutes").tag(minutes)
                }
                if case .at(let date) = player.sleepTimer {
                    Text("Pauses at \(date.formatted(date: .omitted, time: .shortened))").tag(Self.tag(for: player.sleepTimer))
                }
            }
            .pickerStyle(.inline)
        }

        Divider()

        if let link = player.activeLink {
            let players = ExternalPlayer.installed.filter { $0.supports(link) }
            Menu("Open In") {
                if players.isEmpty {
                    Text("Install IINA, VLC or mpv to open streams externally")
                }
                ForEach(players) { external in
                    Button(external.rawValue) { player.openExternally(with: external) }
                }
            }
        }

        Button("Take Screenshot") { player.takeScreenshot() }
        Button("Next Frame") { player.frameStep(forward: true) }
        Button("Previous Frame") { player.frameStep(forward: false) }
    }

    /// Minutes for a running countdown are shown as a custom tag so the
    /// picker can tick it; the preset rows stay selectable.
    static func tag(for timer: PlayerViewModel.SleepTimer?) -> Int {
        switch timer {
        case nil: return 0
        case .endOfEpisode: return -1
        case .at: return -2
        }
    }
}
