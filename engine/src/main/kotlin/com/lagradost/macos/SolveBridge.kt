package com.lagradost.macos

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withTimeoutOrNull
import java.net.URI
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Anti-bot clearance bridge between the Kotlin daemon and the Swift
 * `WebViewSolverService` (Architecture.md §5.2, plan WS-1.3).
 *
 * Flow:
 * 1. `SolveInterceptor` (on the OkHttp clients providers use) detects a
 *    challenge (403/503 + Cloudflare markers) and registers a pending task,
 *    parking the request.
 * 2. The Swift client polls `GET /solve/pending`, runs the URL through an
 *    offscreen WKWebView, and POSTs the clearance cookies to
 *    `/solve-callback`.
 * 3. The interceptor retries the original request with the cookies; they also
 *    stay cached per host for subsequent requests.
 *
 * Cookies live in-memory only (SEC-02 posture: no credential-like data on
 * disk). Metrics track created/solved tasks for /diagnostics.
 */
object SolveBridge {
    data class SolvedChallenge(val taskId: String, val cookies: String)

    data class PendingTask(
        val taskId: String,
        val targetUrl: String,
        val createdAt: Long,
        val deferred: CompletableDeferred<SolvedChallenge>,
        /** The challenged request's User-Agent: clearance is bound to it, so the solver must use it too. */
        val userAgent: String? = null,
        /**
         * False for a worker's challenge: its cookies go back to that worker only
         * and never into the engine's shared cache, which engine-side and
         * repository requests read (L3).
         */
        val shared: Boolean = true,
    ) {
        val ageMs: Long get() = System.currentTimeMillis() - createdAt
    }

    private val pending = ConcurrentHashMap<String, PendingTask>()

    /** Set in worker processes: forwards a challenge to the control plane and returns clearance cookies. */
    @Volatile var remoteSolver: (suspend (targetUrl: String, userAgent: String?) -> String?)? = null

    /** Control plane: solves a challenge on behalf of a worker. Cookies go only to the requester (not the shared cache). */
    suspend fun solveForWorker(targetUrl: String, userAgent: String? = null): String? {
        val task = newTask(targetUrl, userAgent, shared = false)
        val solution = awaitSolution(task) ?: return null
        return solution.cookies
    }

