package com.lagradost.macos.models

import kotlinx.serialization.Serializable

@Serializable
data class RepositoryDto(
    val name: String,
    val url: String,
    val description: String? = null,
    val iconUrl: String? = null,
    val manifestVersion: Int = 0,
    val pluginCount: Int = 0,
    val status: String,
    val error: String? = null,
    /** Signed by a key the organization pinned (not merely signed: see [tier]). */
    val verified: Boolean = false,
    /** SHA-256 fingerprint of the repository's signing key (shown for signed catalogs). */
    val keyFingerprint: String? = null,
    /**
     * "verified" (signed by a policy-pinned key), "signed" (signed by the key
     * first seen for it; consent required) or "community" (unsigned, consent required).
     */
    val tier: String = "community",
    val consented: Boolean = false,
    /** Installing needs the user's first-time consent ([consented] records it). */
    val consentRequired: Boolean = true,
    val lastSyncedAt: Long? = null,
    val lastAttemptAt: Long? = null,
    val installedCount: Int = 0,
    val discoveredVia: String? = null,
    val allowedByPolicy: Boolean = true,
    /** Child repositories of an HTML discovery page that this sync could not load (returned by sync only). */
    val skippedRepositories: List<SkippedRepositoryDto> = emptyList(),
)

@Serializable
data class SkippedRepositoryDto(val url: String, val reason: String)

@Serializable
data class ReposSyncRequestDto(
    val repoUrl: String,
    val installAll: Boolean = false,
)

@Serializable
data class ReposImportRequestDto(val urls: List<String>)

@Serializable
data class RepoRemoveRequestDto(
    val repoUrl: String,
    /** True also uninstalls every extension installed from this repository. */
    val deleteDownloadedPlugins: Boolean = true,
)

@Serializable
data class RepoConsentRequestDto(val repoUrl: String, val allow: Boolean)

@Serializable
data class PluginInstallRequestDto(
    val repoUrl: String,
    val internalName: String,
    val pluginUrl: String = "",
    val fileHash: String? = null,
    /** Explicitly accept an older catalog version than the installed one. */
    val allowDowngrade: Boolean = false,
)

/** Body for update / rollback / retry / uninstall. */
@Serializable
data class InstallationRequestDto(val installationId: String)

@Serializable
data class UpdateResultDto(val installationId: String, val name: String, val error: String? = null)

@Serializable
data class UpdateAllRequestDto(val repoUrl: String? = null)

@Serializable
data class ExtensionSettingsDto(
    val autoUpdate: Boolean = false,
    /** Non-null when an organization policy fixes the value. */
    val autoUpdateManaged: Boolean = false,
    val allowCommunityTier: Boolean = true,
    val allowLocalObservation: Boolean = true,
    val allowUserRepositories: Boolean = true,
    val policyManaged: Boolean = false,
    val safeMode: Boolean = false,
    val legacyArtifactsPending: Int = 0,
    /** Outcome of the last periodic catalog refresh (null until one has run). */
    val lastBackgroundRefresh: BackgroundRefreshDto? = null,
    /** Local `.cs3` imports are enabled (plan D5). */
    val developerMode: Boolean = false,
    /** False when an organization policy forbids developer mode. */
    val developerModeAllowed: Boolean = true,
)

@Serializable
data class BackgroundRefreshDto(
    val at: Long,
    val repositories: Int,
    val syncFailures: Int,
    /** Names of extensions updated automatically. */
    val updated: List<String> = emptyList(),
    val updateFailures: List<String> = emptyList(),
)

@Serializable
data class ExtensionSettingsUpdateDto(val autoUpdate: Boolean? = null, val developerMode: Boolean? = null)

@Serializable
data class DeveloperInstallRequestDto(val path: String)

/** Typed IPC error (IPC v4). */
@Serializable
data class ExtensionErrorDto(val error: String, val code: String, val detail: String? = null)

@Serializable
data class RepoPluginDto(
    val id: String,
    val name: String,
    val internalName: String,
    val version: Int = 0,
    val apiVersion: Int = 0,
    val url: String,
    val repositoryUrl: String,
    val description: String? = null,
    val authors: List<String> = emptyList(),
    val tvTypes: List<String> = emptyList(),
    val language: String? = null,
    val iconUrl: String? = null,
    val fileSize: Long? = null,
    val fileHash: String? = null,
    val status: Int = 1,
    val isInstalled: Boolean = false,
    val isUpdateAvailable: Boolean = false,
    val installationAllowed: Boolean = false,
    val installationBlockedReason: String? = null,
    val tier: String? = null,
    val installationId: String? = null,
    val installedVersion: Int? = null,
    /** "none", "update" or "older_in_catalog". */
    val updateState: String = "none",
    val requiresConsent: Boolean = false,
    val verificationMode: String? = null,
)

