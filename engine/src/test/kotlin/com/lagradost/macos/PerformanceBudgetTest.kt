package com.lagradost.macos

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlin.test.*

/**
 * Plan T9.3 budgets that belong to the engine: the extension screens' reads
 * stay fast with 100 installed extensions, and `/health` answers while a slow
 * restore runs in the background. (Worker cold-start cost is measured in
 * WorkerIsolationTest and the end-to-end run; UI rendering belongs to T9.2.)
 */
class PerformanceBudgetTest {
    private val repo = SignedCatalogFixture("https://budget.invalid/repo.json")
    private val count = 100
    private lateinit var runtime: FakeRuntime
    private lateinit var manager: InstallationManager

    @BeforeTest fun before() = runBlocking {
        ExtensionTestSupport.resetHome()
        runtime = FakeRuntime()
        val artifacts = (1..count).associate { "Ext$it" to "budget artifact $it".toByteArray() }
        manager = ExtensionTestSupport.use(InstallationManager(runtime, repo.publish(artifacts, revision = 1)))
        artifacts.keys.forEach { manager.install(repo.url, it) }
    }

    @AfterTest fun after() = ExtensionTestSupport.resetHome()

    /** Median of several timed calls after one warm-up call. */
    private fun medianMs(block: () -> Unit): Long {
        block()
        return (1..7).map { val start = System.nanoTime(); block(); (System.nanoTime() - start) / 1_000_000 }.sorted()[3]
    }

    @Test fun `extension lists stay within the UI budget with 100 installed`() = RouteHarness().use { http ->
        assertEquals(count, DaemonState.snapshot().installations.size)
        val installed = medianMs { assertEquals(200, http.get("/plugins").status) }
        val catalog = medianMs { assertEquals(200, http.get("/repos/plugins?repoUrl=${repo.url}").status) }
        val repositories = medianMs { assertEquals(200, http.get("/repos").status) }
        println("BUDGET plugins=${installed}ms catalog=${catalog}ms repos=${repositories}ms (n=$count)")
        assertTrue(installed < 200, "GET /plugins took ${installed} ms")
        assertTrue(catalog < 200, "GET /repos/plugins took ${catalog} ms")
        assertTrue(repositories < 200, "GET /repos took ${repositories} ms")
    }

    @Test fun `health answers while a slow restore runs and restore completes within budget`() = RouteHarness().use { http ->
        runtime.onPrepare = { Thread.sleep(20) } // 100 × 20 ms of simulated extension loading
        DaemonState.update { state -> state.copy(installations = state.installations.mapValues { it.value.copy(generation = it.value.generation + "-next") }) }
        runBlocking {
            val restore = async(Dispatchers.IO) { manager.restoreAll() }
            val healthMs = medianMs { assertEquals(200, http.get("/health", auth = false).status) }
            assertTrue(healthMs < 100, "/health took ${healthMs} ms during restore")
            val started = System.currentTimeMillis()
            val result = restore.await()
            assertEquals(count, result.restored)
            println("BUDGET health-during-restore=${healthMs}ms restore=${System.currentTimeMillis() - started}ms")
            assertTrue(System.currentTimeMillis() - started < 30_000, "restore of $count extensions exceeded 30 s")
        }
    }
}
