package com.lagradost.macos

import com.lagradost.macos.worker.ExtractRequest
import com.lagradost.macos.worker.ExtractorDescriptor
import com.lagradost.macos.worker.RemoteProvider
import com.lagradost.macos.worker.WorkerExtensionRuntime
import com.lagradost.macos.worker.WorkerLauncher
import com.lagradost.macos.worker.WorkerPlugin
import com.lagradost.macos.worker.WorkerPool
import kotlinx.coroutines.runBlocking
import kotlin.test.*

/**
 * Plan RT-12 against real worker JVMs: a provider in one extension resolves a
 * video host through an extractor another extension ships, the host's worker
 * starts on demand, routes never cycle, and disabled extensions are not used.
 */
class ExtractorRoutingTest {
    private val repo = SignedCatalogFixture("https://routing.invalid/repo.json")
    private lateinit var manager: InstallationManager
    private lateinit var host: DaemonState.InstalledExtension
    private lateinit var consumer: DaemonState.InstalledExtension

    @BeforeTest fun before() {
        ExtensionTestSupport.resetHome()
        WorkerPool.resetForTest()
        ExtractorRouter.install()
        ExtensionTestSupport.allowUnsandboxedWorkers()
    }

    @AfterTest fun after() {
        WorkerPool.resetForTest()
        ExtensionTestSupport.resetHome()
    }

    private suspend fun install() {
        val fetcher = repo.publish(mapOf(
            "Host" to ExtensionTestSupport.extension("extractor-host"),
            "Consumer" to ExtensionTestSupport.extension("consumer"),
        ), revision = 1)
        manager = ExtensionTestSupport.use(InstallationManager(WorkerExtensionRuntime(WorkerLauncher(sandboxed = false)), fetcher))
        host = manager.install(repo.url, "Host")
        consumer = manager.install(repo.url, "Consumer")
    }

    private fun handle(record: DaemonState.InstalledExtension) =
        assertIs<WorkerPlugin>(PluginBridge.loadedInstallation(record.id)!!.plugin).handle

    private fun consumerProvider() = assertIs<RemoteProvider>(PluginBridge.loadedInstallation(consumer.id)!!.providers.single())

    @Test fun `extractor descriptors are recorded with the install receipt`() = runBlocking<Unit> {
        install()
        val stored = DaemonState.snapshot().installations.getValue(host.id)
        assertEquals(listOf(ExtractorDescriptor("FixtureHost", "https://host.invalid")), stored.extractorDescriptors)
        assertEquals(emptyList(), stored.providerDescriptors, "an extractor-only extension registers no provider")
        assertEquals(listOf("FixtureLoop"), DaemonState.snapshot().installations.getValue(consumer.id).extractorDescriptors.map { it.name })
    }

    @Test fun `a provider uses an extractor another extension ships, starting its stopped worker`() = runBlocking<Unit> {
        install()
        // Restore path: the receipt's descriptors register the host without starting it.
        manager.setEnabled(host.id, false)
        manager.setEnabled(host.id, true)
        assertFalse(handle(host).running, "extractor-only extensions register lazily too")
        // Every running worker is busy while the provider waits: routing may exceed the soft cap.
        WorkerPool.maxRunning = 1

        val response = ProviderExecutor.loadLinks(consumerProvider(), "https://host.invalid/v/42")
        val link = response.links.single()
        assertEquals("https://cdn.invalid/42.m3u8", link.url)
        assertEquals("M3U8", link.type)
        assertEquals(720, link.quality)
        assertEquals("42", link.headers["X-Fixture"])
        assertEquals("https://consumer.invalid/", link.headers["referer"], "the caller's referer reaches the extractor")
        assertEquals("host-data", link.extractorData)
        assertEquals("success", response.outcome)
        assertTrue(handle(host).running)
    }

    @Test fun `extract routes to extractor-only extensions`() = runBlocking<Unit> {
        install()
        val response = ProviderExecutor.extract("https://host.invalid/v/7", null)
        assertEquals(listOf("https://cdn.invalid/7.m3u8"), response.links.map { it.url })
    }

    @Test fun `route cycles end instead of bouncing between extensions`() = runBlocking<Unit> {
        install()
        // cyclefixture.test -> consumer's extractor -> host.invalid/loop -> host's extractor -> cyclefixture.test (already visited).
        val started = System.currentTimeMillis()
        val response = ProviderExecutor.extract("http://cyclefixture.test/start", null)
        assertEquals(emptyList(), response.links)
        assertTrue(System.currentTimeMillis() - started < 30_000, "the cycle is cut, not timed out")
        assertTrue(handle(host).running && handle(consumer).running)
    }

    @Test fun `disabled extensions are never routed to`() = runBlocking<Unit> {
        install()
        manager.setEnabled(host.id, false)
        val response = ProviderExecutor.loadLinks(consumerProvider(), "https://host.invalid/v/1")
        assertEquals(emptyList(), response.links)
        assertEquals("provider_no_data", response.failures.single().code)
    }

    @Test fun `route state from a worker is bounded by the engine`() = runBlocking<Unit> {
        install()
        assertNull(ExtractorRouter.route("https://host.invalid/v/1", null, ExtractorRoute.within(60_000, hops = ExtractorRouter.MAX_HOPS)))
        assertNull(ExtractorRouter.route("file:///etc/passwd", null, ExtractorRoute.within(60_000)), "only web URLs are routed")
        // An exhausted budget is not stretched by routing: nothing is called.
        assertEquals(emptyList(), ExtractorRouter.route("https://host.invalid/v/1", null, ExtractorRoute.within(0))?.links.orEmpty())
        // A worker cannot route back to itself, whatever visited set it claims.
        val self = ExtractorRouter.answer(host.id, ExtractRequest("https://host.invalid/v/1", visited = listOf("forged"), hops = -5))
        assertEquals(emptyList(), self.links)
        // Another worker's request is answered.
        val routed = ExtractorRouter.answer(consumer.id, ExtractRequest("https://host.invalid/v/9", budgetMs = Long.MAX_VALUE))
        assertEquals(listOf("https://cdn.invalid/9.m3u8"), routed.links.map { it.url })
    }
}
