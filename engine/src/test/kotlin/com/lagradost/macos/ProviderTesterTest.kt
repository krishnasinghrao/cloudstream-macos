package com.lagradost.macos

import com.lagradost.cloudstream3.LoadResponse
import com.lagradost.cloudstream3.MainAPI
import com.lagradost.cloudstream3.SearchResponseList
import com.lagradost.cloudstream3.SubtitleFile
import com.lagradost.cloudstream3.TvType
import com.lagradost.cloudstream3.newMovieLoadResponse
import com.lagradost.cloudstream3.newMovieSearchResponse
import com.lagradost.cloudstream3.newSearchResponseList
import com.lagradost.cloudstream3.utils.ExtractorLink
import com.lagradost.cloudstream3.utils.newExtractorLink
import kotlinx.coroutines.runBlocking
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals

/** Offline-Features-Plan Phase 8: provider end-to-end health check. */
class ProviderTesterTest {
    private open class Fixture(override var name: String, val links: Int = 1, val results: Int = 1) : MainAPI() {
        override var mainUrl = "https://fixture.example"
        override val supportedTypes = setOf(TvType.Movie)

        override suspend fun search(query: String, page: Int): SearchResponseList =
            newSearchResponseList((1..results).map { newMovieSearchResponse("M$it", "https://fixture.example/m$it") }, false)

        override suspend fun load(url: String): LoadResponse = newMovieLoadResponse("Movie", url, TvType.Movie, "$url#data")

        override suspend fun loadLinks(
            data: String,
            isCasting: Boolean,
            subtitleCallback: (SubtitleFile) -> Unit,
            callback: (ExtractorLink) -> Unit,
        ): Boolean {
            repeat(links) { callback(newExtractorLink(name, name, "https://cdn.example/$it.mp4")) }
            return links > 0
        }
    }

    private class BrokenDetails(name: String) : Fixture(name) {
        override suspend fun load(url: String): LoadResponse = error("the site changed")
    }

    @AfterTest
    fun reset() = ProviderExecutor.invalidateCaches()

    @Test
    fun `healthy provider passes every step`() = runBlocking {
        val result = ProviderTester.test(Fixture("Healthy"))
        assertEquals("pass", result.status)
        assertEquals(listOf("search", "details", "links"), result.steps.map { it.name })
    }

    @Test
    fun `provider without streams is partial`() = runBlocking {
        val result = ProviderTester.test(Fixture("NoLinks", links = 0))
        assertEquals("partial", result.status)
        assertEquals(false, result.steps.last().ok)
    }

    @Test
    fun `provider without results fails and skips later steps`() = runBlocking {
        val result = ProviderTester.test(Fixture("Empty", results = 0))
        assertEquals("fail", result.status)
        assertEquals(listOf("search", "details"), result.steps.map { it.name })
    }

    @Test
    fun `a details failure is a failed step, not an exception`() = runBlocking {
        val result = ProviderTester.test(BrokenDetails("Broken"))
        assertEquals("partial", result.status)
        assertEquals(listOf("search", "details"), result.steps.map { it.name })
        assertEquals(false, result.steps.last().ok)
    }

    @Test
    fun `one provider failing its details does not abort the batch`() = runBlocking {
        val seen = java.util.Collections.synchronizedList(mutableListOf<String>())
        ProviderTester.runAll(listOf(Fixture("A"), BrokenDetails("B"), Fixture("C"))) { seen += it.provider }
        assertEquals(setOf("A", "B", "C"), seen.toSet())
    }

    @Test
    fun `runAll reports every provider`() = runBlocking {
        val seen = java.util.Collections.synchronizedList(mutableListOf<String>())
        ProviderTester.runAll(listOf(Fixture("A"), Fixture("B"), Fixture("C"), Fixture("D"))) { seen += it.provider }
        assertEquals(setOf("A", "B", "C", "D"), seen.toSet())
    }
}
