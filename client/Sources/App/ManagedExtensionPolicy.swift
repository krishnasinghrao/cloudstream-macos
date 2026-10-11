import Foundation

/// Organization policy for extensions, read from managed preferences
/// (a configuration profile targeting this app's domain). Only values the
/// system reports as *forced* count, so a user cannot relax — or spoof — a
/// policy with `defaults write`. The daemon enforces the policy; the UI only
/// mirrors it.
///
/// Keys (docs/Security.md → Managed configuration):
/// - `ExtensionsAllowedRepositories` — [String] repository URLs (case, default port and query ignored)
/// - `ExtensionsBlockedRepositories` — [String] hosts (with their subdomains) or host + path prefixes
/// - `ExtensionsPinnedRepositoryKeys` — [String: String] URL → Ed25519 public key (base64)
/// - `ExtensionsAllowCommunityRepositories` — Bool
/// - `ExtensionsAllowUserRepositories` — Bool
/// - `ExtensionsAutoUpdate` — Bool
/// - `ExtensionsSafeModeOnly` — Bool
/// - `ExtensionsRequireSandbox` — Bool (default true: the engine refuses to run extensions unsandboxed)
/// - `ExtensionsAllowDeveloperExtensions` — Bool (false forbids developer mode)
struct ManagedExtensionPolicy: Encodable, Equatable, Sendable {
    var allowedRepositories: [String]?
    var blockedRepositories: [String] = []
    var pinnedRepositoryKeys: [String: String] = [:]
    var allowCommunityTier = true
    var allowLocalObservation = true
    var allowUserRepositories = true
    var autoUpdate: Bool?
    var safeModeOnly = false
    /// False forbids developer mode (local extension files).
    var allowDeveloperExtensions = true
    /// Never run extension code outside the macOS sandbox (enforced by the engine).
    /// On unless a profile turns it off: a Mac without `sandbox-exec` refuses
    /// extensions rather than running them unconfined (audit L6).
    var requireSandbox = true
    var managed = false

    private enum CodingKeys: String, CodingKey {
        case allowedRepositories, blockedRepositories, pinnedRepositoryKeys, allowCommunityTier
        case allowLocalObservation, allowUserRepositories, autoUpdate, safeModeOnly, requireSandbox, allowDeveloperExtensions, managed
    }

    static func current(defaults: UserDefaults = AppEnvironment.defaults) -> ManagedExtensionPolicy {
        from { key in defaults.objectIsForced(forKey: key) ? defaults.object(forKey: key) : nil }
    }

    /// Builds the policy from forced values. A forced key with the wrong type
    /// means the profile is misconfigured: fail closed instead of ignoring it.
    static func from(forced: (String) -> Any?) -> ManagedExtensionPolicy {
        var policy = ManagedExtensionPolicy()
        var invalid = false
        func read<T>(_ key: String, as _: T.Type) -> T? {
            guard let raw = forced(key) else { return nil }
            policy.managed = true
            guard let value = raw as? T else { invalid = true; return nil }
            return value
        }
        if let value = read("ExtensionsAllowedRepositories", as: [String].self) { policy.allowedRepositories = value }
        if let value = read("ExtensionsBlockedRepositories", as: [String].self) { policy.blockedRepositories = value }
        if let value = read("ExtensionsPinnedRepositoryKeys", as: [String: String].self) { policy.pinnedRepositoryKeys = value }
        if let value = read("ExtensionsAllowCommunityRepositories", as: Bool.self) { policy.allowCommunityTier = value }
        if let value = read("ExtensionsAllowLocalArtifactObservation", as: Bool.self) { policy.allowLocalObservation = value }
        if let value = read("ExtensionsAllowUserRepositories", as: Bool.self) { policy.allowUserRepositories = value }
        if let value = read("ExtensionsAutoUpdate", as: Bool.self) { policy.autoUpdate = value }
        if let value = read("ExtensionsSafeModeOnly", as: Bool.self) { policy.safeModeOnly = value }
        if let value = read("ExtensionsRequireSandbox", as: Bool.self) { policy.requireSandbox = value }
        if let value = read("ExtensionsAllowDeveloperExtensions", as: Bool.self) { policy.allowDeveloperExtensions = value }
        return invalid ? .failClosed() : policy
    }

    /// Nothing loads and nothing can be added (misconfigured or unreadable policy).
    /// The sandbox requirement is never relaxed here.
    static func failClosed() -> ManagedExtensionPolicy {
        ManagedExtensionPolicy(allowedRepositories: [], allowCommunityTier: false, allowUserRepositories: false,
                               safeModeOnly: true, allowDeveloperExtensions: false, requireSandbox: true, managed: true)
    }
}

/// Second stdin line for the daemon (after the bearer token).
struct DaemonLaunchOptions: Encodable, Sendable {
    let policy: ManagedExtensionPolicy
    let safeMode: Bool
    /// One sandboxed worker process per extension (ADR-0016).
    var isolation = "worker"

    func encodedLine() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // An encoding failure must not reach the daemon as "no policy".
        let body = (try? encoder.encode(self))
            ?? (try? encoder.encode(DaemonLaunchOptions(policy: .failClosed(), safeMode: true)))
            ?? Data(#"{"isolation":"worker","policy":{"allowCommunityTier":false,"allowUserRepositories":false,"allowedRepositories":[],"allowDeveloperExtensions":false,"managed":true,"requireSandbox":true,"safeModeOnly":true},"safeMode":true}"#.utf8)
        return body + Data("\n".utf8)
    }
}
