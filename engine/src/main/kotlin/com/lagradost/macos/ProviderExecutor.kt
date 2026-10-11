package com.lagradost.macos

import com.lagradost.cloudstream3.AnimeLoadResponse
import com.lagradost.cloudstream3.AnimeSearchResponse
import com.lagradost.cloudstream3.HomePageList
import com.lagradost.cloudstream3.LiveStreamLoadResponse
import com.lagradost.cloudstream3.MainAPI
import com.lagradost.cloudstream3.MainPageRequest
import com.lagradost.cloudstream3.MovieLoadResponse
import com.lagradost.cloudstream3.MovieSearchResponse
import com.lagradost.cloudstream3.Score
import com.lagradost.cloudstream3.SearchResponse
import com.lagradost.cloudstream3.TvSeriesLoadResponse
import com.lagradost.cloudstream3.TvSeriesSearchResponse
import com.lagradost.cloudstream3.isMovieType
import com.lagradost.macos.models.ActorDto
import com.lagradost.macos.models.DetailsDto
import com.lagradost.macos.models.EpisodeDto
import com.lagradost.macos.models.HomePageDto
import com.lagradost.macos.models.HomePageListDto
import com.lagradost.macos.models.LinksResponseDto
import com.lagradost.macos.models.NextAiringDto
import com.lagradost.macos.models.SeasonNameDto
import com.lagradost.macos.models.TrailerDto
import com.lagradost.cloudstream3.EpisodeResponse
import com.lagradost.macos.models.SearchResultDto
import com.lagradost.macos.models.StreamLinkDto
import com.lagradost.macos.models.SubtitleDto
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.ensureActive
import com.lagradost.macos.models.OperationFailureDto
import com.lagradost.macos.worker.RemoteProvider

/**
 * Executes provider calls across all loaded plugins with structured concurrency.
 *
 * Coroutine deadlines cancel cooperative provider work. Blocking callbacks still
 * require the isolated-worker boundary before hard deadlines can be guaranteed.
 * Every call is recorded into [Metrics] for /diagnostics, and disabled
 * providers (DaemonState) are skipped.
 */
object ProviderExecutor {
    private const val REMOTE_MARGIN_MS = OperationBudget.WORKER_MARGIN_MS
    private const val EXTRACT_TIMEOUT_MS = OperationBudget.DEFAULT_MS

    /** Providers the user disabled in Settings are invisible to all queries. */
    private fun usable(providers: List<MainAPI>): List<MainAPI> =
        providers.filter { DaemonState.isProviderEnabled(PluginBridge.providerId(it)) }

    /** Visible providers (enabled + optional provider ID, name or installation filter). */
    fun providers(filter: List<String>? = null): List<MainAPI> =
        usable(PluginBridge.allProviders()).filter { provider ->
            filter == null || filter.isEmpty() ||
                PluginBridge.providerId(provider) in filter || provider.name in filter || provider.sourcePlugin in filter
        }

    /** Exact provider ID, or a provider name when it is unambiguous. */
    fun findProvider(idOrName: String): MainAPI? =
        PluginBridge.findProvider(idOrName)?.takeIf { DaemonState.isProviderEnabled(PluginBridge.providerId(it)) }

    /** Why [findProvider] returned nothing, as a sentence the client can show. */
    fun unavailableReason(idOrName: String): String {
        val needle = idOrName.trim()
        if (needle.isEmpty()) return "No provider was given for this title."
        val loaded = PluginBridge.allProviders()
        if (loaded.count { it.name == needle } > 1) {
            return "More than one installed provider is named “$needle”. Choose which one owns this title (Library ▸ Choose Provider…)."
        }
        // An ID is `<installationId>:<name>`; a bare name comes from older or imported records.
        val installationId = needle.substringBefore(':', "").takeIf { it.length == 64 }
        val name = if (installationId != null) needle.substringAfter(':') else needle
        loaded.firstOrNull { PluginBridge.providerId(it) == needle || it.name == name }?.let {
            return "The provider “${it.name}” is turned off. Turn it on in Settings ▸ Extensions."
        }
        val installations = DaemonState.snapshot().installations.values
        val owner = installations.firstOrNull { it.id == installationId }
            ?: installations.firstOrNull { name in it.providerNames }
            ?: return "No installed extension provides “$name”. Install it from Settings ▸ Extensions."
        val extension = owner.metadata.name.ifBlank { owner.internalName }
        val manager = RepositoryService.installations
        return when {
            owner.revokedReason != null -> "The extension “$extension” is disabled: ${owner.revokedReason}"
            owner.quarantinedReason != null -> "The extension “$extension” was stopped: ${owner.quarantinedReason}"
            !owner.enabled -> "The extension “$extension” is turned off. Turn it on in Settings ▸ Extensions."
            name !in owner.providerNames && owner.providerNames.isNotEmpty() ->
                "The extension “$extension” no longer provides “$name” (it now provides ${owner.providerNames.joinToString { "“$it”" }}). Choose another provider for this title."
            manager.lastError(owner.id) != null -> "The extension “$extension” could not start: ${manager.lastError(owner.id)}"
            manager.restoreState.phase == "restoring" -> "The extension “$extension” is still starting. Try again in a moment."
            else -> "The extension “$extension” is installed but did not load “$name”. Retry it in Settings ▸ Extensions."
        }
    }

