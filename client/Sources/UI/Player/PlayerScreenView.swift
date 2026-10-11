import AppKit
import SwiftUI

/// The player window's SwiftUI content: Metal viewport + floating HUD.
/// Window chrome is the system's (PlayerWindowController); this view carries
/// no traffic-light compensation.
///
/// Interaction model (Player-Remediation-Plan D2): like QuickTime, a single
/// click does nothing (it would otherwise delay every click by the
/// double-click interval); double-click toggles full screen; Space / K pause.
struct PlayerScreenView: View {
    let player: PlayerViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let session = player.session, let request = player.loadRequest {
                MpvPlayerView(player: player, request: request)
                    .ignoresSafeArea()
                    .onHover { hovering in
                        if hovering { player.showHUD() }
                    }
                    .onTapGesture(count: 2) {
                        player.toggleFullScreen()
                    }

                if player.hudVisible {
                    PlayerScrim()
                        .transition(.opacity)

                    PlayerTopTitleView(session: session, isFullScreen: player.isFullScreen)
                        .transition(.opacity)

                    PlayerHUDView(session: session, player: player)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }

            PlayerStatusOverlay(player: player)

            // No session yet: name what is being opened, where the session's
            // own title will appear.
            if player.session == nil, player.error == nil, let title = player.pendingTitle {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 80)
                    .padding(.top, player.isFullScreen ? 28 : 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
            }

            if player.session != nil, player.error == nil {
                VStack(alignment: .trailing, spacing: 12) {
                    Spacer()
                    if let upNext = player.upNext {
                        UpNextCard(upNext: upNext, player: player)
                            .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                    } else if let segment = player.activeSkip {
                        SkipSegmentPill(segment: segment, player: player)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 32)
                // Clear the HUD bar when it is showing.
                .padding(.bottom, player.hudVisible ? 150 : 40)
                .animation(.easeInOut(duration: 0.2), value: player.hudVisible)
            }

            if let notice = player.notice, player.error == nil {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .modifier(PlayerHUDSurface(cornerRadius: 12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 56)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            if let error = player.error {
                PlayerErrorCard(message: error, player: player)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        // Drop a subtitle file onto the video to load it (Phase 5).
        .dropDestination(for: URL.self) { urls, _ in
            guard player.session != nil else { return false }
            return urls.contains { player.addLocalSubtitleFile($0) }
        }
        .environment(\.colorScheme, .dark)
        .animation(.easeInOut(duration: 0.2), value: player.hudVisible)
        .animation(.easeInOut(duration: 0.2), value: player.error != nil)
        .animation(.easeInOut(duration: 0.2), value: player.notice)
        .animation(.easeInOut(duration: 0.25), value: player.upNext)
        .animation(.easeInOut(duration: 0.2), value: player.activeSkip)
        .onChange(of: player.hudVisible) { _, visible in
            PlayerWindowController.shared.setControlsVisible(visible)
            if !visible && player.isPlaying {
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
    }
}

// MARK: - Scrim

/// Clear glass over media needs a dark scrim for legibility over bright
/// frames (Liquid Glass media rule, D6).
private struct PlayerScrim: View {
    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 110)
            Spacer(minLength: 0)
            LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
                .frame(height: 220)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Loading / buffering

/// A bare system spinner while links resolve, the stream loads, or it
/// re-buffers — no card or copy, matching the TV app and QuickTime (D1).
/// The title is already shown by the top title bar. Never blocks the HUD.
private struct PlayerStatusOverlay: View {
    let player: PlayerViewModel

    private var accessibilityStatus: String? {
        switch player.phase {
        case .resolving: "Finding streams"
        case .loading: "Loading"
        case .ready where player.isBuffering: "Buffering"
        default: nil
        }
    }

    var body: some View {
        if let accessibilityStatus {
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                // Re-buffering shows how far along it is, not a silent spinner.
                if player.phase == .ready, let percent = player.bufferingPercent {
                    Text("\(percent)%")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            // Keeps the spinner legible over bright frames while buffering.
            .shadow(color: .black.opacity(0.5), radius: 6)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(player.bufferingPercent.map { "\(accessibilityStatus), \($0) percent" } ?? accessibilityStatus)
        }
    }
}

// MARK: - Player Top Title

/// Title and episode label at the top of the video, visible with the HUD.
struct PlayerTopTitleView: View {
    let session: PlayerViewModel.Session
    let isFullScreen: Bool

    var body: some View {
        VStack {
            VStack(spacing: 3) {
                Text(session.details.name)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if session.details.isSeries {
                    Text(session.episodeLabel)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }
            }
            .shadow(color: .black.opacity(0.6), radius: 4, x: 0, y: 1)
            .padding(.horizontal, 80)
            .padding(.top, isFullScreen ? 28 : 12)
            .allowsHitTesting(false)

            Spacer()
        }
    }
}

// MARK: - Error Card

/// Playback failure with the actions that can actually fix it (D9).
struct PlayerErrorCard: View {
    let message: String
    let player: PlayerViewModel

    var body: some View {
        VStack(spacing: 12) {
            Label {
                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
            }
            .labelStyle(.titleAndIcon)

            HStack(spacing: 10) {
                if player.hasNextMirror {
                    Button("Try Next Mirror") {
                        player.tryNextMirror()
                    }
                    .keyboardShortcut(.defaultAction)
                }
                Button(player.session == nil ? "Close" : "Dismiss") {
                    player.dismissError()
                }
                .keyboardShortcut(.cancelAction)
            }
            .controlSize(.regular)
        }
        .padding(18)
        .frame(maxWidth: 440)
        .modifier(PlayerHUDSurface(cornerRadius: 16))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 56)
        .padding(.horizontal, 24)
    }
}
