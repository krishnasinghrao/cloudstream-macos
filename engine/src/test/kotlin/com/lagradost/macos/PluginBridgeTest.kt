package com.lagradost.macos

import kotlinx.coroutines.runBlocking
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.test.*

/**
 * Loader tests through the real pipeline: DEX produced by Android's d8
 * (src/test/fixtures/extension) → dex2jar → VerifiedClassLoader → staged
 * registration → publication. No community code is executed.
 */
class PluginBridgeTest {
    private val fixture = SignedCatalogFixture("https://loader-fixture.invalid/repo.json")

    @BeforeTest fun before() = ExtensionTestSupport.resetHome()
    @AfterTest fun after() = ExtensionTestSupport.resetHome()

    private suspend fun install(name: String, bytes: ByteArray, revision: Long = 1): Pair<InstallationManager, DaemonState.InstalledExtension> {
        val fetcher = fixture.publish(mapOf(name to bytes), revision)
        val manager = InstallationManager(BridgeExtensionRuntime, fetcher)
        return manager to manager.install(fixture.url, name)
    }

    private fun zip(entries: Map<String, ByteArray>): ByteArray = ByteArrayOutputStream().also { out ->
        ZipOutputStream(out).use { zip -> entries.forEach { (name, body) -> zip.putNextEntry(ZipEntry(name)); zip.write(body); zip.closeEntry() } }
    }.toByteArray()

    @Test fun `android compiled extension loads with namespaced context and android descriptors`() = runBlocking<Unit> {
        val (_, record) = install("Fixture", ExtensionTestSupport.extension("fixture"))
        val loaded = assertNotNull(PluginBridge.loadedInstallation(record.id))
        val provider = loaded.providers.single()
        assertEquals("FixtureProvider", provider.name)
        assertEquals("${record.id}:FixtureProvider", PluginBridge.providerId(provider))
        assertSame(provider, PluginBridge.findProvider("${record.id}:FixtureProvider"))
        assertEquals("yes", loaded.plugin.javaClass.getField("lastPreference").get(null), "SharedPreferences and Pair descriptors match Android")
        val prefs = File(CloudDirs.extensionDataDir, "${record.id}/shared_prefs/fixture.json")
        assertTrue(prefs.isFile, "preferences persist inside the extension's private directory")
        assertEquals(1, record.jarHashes.size)
        assertEquals(listOf("FixtureProvider"), record.providerNames)
    }

    @Test fun `android compiled provider receives its declared main-page requests in order`() = runBlocking<Unit> {
        val (_, record) = install("Fixture", ExtensionTestSupport.extension("fixture"))
        val provider = PluginBridge.loadedInstallation(record.id)!!.providers.single()
        val home = ProviderExecutor.loadHome(provider, page = 1)
        assertEquals("${record.id}:FixtureProvider", home.providerId)
        assertEquals(listOf("Trending|trending|1", "Latest|latest|1"), home.lists.map { it.name })
        assertEquals(listOf(false, true), home.lists.map { it.isHorizontal })
    }

    @Test fun `multi dex extension translates every dex entry`() = runBlocking<Unit> {
        val (_, record) = install("Multi", ExtensionTestSupport.extension("multidex"))
        assertEquals(2, record.jarHashes.size)
        assertEquals("FixtureProvider", PluginBridge.loadedInstallation(record.id)!!.providers.single().name)
    }

    @Test fun `failing load publishes nothing and commits nothing`() = runBlocking<Unit> {
        val failure = assertFailsWith<ExtensionException> { install("Failing", ExtensionTestSupport.extension("failing")) }
        assertEquals(ExtensionException.Code.LOAD_FAILED, failure.code)
        assertTrue(PluginBridge.allProviders().none { it.name == "FixtureProvider" }, "registrations made before the failure are discarded")
        assertTrue(DaemonState.snapshot().installations.isEmpty())
    }

    /** RT-13: an aapt2-built requiresResources=true extension reads its compiled resources and assets in load(). */
    @Test fun `extensions with compiled Android resources load and use them`() = runBlocking<Unit> {
        // The plugin checks every value itself (locale default, format, references, arrays, scalars, missing IDs, assets).
        val (_, record) = install("AndroidResources", ExtensionTestSupport.extension("android-resources"))
        val loaded = assertNotNull(PluginBridge.loadedInstallation(record.id))
        val provider = loaded.providers.single()
        assertEquals("ResourceProvider", provider.name, "named from res/values, not the values-fr variant")
        assertEquals("https://resources.invalid", provider.mainUrl, "read from assets/")
        assertEquals(2, ProviderExecutor.loadHome(provider, 1).lists.size, "the provider operates")
        assertEquals(listOf("Android settings screens"), loaded.unsupportedFeatures, "layouts are reported, not rendered")
    }