    /** Bounded fan-out so one query cannot occupy every IO worker. */
    private val searchPermits = kotlinx.coroutines.sync.Semaphore(8)

    // ------------------------------------------------------------------ search

    /**
     * Parallel search across [providers]. Each provider runs on Dispatchers.IO
     * with an individual [SEARCH_TIMEOUT_MS] barrier. Failures are contained:
     * one broken provider never affects the others.
     */
    suspend fun searchAll(query: String, providers: List<MainAPI>): List<SearchResultDto> =
        coroutineScope {
            usable(providers)
                .map { provider ->
                    async(Dispatchers.IO) { searchOne(provider, query) }
                }
                .awaitAll()
                .flatMap { it.results }
        }

    /** Outcome of one provider's search for the streaming endpoint. */
    data class ProviderSearchResult(
        val provider: String,
        val results: List<SearchResultDto>,
        val error: String?,
        val providerId: String = provider,
        val failure: OperationFailureDto? = null,
    )

    /**
     * Searches a single provider with the full barrier treatment — used by the
     * NDJSON streaming endpoint so faster providers surface first.
     */
    suspend fun searchOne(provider: MainAPI, query: String): ProviderSearchResult {
        searchPermits.acquire()
        return try { executeSearch(provider, query) } finally { searchPermits.release() }
    }

    private suspend fun executeSearch(provider: MainAPI, query: String): ProviderSearchResult {
        val start = System.nanoTime()
        val budget = OperationBudget.forHint(provider.searchTimeoutMs)
        return try {
            val results = safeProvider(provider, "search") {
                if (provider is RemoteProvider) provider.remoteSearch(query, budget + REMOTE_MARGIN_MS)
                else withTimeout(budget) { searchWithApiFallback(provider, query)?.map { toDto(it, provider) } }
            } ?: throw OperationFailures.capture(provider, "search", ProviderNoDataException())
            Metrics.recordProviderSuccess(provider.name, (System.nanoTime() - start) / 1_000_000)
            OperationHealth.success(provider, OperationHealth.Stage.SEARCH)
            ProviderSearchResult(provider.name, results, null, PluginBridge.providerId(provider))
        } catch (failure: OperationException) {
            Metrics.recordProviderFailure(provider.name, failure.failure.code)
            OperationHealth.failure(provider, OperationHealth.Stage.SEARCH, failure.failure)
            ProviderSearchResult(provider.name, emptyList(), failure.failure.publicMessage, PluginBridge.providerId(provider), failure.failure)
        }
    }

    // MainAPI's paginated default already delegates to legacy search. Calling
    // legacy again on null both repeats the request and masks a real failure.
    private suspend fun searchWithApiFallback(provider: MainAPI, query: String): List<SearchResponse>? =
        provider.search(query, 1)?.items

    // ------------------------------------------------------------------ home

