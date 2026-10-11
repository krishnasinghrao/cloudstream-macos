package com.lagradost.macos

import com.lagradost.macos.models.StreamLinkDto
import com.lagradost.macos.worker.RemoteProvider
import com.lagradost.macos.worker.WorkerExtensionRuntime
import com.lagradost.macos.worker.WorkerLauncher
import com.lagradost.macos.worker.WorkerPool
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import org.junit.Assume.assumeTrue
import java.io.File
import kotlin.test.*

/**
 * RT-17's engine half: an Android-compiled extension, installed from a signed
 * catalog and run in a sandboxed worker, resolves links through the engine's
 * sanitising path. With `-Dcs.exportLinks=<file>` (and `-Dcs.exportOrigin=`)
 * the links are written in the format the client's
 * `testLiveExtensionStreamsReachTheirFirstFrame` plays
 * (`scripts/run_full_client_tests.sh` does both).
 */
class LocalMediaLinksTest {
    @Serializable private data class Export(val provider: String, val link: StreamLinkDto)

    private val repo = SignedCatalogFixture("https://local-media.invalid/repo.json")

    @BeforeTest fun before() {
        ExtensionTestSupport.resetHome()
        WorkerPool.resetForTest()
    }

    @AfterTest fun after() {
        WorkerPool.resetForTest()
        ExtensionTestSupport.resetHome()
    }

    @Test fun `a sandboxed extension resolves links to its origin with the headers it attaches`() = runBlocking<Unit> {
        // sandbox-exec exists only on macOS; there, a missing sandbox is a real failure.
        assumeTrue("extension workers are sandboxed with macOS sandbox-exec", System.getProperty("os.name").startsWith("Mac"))
        assertTrue(WorkerLauncher.SANDBOX_AVAILABLE, "the macOS sandbox is required for extension workers")
        val origin = System.getProperty("cs.exportOrigin") ?: "http://127.0.0.1:8000"
        val fetcher = repo.publish(mapOf("LocalMedia" to ExtensionTestSupport.extension("local-media")), revision = 1)
        val manager = ExtensionTestSupport.use(InstallationManager(WorkerExtensionRuntime(WorkerLauncher(sandboxed = true)), fetcher))
        val record = manager.install(repo.url, "LocalMedia")
        val provider = assertIs<RemoteProvider>(assertNotNull(PluginBridge.loadedInstallation(record.id)).providers.single())
        assertEquals("LocalMediaProvider", provider.name)

        val response = ProviderExecutor.loadLinks(provider, origin)
        assertEquals("success", response.outcome, "failures: ${response.failures}")
        val hls = assertNotNull(response.links.singleOrNull { it.type == "M3U8" }, "links: ${response.links}")
        assertEquals("$origin/hls/index.m3u8", hls.url)
        assertEquals("https://local-media.invalid/", hls.headers["referer"], "upstream CloudStream names it in lower case")
        assertEquals("hls-fixture", hls.headers["X-Provider-Key"])
        val mp4 = assertNotNull(response.links.singleOrNull { it.type == "VIDEO" }, "links: ${response.links}")
        assertEquals("$origin/muxed.mp4", mp4.url)
        assertEquals(1080, mp4.quality)

        System.getProperty("cs.exportLinks")?.takeIf { it.isNotBlank() }?.let { path ->
            val rows = response.links.map { Export(response.providerId ?: response.provider, it) }
            File(path).writeText(Json.encodeToString(ListSerializer(Export.serializer()), rows))
        }
    }
}
