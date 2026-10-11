package com.lagradost.macos

import com.lagradost.macos.models.ConnectivityTestRequestDto
import com.lagradost.macos.models.ErrorResponseDto
import com.lagradost.macos.models.NetworkSettingsDto
import com.lagradost.macos.models.ProviderInfoDto
import com.lagradost.macos.models.ProviderTestEventDto
import com.lagradost.macos.models.ProviderTestRequestDto
import com.lagradost.macos.models.ResolverOptionDto
import com.lagradost.macos.models.ExtractRequestDto
import com.lagradost.macos.models.HealthDto
import com.lagradost.macos.models.HomePageDto
import com.lagradost.macos.models.LinksRequestDto
import com.lagradost.macos.models.LinksResponseDto
import com.lagradost.macos.models.LinksStreamEventDto
import com.lagradost.macos.models.MediaRelayRequestDto
import com.lagradost.macos.models.MediaRelayResponseDto
import com.lagradost.macos.models.MediaRelayRevokeRequestDto
import com.lagradost.macos.models.VerifierStartRequestDto
import com.lagradost.macos.models.VerifierStartResponseDto
import com.lagradost.macos.models.VerifierStopRequestDto
import com.lagradost.macos.models.SearchResultDto
import com.lagradost.macos.models.SearchStreamEventDto
import com.lagradost.macos.models.SolveCallbackRequestDto
import com.lagradost.macos.models.SolvePendingDto
import io.ktor.http.ContentType
import io.ktor.http.HttpStatusCode
import io.ktor.serialization.kotlinx.json.json
import io.ktor.server.application.Application
import io.ktor.server.application.call
import io.ktor.server.request.receive
import io.ktor.server.request.uri
import io.ktor.server.response.respond
import io.ktor.server.response.respondText
import io.ktor.server.response.respondTextWriter
import io.ktor.server.routing.get
import io.ktor.server.routing.head
import io.ktor.server.routing.post
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import io.ktor.server.routing.Route

/**
 * Provider, media, solver, network and diagnostics routes. Handlers validate
 * input and delegate to [ProviderExecutor], [SolveBridge], [NetworkSetup] and
 * [Metrics]; extension lifecycle routes live in ExtensionRoutes.kt.
 */
