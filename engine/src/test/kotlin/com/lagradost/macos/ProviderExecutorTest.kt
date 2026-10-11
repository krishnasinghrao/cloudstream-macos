package com.lagradost.macos

import com.lagradost.cloudstream3.MainAPI
import com.lagradost.cloudstream3.MovieSearchResponse
import com.lagradost.cloudstream3.SearchResponse
import com.lagradost.cloudstream3.SearchResponseList
import com.lagradost.cloudstream3.TvType
import com.lagradost.cloudstream3.newSearchResponseList
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Provider execution guarantees (Rules.md §4.3): per-provider isolation, the
 * 5 s budget with per-provider hints, and the modern/legacy search-API
 * fallback — exercised through fake providers with no network.
 */
class ProviderExecutorTest {

    @Suppress("DEPRECATION_ERROR")
    private fun movie(providerName: String, title: String): SearchResponse = MovieSearchResponse(
        name = title,
        url = "https://fake.example/$title",
        apiName = providerName,
        type = TvType.Movie,
    )

    /** Modern-API provider: overrides search(query, page). */
    private class ModernApi(
        override var name: String,
        private val results: Int = 2,
    ) : MainAPI() {
        override var mainUrl = "https://modern.example"
        override val supportedTypes = setOf(TvType.Movie)

        override suspend fun search(query: String, page: Int): SearchResponseList? {
            @Suppress("DEPRECATION_ERROR")
            val items = (1..results).map { idx ->
                MovieSearchResponse(
                    name = "$name-$idx",
                    url = "https://modern.example/$idx",
                    apiName = name,
                    type = TvType.Movie,
                )
            }
            return newSearchResponseList(items, hasNext = false)
        }
    }

    /** Legacy-API provider: overrides search(query) only; the paged base delegates to it. */
    private class LegacyApi(override var name: String) : MainAPI() {
        override var mainUrl = "https://legacy.example"
        override val supportedTypes = setOf(TvType.TvSeries)

        override suspend fun search(query: String): List<SearchResponse> {
            @Suppress("DEPRECATION_ERROR")
            return listOf(
                MovieSearchResponse(
                    name = "$name-1",
                    url = "https://legacy.example/1",
                    apiName = name,
                    type = TvType.TvSeries,
                ),
            )
        }
    }

    /** Provider whose search always throws — must be contained, not propagated. */
    private class BrokenApi(override var name: String) : MainAPI() {
        override val supportedTypes = setOf(TvType.Others)
        override suspend fun search(query: String, page: Int): SearchResponseList? =
            throw IllegalStateException("scrape exploded")
    }

    /** Provider exceeding its own timeout hint — must be cancelled, not waited out. */
    private class SlowApi(override var name: String) : MainAPI() {
        override val supportedTypes = setOf(TvType.Others)
        override val searchTimeoutMs: Long = 150
        override suspend fun search(query: String, page: Int): SearchResponseList? {
            delay(10_000)
            return newSearchResponseList(emptyList())
        }
    }

    @Test
    fun `modern and legacy search APIs both work`() = runBlocking {
        val results = ProviderExecutor.searchAll(
            "query",
            listOf(ModernApi("Modern"), LegacyApi("Legacy")),
        )
        assertEquals(3, results.size) // 2 modern + 1 legacy
        assertEquals(setOf("Modern", "Legacy"), results.map { it.provider }.toSet())
    }

    @Test
    fun `broken provider is isolated and does not affect siblings`() = runBlocking {
        val results = ProviderExecutor.searchAll(
            "query",
            listOf(BrokenApi("Broken"), ModernApi("Healthy", results = 1)),
        )
        assertEquals(1, results.size)
        assertEquals("Healthy", results.single().provider)
    }

    @Test
    fun `slow provider is cancelled at the minimum Android-compatible budget`() = runBlocking {
        val start = System.currentTimeMillis()
        val results = ProviderExecutor.searchAll(
            "query",
            listOf(SlowApi("Slow"), ModernApi("Fast", results = 1)),
        )
        val elapsed = System.currentTimeMillis() - start
        assertTrue(elapsed in 4_800..7_500, "sub-minimum hint should clamp to 5 seconds, took ${elapsed}ms")
        assertEquals(1, results.size)
    }

    @Test
    fun `disabled providers are skipped`() = runBlocking {
        DaemonState.load()
        try {
            DaemonState.setProviderEnabled("Disabled", enabled = false)
            val results = ProviderExecutor.searchAll(
                "query",
                listOf(ModernApi("Disabled"), ModernApi("Enabled", results = 1)),
            )
            assertEquals(1, results.size)
            assertEquals("Enabled", results.single().provider)
        } finally {
            DaemonState.setProviderEnabled("Disabled", enabled = true)
        }
    }

