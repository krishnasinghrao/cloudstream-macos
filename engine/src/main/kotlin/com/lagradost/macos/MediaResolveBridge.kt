package com.lagradost.macos

import com.lagradost.cloudstream3.network.WebViewHostMatch
import com.lagradost.cloudstream3.network.WebViewHostRequest
import com.lagradost.cloudstream3.network.WebViewHostResult
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.Serializable
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.regex.Pattern

/** A regex as the extension built it: JVM pattern and flags (Kotlin `Regex` options map onto them). */
@Serializable
data class PatternSpec(val pattern: String, val flags: Int = 0)

/** What an extension's `WebViewResolver` asked to load (plan RT-11). Crosses the worker protocol. */
@Serializable
data class MediaResolveSpec(
    val url: String,
    val method: String = "GET",
    val headers: Map<String, String> = emptyMap(),
    val intercept: PatternSpec,
    val additional: List<PatternSpec> = emptyList(),
    val userAgent: String? = null,
    val script: String? = null,
    val timeoutMs: Long = 60_000,
)

@Serializable
data class MediaMatchDto(val url: String, val method: String = "GET", val headers: Map<String, String> = emptyMap())

@Serializable
data class MediaResolveOutcome(
    val intercepted: MediaMatchDto? = null,
    val additional: List<MediaMatchDto> = emptyList(),
    val scriptResult: String? = null,
)

/** A page the app should load, as returned by `GET /media/pending`. */
@Serializable
data class MediaPendingDto(
    val taskId: String,
    val url: String,
    val method: String,
    val headers: Map<String, String>,
    val userAgent: String?,
    val script: String?,
    val timeoutMs: Long,
    val ageMs: Long,
)

@Serializable
data class MediaObservedRequestDto(val url: String, val method: String = "GET")

@Serializable
data class MediaObserveRequestDto(val taskId: String, val requests: List<MediaObservedRequestDto>)

@Serializable
data class MediaObserveResponseDto(val known: Boolean, val stop: Boolean)

@Serializable
data class MediaCompleteRequestDto(
    val taskId: String,
    val scriptResult: String? = null,
    /** Host → cookie header from the page's own (ephemeral) cookie store. */
    val cookies: Map<String, String> = emptyMap(),
    val userAgent: String? = null,
    val pageUrl: String? = null,
)

/**
 * Native JavaScript media resolution (plan RT-11). An extension's
 * `WebViewResolver` becomes a task the macOS app runs in an offscreen WebKit
 * view with ephemeral website data. The app reports every request the page
 * makes; the engine matches them against the extension's patterns (so the
 * app never needs Kotlin regex semantics) and tells the app to stop at the
 * intercept match. Everything the app reports is untrusted and bounded.
 */
internal object MediaResolveBridge {
    const val MAX_PENDING = 8
    const val MAX_TIMEOUT_MS = 120_000L
    private const val MAX_URL = 8_192
    private const val MAX_PATTERNS = 32
    private const val MAX_PATTERN_LENGTH = 2_000
    private const val MAX_OBSERVED = 5_000
    private const val MAX_ADDITIONAL = 200
    private const val MAX_SCRIPT_RESULT = 1_000_000
    private const val MATCH_BUDGET_MS = 50L

    private class Task(
        val id: String,
        val spec: MediaResolveSpec,
        val intercept: Pattern,
        val additional: List<Pattern>,
        val createdAt: Long = System.currentTimeMillis(),
    ) {
        val done = CompletableDeferred<MediaCompleteRequestDto?>()
        val seen = HashSet<String>()
        var intercepted: MediaObservedRequestDto? = null
        val extra = mutableListOf<MediaObservedRequestDto>()
    }

    private val tasks = ConcurrentHashMap<String, Task>()

