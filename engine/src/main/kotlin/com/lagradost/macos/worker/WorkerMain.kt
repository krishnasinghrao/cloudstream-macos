package com.lagradost.macos.worker

import com.lagradost.cloudstream3.MainAPI
import com.lagradost.cloudstream3.ProvidersInfoJson
import com.lagradost.macos.NetworkSetup
import com.lagradost.macos.OperationFailures
import com.lagradost.macos.PluginBridge
import com.lagradost.macos.ProviderExecutor
import com.lagradost.macos.ProviderRuntimeBootstrap
import com.lagradost.macos.SolveBridge
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.KSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.decodeFromJsonElement
import java.io.BufferedInputStream
import java.io.DataInputStream
import java.io.File
import java.io.FileDescriptor
import java.io.FileOutputStream
import java.io.PrintStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import kotlin.system.exitProcess

/**
 * Worker process entry (`daemon.jar --worker`, ADR-0016). Hosts exactly one
 * installation's generation and serves the control plane over stdin/stdout.
 * The worker trusts nothing it did not verify itself: the artifact bytes are
 * re-hashed against the receipt before any code runs.
 */
internal object WorkerMain {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val calls = ConcurrentHashMap<Long, Job>()
    /** Worker-initiated requests (`solve`, nested `extract`) awaiting the control plane's answer. */
    private val outbound = ConcurrentHashMap<Long, CompletableDeferred<Frame>>()
    private val outboundIds = AtomicLong(0)
    @Volatile private var installationId = ""
    private lateinit var out: FrameWriter
    private val providers = ConcurrentHashMap<String, MainAPI>()

    fun run() {
        // Extension code may print; only protocol frames may reach the real stdout.
        out = FrameWriter(FileOutputStream(FileDescriptor.out), "worker-protocol-out",
            onFailure = { Runtime.getRuntime().halt(1) })
        System.setOut(PrintStream(FileOutputStream(FileDescriptor.err), true))
        val input = DataInputStream(BufferedInputStream(System.`in`))
        SolveBridge.remoteSolver = ::requestSolve
        com.lagradost.cloudstream3.utils.ExtractorRouting.fallback = ::requestExtract
        com.lagradost.cloudstream3.network.WebViewHost.resolver = ::requestMedia
        com.lagradost.macos.WebViewSessions.transport = ::requestWebView
        while (true) {
            val frame = try { FrameCodec.read(input) } catch (failure: Exception) {
                System.err.println("worker: malformed frame: ${failure.javaClass.simpleName}")
                null
            } ?: break
            dispatch(frame)
        }
        // stdin closed: the control plane is gone or asked us to stop.
        scope.cancel()
        outbound.values.forEach { it.cancel() }
        outbound.clear()
        out.close()
        exitProcess(0)
    }

    private fun send(frame: Frame) = out.send(frame)

    private fun <T> reply(id: Long, serializer: KSerializer<T>, value: T) =
        send(Frame(id, Op.RESULT, FrameCodec.json.encodeToJsonElement(serializer, value)))

    private fun fail(frame: Frame, thrown: Throwable) {
        if (thrown is kotlinx.coroutines.CancellationException && thrown !is kotlinx.coroutines.TimeoutCancellationException) {
            send(Frame(frame.id, Op.ERROR, error = "Operation cancelled", code = "cancelled"))
            return
        }
        val failure = OperationFailures.capture(null, frame.type, thrown).failure
        send(Frame(frame.id, Op.ERROR, error = failure.publicMessage, code = failure.code, failure = failure))
    }

    private inline fun <reified T> decode(payload: JsonElement): T = FrameCodec.json.decodeFromJsonElement(payload)