    @Test fun `resource flagged extensions without a table still load`() = runBlocking<Unit> {
        val (_, record) = install("Resources", ExtensionTestSupport.extension("resources"))
        assertNotNull(PluginBridge.loadedInstallation(record.id))
    }

    @Test fun `a malformed resource table is rejected before any code runs`() = runBlocking<Unit> {
        val archive = zip(mapOf(
            "manifest.json" to """{"name":"X","pluginClassName":"fixture.ResourcePlugin","requiresResources":true}""".toByteArray(),
            "classes.dex" to ExtensionTestSupport.dexOf("android-resources"),
            "resources.arsc" to byteArrayOf(2, 0, 12, 0, 99, 0, 0, 0, 1, 0, 0, 0),
        ))
        val failure = assertFailsWith<ExtensionException> { install("Malformed", archive) }
        assertEquals(ExtensionException.Code.UNSUPPORTED, failure.code)
        assertTrue("malformed" in failure.message.orEmpty())
        assertTrue(DaemonState.snapshot().installations.isEmpty())
    }

    @Test fun `malformed archives fail through the exception barrier`() = runBlocking<Unit> {
        val cases = mapOf(
            "NoManifest" to zip(mapOf("classes.dex" to ExtensionTestSupport.dexOf("fixture"))),
            "NoClass" to zip(mapOf("manifest.json" to """{"name":"X"}""".toByteArray(), "classes.dex" to ExtensionTestSupport.dexOf("fixture"))),
            "NoDex" to zip(mapOf("manifest.json" to """{"name":"X","pluginClassName":"fixture.FixturePlugin"}""".toByteArray())),
            "Garbage" to byteArrayOf(0, 1, 2, 3),
            "GapDex" to zip(mapOf("manifest.json" to """{"name":"X","pluginClassName":"fixture.FixturePlugin"}""".toByteArray(),
                "classes.dex" to ExtensionTestSupport.dexOf("fixture"), "classes3.dex" to ExtensionTestSupport.dexOf("fixture"))),
        )
        var revision = 1L
        for ((name, bytes) in cases) {
            val failure = assertFailsWith<ExtensionException>(name) { install(name, bytes, revision++) }
            assertTrue(failure.code in setOf(ExtensionException.Code.LOAD_FAILED, ExtensionException.Code.UNSUPPORTED), name)
        }
        assertTrue(DaemonState.snapshot().installations.isEmpty())
        assertTrue(PluginBridge.getAllLoadedDescriptors().isEmpty())
    }

    @Test fun `tampered translation cache is rebuilt from verified source before loading`() = runBlocking<Unit> {
        val (manager, record) = install("Fixture", ExtensionTestSupport.extension("fixture"))
        PluginBridge.detach(record.id)
        val jar = File(CloudDirs.pluginCacheDir, "${ArtifactStore.translationKey(record.artifactHash)}.jar")
        assertTrue(jar.isFile)
        val tampered = ByteArray(64) { 7 }
        jar.writeBytes(tampered)
        assertTrue(manager.restore(record.id))
        val rebuilt = jar.readBytes()
        assertFalse(rebuilt.contentEquals(tampered), "tampered translation was replaced")
        // Translation is not byte-reproducible, so the receipt records the rebuilt digest.
        assertEquals(listOf(ArtifactDigest.sha256(rebuilt)), DaemonState.snapshot().installations[record.id]!!.jarHashes)
        assertNotNull(PluginBridge.loadedInstallation(record.id))
    }

    @Test fun `publication rollback keeps registries consistent when a generation is replaced`() = runBlocking<Unit> {
        val (manager, record) = install("Fixture", ExtensionTestSupport.extension("fixture"))
        val first = PluginBridge.loadedInstallation(record.id)!!
        assertTrue(manager.setEnabled(record.id, false))
        assertTrue(PluginBridge.allProviders().none { it === first.providers.single() })
        assertNull(com.lagradost.cloudstream3.APIHolder.getApiFromNameNull("FixtureProvider"), "no ghost API mapping after unload")
        assertTrue(manager.setEnabled(record.id, true))
        val second = PluginBridge.loadedInstallation(record.id)!!
        assertNotSame(first, second)
        assertEquals(1, PluginBridge.allProviders().count { it.name == "FixtureProvider" })
    }

    @Test fun `sha256 is stable and hex-encoded`() {
        val a = ArtifactDigest.sha256("cloudstream".toByteArray())
        assertEquals(a, ArtifactDigest.sha256("cloudstream".toByteArray()))
        assertEquals(64, a.length)
        assertTrue(a.all { it.isDigit() || it in 'a'..'f' })
    }
}
