package com.lagradost.macos

import com.lagradost.cloudstream3.MainAPI
import com.lagradost.cloudstream3.plugins.BasePlugin
import io.ktor.server.engine.embeddedServer
import io.ktor.server.netty.Netty
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import java.io.File
import java.net.HttpURLConnection
import java.net.URI
import java.util.jar.JarOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.test.*

/** Characterization only: passing confirms the documented adverse behavior.
 * Real signatures, fake fetcher, isolated root, harmless parent-classpath plugin.
 * No real DEX translation or community code is exercised. */
class CurrentReviewProbe {
    private val fixture = SignedCatalogFixture("https://current-review.invalid/repo.json")
    private val proofs = InstallationProofStore()

    @BeforeTest fun before() {
        check(CloudDirs.home.path.endsWith("current-review-home"))
        CloudDirs.home.deleteRecursively()
        CloudDirs.home.mkdirs()
        DaemonState.load()
        ReviewHarmlessPlugin.loads = 0
    }
    @AfterTest fun after() {
        PluginBridge.getAllLoadedDescriptors().forEach { PluginBridge.removePlugin(it.installationId) }
    }

    private suspend fun receipt(bytes: ByteArray = "signed fixture source".toByteArray(), enabled: Boolean = true): DaemonState.InstalledExtension {
        val hash = RepositoryService.sha256(bytes)
        val body = """[{"name":"Review","internalName":"Fixture","url":"Fixture.cs3","status":1,"version":7,"fileHash":"$hash"}]"""
        val outcome = RepositoryService.sync(fixture.url, fixture.fetcher(fixture.manifest(body), body))
        val state = DaemonState.snapshot()
        val proof = proofs.put(state.repos.single(), state.repositoryTrust.getValue(fixture.url))
        val record = DaemonState.InstalledExtension(InstallationProofStore.installationId(fixture.url, "Fixture"), fixture.url,
            "Fixture", hash, "review-generation", proof, System.currentTimeMillis(), outcome.plugins.single(), enabled = enabled)
        CloudDirs.cs3StoreDir.mkdirs()
        File(CloudDirs.cs3StoreDir, "$hash.cs3").writeBytes(bytes)
        DaemonState.update { it.copy(installations = mapOf(record.id to record)) }
        return record
    }

    private class FakeRuntime : ExtensionRuntime {
        var prepares = 0
        var publishes = 0
        var onPrepare: () -> Unit = {}
        override fun prepare(record: DaemonState.InstalledExtension, artifact: File): PreparedExtension {
            prepares++; onPrepare()
            return object : PreparedExtension { override val providerNames = listOf("ReviewProvider"); override val extractorCount = 0 }
        }
        override fun publish(record: DaemonState.InstalledExtension, prepared: PreparedExtension): AutoCloseable? { publishes++; return null }
        override fun discard(prepared: PreparedExtension) {}
        override fun remove(id: String): AutoCloseable? = null
    }
    private fun manager(runtime: FakeRuntime, fetcher: RepositoryFetcher = RepositoryFetcher { _, _ -> error("Unexpected fetch") }) =
        InstallationManager(runtime, fetcher)

    @Test fun `retry of committed but unloaded identical version does not prepare runtime`() = runBlocking {
        val record = receipt()
        val runtime = FakeRuntime()
        assertEquals(record, manager(runtime).install(fixture.url, "Fixture", "", null))
        assertEquals(0, runtime.prepares)
        assertNull(PluginBridge.loadedInstallation(record.id))
    }

    @Test fun `repeated enable prepares and republishes same generation twice`() = runBlocking {
        val record = receipt()
        val runtime = FakeRuntime()
        val manager = manager(runtime)
        assertTrue(manager.setEnabled(record.id, true))
        assertTrue(manager.setEnabled(record.id, true))
        assertEquals(2, runtime.prepares)
        assertEquals(2, runtime.publishes)
    }

    @Test fun `restore publishes even when trust anchor changes during preparation`() = runBlocking {
        val record = receipt()
        val runtime = FakeRuntime()
        runtime.onPrepare = { DaemonState.update { it.copy(repositoryTrust = emptyMap()) } }
        assertTrue(manager(runtime).restore(record))
        assertEquals(1, runtime.publishes)
        assertFails { proofs.verify(record, null) }
    }

    @Test fun `signed remote down revision does not revoke old committed receipt`() = runBlocking {
        val record = receipt()
        val down = """[{"name":"Review","internalName":"Fixture","url":"Fixture.cs3","status":0,"version":7,"fileHash":"${record.artifactHash}"}]"""
        RepositoryService.sync(fixture.url, fixture.fetcher(fixture.manifest(down, revision = 2), down))
        assertFalse(RepositoryService.getRepoPlugins(fixture.url).single().installationAllowed)
        val runtime = FakeRuntime()
        assertTrue(manager(runtime).restore(record))
        assertEquals(1, runtime.publishes)
    }

