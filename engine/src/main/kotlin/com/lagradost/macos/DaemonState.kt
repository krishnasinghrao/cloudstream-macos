package com.lagradost.macos

import kotlinx.serialization.Serializable
import java.io.File

/**
 * Persisted daemon state — the only state that survives daemon restarts.
 * Committed installation receipts are the sole authority for executing
 * extension code; catalogs and cached files never are.
 *
 * Filesystem footprint stays inside the data root (SEC-06).
 */
object DaemonState {
    const val SCHEMA_VERSION = 3

    /** How a repository's catalog is trusted. */
    @Serializable
    enum class TrustTier {
        /** Signed root → signed list digests → artifact digests (repository-signing.md). */
        VERIFIED,

        /** Unsigned catalog installable only after explicit consent and truthful byte evidence. */
        COMMUNITY,

        /** Imported from a local file in developer mode (plan D5); loads only while developer mode is on. */
        DEVELOPER,
    }

    @Serializable
    enum class ArtifactVerification {
        @kotlinx.serialization.SerialName("signed_catalog") SIGNED_CATALOG,
        @kotlinx.serialization.SerialName("publisher_digest") PUBLISHER_DIGEST,
        @kotlinx.serialization.SerialName("local_observation") LOCAL_OBSERVATION,
        @kotlinx.serialization.SerialName("developer_import") DEVELOPER_IMPORT;

        companion object {
            fun legacy(tier: TrustTier) = when (tier) {
                TrustTier.VERIFIED -> SIGNED_CATALOG
                TrustTier.COMMUNITY -> PUBLISHER_DIGEST
                TrustTier.DEVELOPER -> DEVELOPER_IMPORT
            }
        }
    }

    /** Pseudo-repository that owns developer (local file) installations. */
    const val DEVELOPER_SOURCE = "developer:local"

    @Serializable
    data class ProviderOverride(
        val url: String? = null,
        /** Credentials are never persisted here; the client keeps them in the Keychain. */
        val hasCredentials: Boolean = false,
    )

    @Serializable
    data class RepositoryTrustAnchor(
        val publicKey: String,
        val keyFingerprint: String,
        val catalogVersion: Long = 0,
        val catalogDigest: String? = null,
    )

    /** Exact catalog list bytes as fetched (signed or community). */
    @Serializable
    data class AuthenticatedCatalogList(val reference: String, val effectiveUrl: String, val body: String)

    @Serializable
    data class RepositoryConsent(val consentedAt: Long, val source: String = "user")

    /** Last committed generation kept for one-step rollback. */
    @Serializable
    data class PreviousGeneration(
        val artifactHash: String,
        val generation: String,
        val proofHash: String,
        val metadata: RepositoryService.SitePlugin,
        val tier: TrustTier,
        val jarHashes: List<String> = emptyList(),
        val providerNames: List<String> = emptyList(),
        val extractorCount: Int = 0,
        val providerDescriptors: List<com.lagradost.macos.worker.ProviderDescriptor> = emptyList(),
        val verificationMode: ArtifactVerification = ArtifactVerification.legacy(tier),
        val publisherHash: String? = RepositoryService.normalizedHash(metadata.fileHash),
        val proofFormatVersion: Int = 1,        val extractorDescriptors: List<com.lagradost.macos.worker.ExtractorDescriptor> = emptyList(),
    )

    @Serializable
    data class InstalledExtension(
        val id: String,
        val repositoryUrl: String,
        val internalName: String,
        val artifactHash: String,
        val generation: String,
        val proofHash: String,
        val installedAt: Long,
        val metadata: RepositoryService.SitePlugin,
        val providerNames: List<String> = emptyList(),
        val extractorCount: Int = 0,
        val enabled: Boolean = true,
        /** Publisher disabled the extension (status 0) or trust could not be re-established. */
        val revokedReason: String? = null,
        /** The generation crashed or hung the engine while loading; never auto-loaded again. */
        val quarantinedReason: String? = null,
        val tier: TrustTier = TrustTier.VERIFIED,
        /** SHA-256 of each translated JAR (classes.dex, classes2.dex, …) produced from the verified source. */
        val jarHashes: List<String> = emptyList(),
        val previous: PreviousGeneration? = null,
        /** True when the latest catalog of the owning repository no longer lists this extension. */
        val missingFromCatalog: Boolean = false,
        /** Provider metadata from the last successful load; lets a worker start lazily (ADR-0016). */
        val providerDescriptors: List<com.lagradost.macos.worker.ProviderDescriptor> = emptyList(),
        /** Host types the extension references that this engine lacks (RT-05), from the last translation. */
        val compatibility: com.lagradost.macos.CapabilityReport? = null,
        /** Extractors the extension registered at its last load; routes hosts to a stopped worker (RT-12). */
        val extractorDescriptors: List<com.lagradost.macos.worker.ExtractorDescriptor> = emptyList(),
        val verificationMode: ArtifactVerification = ArtifactVerification.legacy(tier),
        val publisherHash: String? = RepositoryService.normalizedHash(metadata.fileHash),
        val proofFormatVersion: Int = 1,
    )

