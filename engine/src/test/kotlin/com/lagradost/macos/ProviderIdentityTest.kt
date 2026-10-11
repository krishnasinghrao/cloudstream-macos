package com.lagradost.macos

import com.lagradost.cloudstream3.MainAPI
import com.lagradost.cloudstream3.TvType
import com.lagradost.cloudstream3.plugins.BasePlugin
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlin.test.*

/** F03 (provider identity) and N05 (host jobs end with their generation) against the real registry. */
class ProviderIdentityTest {
    private val first = "1".repeat(64)
    private val second = "2".repeat(64)

    private class Movies(owner: String, val verifier: (suspend () -> Unit)? = null) : MainAPI() {
        override var name = "Movies"
        override var mainUrl = "https://$owner.invalid"
        override val supportedTypes = setOf(TvType.Movie)
        init { sourcePlugin = owner }
        override suspend fun extractorVerifierJob(extractorData: String?) {
            verifier?.invoke() ?: throw NotImplementedError()
        }
    }

    private fun generation(id: String, provider: MainAPI) = PluginBridge.LoadedPlugin(id, "gen-$id", "0".repeat(64), null,
        object : BasePlugin() {}, listOf(provider), emptyList(), emptyList(), emptyList())

    @AfterTest fun cleanup() {
        listOf(first, second).forEach { id -> PluginBridge.detach(id) }
    }

    @Test fun `providers with the same name from two extensions are addressed independently`() {
        val a = Movies(first); val b = Movies(second)
        PluginBridge.publish(generation(first, a))
        PluginBridge.publish(generation(second, b))
        assertEquals("$first:Movies", PluginBridge.providerId(a))
        assertSame(a, PluginBridge.findProvider("$first:Movies"))
        assertSame(b, PluginBridge.findProvider("$second:Movies"))
        assertNull(PluginBridge.findProvider("Movies"), "an ambiguous bare name must not pick one")
        assertNull(ProviderExecutor.findProvider("Movies"))
        assertTrue("More than one installed provider" in ProviderExecutor.unavailableReason("Movies"))
        assertTrue("No installed extension provides “Absent”" in ProviderExecutor.unavailableReason("Absent"))
        DaemonState.setProviderEnabled("$first:Movies", false)
        try {
            assertFalse(DaemonState.isProviderEnabled("$first:Movies"))
            assertTrue(DaemonState.isProviderEnabled("$second:Movies"))
        } finally { DaemonState.setProviderEnabled("$first:Movies", true) }
    }

    @Test fun `verifier jobs are cancelled when their generation retires`() = runBlocking<Unit> {
        val started = CompletableDeferred<Unit>()
        val cancelled = CompletableDeferred<Unit>()
        val provider = Movies(first) {
            started.complete(Unit)
            try { awaitCancellation() } finally { cancelled.complete(Unit) }
        }
        PluginBridge.publish(generation(first, provider))
        assertNotNull(VerifierJobs.start("$first:Movies", "data"))
        withTimeout(5_000) { started.await() }
        PluginBridge.retire(requireNotNull(PluginBridge.detach(first)))
        withTimeout(5_000) { cancelled.await() }
        assertEquals(0, VerifierJobs.activeCount)
    }

    @Test fun `calls cannot start on a generation once retirement began`() {
        val provider = Movies(first)
        PluginBridge.publish(generation(first, provider))
        val loaded = requireNotNull(PluginBridge.detach(first))
        PluginBridge.retire(loaded)
        // A caller that looked the provider up before detach cannot run on the retired generation.
        assertFailsWith<IllegalStateException> { PluginBridge.withLease(provider) { "ran" } }
        assertEquals(0, loaded.activeCalls.get())
    }
}