    @Test fun `uninstall during first download leaves active installation able to commit`() = runBlocking {
        val record = receipt()
        DaemonState.update { it.copy(installations = emptyMap()) }
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val runtime = FakeRuntime()
        val manager = manager(runtime, RepositoryFetcher { url, _ ->
            entered.complete(Unit); release.await()
            RepositoryDocument("signed fixture source".toByteArray(), url)
        })
        val installing = async { manager.install(fixture.url, "Fixture", "", null) }
        withTimeout(5000) { entered.await() }
        assertFalse(manager.uninstall(record.id))
        release.complete(Unit)
        val installed = withTimeout(5000) { installing.await() }
        assertTrue(installed.id in DaemonState.snapshot().installations)
        assertEquals(1, runtime.publishes)
    }

    private suspend fun warmedReceipt(enabled: Boolean = true): DaemonState.InstalledExtension {
        val bytes = java.io.ByteArrayOutputStream().also { out ->
            ZipOutputStream(out).use { zip ->
                for ((name, body) in mapOf("manifest.json" to """{"name":"Review","pluginClassName":"com.lagradost.macos.ReviewHarmlessPlugin"}""", "classes.dex" to "invalid dex")) {
                    zip.putNextEntry(ZipEntry(name)); zip.write(body.toByteArray()); zip.closeEntry()
                }
            }
        }.toByteArray()
        val record = receipt(bytes, enabled)
        CloudDirs.pluginCacheDir.mkdirs()
        JarOutputStream(File(CloudDirs.pluginCacheDir, "${record.artifactHash}.jar").outputStream()).close()
        return record
    }

    @Test fun `direct loader runs disabled receipt using unauthenticated warm jar`() = runBlocking {
        val record = warmedReceipt(enabled = false)
        assertNotNull(PluginBridge.loadPluginFromCs3(File(CloudDirs.cs3StoreDir, "${record.artifactHash}.cs3")))
        assertEquals(1, ReviewHarmlessPlugin.loads)
        assertFalse(DaemonState.snapshot().installations.getValue(record.id).enabled)
        assertTrue(PluginBridge.allProviders().any { it.name == "ReviewProvider" })
    }

    @Test fun `actual plugin routes lose metadata ignore stable ID disable and hide unloaded receipts`() = runBlocking {
        val record = warmedReceipt()
        assertNotNull(PluginBridge.loadPluginFromCs3(File(CloudDirs.cs3StoreDir, "${record.artifactHash}.cs3")))
        val tokenField = Class.forName("com.lagradost.macos.MainKt").getDeclaredField("bearerToken")
        tokenField.isAccessible = true
        val oldToken = tokenField.get(null)
        tokenField.set(null, "current-review-token")
        val server = embeddedServer(Netty, host = "127.0.0.1", port = 0) { module() }.start(false)
        try {
            val port = server.engine.resolvedConnectors().single().port
            fun request(path: String, body: String? = null): String {
                val conn = URI("http://127.0.0.1:$port$path").toURL().openConnection() as HttpURLConnection
                conn.connectTimeout = 5000; conn.readTimeout = 5000
                conn.setRequestProperty("Authorization", "Bearer current-review-token")
                if (body != null) {
                    conn.requestMethod = "POST"; conn.doOutput = true
                    conn.setRequestProperty("Content-Type", "application/json")
                    conn.outputStream.use { it.write(body.toByteArray()) }
                }
                assertEquals(200, conn.responseCode)
                return conn.inputStream.bufferedReader().use { it.readText() }.also { conn.disconnect() }
            }
            val dto = Json.parseToJsonElement(request("/plugins")).jsonArray.single().jsonObject
            assertEquals(record.id, dto.getValue("id").jsonPrimitive.content)
            assertEquals(0, dto.getValue("version").jsonPrimitive.int)
            assertFalse(dto.getValue("verified").jsonPrimitive.boolean)
            request("/plugins/setEnabled", """{"provider":"${record.id}","enabled":false}""")
            assertTrue(DaemonState.isProviderEnabled("ReviewProvider"))
            assertTrue(DaemonState.snapshot().installations.getValue(record.id).enabled)
            assertTrue(record.id in DaemonState.snapshot().disabledProviders)
            PluginBridge.removePlugin(record.id)
            assertTrue(Json.parseToJsonElement(request("/plugins")).jsonArray.isEmpty())
            assertTrue(RepositoryService.getRepoPlugins(fixture.url).single().isInstalled)
        } finally { server.stop(0, 1000); tokenField.set(null, oldToken) }
    }
}

class ReviewHarmlessPlugin : BasePlugin() {
    companion object { var loads = 0 }
    override fun load() {
        loads++
        registerMainAPI(object : MainAPI() { override var name = "ReviewProvider" })
    }
}
