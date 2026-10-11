package com.lagradost.macos

import com.lagradost.macos.worker.RemoteProvider
import com.lagradost.macos.worker.WorkerExtensionRuntime
import com.lagradost.macos.worker.WorkerLauncher
import com.lagradost.macos.worker.WorkerPool
import kotlinx.coroutines.runBlocking
import kotlin.test.*

/**
 * Audit A33 in a real isolated worker process: the compiled fixture provider
 * reports the address and credential its live instance holds, so each
 * assertion is about what the running extension was actually left with.
 */
class WorkerCredentialTest {
    private val repo = SignedCatalogFixture("https://credentials.invalid/repo.json")

    @BeforeTest fun before() { ExtensionTestSupport.resetHome(); WorkerPool.resetForTest(); OperationHealth.clearForTest(); ExtensionTestSupport.allowUnsandboxedWorkers() }
    @AfterTest fun after() { WorkerPool.resetForTest(); ExtensionTestSupport.resetHome() }

    private suspend fun install(): RemoteProvider {
        val fetcher = repo.publish(mapOf("Credential" to ExtensionTestSupport.extension("credential")), revision = 1)
        val record = ExtensionTestSupport.use(InstallationManager(WorkerExtensionRuntime(WorkerLauncher(sandboxed = false)), fetcher))
            .install(repo.url, "Credential")
        return assertIs<RemoteProvider>(PluginBridge.loadedInstallation(record.id)!!.providers.single())
    }

    /** "<address>|<credential or none>" as the worker's provider reports it now. */
    private suspend fun live(provider: RemoteProvider): String {
        val home = ProviderExecutor.loadHome(provider, 1)
        assertEquals("success", home.outcome, home.failures.toString())
        // One shelf per declared homepage request; each names the same live state.
        return home.lists.map { it.name }.toSet().single()
    }

    @Test fun `set, replace and clear reach the running worker and a clear never falls back`() = runBlocking<Unit> {
        val provider = install()
        assertEquals("https://account.invalid|none", live(provider))
        val pid = assertNotNull(provider.handle.pid)

        val set = ProviderOverrides.configure(provider, url = null, credential = "first-secret", reset = false)
        assertTrue(set.applied)
        assertEquals("https://account.invalid|first-secret", live(provider))
        ProviderOverrides.configure(provider, url = "https://mirror.invalid", credential = null, reset = false)
        assertEquals("https://mirror.invalid|first-secret", live(provider), "an unchanged credential stays")
        ProviderOverrides.configure(provider, url = null, credential = "second-secret", reset = false)
        assertEquals("https://mirror.invalid|second-secret", live(provider))

        val cleared = ProviderOverrides.configure(provider, url = null, credential = null, reset = false, clearCredentials = true)
        assertTrue(cleared.applied)
        assertEquals("https://mirror.invalid|none", live(provider), "the live provider dropped the secret; no earlier one returned")
        assertEquals(pid, provider.handle.pid, "all of this happened in the same running worker")
        assertFalse(DaemonState.overrideFor(PluginBridge.providerId(provider))!!.hasCredentials)

        // A restart applies the committed settings only: still no credential.
        provider.handle.stop()
        assertEquals("https://mirror.invalid|none", live(provider))
        assertNotEquals(pid, provider.handle.pid)
        val audit = AuditLog.recent().joinToString("\n")
        assertFalse("first-secret" in audit || "second-secret" in audit)
    }

    @Test fun `a credential set while the worker is stopped is applied at its next start`() = runBlocking<Unit> {
        val provider = install()
        live(provider)
        provider.handle.stop()
        assertFalse(provider.handle.running)
        ProviderOverrides.configure(provider, url = null, credential = "later-secret", reset = false)
        assertEquals("https://account.invalid|later-secret", live(provider))
        provider.handle.stop()
        ProviderOverrides.configure(provider, url = null, credential = "", reset = false)
        assertEquals("https://account.invalid|none", live(provider), "an empty value from an older caller is a clear")
    }

    @Test fun `a worker that does not accept a clear is stopped and restarts without the secret`() = runBlocking<Unit> {
        val provider = install()
        ProviderOverrides.configure(provider, url = null, credential = "held-secret", reset = false)
        assertEquals("https://account.invalid|held-secret", live(provider))
        val pid = assertNotNull(provider.handle.pid)
        // The worker stops answering: it still holds the secret in memory.
        assertEquals(0, ProcessBuilder("kill", "-STOP", pid.toString()).start().waitFor())
        try {
            val response = ProviderOverrides.configure(provider, url = null, credential = null, reset = false, clearCredentials = true)
            assertFalse(response.applied, "the change was not acknowledged, so it is not reported as applied")
            assertTrue(response.pending)
            assertFalse(provider.handle.running, "the process that may still hold the secret is gone")
            // A frozen process cannot shut down by itself; it is killed after the stop grace period.
            val deadline = System.currentTimeMillis() + 10_000
            while (ProcessHandle.of(pid).map { it.isAlive }.orElse(false) && System.currentTimeMillis() < deadline) Thread.sleep(50)
            assertFalse(ProcessHandle.of(pid).map { it.isAlive }.orElse(false))
        } finally {
            ProcessBuilder("kill", "-CONT", pid.toString()).start().waitFor()
        }
        assertEquals("https://account.invalid|none", live(provider))
    }
}
