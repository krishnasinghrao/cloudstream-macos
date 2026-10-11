package com.lagradost.macos

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

internal interface PreparedExtension {
    val providerNames: List<String>
    val extractorCount: Int
    val jarHashes: List<String>
    val unsupportedFeatures: List<String>
    val providerDescriptors: List<com.lagradost.macos.worker.ProviderDescriptor>
    /** Static host-compatibility evidence (RT-05), when assessed. */
    val compatibility: CapabilityReport? get() = null
    /** Extractors the extension registered (RT-12 routing). */
    val extractorDescriptors: List<com.lagradost.macos.worker.ExtractorDescriptor> get() = emptyList()
}

internal interface ExtensionRuntime {
    /** Loads plugin code without publishing any registration. */
    fun prepare(record: DaemonState.InstalledExtension, artifact: File, reuseTranslation: Boolean): PreparedExtension
    /** Publishes atomically; on failure the old generation must remain published.
     * Returns a handle that retires the replaced generation. */
    fun publish(record: DaemonState.InstalledExtension, prepared: PreparedExtension): AutoCloseable?
    fun discard(prepared: PreparedExtension)
    fun remove(id: String): AutoCloseable?
    /** True when exactly this record's generation is published. */
    fun isCurrent(record: DaemonState.InstalledExtension): Boolean
}

internal object BridgeExtensionRuntime : ExtensionRuntime {
    private class Prepared(val descriptor: PluginBridge.LoadedPlugin) : PreparedExtension {
        override val providerNames = descriptor.providers.map { it.name }
        override val extractorCount = descriptor.extractorCount
        override val jarHashes = descriptor.jarHashes
        override val unsupportedFeatures = descriptor.unsupportedFeatures
        override val providerDescriptors = descriptor.providers.map { with(com.lagradost.macos.worker.WorkerDescriptors) { it.descriptor() } }
        override val compatibility = descriptor.compatibility
        override val extractorDescriptors = descriptor.extractors.map { com.lagradost.macos.worker.WorkerDescriptors.extractor(it) }
    }
    override fun prepare(record: DaemonState.InstalledExtension, artifact: File, reuseTranslation: Boolean): PreparedExtension =
        Prepared(PluginBridge.prepare(record, artifact, reuseTranslation))
    override fun publish(record: DaemonState.InstalledExtension, prepared: PreparedExtension): AutoCloseable? =
        PluginBridge.publish((prepared as Prepared).descriptor)?.let { AutoCloseable { PluginBridge.retire(it) } }
    override fun discard(prepared: PreparedExtension) { PluginBridge.discard((prepared as Prepared).descriptor) }
    override fun remove(id: String): AutoCloseable? = PluginBridge.detach(id)?.let { AutoCloseable { PluginBridge.retire(it) } }
    override fun isCurrent(record: DaemonState.InstalledExtension): Boolean =
        PluginBridge.loadedInstallation(record.id)?.generation == record.generation
}

/**
 * The only authority for installing, updating, enabling and removing
 * extension code. Every operation on one installation is serialized (callers
 * wait; nothing is silently cancelled). Durable commit precedes publication and
 * the previous generation serves until both succeed.
 */