    private fun dispatch(frame: Frame) {
        when (frame.type) {
            Op.INIT -> handle(frame) { reply(frame.id, InitResult.serializer(), init(decode(frame.payload))) }
            Op.SEARCH -> handle(frame) {
                val request = decode<SearchRequest>(frame.payload)
                val result = ProviderExecutor.searchOne(provider(request.provider), request.query)
                reply(frame.id, SearchResponsePayload.serializer(),
                    SearchResponsePayload(if (result.error == null) result.results else null, result.error, result.failure))
            }
            Op.HOME -> handle(frame) {
                val request = decode<HomeRequest>(frame.payload)
                reply(frame.id, com.lagradost.macos.models.HomePageDto.serializer(), ProviderExecutor.loadHome(provider(request.provider), request.page))
            }
            Op.DETAILS -> handle(frame) {
                val request = decode<DetailsRequest>(frame.payload)
                reply(frame.id, DetailsResponsePayload.serializer(),
                    DetailsResponsePayload(ProviderExecutor.loadDetails(provider(request.provider), request.url, refresh = true)))
            }
            Op.LINKS -> handle(frame) {
                val request = decode<LinksRequest>(frame.payload)
                val response = ProviderExecutor.loadLinksStreaming(provider(request.provider), request.data,
                    onLink = { event(frame.id, LinkEvent(link = it)) },
                    onSubtitle = { event(frame.id, LinkEvent(subtitle = it)) })
                reply(frame.id, com.lagradost.macos.models.LinksResponseDto.serializer(), response)
            }
            Op.EXTRACT -> handle(frame) {
                val request = decode<ExtractRequest>(frame.payload)
                val budget = (request.budgetMs ?: com.lagradost.macos.OperationBudget.DEFAULT_MS)
                    .coerceIn(1_000L, com.lagradost.macos.OperationBudget.DEFAULT_MS)
                val route = com.lagradost.macos.ExtractorRoute.within(budget, request.visited.toSet() + installationId, request.hops)
                val response = kotlinx.coroutines.withContext(route) { ProviderExecutor.extract(request.url, request.referer, budget) }
                reply(frame.id, com.lagradost.macos.models.LinksResponseDto.serializer(), response)
            }
            Op.VERIFY -> handle(frame) {
                val request = decode<VerifyRequest>(frame.payload)
                val api = provider(request.provider)
                try { api.extractorVerifierJob(request.data) } catch (_: NotImplementedError) { }
                reply(frame.id, Boolean.serializer(), true)
            }
            Op.CONFIGURE -> handle(frame) {
                val request = decode<ConfigureRequest>(frame.payload)
                configure(provider(request.provider), ProviderConfig(request.url, request.credentials), request.clearCredentials)
                reply(frame.id, Boolean.serializer(), true)
            }
            Op.PREFS_GET -> handle(frame) {
                reply(frame.id, com.lagradost.macos.ExtensionPreferencesDto.serializer(), preferences().describe())
            }
            Op.PREFS_SET -> handle(frame) {
                try {
                    preferences().apply(decode<List<com.lagradost.macos.ExtensionPreferenceUpdateDto>>(frame.payload))
                } catch (invalid: IllegalArgumentException) {
                    // A rejected value is the user's to fix: return the validation message, not a generic failure.
                    send(Frame(frame.id, Op.ERROR, error = invalid.message?.take(300) ?: "Invalid setting", code = "invalid_request"))
                    return@handle
                }
                reply(frame.id, com.lagradost.macos.ExtensionPreferencesDto.serializer(), preferences().describe())
            }
            Op.NETWORK -> handle(frame) {
                NetworkSetup.apply(decode<com.lagradost.macos.DaemonState.NetworkSettings>(frame.payload).copy(httpCacheMb = 0))
                reply(frame.id, Boolean.serializer(), true)
            }
            Op.CANCEL -> calls.remove(decode<CancelRequest>(frame.payload).target)?.cancel()
            Op.RESULT, Op.ERROR -> outbound.remove(frame.id)?.complete(frame)
            Op.SHUTDOWN -> {
                runCatching { PluginBridge.getAllLoadedDescriptors().forEach { it.plugin.beforeUnload() } }
                exitProcess(0)
            }
            else -> send(Frame(frame.id, Op.ERROR, error = "Unknown request ${frame.type}"))
        }
    }