    /**
     * Parks [spec] for the app and waits (bounded) for it. Returns what matched
     * — possibly only additional URLs when the page never reached the intercept
     * pattern, as Android returns on timeout — or null when nothing ran.
     */
    suspend fun resolve(spec: MediaResolveSpec): MediaResolveOutcome? {
        val target = runCatching { java.net.URI(spec.url) }.getOrNull()
        require(spec.url.length <= MAX_URL && target?.scheme?.lowercase() in setOf("http", "https") && target?.host != null) {
            "WebViewResolver needs an http(s) URL"
        }
        require(spec.method.uppercase() in setOf("GET", "POST")) { "Unsupported WebViewResolver method" }
        require(spec.additional.size <= MAX_PATTERNS && spec.headers.size <= 32) { "Too many WebViewResolver patterns or headers" }
        val task = Task(UUID.randomUUID().toString(), spec.copy(
            // Header values go to the app's web view: no control characters (request splitting), bounded length.
            headers = spec.headers.filter { (name, value) ->
                name.matches(HEADER_NAME) && !name.equals("host", true) && value.length <= 4_000 && value.none { it < ' ' || it == '\u007f' }
            },
            userAgent = spec.userAgent?.take(512)?.takeIf { it.none { c -> c < ' ' || c == '\u007f' } }, script = spec.script?.take(100_000),
            timeoutMs = spec.timeoutMs.coerceIn(1_000, MAX_TIMEOUT_MS),
        ), compile(spec.intercept), spec.additional.map(::compile))
        synchronized(tasks) {
            if (tasks.size >= MAX_PENDING) throw WorkerCapacityException()
            tasks[task.id] = task
        }
        PendingSignal.parked()
        try {
            val completion = withTimeoutOrNull(task.spec.timeoutMs) { task.done.await() }
            return outcome(task, completion)
        } finally {
            tasks.remove(task.id)
        }
    }

    private fun compile(spec: PatternSpec): Pattern {
        require(spec.pattern.length <= MAX_PATTERN_LENGTH) { "WebViewResolver pattern is too long" }
        // Only the flags Kotlin Regex options produce.
        return Pattern.compile(spec.pattern, spec.flags and ALLOWED_FLAGS)
    }

    fun pending(): List<MediaPendingDto> {
        val now = System.currentTimeMillis()
        return tasks.values.filter { !it.done.isCompleted }.sortedBy { it.createdAt }.map {
            MediaPendingDto(it.id, it.spec.url, it.spec.method.uppercase(), it.spec.headers, it.spec.userAgent, it.spec.script,
                it.spec.timeoutMs - (now - it.createdAt), now - it.createdAt)
        }
    }

    /** Records requests the page made; true in `stop` once the intercept pattern matched. */
    fun observe(request: MediaObserveRequestDto): MediaObserveResponseDto {
        val task = tasks[request.taskId] ?: return MediaObserveResponseDto(known = false, stop = true)
        synchronized(task) {
            for (observed in request.requests.take(500)) {
                if (task.intercepted != null || task.seen.size >= MAX_OBSERVED) break
                val url = observed.url
                if (url.length > MAX_URL || !(url.startsWith("http://", true) || url.startsWith("https://", true))) continue
                if (!task.seen.add(url)) continue
                val method = observed.method.uppercase().takeIf { it.matches(METHOD) } ?: "GET"
                if (matches(task.intercept, url)) task.intercepted = MediaObservedRequestDto(url, method)
                else if (task.extra.size < MAX_ADDITIONAL && task.additional.any { matches(it, url) }) task.extra += MediaObservedRequestDto(url, method)
            }
            return MediaObserveResponseDto(known = true, stop = task.intercepted != null)
        }
    }

    /** The app finished the page (stopped, loaded or timed out). False for an unknown task. */
    fun complete(request: MediaCompleteRequestDto): Boolean {
        val task = tasks[request.taskId] ?: return false
        return task.done.complete(request)
    }

