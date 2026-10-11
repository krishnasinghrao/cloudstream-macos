package com.lagradost.macos

import com.lagradost.cloudstream3.MainAPI
import com.lagradost.macos.models.ProviderTestResultDto
import com.lagradost.macos.models.ProviderTestStepDto
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit

/**
 * End-to-end provider health check (Android `settings/testing/TestFragment`
 * parity, Offline-Features-Plan Phase 8): homepage → search → details →
 * links, each with its timing. Steps reuse [ProviderExecutor] so they get the
 * same timeouts, caches and error barriers real use gets. Links are resolved
 * but never played or downloaded.
 */
object ProviderTester {
    private const val PARALLELISM = 3
    const val DEFAULT_QUERY = "the"

    suspend fun runAll(
        providers: List<MainAPI>,
        query: String = DEFAULT_QUERY,
        onResult: (ProviderTestResultDto) -> Unit,
    ) = coroutineScope {
        val permits = Semaphore(PARALLELISM)
        providers.map { provider ->
            async(Dispatchers.IO) { permits.withPermit { onResult(test(provider, query)) } }
        }.awaitAll()
        Unit
    }

    suspend fun test(provider: MainAPI, query: String = DEFAULT_QUERY): ProviderTestResultDto {
        val steps = mutableListOf<ProviderTestStepDto>()
        var sampleUrl: String? = null

        if (provider.hasMainPage) {
            attempt(steps, "homepage") { ProviderExecutor.loadHome(provider, 1) }?.let { (home, ms) ->
                val items = home.lists.flatMap { it.items }
                steps += ProviderTestStepDto("homepage", ok = items.isNotEmpty(), latencyMs = ms,
                    detail = if (items.isEmpty()) "no shelves" else "${home.lists.size} shelves, ${items.size} titles")
                sampleUrl = items.firstOrNull()?.url
            }
        }

        val (search, searchMs) = timed { ProviderExecutor.searchOne(provider, query) }
        steps += ProviderTestStepDto("search", ok = search.error == null && search.results.isNotEmpty(), latencyMs = searchMs,
            detail = search.error ?: "${search.results.size} results for “$query”")
        sampleUrl = sampleUrl ?: search.results.firstOrNull()?.url

        if (sampleUrl == null) {
            steps += ProviderTestStepDto("details", ok = false, detail = "skipped — no title to open")
            return result(provider, steps)
        }

        val (details, detailsMs) = attempt(steps, "details") { ProviderExecutor.loadDetails(provider, sampleUrl, refresh = true) }
            ?: return result(provider, steps)
        steps += ProviderTestStepDto("details", ok = true, latencyMs = detailsMs,
            detail = "“${details.name}” — " + if (details.episodes.isEmpty()) "movie" else "${details.episodes.size} episodes")

        val data = details.movieData ?: details.episodes.firstOrNull()?.data
        if (data.isNullOrEmpty()) {
            steps += ProviderTestStepDto("links", ok = false, detail = "skipped — no playable data")
            return result(provider, steps)
        }
        val (links, linksMs) = attempt(steps, "links") { ProviderExecutor.loadLinks(provider, data) }
            ?: return result(provider, steps)
        steps += ProviderTestStepDto("links", ok = links.links.isNotEmpty(), latencyMs = linksMs,
            detail = "${links.links.size} streams, ${links.subtitles.size} subtitles")
        return result(provider, steps)
    }

    private fun result(provider: MainAPI, steps: List<ProviderTestStepDto>): ProviderTestResultDto {
        val status = when {
            steps.all { it.ok } -> "pass"
            steps.any { it.ok } -> "partial"
            else -> "fail"
        }
        return ProviderTestResultDto(provider = provider.name, status = status, steps = steps)
    }

    /**
     * Times [block] as step [name]. [ProviderExecutor] reports a failed stage by
     * throwing, so the failure is recorded as a failed step and null is returned;
     * letting it escape would abort every other provider in a batch run.
     */
    private inline fun <T> attempt(steps: MutableList<ProviderTestStepDto>, name: String, block: () -> T): Pair<T, Long>? {
        val start = System.nanoTime()
        return try {
            timed(block)
        } catch (failure: OperationException) {
            steps += ProviderTestStepDto(name, ok = false, latencyMs = (System.nanoTime() - start) / 1_000_000,
                detail = failure.message ?: "failed")
            null
        }
    }

    private inline fun <T> timed(block: () -> T): Pair<T, Long> {
        val start = System.nanoTime()
        val value = block()
        return value to (System.nanoTime() - start) / 1_000_000
    }
}
