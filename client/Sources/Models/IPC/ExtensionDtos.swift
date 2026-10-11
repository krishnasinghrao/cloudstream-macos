import Foundation

// IPC JSON values mirrored by the engine (ipc-api.md, contract v6).

struct RepositoryDto: Codable, Sendable, Identifiable, Hashable {
    let name: String
    let url: String
    let description: String?
    let iconUrl: String?
    let manifestVersion: Int
    let pluginCount: Int
    let status: String
    let error: String?
    let verified: Bool
    let keyFingerprint: String?
    /// "verified" (signed by a key the organization pinned), "signed" (signed by
    /// the key first seen for it; installs need consent) or "community"
    /// (unsigned; installs need consent).
    var tier: String = "community"
    var consented: Bool = false
    /// Installing needs the user's first-time consent (every repository whose key policy has not pinned).
    var consentRequired: Bool = true
    var lastSyncedAt: Int? = nil
    var lastAttemptAt: Int? = nil
    var installedCount: Int = 0
    var discoveredVia: String? = nil
    var allowedByPolicy: Bool = true

    var id: String { url }

    enum CodingKeys: String, CodingKey {
        case name, url, description, iconUrl, manifestVersion, pluginCount, status, error, verified, keyFingerprint
        case tier, consented, consentRequired, lastSyncedAt, lastAttemptAt, installedCount, discoveredVia, allowedByPolicy
    }

    init(name: String, url: String, description: String?, iconUrl: String?, manifestVersion: Int, pluginCount: Int,
         status: String, error: String?, verified: Bool, keyFingerprint: String?, tier: String = "community",
         consented: Bool = false, consentRequired: Bool? = nil, lastSyncedAt: Int? = nil, lastAttemptAt: Int? = nil,
         installedCount: Int = 0, discoveredVia: String? = nil, allowedByPolicy: Bool = true) {
        self.name = name
        self.url = url
        self.description = description
        self.iconUrl = iconUrl
        self.manifestVersion = manifestVersion
        self.pluginCount = pluginCount
        self.status = status
        self.error = error
        self.verified = verified
        self.keyFingerprint = keyFingerprint
        self.tier = tier
        self.consented = consented
        self.consentRequired = consentRequired ?? (tier != "verified")
        self.lastSyncedAt = lastSyncedAt
        self.lastAttemptAt = lastAttemptAt
        self.installedCount = installedCount
        self.discoveredVia = discoveredVia
        self.allowedByPolicy = allowedByPolicy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(String.self, forKey: .url)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        iconUrl = try container.decodeIfPresent(String.self, forKey: .iconUrl)
        manifestVersion = try container.decodeIfPresent(Int.self, forKey: .manifestVersion) ?? 0
        pluginCount = try container.decodeIfPresent(Int.self, forKey: .pluginCount) ?? 0
        status = try container.decode(String.self, forKey: .status)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        verified = try container.decodeIfPresent(Bool.self, forKey: .verified) ?? false
        keyFingerprint = try container.decodeIfPresent(String.self, forKey: .keyFingerprint)
        tier = try container.decodeIfPresent(String.self, forKey: .tier) ?? (verified ? "verified" : "community")
        consented = try container.decodeIfPresent(Bool.self, forKey: .consented) ?? false
        consentRequired = try container.decodeIfPresent(Bool.self, forKey: .consentRequired) ?? (tier != "verified")
        lastSyncedAt = try container.decodeIfPresent(Int.self, forKey: .lastSyncedAt)
        lastAttemptAt = try container.decodeIfPresent(Int.self, forKey: .lastAttemptAt)
        installedCount = try container.decodeIfPresent(Int.self, forKey: .installedCount) ?? 0
        discoveredVia = try container.decodeIfPresent(String.self, forKey: .discoveredVia)
        allowedByPolicy = try container.decodeIfPresent(Bool.self, forKey: .allowedByPolicy) ?? true
    }
}

struct RepoPluginDto: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let name: String
    let internalName: String
    let version: Int
    let apiVersion: Int
    let url: String
    let repositoryUrl: String
    let description: String?
    let authors: [String]
    let tvTypes: [String]
    let language: String?
    let iconUrl: String?
    let fileSize: Int?
    let fileHash: String?
    let status: Int
    let isInstalled: Bool
    let isUpdateAvailable: Bool
    var installationAllowed: Bool? = nil
    var installationBlockedReason: String? = nil
    var tier: String? = nil
    var installationId: String? = nil
    var installedVersion: Int? = nil
    /// "none", "update" or "older_in_catalog".
    var updateState: String? = nil
    var requiresConsent: Bool? = nil
    var verificationMode: String? = nil

    var catalogID: String { "\(repositoryUrl.utf8.count):\(repositoryUrl)\(internalName)" }
}