    /**
     * Provider homepage shelves via MainAPI.getMainPage(page, request).
     * Providers without a homepage throw NotImplementedError from the base
     * method; that surfaces as an empty home response, not a crash.
     */
    suspend fun loadHome(provider: MainAPI, page: Int): HomePageDto {
        require(page > 0) { "Homepage page must be positive" }
        if (!provider.hasMainPage && provider.mainPage.isEmpty()) return HomePageDto(provider = provider.name, providerId = PluginBridge.providerId(provider), page = page)
        val start = System.currentTimeMillis()
        val budget = OperationBudget.forHint(provider.getMainPageTimeoutMs)
        if (provider is RemoteProvider) {
            val home = try { safeProvider(provider, "getMainPage") { provider.remoteHome(page, budget + REMOTE_MARGIN_MS) } }
                catch (failure: OperationException) { OperationHealth.failure(provider, OperationHealth.Stage.HOME, failure.failure); throw failure }
            if (home.failures.isEmpty()) Metrics.recordProviderSuccess(provider.name, System.currentTimeMillis() - start)
            else Metrics.recordProviderFailure(provider.name, home.failures.first().code)
            recordHealth(provider, OperationHealth.Stage.HOME, home.failures, produced = home.lists.isNotEmpty())
            return home
        }
        val completed = java.util.concurrent.ConcurrentHashMap<Int, com.lagradost.cloudstream3.HomePageResponse>()
        val failures = java.util.concurrent.CopyOnWriteArrayList<OperationFailureDto>()
        try {
            safeProvider(provider, "getMainPage") {
                withTimeout(budget) {
                    kotlinx.coroutines.withContext(Dispatchers.IO) {
                        val shelves = provider.mainPage
                        require(shelves.size <= 64) { "Provider declares too many homepage requests" }
                        if (page > 1) {
                            val elapsed = (System.currentTimeMillis() - provider.lastHomepageRequest).coerceAtLeast(0)
                            val wait = provider.sequentialMainPageScrollDelay.coerceAtLeast(0) - elapsed
                            if (wait > 0) kotlinx.coroutines.delay(wait)
                        }
                        provider.lastHomepageRequest = System.currentTimeMillis()
                        suspend fun request(index: Int) {
                            kotlinx.coroutines.currentCoroutineContext().ensureActive()
                            val data = shelves[index]
                            try {
                                safeProvider(provider, "getMainPage[$index]") {
                                    provider.getMainPage(page, MainPageRequest(data.name, data.data, data.horizontalImages))
                                }?.let { completed[index] = it } ?: throw OperationFailures.capture(provider, "getMainPage", ProviderNoDataException())
                            } catch (failure: OperationException) { failures.add(failure.failure) }
                        }
                        if (provider.sequentialMainPage) {
                            shelves.indices.forEach { index ->
                                if (index > 0) kotlinx.coroutines.delay(provider.sequentialMainPageDelay.coerceAtLeast(0))
                                request(index)
                            }
                        } else {
                            val permits = kotlinx.coroutines.sync.Semaphore(4)
                            coroutineScope { shelves.indices.map { index -> async {
                                permits.acquire()
                                try { request(index) } finally { permits.release() }
                            } }.awaitAll() }
                        }
                    }
                }
            }
        } catch (failure: OperationException) { failures.add(failure.failure) }
        val responses = completed.toSortedMap().values
        if (failures.isEmpty()) Metrics.recordProviderSuccess(provider.name, System.currentTimeMillis() - start)
        else Metrics.recordProviderFailure(provider.name, failures.first().code)
        recordHealth(provider, OperationHealth.Stage.HOME, failures, produced = responses.isNotEmpty())
        return HomePageDto(provider = provider.name, providerId = PluginBridge.providerId(provider), page = page,
            hasNext = responses.any { it.hasNext },
            lists = responses.flatMap { response -> response.items.map { toListDto(it, provider) } },
            failures = failures.toList(), outcome = if (failures.isEmpty()) "success" else if (responses.isEmpty()) "failure" else "partial")
    }

    private fun toListDto(list: HomePageList, provider: MainAPI): HomePageListDto = HomePageListDto(
        name = list.name,
        isHorizontal = list.isHorizontalImages,
        items = list.list.map { toDto(it, provider) },
    )

    // ------------------------------------------------------------------ details

    /**
     * Details cache (Android `APIRepository.load` parity): re-opening a title,
     * resuming from Continue Watching and background episode checks within
     * [DETAILS_CACHE_TTL_MS] reuse the last load instead of re-scraping.
     * Keyed by provider + URL; failures are never cached.
     */
    private const val DETAILS_CACHE_TTL_MS = 10 * 60_000L
    private const val DETAILS_CACHE_MAX_ENTRIES = 50

