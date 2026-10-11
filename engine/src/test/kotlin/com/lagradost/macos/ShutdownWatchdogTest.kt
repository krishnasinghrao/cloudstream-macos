package com.lagradost.macos

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.test.*

class ShutdownWatchdogTest {
    @Test fun `shutdown is forced after the grace period and arming never blocks`() {
        val halted = CountDownLatch(1)
        val started = System.nanoTime()
        val watchdog = ShutdownWatchdog.arm(300) { halted.countDown() }
        assertTrue((System.nanoTime() - started) / 1_000_000 < 200, "arming returns at once: a clean shutdown is not delayed")
        assertTrue(watchdog.isDaemon, "the watchdog itself never keeps the JVM alive")
        assertFalse(halted.await(150, TimeUnit.MILLISECONDS), "not before the grace period")
        assertTrue(halted.await(2, TimeUnit.SECONDS), "a hung shutdown is ended")
    }
}