    private fun outcome(task: Task, completion: MediaCompleteRequestDto?): MediaResolveOutcome? {
        val (intercepted, extra) = synchronized(task) { task.intercepted to task.extra.toList() }
        if (completion == null && intercepted == null && extra.isEmpty()) return null
        val pageUrl = completion?.pageUrl?.takeIf { it.length <= MAX_URL && (it.startsWith("https://") || it.startsWith("http://")) } ?: task.spec.url
        val userAgent = (completion?.userAgent ?: task.spec.userAgent)?.take(512)?.takeIf { it.none { c -> c < ' ' } }
        val cookies = completion?.cookies.orEmpty().entries.take(16)
            .filter { (host, value) -> host.length <= 253 && value.length <= 8_000 && value.none { it < ' ' || it.code > 126 } }
            .associate { it.key.lowercase() to it.value }
        fun headers(url: String): Map<String, String> = buildMap {
            put("Referer", pageUrl)
            userAgent?.let { put("User-Agent", it) }
            val host = runCatching { java.net.URI(url).host?.lowercase() }.getOrNull()
            host?.let { cookies[it] }?.let { put("Cookie", it) }
        }
        return MediaResolveOutcome(
            intercepted = intercepted?.let { MediaMatchDto(it.url, it.method, headers(it.url)) },
            additional = extra.map { MediaMatchDto(it.url, it.method, headers(it.url)) },
            scriptResult = completion?.scriptResult?.take(MAX_SCRIPT_RESULT),
        )
    }

    /** Pattern matching with a time budget: an extension's pattern must not hang the engine on a crafted URL. */
    private fun matches(pattern: Pattern, url: String): Boolean = try {
        pattern.matcher(DeadlineCharSequence(url, System.nanoTime() + MATCH_BUDGET_MS * 1_000_000)).find()
    } catch (_: MatchTimeout) { false }

    private class MatchTimeout : RuntimeException(null, null, false, false)

    private class DeadlineCharSequence(private val text: CharSequence, private val deadline: Long) : CharSequence {
        override val length: Int get() = text.length
        override fun get(index: Int): Char {
            if (System.nanoTime() > deadline) throw MatchTimeout()
            return text[index]
        }
        override fun subSequence(startIndex: Int, endIndex: Int): CharSequence = DeadlineCharSequence(text.subSequence(startIndex, endIndex), deadline)
        override fun toString(): String = text.toString()
    }

    // ---- extension side (worker or in-process)

    /** The extension's request as it crosses to the engine. */
    fun spec(request: WebViewHostRequest, remainingMs: Long = MAX_TIMEOUT_MS) = MediaResolveSpec(
        url = request.url, method = request.method, headers = request.headers,
        intercept = PatternSpec(request.interceptUrl.pattern, request.interceptUrl.toPattern().flags()),
        additional = request.additionalUrls.map { PatternSpec(it.pattern, it.toPattern().flags()) },
        userAgent = request.userAgent, script = request.script,
        timeoutMs = request.timeoutMs.coerceAtMost(remainingMs),
    )

    fun hostResult(outcome: MediaResolveOutcome): WebViewHostResult = WebViewHostResult(
        intercepted = outcome.intercepted?.let { WebViewHostMatch(it.url, it.method, it.headers) },
        additional = outcome.additional.map { WebViewHostMatch(it.url, it.method, it.headers) },
        scriptResult = outcome.scriptResult,
    )

    /** Control plane (in-process providers): resolve directly through the app. */
    fun install() {
        com.lagradost.cloudstream3.network.WebViewHost.resolver = { request -> resolve(spec(request))?.let(::hostResult) }
    }

    /** Tests only. */
    internal fun clearForTest() = tasks.values.toList().forEach { it.done.complete(null); tasks.remove(it.id) }

    private val HEADER_NAME = Regex("[A-Za-z0-9!#$%&'*+.^_`|~-]{1,64}")
    private val METHOD = Regex("[A-Z]{3,7}")
    private const val ALLOWED_FLAGS = Pattern.CASE_INSENSITIVE or Pattern.MULTILINE or Pattern.DOTALL or
        Pattern.COMMENTS or Pattern.UNICODE_CASE or Pattern.LITERAL or Pattern.CANON_EQ
}
