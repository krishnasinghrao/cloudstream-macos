import SwiftUI

// MARK: - Download Source Picker

/// Lists the sources one episode (or movie) can be downloaded from. Sources
/// are only known after asking the provider, so this loads in a popover
/// rather than living directly in a context menu.
struct DownloadSourcePicker: View {
    let title: String
    let footnote: String?
    let provider: String
    let providerID: String?
    let episodeData: String
    let onChoose: (DownloadPolicy.SourceChoice) -> Void

    private enum Phase {
        case loading
        case loaded([StreamLinkDto])
        case failed(String)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            switch phase {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finding sources…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { Task { await load() } }
            case .loaded(let links):
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                            SourceRow(link: link) {
                                onChoose(DownloadPolicy.SourceChoice(link))
                                dismiss()
                            }
                        }
                    }
                }
                // A ScrollView has no intrinsic height and collapses inside a
                // popover: size it to its rows, capped.
                .frame(height: min(CGFloat(links.count) * 50, 360))
            }

            if let footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 440)
        .task { await load() }
    }

    private func load() async {
        phase = .loading
        do {
            let links = try await DownloadService.shared.availableSources(
                provider: provider,
                providerID: providerID,
                episodeData: episodeData,
            )
            // Identical source/name/quality entries would queue the same pick.
            var seen = Set<DownloadPolicy.SourceChoice>()
            let unique = links.filter { seen.insert(DownloadPolicy.SourceChoice($0)).inserted }
            phase = unique.isEmpty ? .failed("No downloadable sources were found.") : .loaded(unique)
        } catch is CancellationError {
            return
        } catch {
            phase = .failed("Couldn’t load sources: \(error.localizedDescription)")
        }
    }

    private struct SourceRow: View {
        let link: StreamLinkDto
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(link.name.isEmpty ? link.source : link.name)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if !link.source.isEmpty, link.source != link.name {
                            Text(link.source)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(link.quality > 0 ? link.qualityLabel : "Unknown quality")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .background(hovering ? Color.hoverFill : .clear, in: .rect(cornerRadius: 6, style: .continuous))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
    }
}