    private data class CookieEntry(val header: String, val expiresAt: Long)
    private val solvedCookies = object : LinkedHashMap<String, CookieEntry>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, CookieEntry>?): Boolean = size > 128
    }
    private const val SOLVE_TIMEOUT_MS = 90_000L
    private const val COOKIE_LIFETIME_MS = 5 * 60_000L
    private const val MAX_PENDING = 32

    fun newTask(targetUrl: String, userAgent: String? = null, shared: Boolean = true): PendingTask = synchronized(pending) {
        require(origin(targetUrl) != null) { "Challenge target must be an HTTPS URL" }
        listPending()
        check(pending.size < MAX_PENDING) { "Too many pending challenges" }
        val taskId = UUID.randomUUID().toString()
        val agent = userAgent?.takeIf { it.length <= 512 && it.none { c -> c < ' ' || c == '\u007f' } }
        val task = PendingTask(taskId, targetUrl, System.currentTimeMillis(), CompletableDeferred(), agent, shared)
        pending[taskId] = task
        Metrics.recordSolveCreated()
        DaemonLog.info("solve.parked", mapOf("taskId" to taskId))
        PendingSignal.parked()
        task
    }

    fun listPending(): List<PendingTask> {
        pending.values.filter { it.ageMs > SOLVE_TIMEOUT_MS }.forEach { cancel(it) }
        return pending.values.sortedBy { it.createdAt }
    }

    /** A callback can only solve its original target, never populate another origin. */
    fun complete(taskId: String, targetUrl: String?, cookies: String): Boolean = synchronized(pending) {
        if (!validCookieHeader(cookies)) return false
        val task = pending[taskId] ?: return false
        if (targetUrl != null && targetUrl != task.targetUrl) return false
        if (task.ageMs > SOLVE_TIMEOUT_MS) { cancel(task); return false }
        val origin = origin(task.targetUrl) ?: return false
        if (!task.deferred.complete(SolvedChallenge(taskId, cookies))) return false
        pending.remove(taskId, task)
        if (task.shared) cache(origin, cookies)
        Metrics.recordSolveSolved()
        DaemonLog.info("solve.completed", mapOf("taskId" to taskId))
        true
    }

    suspend fun awaitSolution(task: PendingTask): SolvedChallenge? = try {
        withTimeoutOrNull(SOLVE_TIMEOUT_MS) {
            // A task cancelled by clearCachedCookies (app locked) ends as unsolved,
            // never as a CancellationException escaping into an OkHttp interceptor.
            try { task.deferred.await() } catch (e: kotlinx.coroutines.CancellationException) {
                if (task.deferred.isCancelled && isActive) null else throw e
            }
        }
    } finally {
        cancel(task)
    }

    fun cancel(task: PendingTask) {
        pending.remove(task.taskId, task)
        task.deferred.cancel()
    }

    fun cookieHeaderFor(url: String): String? {
        val key = origin(url) ?: return null
        return synchronized(solvedCookies) {
            val entry = solvedCookies[key] ?: return@synchronized null
            if (entry.expiresAt <= System.currentTimeMillis()) {
                solvedCookies.remove(key)
                null
            } else entry.header
        }
    }

    private const val REJECTED_FOR_MS = 10 * 60_000L
    /** Origins whose fresh clearance was still challenged, until when. */
    private val rejected = ConcurrentHashMap<String, Long>()

    /** The site challenged a request that carried a fresh clearance: stop solving it for a while. */
    fun rejectClearance(url: String) {
        val key = origin(url) ?: return
        rejected[key] = System.currentTimeMillis() + REJECTED_FOR_MS
        synchronized(solvedCookies) { solvedCookies.remove(key) }
    }

    fun clearanceRejected(url: String): Boolean {
        val key = origin(url) ?: return false
        val until = rejected[key] ?: return false
        if (until > System.currentTimeMillis()) return true
        rejected.remove(key, until)
        return false
    }

    /** SEC-08: Purges cached clearance cookies and cancels pending solve tasks when app is locked. */
    fun clearCachedCookies() {
        synchronized(solvedCookies) {
            solvedCookies.clear()
        }
        rejected.clear()
        synchronized(pending) {
            pending.values.forEach { it.deferred.cancel() }
            pending.clear()
        }
    }

    internal fun applySolvedCookies(targetUrl: String, cookies: String) {
        require(validCookieHeader(cookies)) { "Invalid clearance cookie header" }
        val key = requireNotNull(origin(targetUrl)) { "Challenge target must use HTTPS" }
        cache(key, cookies)
    }

    private fun cache(origin: String, cookies: String) = synchronized(solvedCookies) {
        solvedCookies[origin] = CookieEntry(cookies, System.currentTimeMillis() + COOKIE_LIFETIME_MS)
    }

    internal fun validCookieHeader(value: String): Boolean =
        value.isNotBlank() && value.length <= 4096 && value.all { it.code in 32..126 } &&
            value.split(';').map { it.trim() }.filter { it.isNotEmpty() }.let { parts ->
                parts.isNotEmpty() && parts.all { part ->
                    val pair = part.split('=', limit = 2)
                    pair.size == 2 && pair[0].matches(Regex("[!#$%&'*+.^_`|~0-9A-Za-z-]+"))
                }
            }

    private fun origin(url: String): String? = try {
        val uri = URI(url)
        val host = uri.host?.lowercase()
        if (!uri.scheme.equals("https", true) || host == null || uri.userInfo != null) null
        else "https://$host:${if (uri.port == -1) 443 else uri.port}"
    } catch (_: Exception) { null }
}
