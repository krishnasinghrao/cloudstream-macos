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

    private val defaultVersion = MutableStateFlow(0L)
    private val solveVersion = MutableStateFlow(0L)
    private val mediaVersion = MutableStateFlow(0L)
    private val webviewVersion = MutableStateFlow(0L)

    /** Called whenever a solve challenge task is parked for the app. */
    fun parkedSolve() {
        solveVersion.value++
        defaultVersion.value++
    }

    /** Called whenever a media resolution task is parked for the app. */
    fun parkedMedia() {
        mediaVersion.value++
        defaultVersion.value++
    }

    /** Called whenever a webview command is parked for the app. */
    fun parkedWebView() {
        webviewVersion.value++
        defaultVersion.value++
    }

    /** Called whenever a task is parked for the app (wakes all endpoints). */
    fun parked() {
        defaultVersion.value++
        solveVersion.value++
        mediaVersion.value++
        webviewVersion.value++
    }

    /** Await pending solve challenge tasks. */
    suspend fun <T> awaitSolve(waitMs: Long, list: () -> List<T>): List<T> =
        awaitNonEmptyFlow(solveVersion, waitMs, list)

    /** Await pending media resolution tasks. */
    suspend fun <T> awaitMedia(waitMs: Long, list: () -> List<T>): List<T> =
        awaitNonEmptyFlow(mediaVersion, waitMs, list)

    /** Await pending webview session tasks. */
    suspend fun <T> awaitWebView(waitMs: Long, list: () -> List<T>): List<T> =
        awaitNonEmptyFlow(webviewVersion, waitMs, list)

    /**
     * Returns [list]'s result once it is non-empty, or after [waitMs] (capped
     * at [MAX_WAIT_MS]) with whatever it then holds. A version read before
     * listing means a task parked in between is never missed.
     */
    suspend fun <T> awaitNonEmpty(waitMs: Long, list: () -> List<T>): List<T> =
        awaitNonEmptyFlow(defaultVersion, waitMs, list)

    private suspend fun <T> awaitNonEmptyFlow(flow: MutableStateFlow<Long>, waitMs: Long, list: () -> List<T>): List<T> {
        val deadline = System.currentTimeMillis() + waitMs.coerceIn(0, MAX_WAIT_MS)
        while (true) {
            val seen = flow.value
            val items = list()
            val remaining = deadline - System.currentTimeMillis()
            if (items.isNotEmpty() || remaining <= 0) return items
            withTimeoutOrNull(remaining) { flow.first { it != seen } } ?: return list()
        }
    }
}
