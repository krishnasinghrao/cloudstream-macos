import SwiftUI

// MARK: - Semantic palette (ADR-0010: system colors, both appearances)

extension Color {
    /// Content-layer canvas — the standard window background.
    static let canvas = Color(nsColor: .windowBackgroundColor)
    /// Inset cards and rows — standard control background.
    static let cardSurface = Color(nsColor: .controlBackgroundColor)
    /// Hover fill for cards and rows; adapts to appearance.
    static let hoverFill = Color.primary.opacity(0.06)
    /// Subtle borders around inset cards.
    static let cardBorder = Color(nsColor: .separatorColor)

    static let textTertiary = Color(nsColor: .tertiaryLabelColor)
}

// MARK: - Press feedback

/// Controls that start playback: the press itself is acknowledged (dim plus a
/// slight sink) before the player window appears.
struct PressFeedbackButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Loading placeholder

struct LoadingView: View {
    let label: String

    init(_ label: String = "Loading…") {
        self.label = label
    }

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Watch status menu

/// The "Watch Status" submenu of a title's context menu. A picker, so the
/// title's current status carries the native checkmark.
struct WatchStatusMenu: View {
    let current: WatchType?
    let onSelect: (WatchType) -> Void

    var body: some View {
        Picker("Watch Status", selection: Binding<WatchType?>(
            get: { current },
            set: { if let type = $0, type != current { onSelect(type) } },
        )) {
            ForEach(WatchType.allCases) { type in
                Text(type.label).tag(WatchType?.some(type))
            }
        }
        .pickerStyle(.menu)
    }
}

// MARK: - Hoverable row

/// A full-width list row that is a button: a subtle rounded fill follows the
/// pointer and the press dims it, as in Finder and Music lists.
struct HoverRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverRow(configuration: configuration)
    }

    private struct HoverRow: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovering || configuration.isPressed ? Color.hoverFill : .clear)
                )
                .opacity(configuration.isPressed ? 0.75 : 1)
                .contentShape(.rect(cornerRadius: 8, style: .continuous))
                .onHover { hovering = $0 }
        }
    }
}
