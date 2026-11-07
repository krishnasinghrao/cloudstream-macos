import SwiftUI

/// The update row's own metrics. Deliberately not shared with the sidebar
/// list: the row sits in the sidebar's bottom inset, outside the list cells.
private enum UpdateRowLayout {
    /// Matches ProfileSwitcher's horizontal padding below it.
    static let horizontalInset: CGFloat = 12
    static let iconWidth: CGFloat = 20
}

/// The sidebar's update row, directly above the profile button. Present only
/// while an update needs attention: available (not skipped), downloading,
/// preparing, ready to install, or failed.
struct SidebarUpdateRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let updater = SoftwareUpdater.shared
        VStack(spacing: 0) {
            if let release = updater.sidebarRelease, !AppLock.shared.isLocked {
                SidebarUpdateCard(phase: updater.phase, release: release)
                    .padding(.horizontal, UpdateRowLayout.horizontalInset)
                    .padding(.top, 8)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: updater.sidebarRelease?.version)
    }
}

private struct SidebarUpdateCard: View {
    let phase: SoftwareUpdater.Phase
    let release: UpdateRelease
    @State private var isHovered = false

    private var updater: SoftwareUpdater { .shared }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            symbol
                .font(.title3)
                .frame(width: UpdateRowLayout.iconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                detail
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .topTrailing) { skipButton }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Release Notes") { updater.openReleaseNotes() }
            if case .available = phase {
                Button("Skip This Version") { updater.skipThisVersion() }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Sidebar Update")
    }

    private var title: String {
        switch phase {
        case .downloading: "Downloading Update"
        case .preparing: "Preparing Update"
        case .ready: "Update Ready"
        case .failed: "Update Failed"
        default: "Update Available"
        }
    }

    @ViewBuilder private var symbol: some View {
        switch phase {
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .ready:
            Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.tint)
        default:
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
        }
    }

    @ViewBuilder private var detail: some View {
        switch phase {
        case .downloading(_, let fraction):
            HStack(spacing: 6) {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Downloading version \(release.version.description)")
            .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
        case .preparing:
            ProgressView()
                .progressViewStyle(.linear)
                .controlSize(.small)
                .accessibilityLabel("Verifying the update")
        case .failed(let message, _):
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help(message)
        case .ready:
            secondary("Version \(release.version.description)")
        default:
            secondary("Version \(release.version.description)")
        }
    }

    private func secondary(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    @ViewBuilder private var trailing: some View {
        switch phase {
        case .available:
            Button(updater.location == .supported ? "Download" : "Download…") { updater.download() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(updater.location == .supported
                      ? "Download version \(release.version.description); it installs when you restart"
                      : "Open the release page to download version \(release.version.description)")
                .accessibilityIdentifier("Sidebar Update Download")
        case .downloading:
            Button {
                updater.cancelDownload()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Cancel the download")
            .accessibilityLabel("Cancel Download")
        case .ready:
            Button("Restart") { updater.restartToUpdate() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Restart CloudStream to install version \(release.version.description)")
                .accessibilityIdentifier("Sidebar Update Restart")
        case .failed:
            Button("Retry") { updater.download() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Try downloading version \(release.version.description) again")
        default:
            EmptyView()
        }
    }

    /// The hover close control: hides this version until a newer one
    /// (Settings ▸ General still offers it).
    @ViewBuilder private var skipButton: some View {
        if case .available = phase, isHovered {
            Button {
                updater.skipThisVersion()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .background(.background, in: Circle())
                    .overlay { Circle().strokeBorder(.separator, lineWidth: 0.5) }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
            .help("Skip this version. You can still update in Settings.")
            .accessibilityLabel("Skip This Version")
            .transition(.opacity)
        }
    }
}

/// Settings ▸ General ▸ Software Update.
struct SoftwareUpdateSettingsSection: View {
    var body: some View {
        @Bindable var updater = SoftwareUpdater.shared
        Section {
            LabeledContent("Current Version", value: updater.currentVersion.description)
            status(updater)
            Toggle("Check for updates automatically", isOn: $updater.automaticallyChecks)
                .disabled(!updater.isAvailable)
        } header: {
            Text("Software Update")
        } footer: {
            Text(footer(updater))
                .foregroundStyle(.secondary)
        }
    }

    private func footer(_ updater: SoftwareUpdater) -> String {
        guard updater.isAvailable else { return "This build doesn’t update itself. Download new versions from the project’s GitHub releases." }
        if case .manualOnly(let reason) = updater.location { return reason }
        return "Updates come from the project’s GitHub releases. A downloaded update is verified, then installed when you restart or quit CloudStream."
    }

    @ViewBuilder private func status(_ updater: SoftwareUpdater) -> some View {
        switch updater.phase {
        case .checking:
            LabeledContent {
                ProgressView().controlSize(.small)
            } label: {
                Text("Checking for updates…")
            }
        case .available(let release):
            LabeledContent {
                HStack(spacing: 8) {
                    Button("Release Notes") { updater.openReleaseNotes() }
                    Button(updater.location == .supported ? "Download and Install" : "Download…") { updater.download() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("Settings Update Download")
                }
            } label: {
                Text("Version \(release.version.description) is available")
                if let date = release.publishedAt {
                    Text("Released \(date.formatted(date: .abbreviated, time: .omitted))")
                }
            }
        case .downloading(let release, let fraction):
            LabeledContent {
                HStack(spacing: 8) {
                    ProgressView(value: fraction)
                        .frame(width: 120)
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button("Cancel") { updater.cancelDownload() }
                }
            } label: {
                Text("Downloading version \(release.version.description)…")
            }
        case .preparing(let release):
            LabeledContent {
                ProgressView().controlSize(.small)
            } label: {
                Text("Verifying version \(release.version.description)…")
            }
        case .ready(let release):
            LabeledContent {
                Button("Restart to Update") { updater.restartToUpdate() }
                    .buttonStyle(.borderedProminent)
            } label: {
                Text("Version \(release.version.description) is ready to install")
                Text("It also installs the next time you quit CloudStream.")
            }
        case .failed(let message, let release):
            LabeledContent {
                Button("Try Again") { release == nil ? updater.checkNow() : updater.download() }
            } label: {
                if let release {
                    Text("Couldn’t install version \(release.version.description)")
                } else {
                    Text("Couldn’t check for updates")
                }
                Text(message)
            }
        case .idle, .upToDate:
            LabeledContent {
                Button("Check for Updates") { updater.checkNow() }
                    .disabled(!updater.isAvailable)
                    .accessibilityIdentifier("Settings Check for Updates")
            } label: {
                Text(updater.phase == .upToDate ? "CloudStream is up to date" : "Check for a newer version")
                if let error = updater.lastBackgroundError {
                    Text("The last automatic check failed: \(error)")
                } else if let date = updater.lastCheckedAt {
                    Text("Last checked \(date.formatted(.relative(presentation: .named)))")
                }
            }
        }
    }
}

/// CloudStream ▸ Check for Updates…: checks and shows the result in Settings.
struct CheckForUpdatesCommand: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Check for Updates…") {
            SoftwareUpdater.shared.checkNow()
            openSettings()
        }
        .disabled(!SoftwareUpdater.shared.isAvailable)
    }
}