struct PluginInstallRequestDto: Encodable, Sendable {
    let repoUrl: String
    let internalName: String
    let pluginUrl: String
    let fileHash: String?
    var allowDowngrade: Bool = false
}

/// Body for update / rollback / retry / uninstall (IPC v4).
struct InstallationRequestDto: Encodable, Sendable {
    let installationId: String
}

struct RepoConsentRequestDto: Encodable, Sendable {
    let repoUrl: String
    let allow: Bool
}

struct UpdateAllRequestDto: Encodable, Sendable {
    let repoUrl: String?
}

struct UpdateResultDto: Codable, Sendable, Hashable {
    let installationId: String
    let name: String
    let error: String?
}

struct ExtensionSettingsDto: Codable, Sendable, Hashable {
    var autoUpdate: Bool = false
    var autoUpdateManaged: Bool = false
    var allowCommunityTier: Bool = true
    var allowUserRepositories: Bool = true
    var policyManaged: Bool = false
    var safeMode: Bool = false
    var legacyArtifactsPending: Int = 0
    /// Outcome of the engine's last periodic catalog refresh.
    var lastBackgroundRefresh: BackgroundRefreshDto?
    /// Local `.cs3` imports are enabled (plan D5).
    var developerMode = false
    /// False when an organization policy forbids developer mode.
    var developerModeAllowed = true
}

struct DeveloperInstallRequestDto: Encodable, Sendable {
    let path: String
}

struct BackgroundRefreshDto: Codable, Sendable, Hashable {
    let at: Int64
    let repositories: Int
    let syncFailures: Int
    var updated: [String] = []
    var updateFailures: [String] = []
}

struct ExtensionSettingsUpdateDto: Encodable, Sendable {
    var autoUpdate: Bool? = nil
    var developerMode: Bool? = nil
}

struct ProviderEnabledRequestDto: Encodable, Sendable {
    let providerId: String
    let enabled: Bool
}

/// Outcome of registering one repository address: `applied`,
/// `already_present` or `rejected` (with a reason).
struct RepoRegistrationDto: Codable, Sendable, Equatable {
    let url: String
    let status: String
    var reason: String? = nil
}

/// One provider setting in a configuration request.
enum ProviderSettingPatch: Equatable, Sendable {
    case unchanged
    case set(String)
    case clear

    var value: String? { if case .set(let value) = self { return value } else { return nil } }
}

struct PluginConfigRequestDto: Encodable, Sendable {
    let providerId: String
    /// nil = unchanged. Clears are explicit flags, never an absent value.
    let url: String?
    let credentials: String?
    var reset: Bool = false
    var clearUrl: Bool = false
    var clearCredentials: Bool = false

    init(providerId: String, url: ProviderSettingPatch = .unchanged, credentials: ProviderSettingPatch = .unchanged, reset: Bool = false) {
        self.providerId = providerId
        self.url = url.value
        self.credentials = credentials.value
        self.reset = reset
        self.clearUrl = url == .clear
        self.clearCredentials = credentials == .clear
    }
}

struct PluginConfigResponseDto: Codable, Sendable {
    let providerId: String
    let mainUrl: String
    /// The running provider uses the requested settings now.
    let applied: Bool
    let detail: String?
    /// Accepted by the engine; takes effect when the extension next loads.
    var pending: Bool? = nil
    var retryable: Bool? = nil

    /// The engine holds the requested state, live or for the next load.
    var accepted: Bool { applied || pending == true }
}

struct RepoRemoveRequestDto: Encodable, Sendable {
    let repoUrl: String
    let deleteDownloadedPlugins: Bool
}

struct ReposSyncRequestDto: Encodable, Sendable {
    let repoUrl: String
    let installAll: Bool
}

struct CompatibilityDto: Codable, Sendable, Hashable {
    let profile: String
    let current: Bool
    var coreCode: [String] = []
    var otherCode: [String] = []
    var truncated: Bool = false

    /// Referenced from the extension's entry or provider code: those paths fail if they run.
    var hasCoreGaps: Bool { !coreCode.isEmpty }
}

/// A provider name two installed extensions both register (X2).
struct SharedProviderNameDto: Codable, Sendable, Hashable {
    let provider: String
    let alsoIn: [String]
}

/// RT-16: last outcome of one provider operation stage for the installed version.
struct OperationHealthDto: Codable, Sendable, Hashable {
    let provider: String
    let providerId: String
    let stage: String
    let ok: Bool
    var code: String? = nil
    var message: String? = nil
    let at: Int64