    @Test
    fun `searchOne records per-provider outcome`() = runBlocking {
        val ok = ProviderExecutor.searchOne(ModernApi("MetricsOk"), "q")
        assertEquals(null, ok.error)
        assertEquals(2, ok.results.size)

        val broken = ProviderExecutor.searchOne(BrokenApi("MetricsBroken"), "q")
        assertTrue(broken.error != null)
        assertTrue(broken.results.isEmpty())
    }

    @Test
    fun `home returns empty dto for provider without getMainPage`() = runBlocking {
        val home = ProviderExecutor.loadHome(ModernApi("NoHome"), 1)
        assertEquals("NoHome", home.provider)
        assertTrue(home.lists.isEmpty())
    }
    @Test fun `legacy null is failure and never called twice`() = runBlocking {
        var calls = 0
        val provider = object : MainAPI() {
            override suspend fun search(query: String): List<SearchResponse>? { calls++; return null }
        }
        val outcome = ProviderExecutor.searchOne(provider, "q")
        assertEquals(1, calls)
        assertTrue(outcome.error != null)
    }

    @Test fun `modern null does not call legacy or become empty success`() = runBlocking {
        val provider = object : MainAPI() {
            override suspend fun search(query: String, page: Int): SearchResponseList? = null
            override suspend fun search(query: String): List<SearchResponse> = error("must not be called")
        }
        assertTrue(ProviderExecutor.searchOne(provider, "q").error != null)
    }

    @Test fun `caller cancellation crosses provider error barrier`() = runBlocking {
        val provider = object : MainAPI() {
            override suspend fun search(query: String, page: Int): SearchResponseList? =
                throw kotlinx.coroutines.CancellationException("caller cancelled")
        }
        kotlin.test.assertFailsWith<kotlinx.coroutines.CancellationException> {
            ProviderExecutor.searchOne(provider, "q")
        }
        Unit
    }

    @Test fun `homepage preserves shelf data order and partial failures`() = runBlocking {
        val requests = java.util.Collections.synchronizedList(mutableListOf<com.lagradost.cloudstream3.MainPageRequest>())
        val provider = object : MainAPI() {
            override val mainPage = listOf(
                com.lagradost.cloudstream3.MainPageData("First", "/a", true),
                com.lagradost.cloudstream3.MainPageData("Broken", "/b", false),
                com.lagradost.cloudstream3.MainPageData("Last", "/c", false),
            )
            override suspend fun getMainPage(page: Int, request: com.lagradost.cloudstream3.MainPageRequest): com.lagradost.cloudstream3.HomePageResponse {
                requests.add(request)
                if (request.name == "Broken") error("fixture failure")
                if (request.name == "First") delay(30)
                @Suppress("DEPRECATION_ERROR")
                return com.lagradost.cloudstream3.HomePageResponse(
                    listOf(com.lagradost.cloudstream3.HomePageList(request.name, emptyList(), request.horizontalImages)),
                    hasNext = request.name == "Last",
                )
            }
        }
        val home = ProviderExecutor.loadHome(provider, 1)
        assertEquals(listOf("First", "Last"), home.lists.map { it.name })
        assertEquals(listOf(true, false), home.lists.map { it.isHorizontal })
        assertEquals(setOf("/a", "/b", "/c"), requests.map { it.data }.toSet())
        assertTrue(home.hasNext)
    }

    @Test fun `sequential homepage keeps successful shelves when a later shelf times out`() = runBlocking {
        val calls = mutableListOf<String>()
        val provider = object : MainAPI() {
            override var sequentialMainPage = true
            override val getMainPageTimeoutMs = 150L
            override val mainPage = listOf(
                com.lagradost.cloudstream3.MainPageData("First", "a"),
                com.lagradost.cloudstream3.MainPageData("Slow", "b"),
                com.lagradost.cloudstream3.MainPageData("Never", "c"),
            )
            override suspend fun getMainPage(page: Int, request: com.lagradost.cloudstream3.MainPageRequest): com.lagradost.cloudstream3.HomePageResponse {
                calls.add(request.name)
                if (request.name == "Slow") delay(10_000)
                @Suppress("DEPRECATION_ERROR")
                return com.lagradost.cloudstream3.HomePageResponse(listOf(com.lagradost.cloudstream3.HomePageList(request.name, emptyList())))
            }
        }
        val home = ProviderExecutor.loadHome(provider, 1)
        assertEquals(listOf("First", "Slow"), calls)
        assertEquals(listOf("First"), home.lists.map { it.name })
    }

}
