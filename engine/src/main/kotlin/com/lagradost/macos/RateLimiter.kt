package com.lagradost.macos

import java.util.concurrent.ConcurrentHashMap

/**
 * Token-bucket rate limiting for IPC endpoints (plan WS-4.3).
 *
 * Bounds runaway clients: a UI bug or a retry storm cannot turn the daemon
 * into a scraping hammer. Buckets are per endpoint-group; capacity is
 * generous for legitimate interactive use.
 */
class RateLimiter(
    private val capacity: Int,
    private val refillPerSecond: Double,
) {
    private class Bucket(var tokens: Double, var lastRefillNanos: Long)

    private val buckets = ConcurrentHashMap<String, Bucket>()

    /** Returns true when the call is allowed. */
    fun tryAcquire(key: String): Boolean {
        val now = System.nanoTime()
        val bucket = buckets.computeIfAbsent(key) { Bucket(capacity.toDouble(), now) }
        synchronized(bucket) {
            val elapsedSeconds = (now - bucket.lastRefillNanos) / 1_000_000_000.0
            bucket.tokens = minOf(capacity.toDouble(), bucket.tokens + elapsedSeconds * refillPerSecond)
            bucket.lastRefillNanos = now
            if (bucket.tokens >= 1.0) {
                bucket.tokens -= 1.0
                return true
            }
            return false
        }
    }

    companion object {
        private val limiters = mapOf(
            "search" to RateLimiter(capacity = 40, refillPerSecond = 20.0),
            "home" to RateLimiter(capacity = 20, refillPerSecond = 10.0),
            "details" to RateLimiter(capacity = 60, refillPerSecond = 30.0),
            "links" to RateLimiter(capacity = 60, refillPerSecond = 30.0),
            "sync" to RateLimiter(capacity = 4, refillPerSecond = 0.5),
            "solve" to RateLimiter(capacity = 10, refillPerSecond = 5.0),
            "write" to RateLimiter(capacity = 20, refillPerSecond = 10.0),
            // Connectivity / provider test runs fan out to every provider.
            "diagnose" to RateLimiter(capacity = 3, refillPerSecond = 0.1),
        )

        fun check(group: String): Boolean =
            limiters[group]?.tryAcquire(group) ?: true

        /** Tests only: buckets are process-wide, so one test's calls must not throttle the next. */
        internal fun resetForTest() = limiters.values.forEach { it.buckets.clear() }
    }
}
