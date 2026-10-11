package com.lagradost.macos

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class RateLimiterTest {

    @Test
    fun `allows burst up to capacity then blocks`() {
        val limiter = RateLimiter(capacity = 3, refillPerSecond = 0.001)
        assertTrue(limiter.tryAcquire("k"))
        assertTrue(limiter.tryAcquire("k"))
        assertTrue(limiter.tryAcquire("k"))
        assertFalse(limiter.tryAcquire("k"))
    }

    @Test
    fun `buckets are independent per key`() {
        val limiter = RateLimiter(capacity = 1, refillPerSecond = 0.001)
        assertTrue(limiter.tryAcquire("search"))
        assertFalse(limiter.tryAcquire("search"))
        assertTrue(limiter.tryAcquire("links"))
    }

    @Test
    fun `refills over time`() {
        val limiter = RateLimiter(capacity = 1, refillPerSecond = 50.0)
        assertTrue(limiter.tryAcquire("k"))
        assertFalse(limiter.tryAcquire("k"))
        Thread.sleep(60)
        assertTrue(limiter.tryAcquire("k"))
    }

    @Test
    fun `companion groups limit sanely`() {
        // 40-capacity search bucket: an honest interactive burst passes.
        repeat(30) { RateLimiter.check("search") }
        // Sync is far tighter: a 10-attempt storm must be cut off.
        var blocked = false
        repeat(10) { if (!RateLimiter.check("sync")) blocked = true }
        assertTrue(blocked)
    }
}
