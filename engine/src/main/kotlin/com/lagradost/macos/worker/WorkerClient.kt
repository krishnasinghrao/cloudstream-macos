package com.lagradost.macos.worker

import com.lagradost.macos.DaemonLog
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonElement
import java.io.BufferedInputStream
import java.io.DataInputStream
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/** A worker call failed for a reason other than the provider's own error. */
internal class WorkerFailure(val kind: Kind, message: String, val code: String? = null,
    val failure: com.lagradost.macos.models.OperationFailureDto? = null) : RuntimeException(message) {
    enum class Kind { TIMEOUT, CRASHED, ERROR }
    companion object {
        /** [code] of a CRASHED failure whose process exited on an OutOfMemoryError. */
        const val OUT_OF_MEMORY = "out_of_memory"
    }
}

/**
 * One running worker process: request multiplexing, streamed events, hard
 * deadlines (cancel, then kill after [CANCEL_GRACE_MS]) and exit detection.
 */
internal class WorkerClient(
    private val installationId: String,
    command: List<String>,
    workingDirectory: File,
    /** The worker's complete environment; the engine's own is never inherited (H1). */
    environment: Map<String, String> = WorkerLauncher.isolatedEnvironment(WorkerLauncher.canonical(workingDirectory.path)),
    /** Solves an anti-bot challenge for this worker; returns cookies or null. */
    private val solve: suspend (SolveRequest) -> String?,
    /** Has the app resolve a WebViewResolver page for this worker (RT-11); bounded by the worker's live calls. */
    private val resolveMedia: suspend (com.lagradost.macos.MediaResolveSpec) -> com.lagradost.macos.MediaResolveOutcome? = { null },
    /** Serves this worker's extension-created WebViews (RT-14). */
    private val webView: suspend (com.lagradost.macos.WebViewRequest) -> com.lagradost.macos.WebViewResponse = {
        com.lagradost.macos.WebViewResponse(alive = false)
    },
    /** Routes this worker's nested extraction to other extensions (RT-12). */
    private val extract: suspend (ExtractRequest) -> com.lagradost.macos.models.LinksResponseDto = {
        com.lagradost.macos.models.LinksResponseDto(provider = "extractor")
    },
    /** Called once when the process exits; [expected] is false for crashes and kills. */
    private val onExit: (client: WorkerClient, expected: Boolean, reason: String) -> Unit,
) {
    private class Pending(val deferred: CompletableDeferred<JsonElement>, val onEvent: ((JsonElement) -> Unit)?,
        /** Monotonic deadline of the call. */
        val deadlineAt: Long) {
        @Volatile var abandonedAt = 0L
    }

    private fun monotonicMs() = System.nanoTime() / 1_000_000

    /** Time left on the latest-ending live call: work a worker starts on its own (a challenge) must fit in it (RT-10). */
    private fun liveCallRemainingMs(): Long {
        val now = monotonicMs()
        return pending.values.filter { it.abandonedAt == 0L }.maxOfOrNull { it.deadlineAt - now } ?: 0L
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    // Cancellation/kill deadlines must not compete with bridge IO or a writer.
    private val deadlines = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val process: Process
    private val output: FrameWriter
    private val pending = ConcurrentHashMap<Long, Pending>()
    private val ids = AtomicLong(0)
    private val stopping = AtomicBoolean(false)
    private val solvesInFlight = java.util.concurrent.atomic.AtomicInteger(0)
    private val extractsInFlight = java.util.concurrent.atomic.AtomicInteger(0)
    private val exited = AtomicBoolean(false)
    private val killRequested = AtomicBoolean(false)
    @Volatile private var killReason: String? = null
    /** The process exited because its heap was exhausted (set before [onExit] runs). */
    @Volatile var outOfMemory = false
        private set
    @Volatile var lastUsed: Long = System.currentTimeMillis()
        private set

    /** Calls in flight (including abandoned calls still being cancelled). */
    val activeCalls: Int get() = pending.size
    val alive: Boolean get() = process.isAlive && !exited.get()
    val acceptingCalls: Boolean get() = alive && !stopping.get() && !killRequested.get()
    val pid: Long get() = process.pid()

    init {
        process = ProcessBuilder(command).directory(workingDirectory).apply {
            environment().clear()
            environment().putAll(environment)
        }.start()
        output = FrameWriter(process.outputStream, "worker-in-${installationId.take(8)}",
            onFailure = { kill("Protocol write failed: ${it.javaClass.simpleName}") })
        Thread({ readLoop() }, "worker-out-${installationId.take(8)}").apply { isDaemon = true }.start()
        Thread({ pumpStderr() }, "worker-err-${installationId.take(8)}").apply { isDaemon = true }.start()
        process.onExit().thenAccept { handleExit() }
    }

    /**
     * Sends a request and waits for its result. On deadline the call fails with
     * [WorkerFailure.Kind.TIMEOUT]; the worker is asked to cancel and is killed
     * if it has not answered within [CANCEL_GRACE_MS].
     */
    suspend fun call(type: String, payload: JsonElement, timeoutMs: Long, onEvent: ((JsonElement) -> Unit)? = null): JsonElement {
        require(timeoutMs > 0) { "Worker call deadline must be positive" }
        if (!acceptingCalls) throw WorkerFailure(WorkerFailure.Kind.CRASHED, killReason ?: "The extension process is not running.")
        lastUsed = System.currentTimeMillis()
        val id = ids.incrementAndGet()
        val entry = Pending(CompletableDeferred(), onEvent, monotonicMs() + timeoutMs)
        pending[id] = entry
        // handleExit sets [exited] before it drains [pending]: every interleaving
        // is either completed by that drain or sees the flag here.
        if (exited.get()) {
            pending.remove(id, entry)
            throw WorkerFailure(WorkerFailure.Kind.CRASHED, killReason ?: "The extension process is not running.")
        }
        // Arm this before serialization/enqueueing, rather than after a pipe
        // write. Deferred completion and process kill do not acquire its lock.
        val deadline = deadlines.launch {
            delay(timeoutMs)
            if (pending[id] === entry && entry.abandonedAt == 0L) {
                abandon(id, entry, "The extension did not respond within ${timeoutMs / 1000} s.")
                entry.deferred.completeExceptionally(WorkerFailure(WorkerFailure.Kind.TIMEOUT, "The extension did not respond in time."))
            }
        }
        var finished = false
        try {
            try {
                output.send(Frame(id, type, payload))
            } catch (closed: IllegalStateException) {
                // The writer closes when the process exits; report it as the crash it is.
                throw WorkerFailure(WorkerFailure.Kind.CRASHED, killReason ?: "The extension process is not running.")
            }
            val result = entry.deferred.await()
            finished = true
            return result
        } catch (cancelled: CancellationException) {
            if (!finished) abandon(id, entry, "cancelled")
            throw cancelled
        } finally {
            deadline.cancel()
            lastUsed = System.currentTimeMillis()
            if (finished || entry.abandonedAt == 0L) pending.remove(id, entry)
        }
    }

    /** Asks the worker to stop [id]; kills the process if it keeps running past the grace period. */
    private fun abandon(id: Long, entry: Pending, reason: String) {
        synchronized(entry) {
            if (pending[id] !== entry || entry.abandonedAt != 0L) return
            entry.abandonedAt = monotonicMs()
        }
        deadlines.launch {
            delay(CANCEL_GRACE_MS)
            if (pending[id] === entry) kill("A call ignored cancellation ($reason)")
        }
        runCatching { send(Frame(0, Op.CANCEL, FrameCodec.json.encodeToJsonElement(CancelRequest.serializer(), CancelRequest(id)))) }
    }

    fun kill(reason: String) {
        if (!process.isAlive || !killRequested.compareAndSet(false, true)) return
        killReason = reason
        DaemonLog.warn("worker.killed", mapOf("installation" to installationId, "reason" to reason))
        // Process.destroyForcibly also closes streams. A ProcessHandle sends
        // the signal without waiting for a buffered writer's monitor.
        process.toHandle().destroyForcibly()
    }

    /** Orderly stop: shutdown frame, then force after a short wait. Never blocks the caller long. */
    fun stop() {
        if (!stopping.compareAndSet(false, true)) return
        deadlines.launch {
            delay(STOP_WAIT_MS)
            if (process.isAlive) process.toHandle().destroyForcibly()
        }
        runCatching { send(Frame(0, Op.SHUTDOWN)) }
    }

    private fun send(frame: Frame) = output.send(frame)

    private fun readLoop() {
        val input = DataInputStream(BufferedInputStream(process.inputStream))
        try {
            while (true) {
                val frame = FrameCodec.read(input) ?: break
                when {
                    frame.type == Op.SOLVE && frame.id < 0 -> scope.launch { answerSolve(frame) }
                    frame.type == Op.EXTRACT && frame.id < 0 -> scope.launch { answerExtract(frame) }
                    frame.type == Op.MEDIA && frame.id < 0 -> scope.launch { answerMedia(frame) }
                    frame.type == Op.WEBVIEW && frame.id < 0 -> scope.launch { answerWebView(frame) }
                    frame.type == Op.EVENT -> pending[frame.id]?.takeIf { it.abandonedAt == 0L }?.onEvent?.let { handler ->
                        runCatching { handler(frame.payload) }.onFailure {
                            if (it is com.lagradost.macos.RejectedMediaResourceException) {
                                // Preserve the terminal resource rejection before
                                // retiring the sender; do not relabel it as a
                                // retryable worker crash or expose raw values.
                                pending.remove(frame.id)?.deferred?.completeExceptionally(it)
                            }
                            kill("Invalid event from extension: ${it.javaClass.simpleName}")
                        }
                    }
                    frame.type == Op.RESULT -> pending.remove(frame.id)?.deferred?.complete(frame.payload)
                    frame.type == Op.ERROR -> pending.remove(frame.id)?.deferred?.completeExceptionally(
                        WorkerFailure(WorkerFailure.Kind.ERROR, frame.failure?.publicMessage ?: frame.error?.take(2000) ?: "Extension error", frame.code, frame.failure))
                    else -> kill("Unexpected frame '${frame.type.take(32)}'")
                }
            }
        } catch (failure: Exception) {
            if (!stopping.get()) kill("Protocol error: ${failure.javaClass.simpleName}")
        }
    }

    private suspend fun answerSolve(frame: Frame) {
        val request = runCatching { FrameCodec.json.decodeFromJsonElement(SolveRequest.serializer(), frame.payload) }.getOrNull()
        if (solvesInFlight.incrementAndGet() > MAX_SOLVES) {
            solvesInFlight.decrementAndGet()
            runCatching { send(Frame(frame.id, Op.ERROR, error = "Too many pending challenges")) }
            return
        }
        try {
            // A challenge outliving every call that could use it would only hold a solver slot.
            val budget = liveCallRemainingMs()
            val cookies = if (request == null || budget < MIN_SOLVE_BUDGET_MS) null else try {
                withTimeoutOrNull(budget) { solve(request) }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) { null }
            send(Frame(frame.id, Op.RESULT, FrameCodec.json.encodeToJsonElement(SolveResult.serializer(), SolveResult(cookies))))
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
        } finally { solvesInFlight.decrementAndGet() }
    }

    /** Pages resolved at once for this worker; further requests wait their turn within their deadline. */
    private val mediaSlots = kotlinx.coroutines.sync.Semaphore(MAX_MEDIA)

    private suspend fun answerMedia(frame: Frame) {
        val spec = runCatching { FrameCodec.json.decodeFromJsonElement(com.lagradost.macos.MediaResolveSpec.serializer(), frame.payload) }.getOrNull()
        val budget = liveCallRemainingMs()
        if (spec == null || budget < MIN_SOLVE_BUDGET_MS) {
            // A page load outside any call, or with no time left, could not reach anyone.
            runCatching { send(Frame(frame.id, Op.ERROR, error = "Page resolution refused", code = if (spec == null) "invalid" else "no_live_call")) }
            return
        }
        val started = monotonicMs()
        val admitted = withTimeoutOrNull(budget - MIN_SOLVE_BUDGET_MS) { mediaSlots.acquire() } != null
        if (!admitted) {
            runCatching { send(Frame(frame.id, Op.ERROR, error = "Page resolution refused", code = "capacity")) }
            return
        }
        try {
            val remaining = budget - (monotonicMs() - started) - com.lagradost.macos.OperationBudget.WORKER_MARGIN_MS
            // A page load may not outlive every call that could use its result.
            val outcome = resolveMedia(spec.copy(timeoutMs = minOf(spec.timeoutMs, remaining.coerceAtLeast(1_000))))
            runCatching {
                send(Frame(frame.id, Op.RESULT, outcome?.let {
                    FrameCodec.json.encodeToJsonElement(com.lagradost.macos.MediaResolveOutcome.serializer(), it)
                } ?: kotlinx.serialization.json.JsonNull))
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            val code = if (failure is com.lagradost.macos.WorkerCapacityException) "capacity" else "provider_failure"
            runCatching { send(Frame(frame.id, Op.ERROR, error = "Page resolution failed", code = code)) }
        } finally { mediaSlots.release() }
    }

    private val webViewsInFlight = java.util.concurrent.atomic.AtomicInteger(0)

    /** Sessions are bounded by WebViewSessionBridge; this bounds one worker's requests in flight. */
    private suspend fun answerWebView(frame: Frame) {
        val request = runCatching { FrameCodec.json.decodeFromJsonElement(com.lagradost.macos.WebViewRequest.serializer(), frame.payload) }.getOrNull()
        if (request == null || webViewsInFlight.incrementAndGet() > MAX_WEBVIEW) {
            if (request != null) webViewsInFlight.decrementAndGet()
            runCatching { send(Frame(frame.id, Op.ERROR, error = "WebView request refused", code = if (request == null) "invalid" else "capacity")) }
            return
        }
        try {
            val response = webView(request)
            runCatching { send(Frame(frame.id, Op.RESULT, FrameCodec.json.encodeToJsonElement(com.lagradost.macos.WebViewResponse.serializer(), response))) }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            val code = if (failure is com.lagradost.macos.WorkerCapacityException) "capacity" else "provider_failure"
            runCatching { send(Frame(frame.id, Op.ERROR, error = "WebView request failed", code = code)) }
        } finally { webViewsInFlight.decrementAndGet() }
    }

    private suspend fun answerExtract(frame: Frame) {
        val request = runCatching { FrameCodec.json.decodeFromJsonElement(ExtractRequest.serializer(), frame.payload) }.getOrNull()
        if (request == null || extractsInFlight.incrementAndGet() > MAX_NESTED_EXTRACTS) {
            if (request != null) extractsInFlight.decrementAndGet()
            runCatching { send(Frame(frame.id, Op.ERROR, error = "Extraction request refused", code = "capacity")) }
            return
        }
        try {
            val response = extract(request)
            runCatching {
                send(Frame(frame.id, Op.RESULT, FrameCodec.json.encodeToJsonElement(com.lagradost.macos.models.LinksResponseDto.serializer(), response)))
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            runCatching { send(Frame(frame.id, Op.ERROR, error = "Extraction failed", code = "provider_failure")) }
        } finally { extractsInFlight.decrementAndGet() }
    }

    /**
     * Extension stderr is untrusted and often carries tokens (L1). By default
     * only a per-minute line count is recorded; with [verboseStderr] each line
     * is kept, redacted at write time by [DaemonLog].
     */
    private fun pumpStderr() {
        val window = LongArray(3) // [windowStart, linesInWindow, suppressedInWindow]
        fun flushSuppressed() {
            if (window[2] > 0) DaemonLog.debug("worker.stderr_suppressed", mapOf("installation" to installationId, "lines" to window[2]))
            window[2] = 0
        }
        process.errorStream.bufferedReader().useLines { lines ->
            lines.forEach { line ->
                // The sandbox denies CFPreferences reads by design; macOS logs each one.
                if ("Couldn't read values in CFPrefsPlistSource" in line) return@forEach
                val now = System.currentTimeMillis()
                if (now - window[0] > 60_000) { flushSuppressed(); window[0] = now; window[1] = 0 }
                if (verboseStderr && ++window[1] <= STDERR_LINES_PER_MINUTE) {
                    DaemonLog.debug("worker.stderr", mapOf("installation" to installationId, "line" to line.take(500)))
                } else window[2]++
            }
        }
        flushSuppressed()
    }

    private fun handleExit() {
        if (!exited.compareAndSet(false, true)) return
        val code = runCatching { process.exitValue() }.getOrNull()
        // The engine stops workers with a shutdown frame or SIGKILL, never
        // SIGTERM: a SIGTERM exit (143) is the system or the app ending the
        // whole process group at shutdown, not a crash of the extension.
        val terminated = killReason == null && code == SIGTERM_EXIT
        val expected = (stopping.get() || terminated) && killReason == null
        outOfMemory = killReason == null && code == OUT_OF_MEMORY_EXIT
        val reason = killReason ?: when {
            terminated -> "The extension process was stopped by the system."
            expected -> "stopped"
            outOfMemory -> "The extension ran out of memory."
            else -> "The extension process exited (code $code)."
        }
        val failureCode = if (outOfMemory) WorkerFailure.OUT_OF_MEMORY else null
        // Remove-then-complete per key: an entry added mid-drain is either seen
        // here or sees [exited] in call(); none is cleared without completing.
        for (key in pending.keys.toList()) {
            pending.remove(key)?.deferred?.completeExceptionally(WorkerFailure(WorkerFailure.Kind.CRASHED, reason, failureCode))
        }
        scope.cancel()
        deadlines.cancel()
        output.close()
        onExit(this, expected, reason)
    }

    companion object {
        /**
         * Opt-in for keeping extension stderr lines in the engine log
         * (`-Dcs.extensionLogs=verbose`, for extension developers).
         */
        @Volatile var verboseStderr: Boolean = System.getProperty("cs.extensionLogs") == "verbose"
        const val CANCEL_GRACE_MS = 3_000L
        /** 128 + SIGTERM: how the JVM reports termination by that signal. */
        internal const val SIGTERM_EXIT = 143
        /** How the JVM exits under `-XX:+ExitOnOutOfMemoryError`. */
        internal const val OUT_OF_MEMORY_EXIT = 3
        private const val STOP_WAIT_MS = 2_000L
        private const val STDERR_LINES_PER_MINUTE = 60L
        private const val MAX_SOLVES = 4
        private const val MIN_SOLVE_BUDGET_MS = 2_000L
        /** Nested extractions one worker may have in flight (RT-12). */
        const val MAX_NESTED_EXTRACTS = 4
        /** WebViewResolver pages one worker may have open (RT-11). */
        const val MAX_MEDIA = 2
        /** A poll per session (four per installation) plus commands. */
        const val MAX_WEBVIEW = 8
    }
}