internal class InstallationManager(
    private val runtime: ExtensionRuntime,
    private val fetcher: RepositoryFetcher,
    private val proofs: InstallationProofStore = InstallationProofStore(),
) {
    private val locks = ConcurrentHashMap<String, Mutex>()
    private val background = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + Dispatchers.IO)

    /** Runtime hosting extension code (the worker runtime answers `/extract` for extension extractors). */
    val runtimeForExtract: ExtensionRuntime get() = runtime
    private val errors = ConcurrentHashMap<String, String>()

    @Volatile var restoreState: RestoreState = RestoreState()
        private set

    data class RestoreState(val phase: String = "idle", val restored: Int = 0, val failed: Int = 0, val quarantined: Int = 0)

    private fun read() = DaemonState.snapshot()
    private fun write(transform: (DaemonState.PersistedState) -> DaemonState.PersistedState) = DaemonState.update(transform)

    private suspend fun <T> withOperation(id: String, block: suspend () -> T): T =
        locks.computeIfAbsent(id) { Mutex() }.withLock { block() }

    fun lastError(id: String): String? = errors[id]
    fun isRunning(record: DaemonState.InstalledExtension) = runtime.isCurrent(record)

    private data class CatalogEntry(
        val repo: DaemonState.PersistedRepository,
        val tier: DaemonState.TrustTier,
        val plugin: RepositoryService.SitePlugin,
        val anchor: DaemonState.RepositoryTrustAnchor?,
    )

    private fun catalogEntry(state: DaemonState.PersistedState, repoUrl: String, internalName: String, requireFresh: Boolean): CatalogEntry {
        val repo = state.repos.singleOrNull { it.url == repoUrl }
            ?: throw ExtensionException(ExtensionException.Code.UNKNOWN_REPOSITORY, "This repository is not added.")
        DaemonRuntime.policy.requireRepository(repoUrl, userInitiated = false)
        val anchor = state.repositoryTrust[repoUrl]
        val catalog = try { CatalogTrust.restoreCatalog(repo, anchor, requireFresh) } catch (failure: SecurityException) {
            throw ExtensionException(ExtensionException.Code.STALE_CATALOG, "Sync this repository to obtain a current catalog.", failure)
        }
        DaemonRuntime.policy.requireTier(catalog.tier, repoUrl)
        if (DaemonRuntime.policy.needsConsent(catalog.tier, repoUrl) && repo.consent == null) {
            throw ExtensionException(ExtensionException.Code.CONSENT_REQUIRED, "Allow installs from this repository first.")
        }
        val plugin = catalog.plugins.singleOrNull { it.internalName == internalName }
            ?: throw ExtensionException(ExtensionException.Code.UNKNOWN_EXTENSION, "This repository does not list that extension.")
        return CatalogEntry(repo, catalog.tier, plugin, anchor)
    }

    // ------------------------------------------------------------------ install / update / rollback

    suspend fun install(repoUrl: String, internalName: String, requestedUrl: String = "", requestedHash: String? = null,
        allowDowngrade: Boolean = false, actor: String = "user"): DaemonState.InstalledExtension {
        val id = InstallationProofStore.installationId(repoUrl, internalName)
        return withOperation(id) { installLocked(id, repoUrl, internalName, requestedUrl, requestedHash, allowDowngrade, actor) }
    }

    suspend fun update(id: String, actor: String = "user"): DaemonState.InstalledExtension {
        val record = read().installations[id] ?: throw ExtensionException(ExtensionException.Code.UNKNOWN_EXTENSION, "Extension is not installed.")
        return install(record.repositoryUrl, record.internalName, actor = actor)
    }

    private suspend fun installLocked(id: String, repoUrl: String, internalName: String, requestedUrl: String,
        requestedHash: String?, allowDowngrade: Boolean, actor: String): DaemonState.InstalledExtension {
        requireHealthy()
        val initial = read()
        val entry = catalogEntry(initial, repoUrl, internalName, requireFresh = true)
        val plugin = entry.plugin
        if (!RepositoryService.isInstallable(plugin.status)) {
            throw ExtensionException(ExtensionException.Code.UNAVAILABLE, "The publisher has disabled this extension.")
        }
        if (plugin.url.isEmpty()) throw ExtensionException(ExtensionException.Code.UNAVAILABLE, RepositoryService.INSECURE_DOWNLOAD_REASON)
        if (requestedUrl.isNotBlank() && requestedUrl != plugin.url ||
            requestedHash != null && RepositoryService.normalizedHash(requestedHash) != RepositoryService.normalizedHash(plugin.fileHash)) {
            throw ExtensionException(ExtensionException.Code.STALE_CATALOG, "The catalog changed; refresh and try again.")
        }
        val declaredHash = RepositoryService.normalizedHash(plugin.fileHash)
        if (!plugin.fileHash.isNullOrBlank() && declaredHash == null) throw ExtensionException(ExtensionException.Code.UNTRUSTED, "The publisher provided an invalid SHA-256 digest.")
        val mode = if (declaredHash == null && entry.tier == DaemonState.TrustTier.COMMUNITY)
            DaemonState.ArtifactVerification.LOCAL_OBSERVATION else DaemonState.ArtifactVerification.legacy(entry.tier)
        DaemonRuntime.policy.requireVerification(mode)
        val old = initial.installations[id]
        if (old != null && !allowDowngrade && plugin.version >= 0 && old.metadata.version >= 0 && plugin.version < old.metadata.version) {
            throw ExtensionException(ExtensionException.Code.DOWNGRADE, "The catalog offers an older version than the one installed.")
        }
        if (old != null && declaredHash != null && old.artifactHash == declaredHash && old.tier == entry.tier && old.metadata == plugin &&
            runCatching { proofs.verify(old, entry.anchor) }.isSuccess) {
            // Same version already committed: make sure it runs instead of returning a dead receipt.
            if (old.enabled && old.revokedReason == null && !runtime.isCurrent(old)) restoreBlocking(id, clearQuarantine = true)
            return read().installations[id] ?: old
        }
        val downloaded = try { RepositoryService.fetchArtifact(plugin, fetcher, mode == DaemonState.ArtifactVerification.LOCAL_OBSERVATION) } catch (failure: SecurityException) {
            throw ExtensionException(ExtensionException.Code.UNTRUSTED, failure.message ?: "Artifact verification failed", failure)
        }
        currentCoroutineContext().ensureActive()
        val hash = downloaded.hash
        val artifact = downloaded.file
        // RT-08: without a publisher digest the catalog cannot say whether the
        // bytes changed, so an update or recheck downloads and compares. The
        // same bytes under the same entry keep the committed generation.
        if (old != null && mode == DaemonState.ArtifactVerification.LOCAL_OBSERVATION && old.artifactHash == hash &&
            old.metadata == plugin && old.tier == entry.tier && old.verificationMode == mode &&
            runCatching { proofs.verify(old, entry.anchor) }.isSuccess) {
            AuditLog.record("extension.recheck", mapOf("installation" to id, "sha256" to hash, "changed" to false), actor)
            if (old.enabled && old.revokedReason == null && !runtime.isCurrent(old)) restoreBlocking(id, clearQuarantine = true)
            return read().installations[id] ?: old
        }
        val observation = if (mode == DaemonState.ArtifactVerification.LOCAL_OBSERVATION)
            InstallationProofStore.ArtifactObservation(internalName, plugin.url, downloaded.effectiveUrl, hash, System.currentTimeMillis()) else null
        val proofHash = proofs.put(entry.repo, entry.anchor, observation)
        val candidate = DaemonState.InstalledExtension(id, repoUrl, internalName, hash, UUID.randomUUID().toString(),
            proofHash, System.currentTimeMillis(), plugin, enabled = old?.enabled ?: true, tier = entry.tier,
            verificationMode = mode, publisherHash = declaredHash, proofFormatVersion = 2,
            previous = if (old != null && old.artifactHash != hash) old.asPrevious() else old?.previous)
        proofs.verify(candidate, entry.anchor)
        val prepared = prepareOrThrow(candidate, artifact, reuseTranslation = false)
        val complete = candidate.copy(providerNames = prepared.providerNames, extractorCount = prepared.extractorCount,
            jarHashes = prepared.jarHashes, providerDescriptors = prepared.providerDescriptors,
            compatibility = prepared.compatibility ?: candidate.compatibility, extractorDescriptors = prepared.extractorDescriptors)
        commitAndPublish(id, old, complete, prepared) { latest ->
            latest.repos.singleOrNull { it.url == repoUrl } == entry.repo && latest.repositoryTrust[repoUrl] == entry.anchor
        }
        AuditLog.record(if (old == null) "extension.install" else "extension.update", mapOf("installation" to id,
            "repository" to repoUrl, "extension" to internalName, "version" to plugin.version, "sha256" to hash,
            "tier" to entry.tier, "previous" to old?.artifactHash), actor)
        collectGarbage()
        return complete
    }

    /**
     * Developer mode (plan D5): imports a local `.cs3`. A new import is never
     * enabled automatically; re-importing an existing one replaces its version
     * and keeps its enabled state. Blocked by policy and by allow-lists.
     */
    suspend fun installDeveloper(bytes: ByteArray, fileName: String, actor: String = "user"): DaemonState.InstalledExtension {
        requireHealthy()
        if (!read().extensionSettings.developerMode) {
            throw ExtensionException(ExtensionException.Code.POLICY_DENIED, "Turn on developer mode to install extensions from files.")
        }
        DaemonRuntime.policy.requireRepository(DaemonState.DEVELOPER_SOURCE, userInitiated = false)
        DaemonRuntime.policy.requireTier(DaemonState.TrustTier.DEVELOPER)
        require(bytes.isNotEmpty() && bytes.size <= RepositoryTransport.MAX_ARTIFACT_BYTES) { "The file is empty or larger than 32 MiB." }
        val internalName = fileName.substringAfterLast('/').removeSuffix(".cs3")
        require(internalName.matches(Regex("[A-Za-z0-9._-]{1,128}")) && !internalName.startsWith(".")) {
            "Use a file name made of letters, digits, dots, dashes or underscores."
        }
        val id = InstallationProofStore.installationId(DaemonState.DEVELOPER_SOURCE, internalName)
        return withOperation(id) {
            val old = read().installations[id]
            val hash = ArtifactDigest.sha256(bytes)
            val artifact = ArtifactStore.source(hash)
            AtomicFiles.write(artifact.toPath(), bytes)
            val metadata = RepositoryService.SitePlugin(url = "", status = 1, version = -1, name = internalName,
                internalName = internalName, repositoryUrl = DaemonState.DEVELOPER_SOURCE, fileSize = bytes.size.toLong(), fileHash = hash)
            val candidate = DaemonState.InstalledExtension(id, DaemonState.DEVELOPER_SOURCE, internalName, hash, UUID.randomUUID().toString(),
                proofs.putDeveloper(hash), System.currentTimeMillis(), metadata, enabled = old?.enabled ?: false,
                tier = DaemonState.TrustTier.DEVELOPER, verificationMode = DaemonState.ArtifactVerification.DEVELOPER_IMPORT,
                publisherHash = hash, proofFormatVersion = 2, previous = if (old != null && old.artifactHash != hash) old.asPrevious() else old?.previous)
            proofs.verify(candidate, null)
            val prepared = prepareOrThrow(candidate, artifact, reuseTranslation = false)
            val complete = candidate.copy(providerNames = prepared.providerNames, extractorCount = prepared.extractorCount,
                jarHashes = prepared.jarHashes, providerDescriptors = prepared.providerDescriptors,
            compatibility = prepared.compatibility ?: candidate.compatibility, extractorDescriptors = prepared.extractorDescriptors)
            commitAndPublish(id, old, complete, prepared) { true }
            AuditLog.record("extension.developer_install", mapOf("installation" to id, "extension" to internalName,
                "sha256" to hash, "previous" to old?.artifactHash), actor)
            collectGarbage()
            complete
        }
    }

    suspend fun rollback(id: String, actor: String = "user"): DaemonState.InstalledExtension = withOperation(id) {
        requireHealthy()
        val old = read().installations[id] ?: throw ExtensionException(ExtensionException.Code.UNKNOWN_EXTENSION, "Extension is not installed.")
        val previous = old.previous ?: throw ExtensionException(ExtensionException.Code.NO_PREVIOUS_VERSION, "No earlier version is available.")
        val candidate = old.copy(artifactHash = previous.artifactHash, generation = UUID.randomUUID().toString(),
            proofHash = previous.proofHash, installedAt = System.currentTimeMillis(), metadata = previous.metadata,
            providerNames = previous.providerNames, extractorCount = previous.extractorCount, tier = previous.tier,
            jarHashes = previous.jarHashes, providerDescriptors = previous.providerDescriptors,
            extractorDescriptors = previous.extractorDescriptors,
            verificationMode = previous.verificationMode, publisherHash = previous.publisherHash, proofFormatVersion = previous.proofFormatVersion,
            previous = old.asPrevious(), revokedReason = null, quarantinedReason = null)
        val anchor = read().repositoryTrust[old.repositoryUrl]
        try { proofs.verify(candidate, anchor) } catch (failure: Exception) {
            throw ExtensionException(ExtensionException.Code.UNTRUSTED, "The earlier version is no longer trusted.", failure)
        }
        val prepared = prepareOrThrow(candidate, ArtifactStore.source(candidate.artifactHash), reuseTranslation = true)
        val complete = candidate.copy(providerNames = prepared.providerNames, extractorCount = prepared.extractorCount,
            jarHashes = prepared.jarHashes, providerDescriptors = prepared.providerDescriptors,
            compatibility = prepared.compatibility ?: candidate.compatibility, extractorDescriptors = prepared.extractorDescriptors)
        commitAndPublish(id, old, complete, prepared) { latest -> latest.repositoryTrust[old.repositoryUrl] == anchor }
        AuditLog.record("extension.rollback", mapOf("installation" to id, "sha256" to complete.artifactHash, "from" to old.artifactHash), actor)
        complete
    }

    private fun prepareOrThrow(candidate: DaemonState.InstalledExtension, artifact: File, reuseTranslation: Boolean): PreparedExtension =
        try { runtime.prepare(candidate, artifact, reuseTranslation) } catch (failure: Throwable) {
            if (failure is kotlinx.coroutines.CancellationException) throw failure
            if (failure is VirtualMachineError && failure !is StackOverflowError) throw failure
            val mapped = ExtensionException.from(failure)
            throw if (mapped.code == ExtensionException.Code.UNSUPPORTED) mapped else
                ExtensionException(ExtensionException.Code.LOAD_FAILED, "The extension failed to start: ${failure.message ?: failure.javaClass.simpleName}", failure)
        }

    /** Durable commit, then publication; the prior generation serves until both succeed. */
    private suspend fun commitAndPublish(id: String, old: DaemonState.InstalledExtension?, complete: DaemonState.InstalledExtension,
        prepared: PreparedExtension, stillValid: (DaemonState.PersistedState) -> Boolean) {
        var published = false
        var retired: AutoCloseable? = null
        try {
            currentCoroutineContext().ensureActive()
            ExtensionLifecycle.locked {
                requireHealthy()
                val latest = read()
                if (latest.installations[id] != old || !stillValid(latest)) {
                    throw ExtensionException(ExtensionException.Code.CONFLICT, "The repository or extension changed during the operation; try again.")
                }
                write { it.copy(installations = it.installations + (id to complete)) }
                try {
                    retired = if (complete.enabled && complete.revokedReason == null && !DaemonRuntime.safeMode) {
                        runtime.publish(complete, prepared).also { published = true }
                    } else runtime.remove(id)
                } catch (failure: Throwable) {
                    // The state store itself enters recovery if this rollback cannot commit.
                    write { state -> state.copy(installations = if (old == null) state.installations - id else state.installations + (id to old)) }
                    throw ExtensionException.from(failure)
                }
            }
            errors.remove(id)
        } finally {
            if (!published) runCatching { runtime.discard(prepared) }
            retired?.let { runCatching { it.close() } }
        }
    }

    // ------------------------------------------------------------------ enable / disable / retry / uninstall

    suspend fun setEnabled(id: String, enabled: Boolean, actor: String = "user"): Boolean = withOperation(id) {
        requireHealthy()
        val old = read().installations[id] ?: throw ExtensionException(ExtensionException.Code.UNKNOWN_EXTENSION, "Extension is not installed.")
        if (old.enabled == enabled && (!enabled || runtime.isCurrent(old))) return@withOperation true
        if (old.enabled != enabled) {
            write { it.copy(installations = it.installations + (id to old.copy(enabled = enabled))) }
            AuditLog.record(if (enabled) "extension.enable" else "extension.disable", mapOf("installation" to id), actor)
        }
        if (!enabled) {
            ExtensionLifecycle.locked { runtime.remove(id) }?.let { runCatching { it.close() } }
            errors.remove(id)
            true
        } else restoreBlocking(id, clearQuarantine = false)
    }

    /** Explicit user retry: clears quarantine and loads the committed generation. */
    suspend fun retry(id: String, actor: String = "user"): Boolean = withOperation(id) {
        requireHealthy()
        if (read().installations[id] == null) throw ExtensionException(ExtensionException.Code.UNKNOWN_EXTENSION, "Extension is not installed.")
        AuditLog.record("extension.retry", mapOf("installation" to id), actor)
        restoreBlocking(id, clearQuarantine = true)
    }

    suspend fun uninstall(id: String, removeData: Boolean = true, actor: String = "user"): Boolean = withOperation(id) {
        requireHealthy()
        var removed: DaemonState.InstalledExtension? = null
        val retired = ExtensionLifecycle.locked {
            val record = read().installations[id] ?: return@locked null
            removed = record
            write { it.copy(installations = it.installations - id) }
            runtime.remove(id)
        }
        retired?.let { runCatching { it.close() } }
        val record = removed ?: return@withOperation false
        errors.remove(id)
        if (removeData) ExtensionStorage.delete(id)
        AuditLog.record("extension.uninstall", mapOf("installation" to id, "repository" to record.repositoryUrl,
            "extension" to record.internalName, "sha256" to record.artifactHash), actor)
        collectGarbage()
        true
    }

    suspend fun removeRepository(url: String, removeInstallations: Boolean, actor: String = "user"): Boolean {
        requireHealthy()
        val state = read()
        if (state.repos.none { it.url == url }) return false
        // Remove the repository first: an install racing with removal then fails
        // its commit check, so no extension from this repository survives the
        // uninstall pass below.
        ExtensionLifecycle.locked { write { it.copy(repos = it.repos.filter { repo -> repo.url != url }) } }
        if (removeInstallations) {
            read().installations.values.filter { it.repositoryUrl == url }.map { it.id }.sorted().forEach { uninstall(it, actor = actor) }
        }
        AuditLog.record("repository.remove", mapOf("repository" to url, "removedExtensions" to removeInstallations), actor)
        return true
    }

    // ------------------------------------------------------------------ restore / startup

    suspend fun restore(id: String): Boolean = withOperation(id) { restoreBlocking(id, clearQuarantine = false) }

    /** Loads a committed generation. Blocking (plugin code runs); callers hold the operation lock. */
    private fun restoreBlocking(id: String, clearQuarantine: Boolean): Boolean {
        var record = read().installations[id] ?: return false
        if (clearQuarantine && record.quarantinedReason != null) {
            val cleared = record.copy(quarantinedReason = null)
            write { it.copy(installations = it.installations + (id to cleared)) }
            record = cleared
        }
        if (!record.enabled) return false
        if (DaemonRuntime.safeMode) { errors[id] = "Safe mode is on; extensions are not loaded."; return false }
        record.revokedReason?.let { errors[id] = it; return false }
        record.quarantinedReason?.let { errors[id] = it; return false }
        if (runtime.isCurrent(record)) { errors.remove(id); return true }
        var marked = false
        return try {
            DaemonRuntime.policy.requireRepository(record.repositoryUrl, userInitiated = false)
            DaemonRuntime.policy.requireTier(record.tier)
            val anchor = read().repositoryTrust[record.repositoryUrl]
            proofs.verify(record, anchor)
            LoadingMarkers.begin(record); marked = true
            val prepared = runtime.prepare(record, ArtifactStore.source(record.artifactHash), reuseTranslation = true)
            var published = false
            try {
                val retired = ExtensionLifecycle.locked {
                    val latest = read()
                    check(latest.installations[id] == record) { "Installation changed while loading" }
                    proofs.verify(record, latest.repositoryTrust[record.repositoryUrl])
                    val r = runtime.publish(record, prepared)
                    published = true
                    if (prepared.jarHashes != record.jarHashes || prepared.providerNames != record.providerNames ||
                        prepared.extractorCount != record.extractorCount || prepared.providerDescriptors != record.providerDescriptors ||
                        prepared.extractorDescriptors != record.extractorDescriptors ||
                        (prepared.compatibility != null && prepared.compatibility != record.compatibility)) {
                        write { it.copy(installations = it.installations + (id to record.copy(jarHashes = prepared.jarHashes,
                            providerNames = prepared.providerNames, extractorCount = prepared.extractorCount,
                            providerDescriptors = prepared.providerDescriptors,
                            compatibility = prepared.compatibility ?: record.compatibility,
                            extractorDescriptors = prepared.extractorDescriptors))) }
                    }
                    r
                }
                retired?.let { runCatching { it.close() } }
            } finally {
                if (!published) runCatching { runtime.discard(prepared) }
            }
            errors.remove(id)
            true
        } catch (failure: Throwable) {
            if (failure is VirtualMachineError && failure !is StackOverflowError) throw failure
            val message = when (failure) {
                is InterruptedException, is kotlinx.coroutines.CancellationException -> "The extension took too long to start."
                is PluginBridge.UnsupportedExtensionException, is PolicyException -> failure.message.orEmpty()
                is SecurityException -> "Trust for this extension could not be verified: ${failure.message}"
                else -> "The extension failed to start: ${failure.message ?: failure.javaClass.simpleName}"
            }
            errors[id] = message
            DaemonLog.warn("installation.restore_failed", mapOf("installation" to id, "error" to failure.javaClass.simpleName))
            false
        } finally {
            if (marked) runCatching { LoadingMarkers.end(record) }
        }
    }

    /** Startup: quarantine generations that crashed the engine while loading,
     * then restore enabled receipts in the background with bounded parallelism. */
    suspend fun restoreAll(parallelism: Int = 4, perExtensionTimeoutMs: Long = 20_000): RestoreState {
        if (DaemonState.recoveryError != null) return RestoreState("recovery").also { restoreState = it }
        restoreState = RestoreState("restoring")
        var quarantined = 0
        LoadingMarkers.leftovers().forEach { (id, generation) ->
            val record = read().installations[id]
            if (record != null && record.generation == generation && record.quarantinedReason == null) {
                write { it.copy(installations = it.installations + (id to record.copy(
                    quarantinedReason = "The engine stopped while this extension was loading. Retry to load it again."))) }
                AuditLog.record("extension.quarantine", mapOf("installation" to id, "generation" to generation), "system")
                quarantined++
            }
        }
        LoadingMarkers.clearAll()
        if (DaemonRuntime.safeMode) return RestoreState("safe_mode", quarantined = quarantined).also { restoreState = it }
        val targets = read().installations.values.filter { it.enabled && it.revokedReason == null && it.quarantinedReason == null }
        val gate = Semaphore(parallelism.coerceAtLeast(1))
        val results = coroutineScope {
            targets.map { record ->
                async(Dispatchers.IO) {
                    gate.withPermit {
                        withOperation(record.id) {
                            withTimeoutOrNull(perExtensionTimeoutMs) {
                                runInterruptible(Dispatchers.IO) { restoreBlocking(record.id, clearQuarantine = false) }
                            } ?: false.also { errors[record.id] = "The extension took too long to start." }
                        }
                    }
                }
            }.awaitAll()
        }
        return RestoreState("ready", results.count { it }, results.count { !it }, quarantined).also { restoreState = it }
    }

    // ------------------------------------------------------------------ reconciliation after sync

    /** Applies a freshly synced catalog to installations from that repository:
     * publisher revocation (status 0) and its reversal, catalog omission, and
     * re-issuing evidence when the same artifact is re-published (including
     * after an explicit key rotation). */
    suspend fun reconcile(repoUrl: String, actor: String = "system") {
        val state = read()
        val repo = state.repos.singleOrNull { it.url == repoUrl } ?: return
        val anchor = state.repositoryTrust[repoUrl]
        val catalog = runCatching { CatalogTrust.restoreCatalog(repo, anchor, requireFresh = false) }.getOrNull() ?: return
        for (id in state.installations.values.filter { it.repositoryUrl == repoUrl }.map { it.id }) {
            withOperation(id) {
                val current = read().installations[id] ?: return@withOperation
                val entry = catalog.plugins.firstOrNull { it.internalName == current.internalName }
                var next = current.copy(missingFromCatalog = entry == null)
                val proofValid = runCatching { proofs.verify(current, anchor) }.isSuccess
                val sameArtifact = entry != null && RepositoryService.normalizedHash(entry.fileHash) == current.artifactHash &&
                    catalog.tier == current.tier
                if (entry != null && sameArtifact && (!proofValid || entry != current.metadata) &&
                    (catalog.tier == DaemonState.TrustTier.VERIFIED || repo.consent != null)) {
                    runCatching { next = next.copy(proofHash = proofs.put(repo, anchor), metadata = entry, proofFormatVersion = 2) }
                }
                val trusted = sameArtifact || proofValid
                val reason = when {
                    entry != null && entry.status == 0 -> REVOKED_BY_PUBLISHER
                    !trusted -> REVOKED_KEY_CHANGED
                    else -> null
                }
                val managedReason = current.revokedReason in setOf(REVOKED_BY_PUBLISHER, REVOKED_KEY_CHANGED, null)
                if (managedReason) next = next.copy(revokedReason = reason)
                if (next.revokedReason != null && runtime.isCurrent(next)) {
                    // Enforce even when the revocation was recorded earlier (e.g. before a restart).
                    ExtensionLifecycle.locked { runtime.remove(id) }?.let { runCatching { it.close() } }
                }
                if (next == current) return@withOperation
                write { it.copy(installations = it.installations + (id to next)) }
                if (next.revokedReason != null && current.revokedReason == null) {
                    ExtensionLifecycle.locked { runtime.remove(id) }?.let { runCatching { it.close() } }
                    errors[id] = next.revokedReason
                    AuditLog.record("extension.revoke", mapOf("installation" to id, "reason" to next.revokedReason), actor)
                } else if (next.revokedReason == null && current.revokedReason != null) {
                    AuditLog.record("extension.unrevoke", mapOf("installation" to id), actor)
                    restoreBlocking(id, clearQuarantine = false)
                } else if (next.proofHash != current.proofHash && next.enabled && next.revokedReason == null && !runtime.isCurrent(next)) {
                    restoreBlocking(id, clearQuarantine = false)
                }
            }
        }
    }

    /** Update candidates for installations from [repoUrl] (or all repositories). */
    fun availableUpdates(repoUrl: String? = null): List<DaemonState.InstalledExtension> {
        val state = read()
        val catalogs = RepositoryService.CatalogCache(state)
        return state.installations.values.filter { repoUrl == null || it.repositoryUrl == repoUrl }.filter { record ->
            val entry = catalogs.entry(record.repositoryUrl, record.internalName) ?: return@filter false
            UpdatePolicy.evaluate(record, entry) == UpdatePolicy.State.UPDATE
        }
    }

    data class UpdateResult(val installationId: String, val name: String, val error: String?)

    /**
     * Applies available updates. Automatic runs are conservative for hashless
     * entries (RT-08): only a higher catalog version is applied; an
     * always-update (-1) or republished entry stays offered to the user.
     */
    suspend fun updateAll(repoUrl: String? = null, actor: String = "user"): List<UpdateResult> =
        availableUpdates(repoUrl).filter { record -> actor != AUTO_UPDATE_ACTOR || automaticallyUpdatable(record) }.map { record ->
            try { update(record.id, actor); UpdateResult(record.id, record.metadata.name, null) } catch (failure: Exception) {
                if (failure is kotlinx.coroutines.CancellationException) throw failure
                UpdateResult(record.id, record.metadata.name, ExtensionException.from(failure).message)
            }
        }

    private fun automaticallyUpdatable(record: DaemonState.InstalledExtension): Boolean {
        val entry = RepositoryService.CatalogCache(read()).entry(record.repositoryUrl, record.internalName) ?: return false
        if (RepositoryService.normalizedHash(entry.fileHash) != null) return true
        return entry.version >= 0 && record.metadata.version >= 0 && entry.version > record.metadata.version
    }

    // ------------------------------------------------------------------ migration & storage

    /** Pre-receipt versions executed any cached artifact. Record those
     * artifacts once, then adopt each one that exactly one saved catalog lists
     * (consent is recorded as a migration for the repository it came from). */
    suspend fun migrateLegacyArtifacts() {
        if (DaemonState.recoveryError != null) return
        val initial = read()
        if (LEGACY_MIGRATION !in initial.completedMigrations) {
            val owned = initial.installations.values.flatMap { listOfNotNull(it.artifactHash, it.previous?.artifactHash) }.toSet()
            val pending = ArtifactStore.storedSources().filterKeys { it !in owned }.map { (hash, size) -> DaemonState.LegacyArtifact(hash, size) }
            write { it.copy(completedMigrations = it.completedMigrations + LEGACY_MIGRATION, unmatchedLegacyArtifacts = pending) }
        }
        for (artifact in read().unmatchedLegacyArtifacts) {
            val state = read()
            val matches = state.repos.flatMap { repo ->
                val catalog = runCatching { CatalogTrust.restoreCatalog(repo, state.repositoryTrust[repo.url], requireFresh = true) }.getOrNull()
                    ?: return@flatMap emptyList()
                if (!runCatching { DaemonRuntime.policy.requireRepository(repo.url, false); DaemonRuntime.policy.requireTier(catalog.tier, repo.url) }.isSuccess) {
                    return@flatMap emptyList()
                }
                catalog.plugins.filter { RepositoryService.normalizedHash(it.fileHash) == artifact.artifactHash && RepositoryService.isInstallable(it.status) }
                    .map { Triple(repo, catalog.tier, it) }
            }
            val (repo, tier, plugin) = matches.singleOrNull() ?: continue
            val id = InstallationProofStore.installationId(repo.url, plugin.internalName)
            withOperation(id) {
                val latest = read()
                if (latest.installations.containsKey(id)) {
                    write { s -> s.copy(unmatchedLegacyArtifacts = s.unmatchedLegacyArtifacts - artifact) }
                    return@withOperation
                }
                val source = ArtifactStore.source(artifact.artifactHash)
                if (!source.isFile || ArtifactDigest.sha256(source) != artifact.artifactHash) {
                    write { s -> s.copy(unmatchedLegacyArtifacts = s.unmatchedLegacyArtifacts - artifact) }
                    return@withOperation
                }
                val consented = if (tier == DaemonState.TrustTier.COMMUNITY && repo.consent == null)
                    repo.copy(consent = DaemonState.RepositoryConsent(System.currentTimeMillis(), "migration")) else repo
                val proofHash = runCatching { proofs.put(consented, latest.repositoryTrust[repo.url]) }.getOrNull() ?: return@withOperation
                val record = DaemonState.InstalledExtension(id, repo.url, plugin.internalName, artifact.artifactHash,
                    UUID.randomUUID().toString(), proofHash, System.currentTimeMillis(), plugin, tier = tier)
                write { s -> s.copy(
                    repos = s.repos.map { if (it.url == repo.url) it.copy(consent = it.consent ?: consented.consent) else it },
                    installations = s.installations + (id to record),
                    unmatchedLegacyArtifacts = s.unmatchedLegacyArtifacts - artifact) }
                AuditLog.record("extension.migrate", mapOf("installation" to id, "repository" to repo.url, "sha256" to artifact.artifactHash), "system")
                restoreBlocking(id, clearQuarantine = false)
            }
        }
    }

    /** User chose not to restore the remaining legacy artifacts. */
    fun dismissLegacyArtifacts() {
        write { it.copy(unmatchedLegacyArtifacts = emptyList()) }
        collectGarbage()
    }

    /** A worker produced new translation digests for the current generation; record them for cache reuse.
     * Asynchronous: the restore that started the worker may still hold this installation's lock. */
    fun recordTranslation(id: String, generation: String, jarHashes: List<String>) {
        if (jarHashes.any { RepositoryService.normalizedHash(it) != it }) return
        background.launch {
            withOperation(id) {
                val record = read().installations[id]?.takeIf { it.generation == generation && it.jarHashes != jarHashes } ?: return@withOperation
                write { it.copy(installations = it.installations + (id to record.copy(jarHashes = jarHashes))) }
            }
        }
    }

    /** A worker start reassessed host compatibility (e.g. after a runtime profile upgrade): keep the receipt current. */
    fun recordAssessment(id: String, generation: String, report: CapabilityReport) {
        background.launch {
            withOperation(id) {
                val record = read().installations[id]?.takeIf { it.generation == generation && it.compatibility != report } ?: return@withOperation
                write { it.copy(installations = it.installations + (id to record.copy(compatibility = report))) }
            }
        }
    }

    /** Developer mode changed: stop running developer extensions, or load the enabled ones again. */
    suspend fun applyDeveloperMode() {
        val on = read().extensionSettings.developerMode
        for (record in read().installations.values.filter { it.tier == DaemonState.TrustTier.DEVELOPER }) {
            withOperation(record.id) {
                if (on) {
                    if (record.enabled) restoreBlocking(record.id, clearQuarantine = false)
                } else {
                    ExtensionLifecycle.locked { runtime.remove(record.id) }?.let { runCatching { it.close() } }
                    errors[record.id] = "Developer mode is off; local extensions do not load."
                }
            }
        }
    }

    /** Crash budget exceeded (worker runtime): stop loading this generation until the user retries. */
    suspend fun quarantineSync(id: String, reason: String) = withOperation(id) {
        val record = read().installations[id] ?: return@withOperation
        if (record.quarantinedReason != null) return@withOperation
        write { it.copy(installations = it.installations + (id to record.copy(quarantinedReason = reason))) }
        ExtensionLifecycle.locked { runtime.remove(id) }?.let { runCatching { it.close() } }
        errors[id] = reason
        AuditLog.record("extension.quarantine", mapOf("installation" to id, "generation" to record.generation, "reason" to "crash budget"), "system")
    }

    fun quarantine(id: String, reason: String) {
        background.launch { quarantineSync(id, reason) }
    }

    fun collectGarbage() {
        if (DaemonState.recoveryError != null) return
        // Worker homes of extensions that are no longer installed.
        val installed = read().installations.keys
        File(CloudDirs.home, "workers").listFiles()?.filter { it.isDirectory && it.name !in installed }?.forEach { it.deleteRecursively() }
        try {
            val collected = ArtifactStore.collect(read(), proofs)
            if (collected != ArtifactStore.Collected(0, 0, 0)) DaemonLog.info("artifacts.collected", mapOf(
                "sources" to collected.sources, "translations" to collected.translations, "proofs" to collected.proofs))
        } catch (failure: Exception) {
            DaemonLog.warn("artifacts.collect_failed", mapOf("error" to failure.javaClass.simpleName))
        }
    }

    private fun requireHealthy() {
        DaemonState.recoveryError?.let { throw ExtensionException(ExtensionException.Code.RECOVERY_REQUIRED, it) }
    }

    private fun DaemonState.InstalledExtension.asPrevious() = DaemonState.PreviousGeneration(artifactHash, generation,
        proofHash, metadata, tier, jarHashes, providerNames, extractorCount, providerDescriptors, verificationMode, publisherHash, proofFormatVersion,
        extractorDescriptors)

    companion object {
        const val REVOKED_BY_PUBLISHER = "The publisher disabled this extension."
        const val REVOKED_KEY_CHANGED = "The repository's signing key changed and this version is no longer listed. Update or uninstall it."
        const val LEGACY_MIGRATION = "cache-to-receipts-v1"
        /** Actor of updates the engine applies on its own. */
        const val AUTO_UPDATE_ACTOR = "auto-update"
    }
}

/** Android-compatible update semantics (version, -1 = always update) plus digest changes. */
object UpdatePolicy {
    enum class State { NONE, UPDATE, OLDER_IN_CATALOG }

    fun evaluate(installed: DaemonState.InstalledExtension, entry: RepositoryService.SitePlugin): State {
        val hash = RepositoryService.normalizedHash(entry.fileHash)
        // Absent digest: Android-compatible, version-based. Present but malformed: never
        // installable (Android verifies any fileHash it is given), so never offer it.
        if (hash == null && !entry.fileHash.isNullOrBlank()) return State.NONE
        if (hash != null && hash == installed.artifactHash) return State.NONE
        if (hash == null && entry == installed.metadata && entry.version != -1) return State.NONE
        if (!RepositoryService.isInstallable(entry.status)) return State.NONE
        val available = entry.version
        val current = installed.metadata.version
        return when {
            available == -1 || current == -1 -> State.UPDATE
            available > current -> State.UPDATE
            available == current -> State.UPDATE // same version republished with different bytes
            else -> State.OLDER_IN_CATALOG
        }
    }
}