    /** Runs [block] as a cancellable call; failures become `error` frames. */
    private fun handle(frame: Frame, block: suspend () -> Unit) {
        val job = scope.launch(start = kotlinx.coroutines.CoroutineStart.LAZY) {
            // Bodies left open when no operation is running are reclaimed (Remediation 5.1).
            try { com.lagradost.macos.network.ResponseTracker.operation { block() } } catch (failure: Throwable) {
                if (failure is VirtualMachineError && failure !is StackOverflowError) throw failure
                runCatching { fail(frame, failure) }
            } finally { calls.remove(frame.id) }
        }
        calls[frame.id] = job
        job.start()
    }

    private fun event(id: Long, value: LinkEvent) =
        send(Frame(id, Op.EVENT, FrameCodec.json.encodeToJsonElement(LinkEvent.serializer(), value)))

    private fun provider(name: String): MainAPI = providers[name] ?: error("Unknown provider $name")

    private fun preferences() = PluginBridge.loadedInstallation(installationId)?.preferences ?: error("Extension is not loaded")

    private fun init(request: InitRequest): InitResult {
        check(installationId.isEmpty() && providers.isEmpty()) { "Worker already initialized" }
        // Before any client is built: every connection goes through the engine's egress proxy.
        request.egress?.let(WorkerEgress::install)
        NetworkSetup.apply(request.network.copy(httpCacheMb = 0))
        ProviderRuntimeBootstrap.initialize()
        val prepared = PluginBridge.prepare(request.record, File(request.artifactPath), request.reuseTranslation)
        PluginBridge.publish(prepared)
        installationId = request.record.id
        prepared.providers.forEach { api ->
            providers[api.name] = api
            request.providerConfig[api.name]?.let { configure(api, it) }
        }
        return InitResult(
            providers = prepared.providers.map { with(WorkerDescriptors) { it.descriptor() } },
            extractorCount = prepared.extractorCount,
            jarHashes = prepared.jarHashes,
            unsupportedFeatures = prepared.unsupportedFeatures,
            compatibility = prepared.compatibility,
            extractors = prepared.extractors.map(WorkerDescriptors::extractor),
        )
    }

    internal fun configure(api: MainAPI, config: ProviderConfig, clearCredentials: Boolean = false) {
        if (!api.canBeOverridden) return
        // A clear leaves no credential; it must not fall back to the live one.
        val credentials = if (clearCredentials) null else config.credentials ?: api.storedCredentials
        api.overrideWithNewData(ProvidersInfoJson(api.name, config.url ?: api.mainUrl, credentials, 1))
    }

    /** Sends a worker-initiated request; null when unanswered within [timeoutMs]. */
    private suspend fun request(type: String, payload: JsonElement, timeoutMs: Long): Frame? {
        val id = -outboundIds.incrementAndGet()
        val deferred = CompletableDeferred<Frame>()
        outbound[id] = deferred
        return try {
            withTimeoutOrNull(timeoutMs) {
                out.send(Frame(id, type, payload), timeoutMs)
                deferred.await()
            }
        } finally { outbound.remove(id) }
    }

    /** Forwards an anti-bot challenge to the control plane (bounded wait). */
    private suspend fun requestSolve(targetUrl: String, userAgent: String?): String? {
        val answer = request(Op.SOLVE, FrameCodec.json.encodeToJsonElement(SolveRequest.serializer(), SolveRequest(targetUrl, userAgent)), 100_000)
            ?.takeIf { it.type == Op.RESULT } ?: return null
        return runCatching { decode<SolveResult>(answer.payload).cookies }.getOrNull()
    }

    /** `WebViewResolver` (RT-11): the control plane has the app load the page in WebKit. */
    private suspend fun requestMedia(request: com.lagradost.cloudstream3.network.WebViewHostRequest): com.lagradost.cloudstream3.network.WebViewHostResult? {
        val spec = com.lagradost.macos.MediaResolveBridge.spec(request)
        val answer = request(Op.MEDIA, FrameCodec.json.encodeToJsonElement(com.lagradost.macos.MediaResolveSpec.serializer(), spec),
            spec.timeoutMs + com.lagradost.macos.OperationBudget.WORKER_MARGIN_MS)
        if (answer == null) return null
        if (answer.type != Op.RESULT) throw IllegalStateException("Page resolution failed: ${answer.code ?: "error"}")
        if (answer.payload is kotlinx.serialization.json.JsonNull) return null
        val outcome = decode<com.lagradost.macos.MediaResolveOutcome>(answer.payload)
        return com.lagradost.macos.MediaResolveBridge.hostResult(outcome)
    }

