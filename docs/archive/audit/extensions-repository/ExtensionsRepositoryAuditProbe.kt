package com.lagradost.macos

import com.lagradost.cloudstream3.APIHolder
import com.lagradost.cloudstream3.MainAPI
import com.lagradost.cloudstream3.SearchResponse
import com.lagradost.cloudstream3.MainPageRequest
import com.lagradost.cloudstream3.HomePageResponse
import com.lagradost.cloudstream3.mainPageOf
import com.lagradost.cloudstream3.app
import com.lagradost.cloudstream3.plugins.BasePlugin
import com.lagradost.cloudstream3.utils.extractorApis
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.Interceptor
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import java.io.File
import java.security.KeyPairGenerator
import java.security.Signature
import java.util.Base64
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.jar.JarOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.test.*

/** Audit characterization only: passing means the documented defect was reproduced.
 * Opt in with audit.init.gradle; not part of the normal regression suite.
 * All HTTP is intercepted. Loader fixtures deliberately exercise a warmed JAR
 * cache with a harmless parent-classpath plugin, not real dex translation.
 */
class ExtensionsRepositoryAuditProbe {
    private val originalClient = app.baseClient
    private val bodies = mutableMapOf<String, ByteArray>()
    private val requests = mutableListOf<String>()
    private val repo = "https://audit.invalid/repo.json"

