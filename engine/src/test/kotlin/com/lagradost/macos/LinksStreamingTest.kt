package com.lagradost.macos

import com.lagradost.cloudstream3.MainAPI
import com.lagradost.cloudstream3.SubtitleFile
import com.lagradost.cloudstream3.TvType
import com.lagradost.cloudstream3.newSubtitleFile
import com.lagradost.cloudstream3.utils.ExtractorLink
import com.lagradost.cloudstream3.utils.ExtractorLinkType
import com.lagradost.cloudstream3.utils.newExtractorLink
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Progressive link resolution (Player-Remediation-Plan A2/A3/A4): links are
 * reported as extractors produce them, the complete response is sorted and
 * cached, and stream URLs keep their signed query strings.
 */
class LinksStreamingTest {

    /** Emits a fast low-quality link, then (after a delay) a slow 1080p one. */
    private class StagedApi(override var name: String) : MainAPI() {
        override var mainUrl = "https://staged.example"
        override val supportedTypes = setOf(TvType.Movie)
        var calls = 0

        override suspend fun loadLinks(
            data: String,
            isCasting: Boolean,
            subtitleCallback: (SubtitleFile) -> Unit,
            callback: (ExtractorLink) -> Unit,
        ): Boolean {
            calls++
            callback(
                newExtractorLink("fast", "Fast", "https://cdn.example/fast.m3u8?ref=site&crc=ab12", ExtractorLinkType.M3U8) {
                    quality = 480
                },
            )
            subtitleCallback(newSubtitleFile("English", "https://subs.example/en.vtt"))
            subtitleCallback(newSubtitleFile("English", "https://subs.example/en.vtt")) // duplicate
            delay(300)
            callback(
                newExtractorLink("slow", "Slow", "https://cdn.example/slow.mp4?utm_source=x&token=t", ExtractorLinkType.VIDEO) {
                    quality = 1080
                },
            )
            return true
        }
    }

    @Test
    fun `links are reported progressively before resolution completes`() = runBlocking {
        val api = StagedApi("Staged-${System.nanoTime()}")
        val arrivals = mutableListOf<Pair<String, Long>>()
        val start = System.currentTimeMillis()

        val response = ProviderExecutor.loadLinksStreaming(
            api,
            "episode-1",
            onLink = { link -> arrivals += link.source to (System.currentTimeMillis() - start) },
            onSubtitle = {},
        )

        assertEquals(listOf("fast", "slow"), arrivals.map { it.first })
        assertTrue(arrivals[0].second < 200, "first link must be emitted immediately, not after the slow extractor")
        assertTrue(arrivals[1].second >= 250, "second link arrives after its extractor delay")
        assertEquals(listOf(1080, 480), response.links.map { it.quality }, "complete response is quality-sorted")
    }

    @Test
    fun `subtitles are deduplicated by url`() = runBlocking {
        val api = StagedApi("Subs-${System.nanoTime()}")
        val subtitles = mutableListOf<String>()
        val response = ProviderExecutor.loadLinksStreaming(api, "episode-1", onLink = {}, onSubtitle = { subtitles += it.url })
        assertEquals(listOf("https://subs.example/en.vtt"), subtitles)
        assertEquals(1, response.subtitles.size)
    }

    @Test
    fun `stream urls keep signed query parameters`() = runBlocking {
        val api = StagedApi("Signed-${System.nanoTime()}")
        val response = ProviderExecutor.loadLinks(api, "episode-1")
        val fast = response.links.first { it.source == "fast" }
        val slow = response.links.first { it.source == "slow" }
        assertEquals("https://cdn.example/fast.m3u8?ref=site&crc=ab12", fast.url, "ambiguous keys must survive (A4)")
        assertEquals("https://cdn.example/slow.mp4?token=t", slow.url, "unambiguous marketing ids are still stripped")
    }

    @Test
    fun `resolved links are cached and replayed through the streaming callbacks`() = runBlocking {
        val api = StagedApi("Cache-${System.nanoTime()}")
        ProviderExecutor.loadLinks(api, "episode-cache")
        assertEquals(1, api.calls)

        val replayed = mutableListOf<String>()
        val start = System.currentTimeMillis()
        val second = ProviderExecutor.loadLinksStreaming(api, "episode-cache", onLink = { replayed += it.source }, onSubtitle = {})
        assertEquals(1, api.calls, "a cached resolution must not re-run the extractors (A3)")
        assertTrue(System.currentTimeMillis() - start < 100, "cache hit is immediate")
        assertEquals(2, second.links.size)
        assertEquals(setOf("fast", "slow"), replayed.toSet())

        ProviderExecutor.loadLinks(api, "episode-other")
        assertEquals(2, api.calls, "different episode data is a different cache key")
    }
}
