package com.lagradost.macos

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.Serializable
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/** What an extension's `android.webkit.WebView` asks for. Crosses the worker protocol. */
@Serializable
data class WebViewRequest(
    val session: String,
    /** `load`, `eval`, `poll` or `destroy`. */
    val op: String,
    val url: String? = null,
    val html: String? = null,
    val baseUrl: String? = null,
    val script: String? = null,
    val userAgent: String? = null,
    /** Names registered with addJavascriptInterface; the page gets a proxy object per name. */
    val interfaces: List<String> = emptyList(),
)

/** Something the page did that the extension must hear about. */
@Serializable
data class WebViewEvent(
    /** `finished` (page loaded) or `call` (page script called a JavaScript interface method). */
    val kind: String,
    val url: String? = null,
    val name: String? = null,
    val method: String? = null,
    val args: List<String> = emptyList(),
)

@Serializable
data class WebViewResponse(
    /** JSON-encoded script result for `eval`, as Android's evaluateJavascript reports it. */
    val result: String? = null,
    val events: List<WebViewEvent> = emptyList(),
    /** False when the session no longer exists (expired, destroyed or refused). */
    val alive: Boolean = true,
)

/** A command for the app, from `GET /webview/pending`. */
@Serializable
data class WebViewCommandDto(
    val commandId: String,
    val session: String,
    val op: String,
    val url: String? = null,
    val html: String? = null,
    val baseUrl: String? = null,
    val script: String? = null,
    val userAgent: String? = null,
    val interfaces: List<String> = emptyList(),
)

@Serializable
data class WebViewResultDto(val commandId: String, val result: String? = null, val error: String? = null)

@Serializable
data class WebViewEventDto(val session: String, val event: WebViewEvent)

/**
 * Backs extension-created `android.webkit.WebView` objects with real WebKit
 * views in the macOS app (follow-up to plan RT-11). Extensions use a hidden
 * WebView as a JavaScript engine: load a page, evaluate scripts, receive calls
 * on a JavaScript interface. The worker's WebView is a handle; each session is
 * an isolated, non-persistent WebKit view owned by one installation.
 *
 * Everything is bounded: sessions per installation and in total, idle
 * lifetime, sizes of pages, scripts, results and event arguments, and queued
 * commands and events. The app's reports are untrusted and are only ever
 * delivered to the session's own installation.
 */
internal object WebViewSessionBridge {
    const val MAX_SESSIONS = 16
    const val MAX_SESSIONS_PER_INSTALLATION = 4
    const val IDLE_MS = 5 * 60_000L
    const val COMMAND_TIMEOUT_MS = 60_000L
    const val POLL_MS = 20_000L
    private const val MAX_HTML = 4 * 1024 * 1024
    private const val MAX_SCRIPT = 1024 * 1024
    private const val MAX_RESULT = 1024 * 1024
    private const val MAX_URL = 8_192
    private const val MAX_EVENTS = 256
    private const val MAX_ARGS = 16
    private const val MAX_ARG = 256 * 1024
    private const val MAX_COMMANDS = 64
    private val NAME = Regex("[A-Za-z_$][A-Za-z0-9_$]{0,63}")
    private val SESSION = Regex("[0-9a-f-]{36}")

    private class Session(val id: String, val owner: String) {
        @Volatile var lastUsed = System.currentTimeMillis()
        val events = Channel<WebViewEvent>(MAX_EVENTS)
        @Volatile var interfaces: Set<String> = emptySet()
    }

    private class Command(val dto: WebViewCommandDto) {
        val done = CompletableDeferred<WebViewResultDto>()
        @Volatile var claimed = false
    }

    private val sessions = ConcurrentHashMap<String, Session>()
    private val commands = ConcurrentHashMap<String, Command>()

    /** Handles one request from [owner]'s worker. Unknown or foreign sessions answer `alive = false`. */
    suspend fun handle(owner: String, request: WebViewRequest): WebViewResponse {
        expire()
        if (!request.session.matches(SESSION)) return WebViewResponse(alive = false)
        // A load that would be refused must not create (and so occupy) a session.
        if (request.op == "load") {
            require((request.url != null && web(request.url)) || (request.html != null && request.html.length <= MAX_HTML)) {
                "WebView load needs a web URL or a page"
            }
            require(request.baseUrl == null || web(request.baseUrl)) { "WebView base URL must be a web URL" }
        }
        val session = when (request.op) {
            "load" -> sessions[request.session]?.takeIf { it.owner == owner } ?: create(owner, request.session) ?: return WebViewResponse(alive = false)
            else -> sessions[request.session]?.takeIf { it.owner == owner } ?: return WebViewResponse(alive = false)
        }
        // Polling alone does not keep a session alive: an idle view is dropped after IDLE_MS.
        if (request.op != "poll") session.lastUsed = System.currentTimeMillis()
        return when (request.op) {
            "load" -> {
                val url = request.url?.takeIf { web(it) }
                val base = request.baseUrl?.takeIf { web(it) }
                val html = request.html?.takeIf { it.length <= MAX_HTML }
                require(url != null || html != null) { "WebView load needs a web URL or a page" }
                session.interfaces = request.interfaces.filter { it.matches(NAME) }.take(8).toSet()
                run(WebViewCommandDto(newId(), session.id, "load", url, html, base, userAgent = request.userAgent?.take(512)?.takeIf { it.none { c -> c < ' ' } },
                    interfaces = session.interfaces.toList()))
                WebViewResponse()
            }
            "eval" -> {
                val script = requireNotNull(request.script) { "Missing script" }
                require(script.length <= MAX_SCRIPT) { "Script is too long" }
                val result = run(WebViewCommandDto(newId(), session.id, "eval", script = script))
                WebViewResponse(result = (result.result ?: "null").take(MAX_RESULT))
            }
            "poll" -> {
                val first = withTimeoutOrNull(POLL_MS) { session.events.receive() }
                val batch = buildList {
                    first?.let(::add)
                    while (size < 32) add(session.events.tryReceive().getOrNull() ?: break)
                }
                WebViewResponse(events = batch, alive = sessions.containsKey(session.id))
            }
            "destroy" -> { destroy(session); WebViewResponse(alive = false) }
            else -> throw IllegalArgumentException("Unknown WebView operation")
        }
    }