internal fun Route.mediaRoutes() {

    get("/providers") {
        Metrics.recordRequest("providers")
        call.respond(
            ProviderExecutor.providers().map { provider ->
                ProviderInfoDto(
                    name = provider.name,
                    providerId = PluginBridge.providerId(provider),
                    plugin = provider.sourcePlugin,
                    mainUrl = provider.mainUrl,
                    language = provider.lang,
                    tvTypes = provider.supportedTypes.map { it.name }.sorted(),
                    hasMainPage = provider.hasMainPage,
                    hasQuickSearch = provider.hasQuickSearch,
                    vpnStatus = provider.vpnStatus.name,
                )
            }.sortedBy { it.name.lowercase() },
        )
    }

    get("/search") {
        Metrics.recordRequest("search")
        if (!RateLimiter.check("search")) {
            call.respond(HttpStatusCode.TooManyRequests, ErrorResponseDto(error = "rate limited"))
            return@get
        }
        val query = call.request.queryParameters["q"].orEmpty().trim()
        if (query.isEmpty()) {
            call.respond(
                HttpStatusCode.BadRequest,
                ErrorResponseDto(error = "missing query", detail = "usage: /search?q=<query>"),
            )
            return@get
        }
        val filter = call.request.queryParameters["plugins"]
            ?.split(',')?.map { it.trim() }?.filter { it.isNotEmpty() }

        val results: List<SearchResultDto> = ProviderExecutor.searchAll(query, ProviderExecutor.providers(filter))
        call.respond(results)
    }

    get("/search/stream") {
        Metrics.recordRequest("search/stream")
        if (!RateLimiter.check("search")) {
            call.respond(HttpStatusCode.TooManyRequests, ErrorResponseDto(error = "rate limited"))
            return@get
        }
        val query = call.request.queryParameters["q"].orEmpty().trim()
        if (query.isEmpty()) {
            call.respond(
                HttpStatusCode.BadRequest,
                ErrorResponseDto(error = "missing query", detail = "usage: /search/stream?q=<query>"),
            )
            return@get
        }
        val filter = call.request.queryParameters["plugins"]
            ?.split(',')?.map { it.trim() }?.filter { it.isNotEmpty() }

        val providers = ProviderExecutor.providers(filter)
        val json = Json { encodeDefaults = true }

        // NDJSON: one SearchStreamEventDto per line; results stream in per
        // provider as each finishes its 5 s barrier.
        call.respondTextWriter(contentType = ContentType("application", "x-ndjson")) {
            val writer = this
            call.withConnectionCancellation {
                val jobs = providers.map { provider ->
                    async(Dispatchers.IO) {
                        val result = ProviderExecutor.searchOne(provider, query)
                        val event = if (result.error == null) {
                            SearchStreamEventDto(type = "provider_result", provider = result.provider, providerId = result.providerId, results = result.results)
                        } else {
                            SearchStreamEventDto(type = "provider_error", provider = result.provider, providerId = result.providerId, error = result.error, failure = result.failure)
                        }
                        val text = json.encodeToString(SearchStreamEventDto.serializer(), event) + "\n"
                        synchronized(writer) {
                            writer.write(text)
                            writer.flush()
                        }
                    }
                }
                jobs.awaitAll()
                Unit
            }
            val doneText = json.encodeToString(SearchStreamEventDto.serializer(), SearchStreamEventDto(type = "done")) + "\n"
            synchronized(writer) {
                writer.write(doneText)
                writer.flush()
            }
        }
    }

    get("/home") {
        Metrics.recordRequest("home")
        if (!RateLimiter.check("home")) {
            call.respond(HttpStatusCode.TooManyRequests, ErrorResponseDto(error = "rate limited"))
            return@get
        }
        val pluginId = call.request.queryParameters["plugin"].orEmpty()
        val page = call.request.queryParameters["page"]?.toIntOrNull() ?: 1
        val provider = ProviderExecutor.findProvider(pluginId)
        if (provider == null) {
            call.respond(
                HttpStatusCode.BadRequest,
                ErrorResponseDto(
                    error = "invalid request",
                    detail = "usage: /home?plugin=<provider>&page=<n>",
                ),
            )
            return@get
        }

        val home: HomePageDto = ProviderExecutor.loadHome(provider, page)
        val failure = home.failures.firstOrNull()
        if (home.outcome == "failure" && failure != null) call.respond(HttpStatusCode.fromValue(OperationFailures.status(failure)),
            ErrorResponseDto(failure.publicMessage, failure = failure))
        else call.respond(home)
    }

    get("/details") {
        Metrics.recordRequest("details")
        if (!RateLimiter.check("details")) {
            call.respond(HttpStatusCode.TooManyRequests, ErrorResponseDto(error = "rate limited"))
            return@get
        }
        val pluginId = call.request.queryParameters["plugin"].orEmpty()
        val url = call.request.queryParameters["url"].orEmpty()
        if (pluginId.isBlank() || url.isEmpty()) {
            call.respond(
                HttpStatusCode.BadRequest,
                ErrorResponseDto(
                    error = "invalid request",
                    detail = "usage: /details?plugin=<provider>&url=<result url>[&refresh=1]",
                ),
            )
            return@get
        }
        // 422, distinct from a malformed request: the provider is missing,
        // disabled, or named by a title that two installations share.
        val provider = ProviderExecutor.findProvider(pluginId)
        if (provider == null) {
            call.respond(
                HttpStatusCode.UnprocessableEntity,
                ErrorResponseDto(error = "provider unavailable", detail = ProviderExecutor.unavailableReason(pluginId)),
            )
            return@get
        }

        val refresh = call.request.queryParameters["refresh"] == "1"
        val details = try { ProviderExecutor.loadDetails(provider, url, refresh) }
        catch (failure: OperationException) {
            call.respond(HttpStatusCode.fromValue(OperationFailures.status(failure.failure)),
                ErrorResponseDto(failure.failure.publicMessage, failure = failure.failure))
            return@get
        }
        call.respond(details)
    }

    // POST /links — episode data strings can be multi-KB; a GET URI cannot
    // carry them reliably (contract v2, ipc-api.md).
    post("/links") {
        Metrics.recordRequest("links")
        if (!RateLimiter.check("links")) {
            call.respond(HttpStatusCode.TooManyRequests, ErrorResponseDto(error = "rate limited"))
            return@post
        }
        val request = call.receive<LinksRequestDto>()
        if (request.data.isEmpty()) {
            call.respond(
                HttpStatusCode.BadRequest,
                ErrorResponseDto(
                    error = "invalid request",
                    detail = "usage: POST /links {\"plugin\": \"<provider>\", \"data\": \"<episode data>\"}",
                ),
            )
            return@post
        }
        // 422, distinct from a malformed request: the provider isn't
        // installed or is disabled. Download clients treat it as terminal.
        val provider = ProviderExecutor.findProvider(request.plugin)
        if (provider == null) {
            call.respond(
                HttpStatusCode.UnprocessableEntity,
                ErrorResponseDto(error = "provider unavailable", detail = ProviderExecutor.unavailableReason(request.plugin)),
            )
            return@post
        }

        val links: LinksResponseDto = ProviderExecutor.loadLinks(provider, request.data)
        val failure = links.failures.firstOrNull()
        if (links.outcome == "failure" && failure != null) call.respond(HttpStatusCode.fromValue(OperationFailures.status(failure)),
            ErrorResponseDto(failure.publicMessage, failure = failure))
        else call.respond(links)
    }

    // POST /extract — extractor-only resolution for one URL (trailers).
    post("/extract") {
        Metrics.recordRequest("extract")
        if (!RateLimiter.check("links")) {
            call.respond(HttpStatusCode.TooManyRequests, ErrorResponseDto(error = "rate limited"))
            return@post
        }
        val request = call.receive<ExtractRequestDto>()
        val target = request.url.trim()
        if (!(target.startsWith("https://", ignoreCase = true) || target.startsWith("http://", ignoreCase = true)) || target.length > 4096) {
            call.respond(
                HttpStatusCode.BadRequest,
                ErrorResponseDto(error = "invalid request", detail = "usage: POST /extract {\"url\": \"https://…\", \"referer\": null}"),
            )
            return@post
        }
        call.respond(ProviderExecutor.extract(target, request.referer))
    }

    // POST /links/stream — progressive NDJSON resolution (Player-Remediation-Plan
    // A2). Each extractor result is written the moment it is produced so the
    // client can start playback without waiting for the slowest extractor.
    post("/links/stream") {
        Metrics.recordRequest("links/stream")
        if (!RateLimiter.check("links")) {
            call.respond(HttpStatusCode.TooManyRequests, ErrorResponseDto(error = "rate limited"))
            return@post
        }
        val request = call.receive<LinksRequestDto>()
        if (request.data.isEmpty()) {
            call.respond(
                HttpStatusCode.BadRequest,
                ErrorResponseDto(
                    error = "invalid request",
                    detail = "usage: POST /links/stream {\"plugin\": \"<provider>\", \"data\": \"<episode data>\"}",
                ),
            )
            return@post
        }
        val provider = ProviderExecutor.findProvider(request.plugin)
        if (provider == null) {
            call.respond(
                HttpStatusCode.UnprocessableEntity,
                ErrorResponseDto(error = "provider unavailable", detail = ProviderExecutor.unavailableReason(request.plugin)),
            )
            return@post
        }

        val json = Json { encodeDefaults = true }
        call.respondTextWriter(contentType = ContentType("application", "x-ndjson")) {
            val writer = this
            fun emit(event: LinksStreamEventDto) {
                val text = json.encodeToString(LinksStreamEventDto.serializer(), event) + "\n"
                // Extractor callbacks fire from arbitrary threads.
                synchronized(writer) {
                    try {
                        writer.write(text)
                        writer.flush()
                    } catch (_: java.io.IOException) {
                        // Client closed the connection (broken pipe); ignore so it is not logged as provider failure.
                    }
                }
            }
            call.withConnectionCancellation {
                val response = withContext(Dispatchers.IO) {
                    ProviderExecutor.loadLinksStreaming(
                        provider,
                        request.data,
                        onLink = { link -> emit(LinksStreamEventDto(type = "link", link = link)) },
                        onSubtitle = { sub -> emit(LinksStreamEventDto(type = "subtitle", subtitle = sub)) },
                    )
                }
                emit(LinksStreamEventDto(type = "done", failures = response.failures, outcome = response.outcome, skipped = response.skipped))
            }
        }
    }

    // POST /links/verify/start|stop — keep-alive for links that carry
    // extractorData while a download/playback uses them (VerifierJobs).
    post("/links/verify/start") {
        Metrics.recordRequest("links/verify/start")
        if (!RateLimiter.check("links")) {
            call.respond(HttpStatusCode.TooManyRequests, ErrorResponseDto(error = "rate limited"))
            return@post
        }
        val request = call.receive<VerifierStartRequestDto>()
        call.respond(VerifierStartResponseDto(jobId = VerifierJobs.start(request.source, request.extractorData)))
    }

    post("/links/verify/stop") {
        Metrics.recordRequest("links/verify/stop")
        val request = call.receive<VerifierStopRequestDto>()
        VerifierJobs.stop(request.jobId)
        call.respond(mapOf("status" to "ok"))
    }

    // ---- Split-stream transport (audit A35): per-resource headers for one playback session.

    post("/media/relay") {
        Metrics.recordRequest("media/relay")
        if (!RateLimiter.check("links")) {
            call.respond(HttpStatusCode.TooManyRequests, ErrorResponseDto(error = "rate limited"))
            return@post
        }
        val request = call.receive<MediaRelayRequestDto>()
        val registration = try {
            MediaRelay.register(request.resources.map { MediaRelay.Resource(it.url, it.headers) })
        } catch (_: IllegalArgumentException) {
            // Covers a rejected URL/header set; neither is echoed.
            call.respond(HttpStatusCode.BadRequest, ErrorResponseDto(error = "invalid request", detail = "unsupported media resource"))
            return@post
        }
        if (registration == null) {
            call.respond(HttpStatusCode.ServiceUnavailable, ErrorResponseDto(error = "relay capacity reached"))
            return@post
        }
        call.respond(MediaRelayResponseDto(registration.sessionId, registration.paths))
    }

    post("/media/relay/revoke") {
        Metrics.recordRequest("media/relay/revoke")
        MediaRelay.revoke(call.receive<MediaRelayRevokeRequestDto>().sessionId)
        call.respond(mapOf("status" to "ok"))
    }

    // Read by the native player, which cannot send the bearer token only to
    // this listener: the unguessable id is the credential (Main.kt).
    get("/media/relay/{id}") { MediaRelay.serve(call, call.parameters["id"].orEmpty(), head = false) }
    head("/media/relay/{id}") { MediaRelay.serve(call, call.parameters["id"].orEmpty(), head = true) }
    // Paths below a directory resource (segments named by a rewritten manifest), kept raw.
    get("/media/relay/{id}/{rest...}") { MediaRelay.serve(call, call.parameters["id"].orEmpty(), head = false, rest = relayRest(call)) }
    head("/media/relay/{id}/{rest...}") { MediaRelay.serve(call, call.parameters["id"].orEmpty(), head = true, rest = relayRest(call)) }

    // Legacy GET /links retained for one release; logged as deprecated.
    get("/links") {
        Metrics.recordRequest("links(deprecated)")
        DaemonLog.warn("links.deprecated_get_used")
        val pluginId = call.request.queryParameters["plugin"].orEmpty()
        val data = call.request.queryParameters["data"].orEmpty()
        val provider = ProviderExecutor.findProvider(pluginId)
        if (provider == null || data.isEmpty()) {
            call.respond(
                HttpStatusCode.BadRequest,
                ErrorResponseDto(error = "invalid request", detail = "use POST /links with a JSON body"),
            )
            return@get
        }
        val links: LinksResponseDto = ProviderExecutor.loadLinks(provider, data)
        call.respond(links)
    }

    get("/solve/pending") {
        Metrics.recordRequest("solve/pending")
        val waitMs = call.request.queryParameters["waitMs"]?.toLongOrNull() ?: 0
        call.respond(
            PendingSignal.awaitNonEmpty(waitMs) { SolveBridge.listPending() }.map { task ->
                SolvePendingDto(taskId = task.taskId, targetUrl = task.targetUrl, ageMs = task.ageMs, userAgent = task.userAgent)
            },
        )
    }

    post("/solve-callback") {
        Metrics.recordRequest("solve-callback")
        val request = call.receive<SolveCallbackRequestDto>()
        val completed = SolveBridge.complete(request.taskId, request.targetUrl, request.cookies)
        if (completed) {
            call.respond(mapOf("status" to "ok"))
        } else {
            call.respond(
                HttpStatusCode.NotFound,
                ErrorResponseDto(error = "unknown task", detail = "no pending solve task '${request.taskId}'"),
            )
        }
    }

    // ---- Native JavaScript media resolution (plan RT-11): the app runs pages in WebKit for WebViewResolver.

    get("/media/pending") {
        Metrics.recordRequest("media/pending")
        val waitMs = call.request.queryParameters["waitMs"]?.toLongOrNull() ?: 0
        call.respond(PendingSignal.awaitNonEmpty(waitMs) { MediaResolveBridge.pending() })
    }

    post("/media/observe") {
        Metrics.recordRequest("media/observe")
        call.respond(MediaResolveBridge.observe(call.receive<MediaObserveRequestDto>()))
    }

    post("/media/complete") {
        Metrics.recordRequest("media/complete")
        if (MediaResolveBridge.complete(call.receive<MediaCompleteRequestDto>())) call.respond(mapOf("status" to "ok"))
        else call.respond(HttpStatusCode.NotFound, ErrorResponseDto(error = "unknown task"))
    }

    // ---- Extension-created WebViews (RT-14): the app runs them in WebKit.

    get("/webview/pending") {
        Metrics.recordRequest("webview/pending")
        val waitMs = call.request.queryParameters["waitMs"]?.toLongOrNull() ?: 0
        call.respond(PendingSignal.awaitNonEmpty(waitMs) { WebViewSessionBridge.pending() })
    }

    post("/webview/complete") {
        Metrics.recordRequest("webview/complete")
        if (WebViewSessionBridge.complete(call.receive<WebViewResultDto>())) call.respond(mapOf("status" to "ok"))
        else call.respond(HttpStatusCode.NotFound, ErrorResponseDto(error = "unknown command"))
    }

    post("/webview/event") {
        Metrics.recordRequest("webview/event")
        if (WebViewSessionBridge.event(call.receive<WebViewEventDto>())) call.respond(mapOf("status" to "ok"))
        else call.respond(HttpStatusCode.NotFound, ErrorResponseDto(error = "unknown session"))
    }

    // ---- Network settings (Offline-Features-Plan Phase 3)

    get("/settings/network") {
        Metrics.recordRequest("settings/network")
        call.respond(networkSettingsDto())
    }

    post("/settings/network") {
        Metrics.recordRequest("settings/network")
        if (!RateLimiter.check("write")) {
            call.respond(HttpStatusCode.TooManyRequests, ErrorResponseDto(error = "rate limited"))
            return@post
        }
        val request = call.receive<NetworkSettingsDto>()
        val requested = DaemonState.NetworkSettings(
            dns = request.dns,
            customDohUrl = request.customDohUrl,
            httpCacheMb = request.httpCacheMb,
            retryOnNetworkError = request.retryOnNetworkError,
            // Older clients do not send it: keep what the user chose.
            githubMirror = request.githubMirror ?: NetworkSetup.current.githubMirror,
        )
        val applied = try {
            NetworkSetup.apply(requested)
        } catch (e: IllegalArgumentException) {
            call.respond(HttpStatusCode.BadRequest, ErrorResponseDto(error = "invalid settings", detail = e.message))
            return@post
        }
        com.lagradost.macos.worker.WorkerPool.broadcastNetwork(applied)
        DaemonState.setNetworkSettings(applied)
        // Responses fetched through the old resolver may be the blocked
        // or poisoned ones the user is switching away from.
        ProviderExecutor.invalidateCaches()
        DaemonLog.info("network.settings_changed", mapOf("dns" to applied.dns, "cacheMb" to applied.httpCacheMb))
        call.respond(networkSettingsDto())
    }

    post("/settings/network/clearCache") {
        Metrics.recordRequest("settings/network/clearCache")
        NetworkSetup.clearCache()
        ProviderExecutor.invalidateCaches()
        call.respond(networkSettingsDto())
    }

    post("/network/test") {
        Metrics.recordRequest("network/test")
        if (!RateLimiter.check("diagnose")) {
            call.respond(HttpStatusCode.TooManyRequests, ErrorResponseDto(error = "rate limited", detail = "wait a few seconds between tests"))
            return@post
        }
        val request = call.receive<ConnectivityTestRequestDto>()
        val targets = ProviderExecutor.providers(request.providers.ifEmpty { null })
            .map { it.name to it.mainUrl }
            .distinctBy { it.second.lowercase() }
        call.respond(ConnectivityTester.test(targets))
    }

    // NDJSON: one result per provider as it finishes, then "done".
    post("/test/run") {
        Metrics.recordRequest("test/run")
        if (!RateLimiter.check("diagnose")) {
            call.respond(HttpStatusCode.TooManyRequests, ErrorResponseDto(error = "rate limited", detail = "a test run just finished — wait a few seconds"))
            return@post
        }
        val request = call.receive<ProviderTestRequestDto>()
        val providers = ProviderExecutor.providers(request.providers.ifEmpty { null })
        val query = request.query?.trim()?.take(100)?.ifEmpty { null } ?: ProviderTester.DEFAULT_QUERY
        val json = Json { encodeDefaults = true }
        call.respondTextWriter(contentType = ContentType("application", "x-ndjson")) {
            val writer = this
            fun emit(event: ProviderTestEventDto) {
                val text = json.encodeToString(ProviderTestEventDto.serializer(), event) + "\n"
                synchronized(writer) {
                    writer.write(text)
                    writer.flush()
                }
            }
            ProviderTester.runAll(providers, query) { emit(ProviderTestEventDto(type = "result", result = it)) }
            emit(ProviderTestEventDto(type = "done", total = providers.size))
        }
    }

    /** Redacted support bundle (plan T8.5); the client saves it where the user chooses. */
    get("/diagnostics/export") {
        Metrics.recordRequest("diagnostics/export")
        val health = com.lagradost.macos.models.HealthDto(
            uptimeMs = System.currentTimeMillis() - Metrics.startedAtMs,
            providersLoaded = PluginBridge.allProviders().size,
        )
        call.respondText(DiagnosticsExport.build(health).toString(), ContentType.Application.Json)
    }

    get("/diagnostics") {
        Metrics.recordRequest("diagnostics")
        call.respond(Metrics.snapshot())
    }
}

private fun networkSettingsDto(): NetworkSettingsDto {
    val current = NetworkSetup.current
    return NetworkSettingsDto(
        dns = current.dns,
        customDohUrl = current.customDohUrl,
        httpCacheMb = current.httpCacheMb,
        retryOnNetworkError = current.retryOnNetworkError,
        githubMirror = current.githubMirror,
        resolvers = com.lagradost.macos.network.DohProvider.entries.map { ResolverOptionDto(it.id, it.label) },
        cacheSizeBytes = NetworkSetup.cacheSizeBytes(),
    )
}

/** The raw (still percent-encoded) path and query after `/media/relay/<id>/`. */
private fun relayRest(call: io.ktor.server.application.ApplicationCall): String {
    val uri = call.request.uri
    val afterPrefix = uri.removePrefix(MediaRelay.PATH_PREFIX)
    return afterPrefix.substringAfter('/', "")
}
