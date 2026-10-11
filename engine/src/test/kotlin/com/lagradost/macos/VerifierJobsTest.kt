package com.lagradost.macos

import com.lagradost.cloudstream3.APIHolder
import com.lagradost.cloudstream3.MainAPI
import com.lagradost.cloudstream3.TvType
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * VerifierJobs (download keep-alive, Android `extractorVerifierJob` parity):
 * jobs start, stop on request, and never leak map entries — including the
 * common case of a provider without a verifier (NotImplementedError).
 */
class VerifierJobsTest {
    private val started = CompletableDeferred<String>()
    private val cancelled = CompletableDeferred<Unit>()

    private inner class KeepAliveApi : MainAPI() {
        override var name = "VerifierKeepAlive"
        override val supportedTypes = setOf(TvType.Movie)
        override suspend fun extractorVerifierJob(extractorData: String?) {
            started.complete(extractorData.orEmpty())
            try {
                awaitCancellation()
            } finally {
                cancelled.complete(Unit)
            }
        }
    }

    private class NoVerifierApi : MainAPI() {
        override var name = "VerifierNone"
        override val supportedTypes = setOf(TvType.Movie)
    }

    private val keepAlive = KeepAliveApi()
    private val noVerifier = NoVerifierApi()

    @AfterTest
    fun unregister() {
        APIHolder.allProviders.removeAll { it === keepAlive || it === noVerifier }
    }

    @Test
    fun `job runs until stopped and is then removed`() = runBlocking {
        APIHolder.allProviders.add(keepAlive)
        val id = VerifierJobs.start("VerifierKeepAlive", "token-123")
        assertNotNull(id)
        assertEquals("token-123", withTimeout(5_000) { started.await() })

        VerifierJobs.stop(id)
        withTimeout(5_000) { cancelled.await() }
        assertEquals(0, VerifierJobs.activeCount)
        VerifierJobs.stop(id) // idempotent
    }

    @Test
    fun `provider without a verifier leaves no stale job`() = runBlocking {
        APIHolder.allProviders.add(noVerifier)
        val id = VerifierJobs.start("VerifierNone", "data")
        assertNotNull(id)
        withTimeout(5_000) {
            while (VerifierJobs.activeCount > 0) kotlinx.coroutines.delay(20)
        }
        assertEquals(0, VerifierJobs.activeCount)
    }

    @Test
    fun `unknown provider or empty data starts nothing`() {
        assertNull(VerifierJobs.start("NoSuchProvider-${System.nanoTime()}", "data"))
        APIHolder.allProviders.add(keepAlive)
        assertNull(VerifierJobs.start("VerifierKeepAlive", ""))
        assertTrue(VerifierJobs.activeCount == 0)
    }
}
