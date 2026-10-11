package com.lagradost.macos

import com.lagradost.cloudstream3.SubtitleFile
import com.lagradost.cloudstream3.newAudioFile
import com.lagradost.cloudstream3.newSubtitleFile
import com.lagradost.cloudstream3.utils.ExtractorLink
import com.lagradost.cloudstream3.utils.ExtractorLinkType
import com.lagradost.cloudstream3.utils.ExtractorRouting
import com.lagradost.cloudstream3.utils.Levenshtein
import com.lagradost.cloudstream3.utils.newExtractorLink
import com.lagradost.cloudstream3.utils.schemaStripRegex
import com.lagradost.macos.models.LinksResponseDto
import com.lagradost.macos.models.OperationFailureDto
import com.lagradost.macos.models.StreamLinkDto
import com.lagradost.macos.models.SubtitleDto
import com.lagradost.macos.worker.ExtractRequest
import com.lagradost.macos.worker.ExtractorDescriptor
import com.lagradost.macos.worker.FrameCodec
import com.lagradost.macos.worker.Op
import com.lagradost.macos.worker.RemoteProvider
import com.lagradost.macos.worker.WorkerHandle
import com.lagradost.macos.worker.WorkerPlugin
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.sync.Semaphore
import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.CoroutineContext

/**
 * State of one routed extraction (RT-12), carried in the coroutine context:
 * installations already on the route, its depth and its deadline. Absent when
 * a route starts. The deadline is monotonic and local to this process; across
 * processes only the remaining duration is sent (RT-10).
 */
internal class ExtractorRoute private constructor(
    val visited: Set<String>,
    val hops: Int,
    private val deadlineAt: Long,
    /** Collects failures of routed calls for callers that report them (`/extract`). */
    val failures: MutableList<OperationFailureDto>?,
) : AbstractCoroutineContextElement(Key) {
    companion object Key : CoroutineContext.Key<ExtractorRoute> {
        private fun monotonicMs(): Long = System.nanoTime() / 1_000_000

        /** A route that must finish within [budgetMs] from now. */
        fun within(budgetMs: Long, visited: Set<String> = emptySet(), hops: Int = 0,
            failures: MutableList<OperationFailureDto>? = null) = ExtractorRoute(visited, hops, monotonicMs() + budgetMs, failures)
    }

    fun remainingMs(): Long = deadlineAt - monotonicMs()

    /** The same route and deadline, reporting failures to [sink]. */
    fun reportingTo(sink: MutableList<OperationFailureDto>) = ExtractorRoute(visited, hops, deadlineAt, sink)
}

/**
 * Routes a URL that no in-process extractor claims to the worker whose
 * extension registered a matching extractor (RT-12). On Android every
 * extension's extractors share one process; here each extension has its own,
 * so without routing a provider could only use built-ins and its own
 * extractors.
 *
 * Matching mirrors the library's `loadExtractor`: newest installation first,
 * URL prefix before mirror-domain similarity. Stopped workers are started on
 * demand from the descriptors persisted with the install receipt. Routes are
 * bounded by visited installations (no cycles), [MAX_HOPS], the caller's
 * deadline and [MAX_CONCURRENT_ROUTES]; workers can lie about route state, so
 * the concurrency bound is what finally caps a misbehaving one.
 */
internal object ExtractorRouter {
    const val MAX_HOPS = 3
    const val MAX_CANDIDATES = 3
    const val MAX_CONCURRENT_ROUTES = 16
    const val MIN_BUDGET_MS = 2_000L
    private const val MAX_VISITED = 16
    private const val MAX_URL_LENGTH = 8_192
    private const val MAX_FAILURES = 8

    private val routes = Semaphore(MAX_CONCURRENT_ROUTES)

    /** Loaded (enabled, current) worker generations with their extractors, newest first. Tests replace it. */
    @Volatile internal var registrations: () -> List<Pair<WorkerHandle, List<ExtractorDescriptor>>> = ::loadedRegistrations

    private fun loadedRegistrations(): List<Pair<WorkerHandle, List<ExtractorDescriptor>>> =
        PluginBridge.getAllLoadedDescriptors()
            .mapNotNull { (it.plugin as? WorkerPlugin)?.handle }
            .filter { !it.retired }
            .sortedByDescending { it.record.installedAt }
            .map { it to (it.initResult?.extractors ?: it.record.extractorDescriptors) }
            .filter { it.second.isNotEmpty() }

    /** Makes in-process `loadExtractor` calls (control plane) fall back to worker extractors. */
    fun install() {
        ExtractorRouting.fallback = { url, referer, onSubtitle, onLink ->
            val route = currentCoroutineContext()[ExtractorRoute]
                ?: ExtractorRoute.within(OperationBudget.DEFAULT_MS)
            val result = route(url, referer, route)
            if (result == null) false else {
                route.failures?.let { sink -> synchronized(sink) { sink.addAll(result.failures) } }
                deliver(result, onSubtitle, onLink)
            }
        }
    }

    /** Installations to try for [url], at most one per installation. */
    fun candidates(url: String, exclude: Set<String>): List<WorkerHandle> {
        val registered = registrations().filter { it.first.installationId !in exclude }
        val compareUrl = url.lowercase().replace(schemaStripRegex, "")
        fun matching(test: (ExtractorDescriptor) -> Boolean) = registered
            .filter { (_, extractors) -> extractors.asReversed().any { it.mainUrl.isNotBlank() && test(it) } }
            .map { it.first }
        val byPrefix = matching { compareUrl.startsWith(it.mainUrl.replace(schemaStripRegex, "")) }
        val byMirror = matching { Levenshtein.partialRatio(it.mainUrl, url) > 80 }
        return (byPrefix + byMirror).distinctBy { it.installationId }.take(MAX_CANDIDATES)
    }

