import SwiftUI

/// Full-window lock screen (Phase 7.3).
struct LockView: View {
    private var lock: AppLock { AppLock.shared }

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThickMaterial).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("CloudStream is locked")
                    .font(.title2.weight(.semibold))
                Text("Profile: \(ProfileStore.shared.active.name)")
                    .foregroundStyle(.secondary)
                Button {
                    Task { await lock.unlock() }
                } label: {
                    Label("Unlock with \(AppLock.biometryName)", systemImage: "touchid")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                if let error = lock.lastError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .padding(40)
        }
        .task { await lock.unlock() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("CloudStream is locked")
    }
}

/// Sidebar footer: current profile + switcher (Phase 7.2).
struct ProfileSwitcher: View {
    @State private var showManager = false
    private var store: ProfileStore { ProfileStore.shared }

    var body: some View {
        Menu {
            ForEach(store.profiles) { profile in
                Button {
                    Task { _ = await AppLock.shared.switchProfile(to: profile) }
                } label: {
                    Label(profile.name + (profile.requiresUnlock ? " 🔒" : ""), systemImage: profile.id == store.activeID ? "checkmark" : profile.symbol)
                }
                .disabled(profile.id == store.activeID)
            }
            Divider()
            Button("Manage Profiles…") { showManager = true }
            if UserPreferences.shared.requireUnlock || store.active.requiresUnlock {
                Button("Lock Now") { AppLock.shared.lockIfEnabled(reason: "manual") }
                    .keyboardShortcut("l", modifiers: [.command, .control])
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: store.active.symbol)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                Text(store.active.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .help("Switch profile")
        .accessibilityLabel("Profile: \(store.active.name). Switch profile")
        .sheet(isPresented: $showManager) { ProfileManagerView() }
    }
}

/// Add, rename, restyle, lock and delete profiles.
struct ProfileManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var editing: ViewerProfile?
    @State private var newName = ""
    @State private var error: String?
    @State private var pendingDelete: ViewerProfile?
    private var store: ProfileStore { ProfileStore.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Profiles")
                .font(.title3.weight(.semibold))
            Text("Each profile has its own library, watch history and per-show settings. Downloads, extensions and app settings are shared.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                ForEach(store.profiles) { profile in
                    row(profile)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(minHeight: 220)

            HStack {
                TextField("New profile name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addProfile)
                Button("Add", action: addProfile)
                    .disabled(ProfileStore.sanitizedName(newName) == nil || store.profiles.count >= ProfileStore.maxProfiles)
            }

            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 480)
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete,
        ) { profile in
            Button("Delete Profile", role: .destructive) {
                do { try store.delete(profile) } catch { self.error = error.localizedDescription }
            }
        } message: { _ in
            Text("Its library, watch history and per-show settings are deleted. This can't be undone.")
        }
    }

    private func row(_ profile: ViewerProfile) -> some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(ViewerProfile.symbols, id: \.self) { symbol in
                    Button { save(profile, symbol: symbol) } label: { Image(systemName: symbol) }
                        .accessibilityLabel(symbol.replacing(".fill", with: "").replacing(".", with: " "))
                }
            } label: {
                Image(systemName: profile.symbol)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Change icon for \(profile.name)")

            TextField("Name", text: Binding(
                get: { profile.name },
                set: { newValue in
                    var copy = profile
                    copy.name = newValue
                    if ProfileStore.sanitizedName(newValue) != nil { try? store.update(copy) }
                },
            ))
            .textFieldStyle(.plain)

            if profile.id == store.activeID {
                Text("Active").font(.caption).foregroundStyle(.secondary)
            }

            Toggle("Lock", isOn: Binding(
                get: { profile.requiresUnlock },
                set: { newValue in
                    Task {
                        // Turning a lock on (or off) needs the owner's approval.
                        guard await AppLock.shared.verifyCanEnable() else { return }
                        var copy = profile
                        copy.requiresUnlock = newValue
                        try? store.update(copy)
                    }
                },
            ))
            .toggleStyle(.checkbox)
            .help("Require \(AppLock.biometryName) to use this profile")

            Button(role: .destructive) {
                pendingDelete = profile
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(profile.isDefault || profile.id == store.activeID)
            .help(profile.isDefault ? "The main profile can't be deleted" : "Delete profile")
            .accessibilityLabel("Delete \(profile.name)")
        }
    }

    private func save(_ profile: ViewerProfile, symbol: String) {
        var copy = profile
        copy.symbol = symbol
        try? store.update(copy)
    }

    private func addProfile() {
        do {
            try store.add(name: newName, symbol: ViewerProfile.symbols[store.profiles.count % ViewerProfile.symbols.count])
            newName = ""
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
