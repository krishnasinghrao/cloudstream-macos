package com.lagradost.macos

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Lets the app long-poll `GET /solve/pending` and `GET /media/pending`
 * instead of asking every few seconds: a request with `waitMs` is held until
 * a challenge or page is parked (or the wait ends), so an idle app and engine
 * do not wake each other up.
 */
internal object PendingSignal {
    /** Longest a request may be held; the app's request timeout is longer. */
    const val MAX_WAIT_MS = 25_000L

    private val version = MutableStateFlow(0L)

    /** Called whenever a task is parked for the app. */
    fun parked() { version.value++ }

    /**
     * Returns [list]'s result once it is non-empty, or after [waitMs] (capped
     * at [MAX_WAIT_MS]) with whatever it then holds. A version read before
     * listing means a task parked in between is never missed.
     */
    suspend fun <T> awaitNonEmpty(waitMs: Long, list: () -> List<T>): List<T> {
        val deadline = System.currentTimeMillis() + waitMs.coerceIn(0, MAX_WAIT_MS)
        while (true) {
            val seen = version.value
            val items = list()
            val remaining = deadline - System.currentTimeMillis()
            if (items.isNotEmpty() || remaining <= 0) return items
            withTimeoutOrNull(remaining) { version.first { it != seen } } ?: return list()
        }
    }
}
