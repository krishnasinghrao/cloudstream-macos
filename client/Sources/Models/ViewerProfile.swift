import Foundation

/// Viewer profiles (Offline-Features-Plan Phase 7.2, Android
/// `AccountSelectActivity` parity). Each profile has its own library, watch
/// history and per-show playback memory in a separate SwiftData store;
/// downloads, extensions and app settings are shared by the Mac.
struct ViewerProfile: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var symbol: String
    /// Require Touch ID / the account password to switch into (and to
    /// unlock the app while) this profile.
    var requiresUnlock: Bool

    static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    var isDefault: Bool { id == Self.defaultID }

    /// SwiftData store file name; the default profile keeps the original store.
    var storeName: String {
        isDefault ? LibraryStore.defaultStoreName : "CloudStreamMac-Profile-\(id.uuidString)"
    }

    static let symbols = ["person.crop.circle.fill", "person.fill", "face.smiling.inverse", "star.circle.fill",
                          "heart.circle.fill", "moon.circle.fill", "gamecontroller.fill", "film.circle.fill",
                          "sparkles", "pawprint.circle.fill"]
}
