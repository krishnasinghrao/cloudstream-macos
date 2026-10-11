package com.lagradost.macos

import com.lagradost.macos.worker.RemoteProvider
import com.lagradost.macos.worker.WorkerExtensionRuntime
import com.lagradost.macos.worker.WorkerLauncher
import com.lagradost.macos.worker.WorkerPool
import kotlinx.coroutines.runBlocking
import kotlin.test.*

/**
 * Plan RT-16 against a real worker: the installed row distinguishes a
 * registered extension from a running process, and reports dated per-stage
 * outcomes of its current version instead of implying it works.
 */
class OperationHealthTest {
    private val repo = SignedCatalogFixture("https://health.invalid/repo.json")

    @BeforeTest fun before() {
        ExtensionTestSupport.resetHome()
        WorkerPool.resetForTest()
        OperationHealth.clearForTest()
        ExtensionTestSupport.allowUnsandboxedWorkers()
    }

    @AfterTest fun after() {
        WorkerPool.resetForTest()
        ExtensionTestSupport.resetHome()
    }

    @Test fun `registered is not running and health is per stage and per version`() = runBlocking<Unit> {
        val fetcher = repo.publish(mapOf("Fixture" to ExtensionTestSupport.extension("fixture")), revision = 1)
        val manager = ExtensionTestSupport.use(InstallationManager(WorkerExtensionRuntime(WorkerLauncher(sandboxed = false)), fetcher))
        val record = manager.install(repo.url, "Fixture")
        manager.setEnabled(record.id, false)
        WorkerPool.resetForTest()
        manager.setEnabled(record.id, true)

        // Listing never starts a worker, and a cold one is not reported as running.
        val cold = assertNotNull(RepositoryService.installedPlugin(record.id))
        assertEquals("ready", cold.state)
        assertEquals("not_started", cold.process)
        assertEquals(emptyList(), cold.health, "nothing has been tried yet")
        assertEquals(0, WorkerPool.runningCount())

        val provider = assertIs<RemoteProvider>(PluginBridge.loadedInstallation(record.id)!!.providers.single())
        ProviderExecutor.loadHome(provider, 1)
        ProviderExecutor.searchOne(provider, "anything") // the fixture implements no search

        val used = assertNotNull(RepositoryService.installedPlugin(record.id))
        assertEquals("running", used.state)
        assertEquals("running", used.process)
        val byStage = used.health.associateBy { it.stage }
        assertTrue(byStage.getValue("home").ok)
        assertFalse(byStage.getValue("search").ok)
        assertEquals("unsupported_capability", byStage.getValue("search").code)
        assertEquals("${record.id}:FixtureProvider", byStage.getValue("search").providerId)
        assertEquals("search", used.health.first().stage, "newest first")

        // Outcomes belong to one version: another generation starts unknown.
        assertEquals(emptyList(), OperationHealth.forGeneration(record.id, "another-generation"))

        // A restart keeps what is known about the installed version...
        OperationHealth.save()
        OperationHealth.reloadForTest()
        assertEquals(used.health, RepositoryService.installedPlugin(record.id)!!.health)
        // ...and drops outcomes of a version that is no longer the installed one.
        val current = DaemonState.snapshot().installations.getValue(record.id)
        DaemonState.update { it.copy(installations = it.installations + (record.id to current.copy(generation = "replaced-generation"))) }
        OperationHealth.reloadForTest()
        assertEquals(emptyList(), OperationHealth.forGeneration(record.id, current.generation))
    }
}
