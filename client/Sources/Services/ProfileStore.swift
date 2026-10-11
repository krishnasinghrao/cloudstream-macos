import Foundation

@MainActor
@Observable
final class ProfileStore {
    static let shared = ProfileStore()

    private(set) var profiles: [ViewerProfile]
    private(set) var activeID: UUID

    @ObservationIgnored private let defaults: UserDefaults
    nonisolated static let maxProfiles = 8
    nonisolated static let maxNameLength = 32

    var active: ViewerProfile {
        profiles.first { $0.id == activeID } ?? profiles[0]
    }

    init(defaults: UserDefaults = AppEnvironment.defaults) {
        self.defaults = defaults
        var loaded = (defaults.data(forKey: "profiles.v1").flatMap { try? JSONDecoder().decode([ViewerProfile].self, from: $0) }) ?? []
        if !loaded.contains(where: \.isDefault) {
            loaded.insert(ViewerProfile(id: ViewerProfile.defaultID, name: "Me", symbol: ViewerProfile.symbols[0], requiresUnlock: false), at: 0)
        }
        // SEC-04: Verify requiresUnlock flags against secure Keychain record to prevent plist tampering
        let keychainLocked = ProfileLockSecurity.readLocked()
        for i in loaded.indices {
            if keychainLocked.contains(loaded[i].id) {
                loaded[i].requiresUnlock = true
            }
        }
        profiles = loaded
        let stored = defaults.string(forKey: "activeProfileID").flatMap(UUID.init(uuidString:))
        activeID = stored.flatMap { id in loaded.first { $0.id == id }?.id } ?? ViewerProfile.defaultID
    }

    /// Opens the active profile's store. Call once at launch.
    func activateStoredProfile(library: LibraryStore = .shared) {
        do {
            try library.activateProfileStore(named: active.isDefault ? nil : active.storeName)
        } catch {
            DaemonLog.client("profile.activate_failed", fields: ["error": error.localizedDescription])
            library.suspendProfileAfterStartupFailure(error, storeName: active.isDefault ? nil : active.storeName)
        }
        SpotlightIndexer.shared.invalidateAndSchedule()
    }

    enum ProfileError: LocalizedError {
        case limitReached
        case invalidName
        case cannotDeleteDefault
        case cannotDeleteActive

        var errorDescription: String? {
            switch self {
            case .limitReached: return "You can have up to \(ProfileStore.maxProfiles) profiles."
            case .invalidName: return "Enter a profile name."
            case .cannotDeleteDefault: return "The main profile can't be deleted."
            case .cannotDeleteActive: return "Switch to another profile before deleting this one."
            }
        }
    }

    static func sanitizedName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxNameLength))
    }

    @discardableResult
    func add(name: String, symbol: String, requiresUnlock: Bool = false) throws -> ViewerProfile {
        guard profiles.count < Self.maxProfiles else { throw ProfileError.limitReached }
        guard let clean = Self.sanitizedName(name) else { throw ProfileError.invalidName }
        let profile = ViewerProfile(id: UUID(), name: clean, symbol: symbol, requiresUnlock: requiresUnlock)
        profiles.append(profile)
        persist()
        return profile
    }

    func update(_ profile: ViewerProfile) throws {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        guard let clean = Self.sanitizedName(profile.name) else { throw ProfileError.invalidName }
        var updated = profile
        updated.name = clean
        profiles[index] = updated
        persist()
    }

    func delete(_ profile: ViewerProfile) throws {
        guard !profile.isDefault else { throw ProfileError.cannotDeleteDefault }
        guard profile.id != activeID else { throw ProfileError.cannotDeleteActive }
        profiles.removeAll { $0.id == profile.id }
        persist()
        LibraryStore.deleteProfileStore(named: profile.storeName)
    }

    /// Switches the library to `profile`. Unlock (if required) is the
    /// caller's job — see `AppLock.switchProfile`.
    func select(_ profile: ViewerProfile, library: LibraryStore = .shared,
                identityProviders: [LibraryIdentityMigration.Provider] = []) throws {
        guard profile.id != activeID else { return }
        WindowSessionRegistry.shared.invalidateProfileNavigation()
        try library.activateProfileStore(named: profile.isDefault ? nil : profile.storeName, identityProviders: identityProviders)
        activeID = profile.id
        persist()
        SpotlightIndexer.shared.invalidateAndSchedule()
        BackupService.shared.checkSchedule()
        DaemonLog.client("profile.switched", fields: ["profile": profile.isDefault ? "default" : "other"])
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(profiles), forKey: "profiles.v1")
        defaults.set(activeID.uuidString, forKey: "activeProfileID")
        // SEC-04: Persist lock requirements to Keychain
        let locked = Set(profiles.filter(\.requiresUnlock).map(\.id))
        ProfileLockSecurity.recordLocked(profileIDs: locked)
    }
}
