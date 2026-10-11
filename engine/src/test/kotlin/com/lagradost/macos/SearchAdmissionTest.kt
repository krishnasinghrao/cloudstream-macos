package com.lagradost.macos

import com.lagradost.cloudstream3.MainAPI
import com.lagradost.cloudstream3.SearchResponse
import kotlinx.coroutines.*
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.*

/** Streaming uses searchOne; batch must share that exact operation permit. */
class SearchAdmissionTest {
    private class GatedProvider(private val gate: CompletableDeferred<Unit>,
                                private val active: AtomicInteger, private val maximum: AtomicInteger,
                                private val entered: AtomicInteger) : MainAPI() {
        override var name = "Admission-${System.nanoTime()}"
        override suspend fun search(query: String): List<SearchResponse> {
            val concurrent = active.incrementAndGet()
            maximum.accumulateAndGet(concurrent, ::maxOf)
            entered.incrementAndGet()
            try { gate.await(); return emptyList() } finally { active.decrementAndGet() }
        }
    }

    private suspend fun until(predicate: () -> Boolean) = withTimeout(2_000) {
        while (!predicate()) delay(5)
    }

    @Test fun `batch and streaming search share eight actual operation permits`() = runBlocking<Unit> {
        val gate = CompletableDeferred<Unit>()
        val active = AtomicInteger()
        val maximum = AtomicInteger()
        val entered = AtomicInteger()
        fun provider() = GatedProvider(gate, active, maximum, entered)
        val streams = (1..8).map { async(Dispatchers.IO) { ProviderExecutor.searchOne(provider(), "stream") } }
        until { active.get() == 8 }
        val batch = async(Dispatchers.IO) { ProviderExecutor.searchAll("batch", (1..12).map { provider() }) }
        val furtherStreams = (1..6).map { async(Dispatchers.IO) { ProviderExecutor.searchOne(provider(), "stream") } }
        delay(100)
        assertEquals(8, entered.get(), "Neither endpoint may bypass an occupied shared bound")
        gate.complete(Unit)
        withTimeout(3_000) { streams.awaitAll(); furtherStreams.awaitAll(); batch.await() }
        assertEquals(26, entered.get())
        assertEquals(8, maximum.get())
        assertEquals(0, active.get())
    }

    @Test fun `cancellation releases held permits and never starts cancelled queued providers`() = runBlocking<Unit> {
        val blocked = CompletableDeferred<Unit>()
        val active = AtomicInteger()
        val maximum = AtomicInteger()
        val entered = AtomicInteger()
        val held = (1..8).map {
            async(Dispatchers.IO) { ProviderExecutor.searchOne(GatedProvider(blocked, active, maximum, entered), "held") }
        }
        until { active.get() == 8 }
        val queued = async(Dispatchers.IO) {
            ProviderExecutor.searchAll("queued", (1..8).map { GatedProvider(blocked, active, maximum, entered) })
        }
        delay(100)
        queued.cancelAndJoin()
        held.forEach { it.cancel() }
        held.joinAll()
        assertEquals(8, entered.get())
        assertEquals(0, active.get())
        val ready = CompletableDeferred<Unit>().apply { complete(Unit) }
        withTimeout(2_000) {
            ProviderExecutor.searchAll("after cancellation", (1..8).map { GatedProvider(ready, active, maximum, entered) })
        }
        assertEquals(16, entered.get(), "All permits remain reusable")
    }

    @Test fun `fast provider result is available before a slow sibling finishes`() = runBlocking<Unit> {
        val slowGate = CompletableDeferred<Unit>()
        val active = AtomicInteger()
        val maximum = AtomicInteger()
        val entered = AtomicInteger()
        val slow = async(Dispatchers.IO) {
            ProviderExecutor.searchOne(GatedProvider(slowGate, active, maximum, entered), "slow")
        }
        until { entered.get() == 1 }
        val fast = withTimeout(1_000) {
            ProviderExecutor.searchOne(GatedProvider(CompletableDeferred<Unit>().apply { complete(Unit) }, active, maximum, entered), "fast")
        }
        assertNull(fast.error)
        assertFalse(slow.isCompleted)
        slowGate.complete(Unit)
        assertNull(slow.await().error)
    }
}
