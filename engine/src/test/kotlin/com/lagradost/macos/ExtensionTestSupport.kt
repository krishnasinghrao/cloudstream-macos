package com.lagradost.macos

import kotlinx.coroutines.runBlocking
import java.io.File

/** Shared isolation for tests that touch the extension singletons. */
/** State with per-attempt bookkeeping removed: rejected syncs record their
 * failure for the UI but must not change trust, catalogs or installations. */
internal fun DaemonState.PersistedState.withoutAttempts() =
    copy(repos = repos.map { it.copy(lastAttemptAt = 0, lastError = null) })

internal object ExtensionTestSupport {
    /** Unloads every generation and resets the isolated data root. */
    fun resetHome() {
        PluginBridge.getAllLoadedDescriptors().forEach { PluginBridge.detach(it.installationId) }
        check(CloudDirs.home.path.contains("build")) { "Refusing to reset a non-test data root" }
        CloudDirs.home.deleteRecursively()
        CloudDirs.home.mkdirs()
        DaemonState.load()
        AuditLog.resetForTest()
        DaemonRuntime.resetForTest()
        ProviderOverrides.clearForTest()
        ProviderExecutor.invalidateCaches()
        RateLimiter.resetForTest()
        OperationHealth.clearForTest()
        RepositoryService.installations = RepositoryService.defaultInstallations()
    }

    /** Routes and sync hooks use [manager] until the next reset. */
    fun use(manager: InstallationManager): InstallationManager = manager.also { RepositoryService.installations = it }

    /**
     * The policy an organization sets to allow extensions outside the macOS
     * sandbox (`ExtensionsRequireSandbox = false`). Tests that run deliberately
     * unsandboxed worker processes opt out explicitly; the default fails closed.
     */
    fun allowUnsandboxedWorkers() = DaemonRuntime.resetForTest(LaunchOptions(ExtensionPolicy(requireSandbox = false)))

    fun extension(name: String): ByteArray =
        requireNotNull(ExtensionTestSupport::class.java.getResourceAsStream("/extensions/$name.cs3")) { "Missing fixture $name" }.readBytes()

    fun verifiedHashes(url: String): Set<String> {
        val state = DaemonState.snapshot()
        val repo = state.repos.singleOrNull { it.url == url } ?: return emptySet()
        val catalog = runCatching { CatalogTrust.restoreCatalog(repo, state.repositoryTrust[url], requireFresh = false) }.getOrNull()
        return if (catalog?.tier == DaemonState.TrustTier.VERIFIED) catalog.plugins.mapNotNull { RepositoryService.normalizedHash(it.fileHash) }.toSet() else emptySet()
    }

    fun removeRepository(url: String, removeInstallations: Boolean = false): Boolean =
        runBlocking { RepositoryService.installations.removeRepository(url, removeInstallations) }

    fun sourceFile(hash: String): File = ArtifactStore.source(hash)

    /** classes.dex bytes of a fixture archive. */
    fun dexOf(name: String): ByteArray = java.util.zip.ZipInputStream(extension(name).inputStream()).use { zip ->
        generateSequence { zip.nextEntry }.first { it.name == "classes.dex" }.let { zip.readBytes() }
    }
}

/** Runtime double: counts calls and can fail or block at each lifecycle step. */
internal class FakeRuntime : ExtensionRuntime {
    private val current = java.util.concurrent.ConcurrentHashMap<String, String>()
    var prepares = 0
    var publishes = 0
    var discards = 0
    var removes = 0
    @Volatile var onPrepare: (DaemonState.InstalledExtension) -> Unit = {}
    @Volatile var failPublish = false

    private class Prepared(val generation: String) : PreparedExtension {
        override val providerNames = listOf("FakeProvider")
        override val extractorCount = 0
        override val jarHashes = listOf("0".repeat(64))
        override val unsupportedFeatures = emptyList<String>()
        override val providerDescriptors = listOf(com.lagradost.macos.worker.ProviderDescriptor("FakeProvider", "https://fake.invalid"))
    }

    @Synchronized override fun prepare(record: DaemonState.InstalledExtension, artifact: java.io.File, reuseTranslation: Boolean): PreparedExtension {
        prepares++
        onPrepare(record)
        return Prepared(record.generation)
    }
    @Synchronized override fun publish(record: DaemonState.InstalledExtension, prepared: PreparedExtension): AutoCloseable? {
        if (failPublish) error("publish failure")
        publishes++
        val old = current.put(record.id, (prepared as Prepared).generation)
        return old?.let { AutoCloseable {} }
    }
    @Synchronized override fun discard(prepared: PreparedExtension) { discards++ }
    @Synchronized override fun remove(id: String): AutoCloseable? { removes++; return current.remove(id)?.let { AutoCloseable {} } }
    override fun isCurrent(record: DaemonState.InstalledExtension) = current[record.id] == record.generation
    fun generation(id: String) = current[id]
}