    private data class CachedDetails(val details: DetailsDto, val storedAt: Long)

    private val detailsCache = object : LinkedHashMap<String, CachedDetails>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, CachedDetails>?): Boolean =
            size > DETAILS_CACHE_MAX_ENTRIES
    }

    /** Test/diagnostic clock seam. */
    internal var now: () -> Long = System::currentTimeMillis

    /** Keys start with the provider ID (installation-scoped), so one extension's
     * update invalidates only its own entries. */
    private fun detailsCacheKey(provider: MainAPI, url: String) = "${PluginBridge.providerId(provider)}\u0000$url"

    internal fun cachedDetails(provider: MainAPI, url: String): DetailsDto? = synchronized(detailsCache) {
        val key = detailsCacheKey(provider, url)
        val entry = detailsCache[key] ?: return null
        if (now() - entry.storedAt > DETAILS_CACHE_TTL_MS) {
            detailsCache.remove(key)
            return null
        }
        entry.details
    }

    internal fun storeDetails(provider: MainAPI, url: String, details: DetailsDto) = synchronized(detailsCache) {
        detailsCache[detailsCacheKey(provider, url)] = CachedDetails(details, now())
    }

    /**
     * Drops every cached provider response. Called whenever the provider set
     * changes (install, uninstall, enable, disable, repository sync) so a
     * replaced plugin never serves its predecessor's results.
     */
    fun invalidateCaches() {
        synchronized(detailsCache) { detailsCache.clear() }
        synchronized(linksCache) { linksCache.clear() }
        DaemonLog.info("provider.caches_invalidated")
    }

    /** Drops cached responses produced by one provider (extension or built-in). */
    fun invalidateProvider(providerId: String) {
        val prefix = "$providerId\u0000"
        synchronized(detailsCache) { detailsCache.keys.removeAll { it.startsWith(prefix) } }
        synchronized(linksCache) { linksCache.keys.removeAll { it.startsWith(prefix) } }
    }

    /** Drops cached responses produced by one installation's providers. */
    fun invalidateCaches(installationId: String) {
        val prefix = "$installationId:"
        synchronized(detailsCache) { detailsCache.keys.removeAll { it.startsWith(prefix) } }
        synchronized(linksCache) { linksCache.keys.removeAll { it.startsWith(prefix) } }
    }

    /**
     * Loads full media details for one provider result URL.
     * @param refresh bypasses (and replaces) the cached entry — the client's ⌘R.
     */
    suspend fun loadDetails(provider: MainAPI, url: String, refresh: Boolean = false): DetailsDto {
        if (!refresh) cachedDetails(provider, url)?.let { return it }
        val start = System.currentTimeMillis()
        val budget = OperationBudget.forHint(provider.loadTimeoutMs)
        val details = try {
            safeProvider(provider, "load") {
                if (provider is RemoteProvider) provider.remoteDetails(url, budget + REMOTE_MARGIN_MS)
                else withTimeout(budget) { provider.load(url)?.let { toDetailsDto(provider, it) } }
            } ?: throw OperationFailures.capture(provider, "load", ProviderNoDataException(), System.currentTimeMillis() - start)
        } catch (failure: OperationException) {
            OperationHealth.failure(provider, OperationHealth.Stage.DETAILS, failure.failure)
            throw failure
        }
        Metrics.recordProviderSuccess(provider.name, System.currentTimeMillis() - start)
        OperationHealth.success(provider, OperationHealth.Stage.DETAILS)
        storeDetails(provider, url, details)
        return details
    }

    // ------------------------------------------------------------------ links

    /**
     * Resolves stream links and subtitles for an episode/movie data string.
     * Links are sorted by quality (failover order) and sanitized (SEC-04).
     */
    /**
     * Resolved-link cache (Player-Remediation-Plan A3). Re-opening an episode,
     * mirror retries, and the client's next-episode prefetch hit this instead
     * of re-running every extractor. The TTL stays short because CDN URLs are
     * frequently signed with a near expiry.
     */
    private const val LINKS_CACHE_TTL_MS = 3 * 60_000L
    private const val LINKS_CACHE_MAX_ENTRIES = 64

    private data class CachedLinks(val response: LinksResponseDto, val storedAt: Long)

    private val linksCache = object : LinkedHashMap<String, CachedLinks>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, CachedLinks>?): Boolean =
            size > LINKS_CACHE_MAX_ENTRIES
    }

    private fun linksCacheKey(provider: MainAPI, data: String) = "${PluginBridge.providerId(provider)}\u0000$data"

    private fun cachedLinks(provider: MainAPI, data: String): LinksResponseDto? = synchronized(linksCache) {
        val key = linksCacheKey(provider, data)
        val entry = linksCache[key] ?: return null
        if (System.currentTimeMillis() - entry.storedAt > LINKS_CACHE_TTL_MS) {
            linksCache.remove(key)
            return null
        }
        entry.response
    }

    private fun storeLinks(provider: MainAPI, data: String, response: LinksResponseDto) {
        // Never cache an empty resolution: a transient scrape failure would
        // otherwise pin "no streams" for the whole TTL.
        if (response.links.isEmpty()) return
        synchronized(linksCache) {
            linksCache[linksCacheKey(provider, data)] = CachedLinks(response, System.currentTimeMillis())
        }
    }

    /**
     * Runs the registered extractors (bundled + plugin) on a single URL —
     * trailers point at YouTube and friends rather than at a provider page.
     * Returns an empty response when no extractor claims the URL.
     */
    suspend fun extract(url: String, referer: String?, budgetMs: Long = EXTRACT_TIMEOUT_MS): LinksResponseDto {
        val links = mutableListOf<StreamLinkDto>()
        val subtitles = LinkedHashMap<String, SubtitleDto>()
        val intake = LinkIntake()
        val failures = mutableListOf<OperationFailureDto>()
        // Extractors of other extensions run in their workers; the loadExtractor
        // fallback routes to them (RT-12) and reports their failures here.
        val outer = currentCoroutineContext()[ExtractorRoute]
        val route = outer?.reportingTo(failures) ?: ExtractorRoute.within(budgetMs, failures = failures)
        try { safeProvider(null, "extract") {
            withTimeout(budgetMs) {
                withContext(route) {
                    com.lagradost.cloudstream3.utils.loadExtractor(
                        url = url,
                        referer = referer,
                        subtitleCallback = { sub -> synchronized(intake) { intake.subtitle(sub) }?.let { synchronized(subtitles) { subtitles.putIfAbsent(it.url, it) } } },
                        callback = { link -> synchronized(intake) { intake.link(link) }?.let { synchronized(links) { links.add(it) } } },
                    )
                }
            }
        }
        } catch (failure: OperationException) { synchronized(failures) { failures.add(failure.failure) } }
        val reported = synchronized(failures) { failures.toList() }
        val found = synchronized(links) { links.sortedByDescending { it.quality } }
        return LinksResponseDto(
            provider = "extractor",
            failures = reported, outcome = if (reported.isEmpty()) "success" else if (found.isEmpty()) "failure" else "partial",
            links = found,
            subtitles = synchronized(subtitles) { subtitles.values.toList() },
            skipped = synchronized(intake) { intake.skipped.toList() },
        )
    }

    /** A stage that produced results counts as working even when some of its parts failed. */
    private fun recordHealth(provider: MainAPI, stage: String, failures: List<OperationFailureDto>, produced: Boolean) {
        if (produced || failures.isEmpty()) OperationHealth.success(provider, stage)
        else OperationHealth.failure(provider, stage, failures.first())
    }

    /** Complete (batch) resolution — POST /links and download JIT resolution. */
    suspend fun loadLinks(provider: MainAPI, data: String): LinksResponseDto =
        loadLinksStreaming(provider, data, onLink = {}, onSubtitle = {})

    /**
     * Progressive resolution (Player-Remediation-Plan A2): every link and
     * subtitle is reported the moment its extractor produces it, so the
     * client can start playback long before the slowest extractor finishes.
     * The complete, quality-sorted response is still returned (and cached).
     */
    suspend fun loadLinksStreaming(
        provider: MainAPI,
        data: String,
        onLink: (StreamLinkDto) -> Unit,
        onSubtitle: (SubtitleDto) -> Unit,
    ): LinksResponseDto {
        cachedLinks(provider, data)?.let { cached ->
            cached.links.forEach(onLink)
            cached.subtitles.forEach(onSubtitle)
            return cached
        }

        val links = mutableListOf<StreamLinkDto>()
        val subtitles = LinkedHashMap<String, SubtitleDto>()
        val intake = LinkIntake()
        val start = System.currentTimeMillis()

        val failures = mutableListOf<OperationFailureDto>()
        var remote: LinksResponseDto? = null
        try {
            safeProvider(provider, "loadLinks") {
                val budget = OperationBudget.forHint(provider.loadLinksTimeoutMs)
                if (provider is RemoteProvider) {
                    val response = provider.remoteLinks(data, budget + REMOTE_MARGIN_MS,
                        onLink = { dto -> synchronized(links) { links.add(dto) }; onLink(dto) },
                        onSubtitle = { dto -> if (synchronized(subtitles) { subtitles.putIfAbsent(dto.url, dto) == null }) onSubtitle(dto) })
                    remote = response
                    failures.addAll(response.failures)
                } else {
                    val success = withTimeout(budget) { provider.loadLinks(data, false,
                        subtitleCallback = { sub ->
                            val dto = synchronized(intake) { intake.subtitle(sub) }
                            if (dto != null && synchronized(subtitles) { subtitles.putIfAbsent(dto.url, dto) == null }) onSubtitle(dto)
                        }, callback = { link ->
                            // Never throws: a link the Mac app cannot use is skipped, not raised into the extension (L1).
                            synchronized(intake) { intake.link(link) }?.let { dto ->
                                synchronized(links) { links.add(dto) }
                                onLink(dto)
                            }
                        }) }
                    if (!success) throw ProviderNoDataException()
                }
            }
        } catch (failure: OperationException) { failures.add(failure.failure) }
        val finalLinks = remote?.links ?: synchronized(links) { links.sortedByDescending { it.quality } }
        val skipped = remote?.skipped ?: synchronized(intake) { intake.skipped.toList() }
        if (finalLinks.isEmpty() && failures.isEmpty()) {
            failures.add(if (skipped.isNotEmpty()) OperationFailures.unsupportedSources(provider, skipped)
                else OperationFailures.capture(provider, "loadLinks", ProviderNoDataException()).failure)
        }
        if (failures.isEmpty()) Metrics.recordProviderSuccess(provider.name, System.currentTimeMillis() - start)
        else Metrics.recordProviderFailure(provider.name, failures.first().code)
        recordHealth(provider, OperationHealth.Stage.LINKS, failures, produced = finalLinks.isNotEmpty())
        val response = LinksResponseDto(provider = provider.name, providerId = PluginBridge.providerId(provider),
            links = finalLinks, subtitles = remote?.subtitles ?: synchronized(subtitles) { subtitles.values.toList() },
            failures = failures, outcome = if (failures.isEmpty()) "success" else if (finalLinks.isEmpty()) "failure" else "partial",
            skipped = skipped)
        if (failures.isEmpty()) storeLinks(provider, data, response)
        return response
    }

    // -------------------------------------------------------------------------
    // Mapping: CloudStream object graph -> stable IPC DTOs
    // -------------------------------------------------------------------------

    private fun toDto(response: SearchResponse, provider: MainAPI): SearchResultDto = SearchResultDto(
        name = response.name,
        url = response.url,
        provider = response.apiName,
        providerId = if (response.apiName == provider.name) PluginBridge.providerId(provider) else response.apiName,
        type = response.type?.name ?: "Others",
        posterUrl = response.posterUrl,
        quality = response.quality?.name,
        score = response.score.toScore100(),
        language = (response as? AnimeSearchResponse)?.let { anime ->
            anime.dubStatus?.joinToString(", ") { it.name.lowercase() }?.ifBlank { null }
        },
        episodes = (response as? TvSeriesSearchResponse)?.episodes
            ?: (response as? AnimeSearchResponse)?.episodes?.values?.maxOrNull(),
        year = (response as? MovieSearchResponse)?.year
            ?: (response as? TvSeriesSearchResponse)?.year
            ?: (response as? AnimeSearchResponse)?.year,
        isMovie = response.type?.isMovieType() == true,
        posterHeaders = response.posterHeaders?.takeIf { it.isNotEmpty() },
    )

    private fun toDetailsDto(provider: MainAPI, response: com.lagradost.cloudstream3.LoadResponse): DetailsDto {
        val episodes: List<EpisodeDto> = when (response) {
            is TvSeriesLoadResponse -> response.episodes.map { it.toDto() }
            // Sub/dub travel as the structured `audio` field; the client
            // renders its own DUB badge (no name-suffix hack).
            is AnimeLoadResponse -> response.episodes.flatMap { (status, list) ->
                val audio = if (status.name.equals("Dubbed", true)) "dub" else "sub"
                list.map { it.toDto(audio) }
            }
            else -> emptyList()
        }

        return DetailsDto(
            provider = provider.name,
            providerId = PluginBridge.providerId(provider),
            url = response.url,
            name = response.name,
            type = response.type.name,
            posterUrl = response.posterUrl,
            backgroundPosterUrl = response.backgroundPosterUrl,
            logoUrl = response.logoUrl,
            plot = response.plot,
            year = response.year,
            durationMinutes = RuntimeNormalizer.minutes(response.duration),
            score = response.score.toScore100(),
            tags = response.tags.orEmpty().map { it.trim() }.filter { it.isNotEmpty() }.distinct(),
            actors = response.actors.orEmpty().take(MAX_ACTORS).map { data ->
                ActorDto(
                    name = data.actor.name,
                    role = data.roleString ?: data.role?.name?.lowercase()?.replaceFirstChar { it.uppercase() },
                    image = data.actor.image,
                    voiceActor = data.voiceActor?.name,
                    voiceActorImage = data.voiceActor?.image,
                )
            },
            contentRating = response.contentRating,
            comingSoon = response.comingSoon,
            episodes = episodes,
            movieData = when (response) {
                is MovieLoadResponse -> response.dataUrl
                is LiveStreamLoadResponse -> response.dataUrl
                else -> null
            },
            recommendations = response.recommendations.orEmpty()
                .take(MAX_RECOMMENDATIONS)
                .mapNotNull { runCatching { toDto(it, provider) }.getOrNull() }
                .ifEmpty { null },
            trailers = response.trailers
                .filter { it.extractorUrl.startsWith("http", ignoreCase = true) }
                .take(MAX_TRAILERS)
                .map { TrailerDto(url = URLSanitizer.sanitizeStream(it.extractorUrl), referer = it.referer, raw = it.raw, headers = it.headers) }
                .ifEmpty { null },
            showStatus = (response as? EpisodeResponse)?.showStatus?.name,
            nextAiring = (response as? EpisodeResponse)?.nextAiring?.let {
                NextAiringDto(episode = it.episode, unixTime = it.unixTime, season = it.season)
            },
            seasonNames = (response as? EpisodeResponse)?.seasonNames
                ?.map { SeasonNameDto(season = it.season, name = it.name, displaySeason = it.displaySeason) }
                ?.ifEmpty { null },
            syncIds = response.syncData.filterValues { it.isNotBlank() }.ifEmpty { null },
            posterHeaders = response.posterHeaders?.takeIf { it.isNotEmpty() },
            uniqueUrl = response.uniqueUrl.takeIf { it.isNotBlank() && it != response.url },
        )
    }

    private const val MAX_ACTORS = 60
    private const val MAX_RECOMMENDATIONS = 30
    private const val MAX_TRAILERS = 5

    private fun com.lagradost.cloudstream3.Episode.toDto(audio: String? = null): EpisodeDto = EpisodeDto(
        data = data,
        name = name,
        season = season,
        episode = episode,
        posterUrl = posterUrl,
        description = description,
        score = score.toScore100(),
        date = date,
        runTimeMinutes = RuntimeNormalizer.minutes(runTime),
        audio = audio,
    )

    private fun Score?.toScore100(): Int? = try {
        this?.toInt(100)
    } catch (_: Throwable) {
        null
    }

    /**
     * Exception barrier (Rules.md §4.2): a malformed or crashing provider must
     * never take down the daemon or sibling providers.
     */
    private inline fun <T> safeProvider(provider: MainAPI?, operation: String, block: () -> T): T {
        val start = System.nanoTime()
        return try {
            PluginBridge.withLease(provider) { block() }
        } catch (thrown: Throwable) {
            val failure = OperationFailures.capture(provider, operation, thrown, (System.nanoTime() - start) / 1_000_000)
            DaemonLog.warn("provider.operation_failed", mapOf("provider" to failure.failure.providerId,
                "request" to failure.failure.requestId, "stage" to failure.failure.stage,
                "code" to failure.failure.code, "cause" to failure.failure.redactedCause))
            throw failure
        }
    }
}
