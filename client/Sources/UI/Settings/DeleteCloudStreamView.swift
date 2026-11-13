import AppKit
import LocalAuthentication
import SwiftUI

/// Settings ▸ General ▸ Delete CloudStream…: review what goes, back up,
/// confirm (typed word and the Mac's password or Touch ID), then delete.
struct DeleteCloudStreamView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    enum Step { case review, backup, confirm, deleting }

    static let confirmationWord = "DELETE"

    @State private var step = Step.review
    @State private var options = Uninstaller.Options()
    @State private var footprint: UninstallFootprint?
    @State private var sizes: [UninstallItem.Category: Int64] = [:]
    @State private var location = InstalledAppLocation.evaluate(Bundle.main.bundleURL)
    @State private var backupURL: URL?
    @State private var skipBackup = false
    @State private var typed = ""
    @State private var failure: String?
    @State private var keychainItems = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            Group {
                switch step {
                case .review: review
                case .backup: backup
                case .confirm: confirm
                case .deleting: deleting
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            buttons
        }
        .padding(24)
        .frame(width: 520)
        .frame(minHeight: 440)
        .interactiveDismissDisabled(step == .deleting)
        .task(id: options) { await rescan() }
    }

    // MARK: Steps

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "trash.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Delete CloudStream").font(.title2.bold())
                Text(subtitle).foregroundStyle(.secondary)
            }
        }
    }

    private var subtitle: String {
        switch step {
        case .review: "Step 1 of 3 — What will be deleted"
        case .backup: "Step 2 of 3 — Back up your library"
        case .confirm: "Step 3 of 3 — Confirm"
        case .deleting: "Deleting…"
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This removes everything CloudStream keeps on this Mac and moves the app to the Trash. It can’t be undone.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(UninstallItem.Category.allCases.filter { $0 != .downloads }, id: \.self) { category in
                    row(category.rawValue, bytes: sizes[category], present: footprint?.items(in: category).isEmpty == false)
                }
                row("Saved passwords and profile locks (Keychain)", bytes: nil, present: keychainItems > 0)
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            Toggle(isOn: $options.deleteDownloads) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Also delete the videos I downloaded")
                    Text(downloadsDetail).font(.callout).foregroundStyle(.secondary)
                }
            }
            if DownloadService.shared.hasTransfersInFlight {
                note("arrow.down.circle", "\(DownloadService.shared.activeCount) downloads in progress will be stopped.")
            }
            if case .manual(let reason) = location.disposal {
                note("info.circle", reason)
            }
            note("photo", "Screenshots in \(Self.display(appState.preferences.screenshotDirectory)) are kept.")
        }
    }

    private var downloadsDetail: String {
        let count = footprint?.items(in: .downloads).count ?? 0
        guard options.deleteDownloads else {
            return "Off: your downloaded videos stay in \(Self.display(appState.preferences.downloadDirectory))."
        }
        let size = (sizes[.downloads] ?? 0).formatted(.byteCount(style: .file))
        return count == 0 ? "No downloaded files were found." : "\(count) files (\(size)). Only files CloudStream downloaded are removed, never whole folders."
    }

    private var backup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your library, watch history, per-show settings, preferences and extension list are deleted along with CloudStream’s automatic backups. Save a backup somewhere safe first: you can import it into CloudStream on any Mac, or into CloudStream for Android.")
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button(backupURL == nil ? "Back Up…" : "Back Up Again…") { runBackup() }
                    .controlSize(.large)
                    .keyboardShortcut(backupURL == nil ? .defaultAction : .init(.return, modifiers: [.command, .shift]))
                if let backupURL {
                    Label("Saved to \(backupURL.lastPathComponent)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .help(backupURL.path)
                }
            }
            let others = ProfileStore.shared.profiles.filter { $0.id != ProfileStore.shared.activeID }
            if !others.isEmpty {
                note("person.2", "A backup holds one profile: this one, \(ProfileStore.shared.active.name). To keep \(others.map(\.name).formatted(.list(type: .and))), cancel now, switch to each profile and back it up from Settings ▸ General ▸ Backup.")
            }
            note("key", "Backups never contain passwords or downloaded videos.")
            if backupURL == nil {
                Toggle("I don’t need a backup. I understand my library, history and settings can’t be recovered.", isOn: $skipBackup)
                    .padding(.top, 4)
            }
        }
    }

    private var confirm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CloudStream will stop, remove its data, and quit. \(location.disposal == .trash ? "The app is then moved to the Trash." : "")")
                .fixedSize(horizontal: false, vertical: true)
            if options.deleteDownloads, let count = footprint?.items(in: .downloads).count, count > 0 {
                note("exclamationmark.triangle", "\(count) downloaded files will be deleted too.")
            }
            if let backupURL {
                note("checkmark.shield", "Backup saved at \(Self.display(backupURL)).")
            } else {
                note("exclamationmark.triangle", "You chose not to back up.")
            }
            Text("Type \(Self.confirmationWord) to confirm.")
                .padding(.top, 4)
            TextField(Self.confirmationWord, text: $typed)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .autocorrectionDisabled()
                .onSubmit { if canDelete { Task { await delete() } } }
                .accessibilityIdentifier("Delete Confirmation Field")
            Text("You’ll be asked for your Mac’s password or Touch ID.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var deleting: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("Stopping CloudStream and removing its data. CloudStream quits when it’s done.")
        }
    }

    private var buttons: some View {
        HStack {
            if step == .backup || step == .confirm {
                Button("Back") { failure = nil; step = step == .confirm ? .backup : .review }
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(step == .deleting)
            switch step {
            case .review:
                Button("Continue") { failure = nil; step = .backup }
                    .keyboardShortcut(.defaultAction)
                    .disabled(footprint == nil)
            case .backup:
                Button("Continue") { failure = nil; step = .confirm }
                    .disabled(backupURL == nil && !skipBackup)
            case .confirm:
                Button("Delete CloudStream", role: .destructive) { Task { await delete() } }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!canDelete)
                    .accessibilityIdentifier("Delete CloudStream Button")
            case .deleting:
                EmptyView()
            }
        }
    }

    // MARK: Pieces

    private func row(_ title: String, bytes: Int64?, present: Bool) -> some View {
        HStack {
            Image(systemName: present ? "trash.circle.fill" : "circle.dashed")
                .foregroundStyle(present ? Color.red : Color.secondary)
                .accessibilityHidden(true)
            Text(title)
            Spacer()
            if let bytes, bytes > 0 {
                Text(bytes.formatted(.byteCount(style: .file))).monospacedDigit().foregroundStyle(.secondary)
            } else if !present {
                Text("None").foregroundStyle(.secondary)
            }
        }
    }

    private func note(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    static func display(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    private var canDelete: Bool {
        step == .confirm && typed.trimmingCharacters(in: .whitespaces) == Self.confirmationWord
            && (backupURL != nil || skipBackup) && !AppLock.shared.isLocked
    }

    // MARK: Actions

    private func rescan() async {
        let scanned = Uninstaller.shared.footprint(options: options)
        footprint = scanned
        // Isolated (test) launches never read the real Keychain.
        keychainItems = AppEnvironment.isIsolated() ? 0
            : Uninstaller.keychainServices.reduce(0) { $0 + GenericPasswordKeychain.accounts(service: $1).count }
        sizes = await Task.detached(priority: .userInitiated) { scanned.measuredSizes() }.value
    }

    private func runBackup() {
        failure = nil
        guard !AppLock.shared.isLocked else { failure = BackupService.RestoreError.locked.localizedDescription; return }
        let panel = NSSavePanel()
        panel.title = "Back Up Before Deleting"
        panel.message = "Choose a place outside CloudStream, such as Documents or iCloud Drive."
        panel.nameFieldStringValue = BackupService.defaultFileName()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let owner = try? LibraryStore.shared.captureProfileOperation()
        let lock = AppLock.shared.generation
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // A backup saved inside a folder that is about to be deleted would be lost.
        let target = url.standardizedFileURL.path
        if let footprint, footprint.items.contains(where: { target == $0.url.standardizedFileURL.path || target.hasPrefix($0.url.standardizedFileURL.path + "/") }) {
            failure = "That folder is deleted with CloudStream. Choose another place, such as Documents."
            return
        }
        do {
            guard AppLock.shared.generation == lock else { throw BackupService.RestoreError.locked }
            guard let owner, LibraryStore.shared.owns(owner) else { throw BackupService.RestoreError.profileChanged }
            let document = try BackupService.shared.makeDocument(appState: appState)
            try BackupService.shared.write(document, to: url)
            backupURL = url
            skipBackup = false
        } catch {
            failure = "Couldn’t write the backup: \(error.localizedDescription)"
        }
    }

    private func delete() async {
        guard canDelete else { return }
        failure = nil
        switch await AppLock.shared.authenticator("delete CloudStream and all of its data") {
        case .success: break
        case .failure(let error):
            // A Mac with no password set can't authenticate; the typed word is the consent then.
            if (error as? LAError)?.code != .passcodeNotSet {
                failure = "Not deleted: \(error.localizedDescription)"
                return
            }
        }
        step = .deleting
        do {
            try await Uninstaller.shared.perform(options: options)
        } catch {
            failure = error.localizedDescription
            step = .confirm
        }
    }
}
