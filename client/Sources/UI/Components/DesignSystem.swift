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
