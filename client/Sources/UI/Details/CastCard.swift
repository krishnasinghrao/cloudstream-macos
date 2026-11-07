import AppKit
import SwiftUI

// MARK: - Cast Card

struct CastCard: View {
    let actor: ActorDto
    @State private var isHovering = false

    var body: some View {
        // A real button, so the card takes keyboard focus and Space/Return
        // activate it like any other control.
        Button(action: searchWeb) { card }
            .buttonStyle(.plain)
            .onHover { hovering in
                isHovering = hovering
            }
            .help("Search the web for \(actor.name)")
            .accessibilityHint("Searches the web for this person")
            .contextMenu {
                Button("Search the Web for \(actor.name)", action: searchWeb)
                Button("Copy Name") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(actor.name, forType: .string)
                }
            }
    }

    private var card: some View {
        VStack(alignment: .center, spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.cardSurface)
                    .frame(width: 72, height: 72)

                if let img = actor.image, !img.isEmpty {
                    PosterImage(url: img, placeholderIcon: "person.fill")
                        .frame(width: 72, height: 72)
                        .clipShape(Circle())
                } else {
                    Image(systemName: "person.fill")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
            }
            .overlay(
                Circle().strokeBorder(
                    isHovering ? Color.primary.opacity(0.3) : Color.cardBorder,
                    lineWidth: 1
                )
            )

            VStack(spacing: 2) {
                Text(actor.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                if let role = actor.role, !role.isEmpty {
                    Text(role)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .multilineTextAlignment(.center)
                }

                if let voice = actor.voiceActor, !voice.isEmpty {
                    Label(voice, systemImage: "mic")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .help("Voice actor: \(voice)")
                }
            }
            .frame(width: 96)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// Opens a web search for the person in the default browser, as the
    /// Android app does.
    private func searchWeb() {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: actor.name)]
        if let url = components?.url {
            NSWorkspace.shared.open(url)
        }
    }
}
