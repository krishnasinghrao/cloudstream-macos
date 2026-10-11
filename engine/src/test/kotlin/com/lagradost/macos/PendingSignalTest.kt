package com.lagradost.macos

import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class PendingSignalTest {
    @Test fun `a held request returns as soon as a task is parked`() = runBlocking<Unit> {
        val tasks = CopyOnWriteArrayList<String>()
        val started = System.nanoTime()
        val waiting = async { PendingSignal.awaitNonEmpty(10_000) { tasks.toList() } }
        delay(200)
        tasks += "challenge"
        PendingSignal.parked()
        assertEquals(listOf("challenge"), waiting.await())
        assertTrue((System.nanoTime() - started) / 1_000_000 < 2_000, "returned on the signal, not at the deadline")
    }

    @Test fun `an empty wait ends at its deadline and zero means no wait`() = runBlocking<Unit> {
        var started = System.nanoTime()
        assertEquals(emptyList(), PendingSignal.awaitNonEmpty(300) { emptyList<String>() })
        assertTrue((System.nanoTime() - started) / 1_000_000 >= 280)
        started = System.nanoTime()
        assertEquals(emptyList(), PendingSignal.awaitNonEmpty(0) { emptyList<String>() })
        assertTrue((System.nanoTime() - started) / 1_000_000 < 100)
    }

    @Test fun `waits are capped`() = runBlocking<Unit> {
        val started = System.nanoTime()
        val waiting = async { PendingSignal.awaitNonEmpty(Long.MAX_VALUE) { listOf("already") } }
        assertEquals(listOf("already"), waiting.await())
        assertTrue((System.nanoTime() - started) / 1_000_000 < 1_000)
    }
}
