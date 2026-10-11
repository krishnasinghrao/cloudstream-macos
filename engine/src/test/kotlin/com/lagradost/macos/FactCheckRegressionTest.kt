package com.lagradost.macos

import com.lagradost.cloudstream3.MainAPI
import com.lagradost.macos.models.DetailsDto
import kotlinx.coroutines.runBlocking
import java.io.File
import kotlin.test.*

/** Regressions for defects found while fact-checking the remediation (2026-09-30). */
class FactCheckRegressionTest {
    private val repo = SignedCatalogFixture("https://factcheck.invalid/repo.json")
    private val artifact = "fact check extension".toByteArray()

    @BeforeTest fun before() = ExtensionTestSupport.resetHome()
    @AfterTest fun after() { ExtensionTestSupport.resetHome(); ProviderOverrides.clearForTest(); DaemonRuntime.resetForTest() }

    private fun manager(runtime: FakeRuntime = FakeRuntime()) = ExtensionTestSupport.use(InstallationManager(runtime,
        RepositoryFetcher { url, _ -> RepositoryDocument(artifact, url) }))

    @Test fun `a missing launch-options line fails closed when the supervisor launched over stdin`() {
        val missing = LaunchOptions.parse(null, required = true)
        assertTrue(missing.safeMode)
        assertEquals(emptyList(), missing.policy.allowedRepositories)
        assertFalse(missing.policy.allowCommunityTier)
        // Development launches (env/argv) keep permissive defaults.
        assertEquals(LaunchOptions(), LaunchOptions.parse(null))
        assertEquals(LaunchOptions.FAIL_CLOSED, LaunchOptions.parse("{not json", required = true))
    }

    @Test fun `policy-pinned keys match URLs with the same normalization as allow lists`() {
        val policy = ExtensionPolicy(pinnedRepositoryKeys = mapOf(" https://example.invalid/a/../repo.json " to "KEY"))
        assertEquals("KEY", policy.pinnedKeyFor("https://example.invalid/repo.json"))
        assertNull(policy.pinnedKeyFor("https://example.invalid/other.json"))
    }

    @Test fun `credentials sent before an installed extension finishes loading are kept for its load`() = runBlocking<Unit> {
        repo.publish(mapOf("Ext" to artifact), revision = 1)
        val record = manager().install(repo.url, "Ext")
        val providerId = "${record.id}:Pending"
        val pending = assertNotNull(ProviderOverrides.configurePending(providerId, "secret", reset = false))
        assertFalse(pending.applied)
        assertNull(ProviderOverrides.configurePending("${"0".repeat(64)}:Pending", "secret", reset = false), "unknown installation")
        assertNull(ProviderOverrides.configurePending("Builtin", "secret", reset = false), "not an extension provider ID")

        val provider = object : MainAPI() { override var name = "Pending"; override var mainUrl = "https://default.invalid" }
        provider.sourcePlugin = record.id
        ProviderOverrides.apply(listOf(provider))
        assertEquals("secret", provider.storedCredentials)
    }

    @Test fun `configuring or toggling a built-in provider invalidates its cached responses`() {
        val provider = object : MainAPI() { override var name = "BuiltinCache"; override var mainUrl = "https://builtin.invalid" }
        ProviderExecutor.storeDetails(provider, "https://builtin.invalid/item", DetailsDto(provider = "BuiltinCache", url = "https://builtin.invalid/item", name = "cached", type = "Movie"))
        assertNotNull(ProviderExecutor.cachedDetails(provider, "https://builtin.invalid/item"))
        ProviderExecutor.invalidateProvider(PluginBridge.providerId(provider))
        assertNull(ProviderExecutor.cachedDetails(provider, "https://builtin.invalid/item"))
    }

    @Test fun `uninstall forgets cached preferences so a reinstall starts empty`() {
        val id = "a".repeat(64)
        val context = android.content.Context(ExtensionStorage.directory(id))
        context.getSharedPreferences("settings", 0).edit().putString("token", "old").commit()
        ExtensionStorage.delete(id)
        assertFalse(File(CloudDirs.extensionDataDir, id).exists())
        val again = android.content.Context(ExtensionStorage.directory(id))
        assertNull(again.getSharedPreferences("settings", 0).getString("token", null))
    }

    @Test fun `removing a repository with its extensions removes the repository before uninstalling`() = runBlocking<Unit> {
        repo.publish(mapOf("Ext" to artifact), revision = 1)
        val runtime = FakeRuntime()
        val manager = manager(runtime)
        val record = manager.install(repo.url, "Ext")
        assertTrue(manager.removeRepository(repo.url, removeInstallations = true))
        assertTrue(DaemonState.snapshot().repos.none { it.url == repo.url })
        assertNull(DaemonState.snapshot().installations[record.id])
        assertNull(runtime.generation(record.id))
        // An install racing with removal can no longer find the repository.
        assertEquals(ExtensionException.Code.UNKNOWN_REPOSITORY,
            assertFailsWith<ExtensionException> { manager.install(repo.url, "Ext") }.code)
    }

    @Test fun `background refresh syncs top-level repositories and applies automatic updates`() = runBlocking<Unit> {
        repo.publish(mapOf("Ext" to artifact), revision = 1, version = 1)
        val manager = manager()
        val record = manager.install(repo.url, "Ext")
        val newer = "fact check extension v2".toByteArray()
        val fetch = repo.publish(mapOf("Ext" to newer), revision = 2, version = 2)
        ExtensionTestSupport.use(InstallationManager(FakeRuntime(), fetch))
        DaemonState.update { it.copy(extensionSettings = it.extensionSettings.copy(autoUpdate = true)) }

        val synced = mutableListOf<String>()
        val result = assertNotNull(BackgroundRefresh.runOnce { synced += it })
        assertEquals(listOf(repo.url), synced)
        assertEquals(listOf("Ext"), result.updated)
        assertEquals(ArtifactDigest.sha256(newer), DaemonState.snapshot().installations[record.id]?.artifactHash)
        assertEquals(result.at, effectiveSettings().lastBackgroundRefresh?.at)

        DaemonRuntime.resetForTest(LaunchOptions(safeMode = true))
        assertNull(BackgroundRefresh.runOnce { error("must not sync in safe mode") })
        BackgroundRefresh.resetForTest()
    }

    @Test fun `network failures reach the user as plain language, not exception text`() {
        val host = ExtensionException.from(java.net.UnknownHostException("ld: nodename nor servname provided, or not known"))
        assertEquals("Couldn't find the server “ld”. Check the address and your internet connection.", host.message)
        assertEquals(ExtensionException.Code.DOWNLOAD_FAILED, host.code)
        assertEquals("The server took too long to respond.", ExtensionException.from(java.net.SocketTimeoutException("Read timed out")).message)
        assertFalse(ExtensionException.from(java.net.ConnectException("Connection refused (Connection refused)")).message!!.contains("refused"))
    }
}