    /** An extension-created `android.webkit.WebView` operation (RT-14), run by the app's WebKit. */
    private suspend fun requestWebView(request: com.lagradost.macos.WebViewRequest): com.lagradost.macos.WebViewResponse {
        val wait = if (request.op == "poll") com.lagradost.macos.WebViewSessionBridge.POLL_MS else com.lagradost.macos.WebViewSessionBridge.COMMAND_TIMEOUT_MS
        val answer = request(Op.WEBVIEW, FrameCodec.json.encodeToJsonElement(com.lagradost.macos.WebViewRequest.serializer(), request),
            wait + com.lagradost.macos.OperationBudget.WORKER_MARGIN_MS) ?: throw IllegalStateException("WebView request timed out")
        if (answer.type != Op.RESULT) throw IllegalStateException("WebView request failed: ${answer.code ?: "error"}")
        return decode<com.lagradost.macos.WebViewResponse>(answer.payload)
    }

    /**
     * `loadExtractor` fallback (RT-12): no extractor in this process claims the
     * URL, so ask the control plane to route it to the extension that registered
     * one. Route state comes from the current call (a routed `extract`) or
     * starts here.
     */
    private suspend fun requestExtract(url: String, referer: String?,
        onSubtitle: (com.lagradost.cloudstream3.SubtitleFile) -> Unit,
        onLink: (com.lagradost.cloudstream3.utils.ExtractorLink) -> Unit): Boolean {
        if (installationId.isEmpty()) return false
        val route = kotlinx.coroutines.currentCoroutineContext()[com.lagradost.macos.ExtractorRoute]
            ?: com.lagradost.macos.ExtractorRoute.within(com.lagradost.macos.OperationBudget.DEFAULT_MS, setOf(installationId))
        val remaining = route.remainingMs()
        if (route.hops >= com.lagradost.macos.ExtractorRouter.MAX_HOPS || remaining < com.lagradost.macos.ExtractorRouter.MIN_BUDGET_MS) return false
        val payload = FrameCodec.json.encodeToJsonElement(ExtractRequest.serializer(),
            ExtractRequest(url, referer, route.visited.toList(), route.hops, remaining))
        val answer = request(Op.EXTRACT, payload, remaining + com.lagradost.macos.OperationBudget.WORKER_MARGIN_MS)
            ?.takeIf { it.type == Op.RESULT } ?: return false
        val response = runCatching { decode<com.lagradost.macos.models.LinksResponseDto>(answer.payload) }.getOrNull() ?: return false
        return com.lagradost.macos.ExtractorRouter.deliver(response, onSubtitle, onLink)
    }
}

internal object WorkerDescriptors {
    fun extractor(api: com.lagradost.cloudstream3.utils.ExtractorApi) = ExtractorDescriptor(
        name = api.name.take(200),
        mainUrl = api.mainUrl.take(2_000),
        requiresReferer = api.requiresReferer,
    )

    fun MainAPI.descriptor() = ProviderDescriptor(
        name = name,
        mainUrl = mainUrl,
        lang = lang,
        supportedTypes = supportedTypes.map { it.name }.sorted(),
        hasMainPage = hasMainPage,
        hasQuickSearch = hasQuickSearch,
        vpnStatus = vpnStatus.name,
        canBeOverridden = canBeOverridden,
        searchTimeoutMs = searchTimeoutMs,
        loadTimeoutMs = loadTimeoutMs,
        loadLinksTimeoutMs = loadLinksTimeoutMs,
        mainPageTimeoutMs = getMainPageTimeoutMs,
    )
}