    private fun web(url: String) = url.length <= MAX_URL && (url.startsWith("https://", true) || url.startsWith("http://", true)) &&
        url.none { it < ' ' }

    private fun newId() = UUID.randomUUID().toString()

    private fun create(owner: String, id: String): Session? = synchronized(sessions) {
        if (sessions.containsKey(id)) return null // another installation's id
        if (sessions.size >= MAX_SESSIONS || sessions.values.count { it.owner == owner } >= MAX_SESSIONS_PER_INSTALLATION) return null
        Session(id, owner).also { sessions[id] = it }
    }

    /** Queues [dto] for the app and waits for its result (bounded). */
    private suspend fun run(dto: WebViewCommandDto): WebViewResultDto {
        if (commands.size >= MAX_COMMANDS) throw WorkerCapacityException()
        val command = Command(dto)
        commands[dto.commandId] = command
        PendingSignal.parked()
        try {
            val result = withTimeoutOrNull(COMMAND_TIMEOUT_MS) { command.done.await() }
                ?: throw IllegalStateException("The app did not run the WebView command in time")
            result.error?.let { throw IllegalStateException("WebView: ${it.take(300)}") }
            return result
        } finally { commands.remove(dto.commandId) }
    }

    private fun destroy(session: Session) {
        if (sessions.remove(session.id) == null) return
        session.events.close()
        // Tell the app to drop the view; nobody waits for the answer.
        val dto = WebViewCommandDto(newId(), session.id, "destroy")
        if (commands.size < MAX_COMMANDS * 2) commands[dto.commandId] = Command(dto)
        PendingSignal.parked()
    }

    private fun expire() {
        val now = System.currentTimeMillis()
        sessions.values.filter { now - it.lastUsed > IDLE_MS }.forEach(::destroy)
        commands.values.filter { it.dto.op == "destroy" && it.claimed }.forEach { commands.remove(it.dto.commandId) }
    }

    /** The installation's worker ended or the generation was retired: drop its views. */
    fun release(owner: String) = sessions.values.filter { it.owner == owner }.forEach(::destroy)

    // ---- app side

    /** Commands not yet handed to the app. Each is handed out once. */
    fun pending(): List<WebViewCommandDto> {
        expire()
        return commands.values.filter { !it.claimed }.sortedBy { it.dto.op != "load" }.onEach { it.claimed = true }.map { it.dto }
    }

    fun complete(result: WebViewResultDto): Boolean {
        val command = commands[result.commandId] ?: return false
        return command.done.complete(result.copy(result = result.result?.take(MAX_RESULT), error = result.error?.take(300)))
    }

    /** A page event from the app. Only interface names the session registered are accepted. */
    fun event(dto: WebViewEventDto): Boolean {
        val session = sessions[dto.session] ?: return false
        val event = when (dto.event.kind) {
            "finished" -> WebViewEvent("finished", url = dto.event.url?.take(MAX_URL))
            "call" -> {
                val name = dto.event.name?.takeIf { it in session.interfaces } ?: return false
                val method = dto.event.method?.takeIf { it.matches(NAME) } ?: return false
                if (dto.event.args.size > MAX_ARGS || dto.event.args.any { it.length > MAX_ARG }) return false
                WebViewEvent("call", name = name, method = method, args = dto.event.args)
            }
            else -> return false
        }
        return session.events.trySend(event).isSuccess
    }

    /** Tests only. */
    internal fun clearForTest() {
        sessions.values.toList().forEach(::destroy)
        commands.clear()
    }

    internal fun sessionCount(): Int = sessions.size
}

/** How an extension process reaches [WebViewSessionBridge]: set in workers (over the pipe) and in-process. */
object WebViewSessions {
    @Volatile var transport: (suspend (WebViewRequest) -> WebViewResponse)? = null
}