@Serializable
data class PluginDto(
    val id: String,
    val name: String,
    val internalName: String,
    val version: Int = 0,
    val apiVersion: Int = 0,
    val language: String? = null,
    val description: String? = null,
    val authors: List<String> = emptyList(),
    val tvTypes: List<String> = emptyList(),
    val iconUrl: String? = null,
    val repositoryUrl: String? = null,
    val mainUrl: String? = null,
    val fileSize: Long = 0,
    val sha256: String? = null,
    val verificationMode: String? = null,
    val publisherHash: String? = null,
    val proofFormatVersion: Int? = null,
    val providers: List<String> = emptyList(),
    val enabled: Boolean = true,
    /** Whether the repository that published this plugin is signature-verified. */
    val verified: Boolean = false,
    val lastError: String? = null,
    /** running, starting, disabled, failed, revoked, quarantined or safe_mode. */
    val state: String = "running",
    val tier: String = "verified",
    val installedAt: Long = 0,
    val availableVersion: Int? = null,
    val updateAvailable: Boolean = false,
    val previousVersion: Int? = null,
    val missingFromCatalog: Boolean = false,
    val repositoryPresent: Boolean = true,
    val extractorCount: Int = 0,
    val providerIds: List<String> = emptyList(),
    val unsupportedFeatures: List<String> = emptyList(),
    /** Static host-compatibility evidence (RT-05); null until the extension has been translated. */
    val compatibility: CompatibilityDto? = null,
    /** Extension process: `not_started` (registered, starts on first use), `running`, or `in_process` (development isolation). */
    val process: String? = null,
    /** Last outcome per provider and stage for the installed version (RT-16), newest first. */
    val health: List<OperationHealthDto> = emptyList(),
    /** Providers of this extension whose names other installed extensions also register (X2). */
    val sharedProviderNames: List<SharedProviderNameDto> = emptyList(),
)

/** A provider name two installed extensions both register: titles saved by name alone are ambiguous. */
@Serializable
data class SharedProviderNameDto(
    val provider: String,
    /** Names of the other extensions that register it. */
    val alsoIn: List<String>,
)

/** RT-16: the last outcome of one provider operation stage. Never contains URLs or provider data. */
@Serializable
data class OperationHealthDto(
    val provider: String,
    val providerId: String,
    /** `search`, `home`, `details` or `links`. */
    val stage: String,
    val ok: Boolean,
    /** Typed failure code when not [ok]. */
    val code: String? = null,
    val message: String? = null,
    val at: Long,
)

/** RT-05: host APIs an extension references that this engine does not provide. */
@Serializable
data class CompatibilityDto(
    /** Runtime profile the assessment was made against. */
    val profile: String,
    /** False when the engine's profile changed since; the next load reassesses. */
    val current: Boolean,
    /** Missing host types referenced from the entry class or provider classes. They fail
     * only if that code runs (e.g. a settings branch), so a working extension may list some. */
    val coreCode: List<String> = emptyList(),
    /** Missing host types elsewhere (usually Android UI that never runs on macOS). */
    val otherCode: List<String> = emptyList(),
    val truncated: Boolean = false,
)

/** POST /plugins/setEnabled body — extension-level (installation) enable state. */
@Serializable
data class PluginEnabledRequestDto(
    val installationId: String,
    val enabled: Boolean,
)

/** POST /providers/setEnabled body — one provider of a multi-provider extension. */
@Serializable
data class ProviderEnabledRequestDto(
    val providerId: String,
    val enabled: Boolean,
)

/** POST /plugins/config body — per-provider overrides (clone-site / credentials).
 * Credentials are applied in memory only; the client keeps them in the Keychain
 * and re-sends them after each engine start. */
@Serializable
data class PluginConfigRequestDto(
    val providerId: String,
    val url: String? = null,
    val credentials: String? = null,
    /** Clears every override for the provider. */
    val reset: Boolean = false,
    /** Explicit clears. A null value means unchanged; an empty value is also treated as a clear. */
    val clearUrl: Boolean = false,
    val clearCredentials: Boolean = false,
)

/** One address of a `/repos/register` request: `applied`, `already_present` or `rejected`. */
@Serializable
data class RepoRegistrationDto(val url: String, val status: String, val reason: String? = null)

@Serializable
data class PluginConfigResponseDto(
    val providerId: String,
    val mainUrl: String,
    /** The live provider is using the requested settings now. */
    val applied: Boolean,
    val detail: String? = null,
    /** Accepted and held by the engine; takes effect when the extension next loads. */
    val pending: Boolean = false,
    /** Not accepted, but the same request may succeed later. */
    val retryable: Boolean = false,
)

/** POST /repos/trust body — explicit re-trust after a pinned key change. */
@Serializable
data class RepoTrustRequestDto(
    val repoUrl: String,
)

/** GET /providers — one entry per enabled provider (IPC v3). */
@Serializable
data class ProviderInfoDto(
    val name: String,
    /** Stable provider identity (`<installationId>:<name>`). */
    val providerId: String = name,
    val enabled: Boolean = true,
    /** Source plugin filename; null for bundled providers. */
    val plugin: String? = null,
    val mainUrl: String,
    val language: String,
    val tvTypes: List<String> = emptyList(),
    val hasMainPage: Boolean = false,
    val hasQuickSearch: Boolean = false,
    /** "None" | "MightBeNeeded" | "Torrent" */
    val vpnStatus: String = "None",
)

@Serializable
data class ExtensionPreferencesUpdateRequestDto(
    val installationId: String,
    val updates: List<com.lagradost.macos.ExtensionPreferenceUpdateDto>,
)