    /**
     * Tries candidates in order until one yields links or subtitles. Null when
     * the route may not continue or nothing matches; otherwise the (sanitized)
     * result, possibly empty with failures.
     */
    suspend fun route(url: String, referer: String?, route: ExtractorRoute, waitForCapacity: Boolean = true): LinksResponseDto? {
        if (route.hops >= MAX_HOPS || url.length > MAX_URL_LENGTH || !url.startsWith("http", ignoreCase = true)) return null
        val candidates = candidates(url, route.visited)
        if (candidates.isEmpty()) return null
        val failures = mutableListOf<OperationFailureDto>()
        if (!routes.tryAcquire()) {
            failures += OperationFailures.capture(null, "extract", WorkerCapacityException()).failure
            return empty(failures)
        }
        try {
            for (handle in candidates) {
                val remaining = route.remainingMs()
                if (remaining < MIN_BUDGET_MS) break
                val request = ExtractRequest(url, referer, (route.visited + handle.installationId).toList(), route.hops + 1,
                    remaining - OperationBudget.WORKER_MARGIN_MS)
                val response = try {
                    handle.call(Op.EXTRACT, FrameCodec.json.encodeToJsonElement(ExtractRequest.serializer(), request),
                        LinksResponseDto.serializer(), remaining, waitForCapacity = waitForCapacity)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (failure: Throwable) {
                    if (failure is VirtualMachineError && failure !is StackOverflowError) throw failure
                    failures += OperationFailures.capture(null, "extract", failure).failure.copy(installationId = handle.installationId)
                    continue
                }
                val clean = sanitize(response)
                if (clean.links.isNotEmpty() || clean.subtitles.isNotEmpty()) return clean.copy(failures = failures + clean.failures)
                failures += response.failures.take(MAX_FAILURES)
            }
        } finally { routes.release() }
        return empty(failures)
    }

    /**
     * Answers a worker's nested extraction request. The worker's route state is
     * untrusted: the origin is always added to the visited set and the budget
     * is clamped to the engine's own default. The calling worker is itself the
     * busy capacity, so a full pool is refused at once rather than waited on.
     */
    suspend fun answer(originInstallation: String, request: ExtractRequest): LinksResponseDto {
        val visited = request.visited.asSequence().take(MAX_VISITED)
            .filter { RepositoryService.normalizedHash(it) == it }.toSet() + originInstallation
        val budget = (request.budgetMs ?: OperationBudget.DEFAULT_MS).coerceIn(0, OperationBudget.DEFAULT_MS)
        val route = ExtractorRoute.within(budget, visited, request.hops.coerceIn(0, MAX_HOPS))
        return route(request.url, request.referer?.take(MAX_URL_LENGTH), route, waitForCapacity = false) ?: empty(emptyList())
    }

    private fun empty(failures: List<OperationFailureDto>) = LinksResponseDto(provider = "extractor",
        failures = failures.take(MAX_FAILURES), outcome = if (failures.isEmpty()) "success" else "failure")

    /** Worker output is untrusted: bound it and sanitize every URL. */
    fun sanitize(response: LinksResponseDto): LinksResponseDto = response.copy(
        provider = "extractor",
        providerId = null,
        links = response.links.take(RemoteProvider.MAX_LINKS).map(RemoteProvider::cleanLink),
        subtitles = response.subtitles.take(RemoteProvider.MAX_SUBTITLES).map(RemoteProvider::cleanSubtitle),
        failures = response.failures.take(MAX_FAILURES),
    )

    /** Hands a routed result to the library callbacks; true when anything was produced. */
    suspend fun deliver(result: LinksResponseDto, onSubtitle: (SubtitleFile) -> Unit, onLink: (ExtractorLink) -> Unit): Boolean {
        result.subtitles.forEach { onSubtitle(toSubtitleFile(it)) }
        val links = result.links.mapNotNull { toExtractorLink(it) }
        links.forEach(onLink)
        return links.isNotEmpty() || result.subtitles.isNotEmpty()
    }

    private suspend fun toSubtitleFile(dto: SubtitleDto): SubtitleFile = newSubtitleFile(dto.language, dto.url)

    /**
     * Rebuilds a library link. Playlist links (segment lists with durations)
     * don't survive the DTO and are skipped.
     */
    internal suspend fun toExtractorLink(dto: StreamLinkDto): ExtractorLink? {
        if (dto.isPlaylist) return null
        val type = runCatching { ExtractorLinkType.valueOf(dto.type) }.getOrNull() ?: return null
        val referer = dto.headers.entries.firstOrNull { it.key.equals("referer", ignoreCase = true) }?.value.orEmpty()
        val audio = dto.audioTracks.map { track ->
            newAudioFile(track.url) { headers = track.headers; label = track.label; language = track.language }
        }
        return newExtractorLink(dto.source, dto.name, dto.url, type) {
            this.quality = dto.quality
            this.headers = dto.headers.filterKeys { !it.equals("referer", ignoreCase = true) }
            this.referer = referer
            this.extractorData = dto.extractorData
            this.audioTracks = audio
        }
    }
}
