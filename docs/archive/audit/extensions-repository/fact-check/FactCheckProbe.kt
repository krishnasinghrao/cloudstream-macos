package com.lagradost.macos

import com.lagradost.cloudstream3.*
import com.lagradost.cloudstream3.plugins.BasePlugin
import com.lagradost.cloudstream3.utils.extractorApis
import kotlinx.coroutines.*
import kotlinx.serialization.json.Json
import okhttp3.Interceptor
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import java.io.File
import java.io.IOException
import java.lang.reflect.Modifier
import java.security.KeyPairGenerator
import java.security.Signature
import java.util.Base64
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.jar.JarOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.test.*

/** Opt-in fact-check characterization, not passing security regression tests.
 * Uses the original audit init script and only synthetic/intercepted fixtures.
 * Do not run concurrently with other singleton-mutating tests in one JVM.
 */
class FactCheckProbe {
    private val originalClient = app.baseClient
    private val bodies = mutableMapOf<String, String>()
    private val root = "https://fact-check.invalid/repo.json"

    @BeforeTest fun before() {
        check(CloudDirs.home.path.endsWith("extensions-audit-home"))
        CloudDirs.home.deleteRecursively()
        CloudDirs.cs3StoreDir.mkdirs()
        CloudDirs.pluginCacheDir.mkdirs()
        DaemonState.load()
        FactCheckPlugin.started = CountDownLatch(1)
        FactCheckPlugin.stopped = CountDownLatch(1)
        app.baseClient = originalClient.newBuilder().addInterceptor(Interceptor { chain ->
            val url = chain.request().url.toString()
            val body = bodies[url] ?: error("Unexpected network request: $url")
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1)
                .code(200).message("Fact-check fixture").body(body.toResponseBody()).build()
        }).build()
    }

    @AfterTest fun after() {
        PluginBridge.getAllLoadedDescriptors().forEach { PluginBridge.removePlugin(it.sha256) }
        APIHolder.allProviders.withLock { APIHolder.allProviders.clear() }
        APIHolder.apis.toList().forEach { APIHolder.removePluginMapping(it) }
        extractorApis.withLock { extractorApis.clear() }
        app.baseClient = originalClient
    }

    private fun artifact(pluginClass: String = FactCheckPlugin::class.java.name): File {
        val tmp = File(CloudDirs.home, "fixture.zip")
        ZipOutputStream(tmp.outputStream()).use { zip ->
            mapOf("manifest.json" to """{"name":"FactCheck","pluginClassName":"$pluginClass"}""",
                "classes.dex" to "synthetic-warmed-cache").forEach { (name, content) ->
                zip.putNextEntry(ZipEntry(name)); zip.write(content.toByteArray()); zip.closeEntry()
            }
        }
        val hash = RepositoryService.sha256(tmp)
        val source = File(CloudDirs.cs3StoreDir, "$hash.cs3")
        tmp.copyTo(source, overwrite = true)
        JarOutputStream(File(CloudDirs.pluginCacheDir, "$hash.jar").outputStream()).use { }
        return source
    }

    @Test fun `F33 counterexample aggregate receives only status one from child syncs`() = runBlocking {
        bodies[root] = """<html><a href="https://fact-check.invalid/child.json">child</a></html>"""
        bodies["https://fact-check.invalid/child.json"] = """{"pluginLists":["list.json"]}"""
        bodies["https://fact-check.invalid/list.json"] = """[
          {"name":"OK","internalName":"OK","url":"ok.cs3","status":1},
          {"name":"Down","internalName":"Down","url":"down.cs3","status":0},
          {"name":"Slow","internalName":"Slow","url":"slow.cs3","status":2}]
        """
        val outcome = RepositoryService.sync(root)
        assertEquals(listOf("OK"), outcome.plugins.map { it.name })
        assertEquals(listOf(1), outcome.plugins.map { it.status })
    }

    @Test fun `failed load leaves catalog installed even without loaded descriptor`() {
        val file = artifact("nonexistent.factcheck.Plugin")
        assertNull(PluginBridge.loadPluginFromCs3(file))
        assertTrue(PluginBridge.getAllLoadedDescriptors().isEmpty())
        assertTrue(RepositoryService.isPluginInstalled(RepositoryService.SitePlugin(
            internalName = "FactCheck", fileHash = RepositoryService.sha256(file))))
    }

    @Test fun `cache directory with cs3 suffix aborts entire boot`() {
        File(CloudDirs.cs3StoreDir, "bad.cs3").mkdirs()
        assertFailsWith<IOException> { RepositoryService.bootFromCache() }
    }

    @Test fun `host verifier survives disable and plugin unload`() {
        val loaded = assertNotNull(PluginBridge.loadPluginFromCs3(artifact()))
        val jobId = assertNotNull(VerifierJobs.start("Fact-check verifier", "fixture"))
        try {
            assertTrue(FactCheckPlugin.started.await(5, TimeUnit.SECONDS))
            DaemonState.setProviderEnabled("Fact-check verifier", false)
            assertNull(ProviderExecutor.findProvider("Fact-check verifier"))
            assertTrue(PluginBridge.removePlugin(loaded.sha256))
            assertEquals(1, VerifierJobs.activeCount)
            assertEquals(1L, FactCheckPlugin.stopped.count)
        } finally {
            VerifierJobs.stop(jobId)
            assertTrue(FactCheckPlugin.stopped.await(5, TimeUnit.SECONDS))
        }
    }

    @Test fun `legacy null search is invoked twice before empty success`() = runBlocking {
        var calls = 0
        val provider = object : MainAPI() {
            override var name = "Fact-check null search"
            override suspend fun search(query: String): List<SearchResponse>? { calls++; return null }
        }
        assertNull(ProviderExecutor.searchOne(provider, "q").error)
        assertEquals(2, calls)
    }

    @Test fun `modern null incorrectly falls back to legacy success`() = runBlocking {
        var legacyCalls = 0
        val provider = object : MainAPI() {
            override var name = "Fact-check modern null"
            override suspend fun search(query: String, page: Int): SearchResponseList? = null
            override suspend fun search(query: String): List<SearchResponse> { legacyCalls++; return emptyList() }
        }
        assertNull(ProviderExecutor.searchOne(provider, "q").error)
        assertEquals(1, legacyCalls)
    }

    @Test fun `Android Pair exposes private fields instead of required public fields`() {
        for (name in listOf("first", "second")) {
            val field = android.util.Pair::class.java.getDeclaredField(name)
            assertTrue(Modifier.isPrivate(field.modifiers))
            assertFailsWith<NoSuchFieldException> { android.util.Pair::class.java.getField(name) }
        }
    }

    @Test fun `Uri percent decoding and query escaping do not follow Android semantics`() {
        assertEquals("a%2Fb", android.net.Uri.parse("https://fixture.invalid/?q=a%2Fb").getQueryParameter("q"))
        assertEquals("a+b", android.net.Uri.encode("a b"))
        assertEquals("https://fixture.invalid?q=a&admin=1", android.net.Uri.Builder()
            .scheme("https").authority("fixture.invalid").appendQueryParameter("q", "a&admin=1").build().toString())
    }

    @Test fun `Base64 DEFAULT rejects embedded linebreaks`() {
        assertFailsWith<IllegalArgumentException> { android.util.Base64.decode("YW\nJj", android.util.Base64.DEFAULT) }
    }

    @Test fun `Context ignores isolated data root but test redirects user home safely`() {
        val originalHome = System.getProperty("user.home")
        val fakeUserHome = File(CloudDirs.home, "fake-user-home")
        try {
            System.setProperty("user.home", fakeUserHome.absolutePath)
            val files = android.content.Context().getFilesDir()
            assertEquals(File(fakeUserHome, ".cloudstream-macos/data"), files)
            assertNotEquals(File(CloudDirs.home, "data"), files)
        } finally {
            System.setProperty("user.home", originalHome)
        }
    }

    @Test fun `same signing key can replay an older manifest`() = runBlocking {
        val keys = KeyPairGenerator.getInstance("Ed25519").generateKeyPair()
        val b64 = Base64.getEncoder()
        val publicKey = b64.encodeToString(keys.public.encoded.takeLast(32).toByteArray())
        fun signed(revision: Int): String {
            val body = """{"name":"revision-$revision","revision":$revision,"pluginLists":[]}"""
            val signer = Signature.getInstance("Ed25519")
            signer.initSign(keys.private)
            signer.update(RepoSignature.canonicalize(Json.parseToJsonElement(body)).toByteArray())
            val signature = b64.encodeToString(signer.sign())
            return body.dropLast(1) + """, "signature":{"algorithm":"ed25519","publicKey":"$publicKey","value":"$signature"}}"""
        }
        val older = signed(1)
        bodies[root] = signed(2)
        assertTrue(RepositoryService.sync(root).verified)
        bodies[root] = older
        assertTrue(RepositoryService.sync(root).verified)
        assertEquals("revision-1", RepositoryService.listRepositories().single().name)
    }

    @Test fun `cookie helper accepts URLs but interceptor supplies bare host`() {
        SolveBridge.applySolvedCookies("https://fact-check-cookie.invalid/path", "cf_clearance=fixture")
        assertEquals("cf_clearance=fixture", SolveBridge.cookieHeaderFor("https://fact-check-cookie.invalid/"))
        assertNull(SolveBridge.cookieHeaderFor("fact-check-cookie.invalid"))
    }
}

class FactCheckPlugin : BasePlugin() {
    companion object {
        var started = CountDownLatch(1)
        var stopped = CountDownLatch(1)
    }
    override fun load() {
        registerMainAPI(object : MainAPI() {
            override var name = "Fact-check verifier"
            override suspend fun extractorVerifierJob(extractorData: String?) {
                started.countDown()
                try { awaitCancellation() } finally { stopped.countDown() }
            }
        })
    }
}
