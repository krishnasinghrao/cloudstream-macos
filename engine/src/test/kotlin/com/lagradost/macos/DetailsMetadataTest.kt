package com.lagradost.macos

import com.lagradost.cloudstream3.Actor
import com.lagradost.cloudstream3.ActorData
import com.lagradost.cloudstream3.DubStatus
import com.lagradost.cloudstream3.LoadResponse
import com.lagradost.cloudstream3.MainAPI
import com.lagradost.cloudstream3.NextAiring
import com.lagradost.cloudstream3.SeasonData
import com.lagradost.cloudstream3.ShowStatus
import com.lagradost.cloudstream3.TrailerData
import com.lagradost.cloudstream3.TvType
import com.lagradost.cloudstream3.addEpisodes
import com.lagradost.cloudstream3.newAnimeLoadResponse
import com.lagradost.cloudstream3.newEpisode
import com.lagradost.cloudstream3.newMovieSearchResponse
import com.lagradost.cloudstream3.newTvSeriesLoadResponse
import kotlinx.coroutines.runBlocking
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/**
 * Offline-Features-Plan Phase 2: metadata the provider already returned
 * reaches the client, and `/details` is cached like Android's APIRepository.
 */
class DetailsMetadataTest {

    private class SeriesApi(override var name: String = "SeriesFixture") : MainAPI() {
        override var mainUrl = "https://series.example"
        override val supportedTypes = setOf(TvType.TvSeries)
        val loads = AtomicInteger()
        var fail = false

        override suspend fun load(url: String): LoadResponse? {
            loads.incrementAndGet()
            if (fail) throw IllegalStateException("down")
            val episodes = listOf(
                newEpisode("https://series.example/e1") { season = 1; episode = 1 },
                newEpisode("https://series.example/e2") { season = 1; episode = 2 },
            )
            return newTvSeriesLoadResponse("Show", url, TvType.TvSeries, episodes) {
                tags = listOf("Drama", " ", "Drama", "Thriller ")
                showStatus = ShowStatus.Ongoing
                nextAiring = NextAiring(episode = 3, unixTime = 1_900_000_000, season = 1)
                seasonNames = listOf(SeasonData(season = 1, name = "The Beginning"))
                recommendations = listOf(newMovieSearchResponse("Other", "https://series.example/other"))
                trailers.add(TrailerData("https://cdn.example/trailer.mp4", "https://series.example", true))
                trailers.add(TrailerData("javascript:alert(1)", null, true))
                syncData["imdb"] = "tt0000001"
                syncData["blank"] = ""
                posterHeaders = mapOf("Referer" to "https://series.example")
                actors = listOf(ActorData(Actor("Lead", "https://img/lead.jpg"), roleString = "Hero", voiceActor = Actor("Voice")))
            }
        }
    }

    private class AnimeApi : MainAPI() {
        override var name = "AnimeFixture"
        override var mainUrl = "https://anime.example"
        override val supportedTypes = setOf(TvType.Anime)

        override suspend fun load(url: String): LoadResponse =
            newAnimeLoadResponse("Anime", url, TvType.Anime) {
                addEpisodes(DubStatus.Subbed, listOf(newEpisode("https://anime.example/s1") { name = "Pilot"; episode = 1 }))
                addEpisodes(DubStatus.Dubbed, listOf(newEpisode("https://anime.example/d1") { name = "Pilot"; episode = 1 }))
            }
    }

    @AfterTest
    fun reset() {
        ProviderExecutor.invalidateCaches()
        ProviderExecutor.now = System::currentTimeMillis
    }

    @Test
    fun `new metadata fields are mapped`() = runBlocking {
        val details = assertNotNull(ProviderExecutor.loadDetails(SeriesApi(), "https://series.example/show"))

        assertEquals(listOf("Drama", "Thriller"), details.tags, "blank and duplicate tags are dropped")
        assertEquals("Ongoing", details.showStatus)
        assertEquals(3, details.nextAiring?.episode)
        assertEquals(1_900_000_000, details.nextAiring?.unixTime)
        assertEquals("The Beginning", details.seasonNames?.single()?.name)
        assertEquals("Other", details.recommendations?.single()?.name)
        assertEquals(1, details.trailers?.size, "non-http trailer URLs are rejected")
        assertTrue(details.trailers!!.single().raw)
        assertEquals(mapOf("imdb" to "tt0000001"), details.syncIds)
        assertEquals("https://series.example", details.posterHeaders?.get("Referer"))
        assertEquals("Voice", details.actors.single().voiceActor)
        assertEquals("Hero", details.actors.single().role)
    }

    @Test
    fun `anime episodes carry audio without renaming`() = runBlocking {
        val details = assertNotNull(ProviderExecutor.loadDetails(AnimeApi(), "https://anime.example/a"))
        val byAudio = details.episodes.associateBy { it.audio }
        assertEquals("Pilot", byAudio["dub"]?.name, "no ' (Dub)' suffix hack")
        assertEquals("Pilot", byAudio["sub"]?.name)
    }

    @Test
    fun `details are cached within the ttl`() = runBlocking {
        val api = SeriesApi()
        ProviderExecutor.loadDetails(api, "https://series.example/show")
        ProviderExecutor.loadDetails(api, "https://series.example/show")
        assertEquals(1, api.loads.get())
    }

    @Test
    fun `refresh bypasses the cache`() = runBlocking {
        val api = SeriesApi()
        ProviderExecutor.loadDetails(api, "https://series.example/show")
        ProviderExecutor.loadDetails(api, "https://series.example/show", refresh = true)
        assertEquals(2, api.loads.get())
    }

    @Test
    fun `cache expires after ttl`() = runBlocking {
        val api = SeriesApi()
        var clock = 0L
        ProviderExecutor.now = { clock }
        ProviderExecutor.loadDetails(api, "https://series.example/show")
        clock += 11 * 60_000L
        ProviderExecutor.loadDetails(api, "https://series.example/show")
        assertEquals(2, api.loads.get())
    }

    @Test
    fun `invalidation drops cached entries`() = runBlocking {
        val api = SeriesApi()
        ProviderExecutor.loadDetails(api, "https://series.example/show")
        ProviderExecutor.invalidateCaches()
        ProviderExecutor.loadDetails(api, "https://series.example/show")
        assertEquals(2, api.loads.get())
    }

    @Test
    fun `failures are never cached`() = runBlocking {
        val api = SeriesApi().apply { fail = true }
        // IPC 5: a failed load is a typed failure (the route reports its cause), and is not cached.
        assertFailsWith<OperationException> { ProviderExecutor.loadDetails(api, "https://series.example/show") }
        api.fail = false
        assertNotNull(ProviderExecutor.loadDetails(api, "https://series.example/show"))
        assertEquals(2, api.loads.get())
    }

    @Test
    fun `cache is keyed per provider`() = runBlocking {
        val a = SeriesApi("A")
        val b = SeriesApi("B")
        ProviderExecutor.loadDetails(a, "https://series.example/show")
        ProviderExecutor.loadDetails(b, "https://series.example/show")
        assertEquals(1, a.loads.get())
        assertEquals(1, b.loads.get())
    }
}