    @Serializable
    data class PersistedRepository(
        val url: String,
        /** TOFU-pinned Ed25519 public key (base64) — null for community repositories. */
        val pinnedPublicKey: String? = null,
        val pinnedKeyFingerprint: String? = null,
        val signed: Boolean = false,
        val manifestJson: String? = null,
        val pluginListsJson: List<String> = emptyList(),
        /** Serialized SitePlugin list from the last successful sync (display only). */
        val pluginsJson: String? = null,
        val lastSyncedAt: Long = 0,
        /** Exact list bytes from the last successful sync; evidence for both trust tiers. */
        val authenticatedLists: List<AuthenticatedCatalogList> = emptyList(),
        /** Explicit user (or migration) consent required to install from a community catalog. */
        val consent: RepositoryConsent? = null,
        val lastAttemptAt: Long = 0,
        val lastError: String? = null,
        /** Repository discovered through an HTML aggregate page (display provenance only). */
        val discoveredVia: String? = null,
    ) {
        val tier: TrustTier get() = if (signed) TrustTier.VERIFIED else TrustTier.COMMUNITY
    }

    @Serializable
    data class LegacyArtifact(val artifactHash: String, val sizeBytes: Long)

    @Serializable
    data class ExtensionSettings(
        val autoUpdate: Boolean = false,
        /** Allows importing extensions from local files (plan D5). Off by default. */
        val developerMode: Boolean = false,
    )

    @Serializable
    data class PersistedState(
        val version: Int = SCHEMA_VERSION,
        val completedMigrations: Set<String> = emptySet(),
        val repos: List<PersistedRepository> = emptyList(),
        val disabledProviders: Set<String> = emptySet(),
        val providerOverrides: Map<String, ProviderOverride> = emptyMap(),
        /** Removal of a catalog does not erase key continuity or rollback protection. */
        val repositoryTrust: Map<String, RepositoryTrustAnchor> = emptyMap(),
        val installations: Map<String, InstalledExtension> = emptyMap(),
        /** Cached artifacts from pre-receipt versions that could not be matched to a catalog. */
        val unmatchedLegacyArtifacts: List<LegacyArtifact> = emptyList(),
        val extensionSettings: ExtensionSettings = ExtensionSettings(),
        /** Resolver, HTTP cache and retry policy (Offline-Features-Plan Phase 3). */
        val network: NetworkSettings = NetworkSettings(),
    )

    @Serializable
    data class NetworkSettings(
        /** [com.lagradost.macos.network.DohProvider.id]. */
        val dns: String = "system",
        val customDohUrl: String? = null,
        /** On-disk HTTP response cache; 0 disables it. */
        val httpCacheMb: Int = 50,
        /** One jittered retry for idempotent requests on transport errors. */
        val retryOnNetworkError: Boolean = true,
        /** Fetch GitHub-hosted repositories and extensions through jsDelivr (N2); off unless the user turns it on. */
        val githubMirror: Boolean = false,
    )

    val stateFile: File get() = File(CloudDirs.stateDir, "state.json")
    private val repository by lazy { StateRepository(stateFile) }
    val recoveryError: String? get() = repository.recoveryError
    fun requireHealthy() = repository.requireHealthy()
    fun load() = repository.load()
    fun snapshot(): PersistedState = repository.snapshot()
    fun update(transform: (PersistedState) -> PersistedState) = repository.update(transform)

    // Provider-level preferences are keyed by stable provider ID (installationId/name).

    fun isProviderEnabled(providerId: String): Boolean = recoveryError == null && providerId !in snapshot().disabledProviders

    fun setProviderEnabled(providerId: String, enabled: Boolean) {
        update { s ->
            s.copy(disabledProviders = if (enabled) s.disabledProviders - providerId else s.disabledProviders + providerId)
        }
    }

    fun overrideFor(providerId: String): ProviderOverride? = snapshot().providerOverrides[providerId]

    fun setProviderOverride(providerId: String, override: ProviderOverride?) {
        update { s ->
            s.copy(providerOverrides = if (override == null) s.providerOverrides - providerId else s.providerOverrides + (providerId to override))
        }
    }

    fun networkSettings(): NetworkSettings = snapshot().network

    fun setNetworkSettings(settings: NetworkSettings) {
        update { s -> s.copy(network = settings) }
    }
}