    @BeforeTest fun before() {
        assertTrue(CloudDirs.home.path.endsWith("extensions-audit-home"))
        CloudDirs.home.deleteRecursively()
        CloudDirs.home.mkdirs()
        CloudDirs.pluginCacheDir.mkdirs()
        CloudDirs.cs3StoreDir.mkdirs()
        DaemonState.load()
        AuditPlugin.fail = false
        AuditPlugin.barrier = null
        app.baseClient = originalClient.newBuilder().addInterceptor(Interceptor { chain ->
            val url = chain.request().url.toString()
            synchronized(requests) { requests.add(url) }
            val body = bodies[url] ?: error("Unexpected network request: $url")
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1)
                .code(200).message("Audit fixture").body(body.toResponseBody()).build()
        }).build()
    }

    @AfterTest fun after() {
        AuditPlugin.barrier = null
        PluginBridge.getAllLoadedDescriptors().forEach { PluginBridge.removePlugin(it.sha256) }
        APIHolder.allProviders.withLock { APIHolder.allProviders.clear() }
        APIHolder.apis.toList().forEach { APIHolder.removePluginMapping(it) }
        extractorApis.withLock { extractorApis.clear() }
        app.baseClient = originalClient
    }

    private fun body(url: String, text: String) { bodies[url] = text.toByteArray() }
    private fun persist(url: String = repo, plugins: List<RepositoryService.SitePlugin>) {
        DaemonState.update { it.copy(repos = it.repos + DaemonState.PersistedRepository(
            url = url, pluginsJson = Json.encodeToString(plugins))) }
    }
    private fun artifact(name: String = "AuditPlugin"): File {
        val tmp = File(CloudDirs.home, "$name.zip")
        ZipOutputStream(tmp.outputStream()).use { zip ->
            mapOf("manifest.json" to """{"name":"$name","pluginClassName":"com.lagradost.macos.AuditPlugin"}""",
                "classes.dex" to "warmed-cache-probe").forEach { (n, v) ->
                zip.putNextEntry(ZipEntry(n)); zip.write(v.toByteArray()); zip.closeEntry()
            }
        }
        val hash = RepositoryService.sha256(tmp)
        val source = File(CloudDirs.cs3StoreDir, "$hash.cs3")
        tmp.copyTo(source, overwrite = true)
        JarOutputStream(File(CloudDirs.pluginCacheDir, "$hash.jar").outputStream()).use { }
        return source
    }

    @Test fun `pinned repository accepts unsigned replacement`() = runBlocking {
        DaemonState.update { it.copy(repos = listOf(DaemonState.PersistedRepository(
            url = repo, pinnedPublicKey = "previously-pinned-key", signed = true))) }
        body(repo, """{"name":"Unsigned replacement","pluginLists":[]}""")
        assertFalse(RepositoryService.sync(repo).verified)
        assertEquals("Unsigned replacement", RepositoryService.listRepositories().single().name)
    }

    @Test fun `signed manifest authenticates no plugin-list contents`() = runBlocking {
        val keys = KeyPairGenerator.getInstance("Ed25519").generateKeyPair()
        val unsigned = """{"name":"Signed","pluginLists":["https://audit.invalid/list.json"]}"""
        val canonical = RepoSignature.canonicalize(Json.parseToJsonElement(unsigned))
        val signer = Signature.getInstance("Ed25519")
        signer.initSign(keys.private); signer.update(canonical.toByteArray())
        val b64 = Base64.getEncoder()
        val signature = b64.encodeToString(signer.sign())
        val publicKey = b64.encodeToString(keys.public.encoded.takeLast(32).toByteArray())
        body(repo, unsigned.dropLast(1) + """, "signature":{"algorithm":"ed25519","publicKey":"$publicKey","value":"$signature"}}""")
        body("https://audit.invalid/list.json", """[{"name":"Initial","url":"a.cs3"}]""")
        assertTrue(RepositoryService.sync(repo).verified)
        body("https://audit.invalid/list.json", """[{"name":"Replaced without signing","url":"b.cs3"}]""")
        val changed = RepositoryService.sync(repo)
        assertTrue(changed.verified)
        assertEquals("Replaced without signing", changed.plugins.single().name)
    }

    @Test fun `HTTPS manifest fetches HTTP list without rejection`() = runBlocking {
        body(repo, """{"pluginLists":["http://audit.invalid/list.json"]}""")
        body("http://audit.invalid/list.json", "[]")
        RepositoryService.sync(repo)
        assertTrue(requests.contains("http://audit.invalid/list.json"))
    }

    @Test fun `verified download returns corrupt existing equal-length file`() = runBlocking {
        val valid = "good".toByteArray()
        val hash = RepositoryService.sha256(valid)
        val cached = File(CloudDirs.cs3StoreDir, "$hash.cs3")
        cached.writeText("evil")
        bodies["https://audit.invalid/p.cs3"] = valid
        val result = RepositoryService.fetchVerifiedCs3(RepositoryService.SitePlugin(
            url = "https://audit.invalid/p.cs3", fileHash = hash))
        assertEquals("evil", result.readText())
        assertNotEquals(hash, RepositoryService.sha256(result))
    }

    @Test fun `boot hash rejection is bypassed by fallback directory scan`() {
        val source = artifact()
        val wrongHash = "a".repeat(64)
        source.renameTo(File(CloudDirs.cs3StoreDir, "$wrongHash.cs3"))
        persist(plugins = listOf(RepositoryService.SitePlugin(name = "AuditPlugin", fileHash = wrongHash)))
        assertEquals(1, RepositoryService.bootFromCache())
        assertEquals(1, PluginBridge.getAllLoadedDescriptors().size)
    }

    @Test fun `load failure leaks registered provider without installed descriptor`() {
        AuditPlugin.fail = true
        assertNull(PluginBridge.loadPluginFromCs3(artifact()))
        assertTrue(PluginBridge.getAllLoadedDescriptors().isEmpty())
        assertTrue(PluginBridge.allProviders().any { it.name == "Audit provider" })
    }

    @Test fun `unload leaves provider in shared API mapping`() {
        val loaded = assertNotNull(PluginBridge.loadPluginFromCs3(artifact()))
        assertTrue(PluginBridge.removePlugin(loaded.sha256))
        assertTrue(PluginBridge.allProviders().isEmpty())
        assertNotNull(APIHolder.getApiFromNameNull("Audit provider"))
    }

    @Test fun `simultaneous identical loads double-register providers`() {
        val source = artifact()
        AuditPlugin.barrier = CountDownLatch(2)
        val executor = Executors.newFixedThreadPool(2)
        try {
            val a = executor.submit<PluginBridge.LoadedPlugin?> { PluginBridge.loadPluginFromCs3(source) }
            val b = executor.submit<PluginBridge.LoadedPlugin?> { PluginBridge.loadPluginFromCs3(source) }
            assertNotNull(a.get(10, TimeUnit.SECONDS)); assertNotNull(b.get(10, TimeUnit.SECONDS))
            assertEquals(1, PluginBridge.getAllLoadedDescriptors().size)
            assertEquals(2, PluginBridge.allProviders().count { it.name == "Audit provider" })
        } finally { executor.shutdownNow() }
    }

    @Test fun `install in repo B selects repo A hash when internal names collide`() = runBlocking {
        val a = RepositoryService.SitePlugin(url = "https://audit.invalid/a.cs3", internalName = "Same",
            fileHash = RepositoryService.sha256("aaa".toByteArray()))
        val b = a.copy(url = "https://audit.invalid/b.cs3", fileHash = RepositoryService.sha256("bbb".toByteArray()))
        persist("https://audit.invalid/A.json", listOf(a))
        persist("https://audit.invalid/B.json", listOf(b))
        body(b.url, "bbb")
        val failure = assertFailsWith<SecurityException> {
            RepositoryService.installPlugin("https://audit.invalid/B.json", "Same", b.url, b.fileHash)
        }
        assertTrue(failure.message.orEmpty().contains(a.fileHash!!))
    }

    @Test fun `repo removal misses installed plugin absent from latest catalog`() {
        val loaded = assertNotNull(PluginBridge.loadPluginFromCs3(artifact()))
        persist(plugins = emptyList())
        assertTrue(RepositoryService.removeRepository(repo, true))
        assertTrue(PluginBridge.loadedPluginHashes().contains(loaded.sha256))
        assertTrue(File(loaded.filename).exists())
    }

    @Test fun `uninstall uses catalog hash as an unchecked filesystem path`() {
        val outsideSources = File(CloudDirs.home, "cache/audit-victim.cs3")
        outsideSources.writeText("harmless isolated test file")
        persist(plugins = listOf(RepositoryService.SitePlugin(internalName = "Traversal",
            fileHash = "../audit-victim")))
        assertTrue(RepositoryService.removeRepository(repo, true))
        assertFalse(outsideSources.exists())
    }

    @Test fun `failed retrust destroys the old pinned key`() = runBlocking {
        DaemonState.update { it.copy(repos = listOf(DaemonState.PersistedRepository(
            url = repo, pinnedPublicKey = "old-pinned-key", signed = true))) }
        body(repo, "not JSON")
        assertFails { RepositoryService.reTrust(repo) }
        assertNull(DaemonState.snapshot().repos.single().pinnedPublicKey)
    }

    @Test fun `legacy search null is misreported as empty success`() = runBlocking {
        val provider = object : MainAPI() {
            override var name = "Audit legacy null"
            override suspend fun search(query: String): List<SearchResponse>? = null
        }
        val result = ProviderExecutor.searchOne(provider, "probe")
        assertNull(result.error)
    }

    @Test fun `shared preferences lose values and removal throws`() {
        val context = android.content.Context()
        val preferences = context.getSharedPreferences("audit", 0)
        preferences.edit().putString("key", "value").commit()
        assertNull(context.getSharedPreferences("audit", 0).getString("key", null))
        assertFailsWith<NullPointerException> { preferences.edit().remove("key") }
        preferences.edit().clear().commit()
        assertEquals("value", preferences.getString("key", null))
    }

    @Test fun `status slow is dropped while revoked loaded provider keeps running`() = runBlocking {
        val loaded = assertNotNull(PluginBridge.loadPluginFromCs3(artifact()))
        body(repo, """{"pluginLists":["https://audit.invalid/list.json"]}""")
        body("https://audit.invalid/list.json", """[
            {"name":"AuditPlugin","internalName":"AuditPlugin","status":0,"fileHash":"${loaded.sha256}"},
            {"name":"Slow but usable","internalName":"Slow","status":2}]
        """)
        assertTrue(RepositoryService.sync(repo).plugins.isEmpty())
        assertTrue(ProviderExecutor.providers().any { it.name == "Audit provider" })
    }

    @Test fun `persisted override is ignored on plugin load`() {
        DaemonState.setProviderOverride("Audit provider", DaemonState.ProviderOverride(url = "https://override.invalid"))
        val loaded = assertNotNull(PluginBridge.loadPluginFromCs3(artifact()))
        assertNotEquals("https://override.invalid", loaded.providers.single().mainUrl)
    }

    @Test fun `failed replacement unloads working version and tombstones it`() = runBlocking {
        val old = assertNotNull(PluginBridge.loadPluginFromCs3(artifact()))
        val replacement = artifact("NewVersion")
        val url = "https://audit.invalid/update.cs3"
        bodies[url] = replacement.readBytes()
        AuditPlugin.fail = true
        assertFailsWith<IllegalStateException> {
            RepositoryService.installPlugin(repo, "AuditPlugin", url)
        }
        assertFalse(PluginBridge.loadedPluginHashes().contains(old.sha256))
        assertTrue(DaemonState.isPluginRemoved(old.sha256))
    }

    @Test fun `home ignores provider-defined main-page requests`() = runBlocking {
        val seen = mutableListOf<MainPageRequest>()
        val provider = object : MainAPI() {
            override var name = "Audit home"
            override val mainPage = mainPageOf("/films" to "Films", "/shows" to "Shows")
            override suspend fun getMainPage(page: Int, request: MainPageRequest): HomePageResponse? {
                seen.add(request)
                return null
            }
        }
        ProviderExecutor.loadHome(provider, 1)
        assertEquals(1, seen.size)
        assertEquals("", seen.single().data)
        assertEquals("", seen.single().name)
    }

    @Test fun `state write failure reports successful in-memory mutation`() {
        DaemonState.setProviderEnabled("First", false)
        File(CloudDirs.stateDir, "state.json.tmp").mkdirs()
        DaemonState.setProviderEnabled("Second", false)
        assertFalse(DaemonState.isProviderEnabled("Second"))
        DaemonState.load()
        assertTrue(DaemonState.isProviderEnabled("Second"))
    }
}

class AuditPlugin : BasePlugin() {
    companion object {
        @Volatile var fail = false
        @Volatile var barrier: CountDownLatch? = null
    }
    override fun load() {
        barrier?.let { it.countDown(); check(it.await(5, TimeUnit.SECONDS)) }
        registerMainAPI(object : MainAPI() { override var name = "Audit provider" })
        if (fail) error("Intentional audit fixture failure after registration")
    }
}