    var stageLabel: String {
        switch stage {
        case "search": "Search"
        case "home": "Home page"
        case "details": "Details"
        case "links": "Video links"
        default: stage.capitalized
        }
    }
}

struct PluginDto: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let name: String
    let internalName: String
    let version: Int
    let apiVersion: Int
    let language: String?
    let description: String?
    let authors: [String]
    let tvTypes: [String]
    let iconUrl: String?
    let repositoryUrl: String?
    let mainUrl: String?
    let fileSize: Int
    let sha256: String?
    let providers: [String]
    let enabled: Bool
    let verified: Bool
    let lastError: String?
    /// running, starting, disabled, failed, revoked, quarantined or safe_mode (IPC v4).
    var state: String? = nil
    var tier: String? = nil
    var installedAt: Int? = nil
    var availableVersion: Int? = nil
    var updateAvailable: Bool? = nil
    var previousVersion: Int? = nil
    var missingFromCatalog: Bool? = nil
    var repositoryPresent: Bool? = nil
    var extractorCount: Int? = nil
    var providerIds: [String]? = nil
    var unsupportedFeatures: [String]? = nil
    /// Android/app APIs the extension references that this Mac engine lacks (RT-05).
    var compatibility: CompatibilityDto? = nil
    /// `not_started`, `running` or `in_process` (RT-16).
    var process: String? = nil
    var health: [OperationHealthDto]? = nil
    var verificationMode: String? = nil
    var publisherHash: String? = nil
    var proofFormatVersion: Int? = nil
    /// Provider names other installed extensions also register (X2).
    var sharedProviderNames: [SharedProviderNameDto]? = nil

    var verificationLabel: String {
        switch verificationMode {
        case "signed_catalog": "Signed catalog"
        case "publisher_digest": "Publisher digest checked"
        case "local_observation": "Downloaded bytes recorded locally"
        case "developer_import": "Local developer import"
        default: verified ? "Signed catalog" : "Publisher verification unknown"
        }
    }

    var runState: String { state ?? (enabled ? "running" : "disabled") }
    /// Registered and usable: running now, or ready to start on first use.
    var isOperational: Bool { runState == "running" || runState == "ready" }
    /// Newest outcome, when it was a failure: the stage the user last saw break.
    var latestFailure: OperationHealthDto? { health?.first.flatMap { $0.ok ? nil : $0 } }
    var isExtractorOnly: Bool { providers.isEmpty }
    /// Hashless installs: the catalog cannot show a republished file, so the user can download and compare (RT-08).
    var canRecheck: Bool { verificationMode == "local_observation" && updateAvailable != true && repositoryPresent != false }
}

/// Catalog sentinels are not displayable versions; shared by UI and isolated tests.
enum ExtensionVersion {
    static func label(_ version: Int) -> String? { version > 0 ? "v\(version)" : nil }
}

struct PluginEnabledRequestDto: Encodable, Sendable {
    let installationId: String
    let enabled: Bool
}

struct ProviderInfoDto: Codable, Sendable, Hashable, Identifiable {
    let name: String
    /// Stable provider identity (IPC v4); nil from older daemons.
    var providerId: String? = nil
    var enabled: Bool? = nil
    let plugin: String?
    let mainUrl: String
    let language: String
    let tvTypes: [String]
    let hasMainPage: Bool
    let hasQuickSearch: Bool
    let vpnStatus: String
    var id: String { providerId ?? name }

    var needsVPN: Bool { vpnStatus != "None" }
}

struct ExtensionPreferenceDto: Codable, Sendable, Hashable {
    let key: String
    /// `string`, `boolean`, `int`, `long`, `float` or `string_set`.
    let type: String
    var `default`: String? = nil
    var value: String? = nil
    var values: [String]? = nil
    var isSet: Bool = false

    var typeLabel: String {
        switch type {
        case "string": "Text"
        case "boolean": "On or off"
        case "int", "long": "Whole number"
        case "float": "Number"
        case "string_set": "List, one item per line"
        default: type
        }
    }

    /// The stored value as edited in a text control.
    var editableText: String { type == "string_set" ? (values ?? []).joined(separator: "\n") : (value ?? "") }
}

struct ExtensionPreferencesDto: Codable, Sendable {
    var fields: [ExtensionPreferenceDto] = []
    var truncated: Bool = false
}

struct ExtensionPreferenceUpdateDto: Codable, Sendable, Hashable {
    let key: String
    let value: String?
    let values: [String]?
    let remove: Bool
}
