package fixture

import android.content.Context
import com.lagradost.api.getContext
import com.lagradost.cloudstream3.*
import com.lagradost.cloudstream3.plugins.Plugin
import com.lagradost.cloudstream3.utils.DataStore
import com.lagradost.cloudstream3.utils.DataStore.getSharedPrefs
import com.lagradost.cloudstream3.network.CloudflareKiller
import com.lagradost.cloudstream3.utils.ExtractorLink
import com.lagradost.cloudstream3.utils.ExtractorLinkType
import com.lagradost.cloudstream3.utils.newExtractorLink
import org.schabi.newpipe.extractor.NewPipe

/** Kotlin-compiled Android fixture: Result, value classes, defaults and suspend calls. */
class KotlinAbiPlugin : Plugin() {
    override fun load(context: Context) {
        check(NewPipe.getDownloader() != null) { "Worker NewPipe downloader is uninitialized" }
        check(getContext() === context) { "Worker context is not bound before load" }
        val value = success("ready").getOrThrow()
        check(failure().exceptionOrNull() is IllegalStateException)
        val prefs = context.getSharedPreferences("kotlin-abi", Context.MODE_PRIVATE)
        prefs.edit().putString("loaded", value).commit()
        val store = context.getSharedPrefs()
        check(store.edit().putString("helper", "persistent").commit())
        check(context.getSharedPrefs().getString("helper", null) == "persistent")
        val killer = CloudflareKiller()
        killer.savedCookies["fixture.invalid"] = CloudflareKiller.parseCookieMap("cf_clearance=a=b")
        check(killer.getCookieHeaders("https://fixture.invalid/page")["Cookie"] == "cf_clearance=a=b")
        registerMainAPI(KotlinAbiProvider())
    }

    private fun success(value: String): Result<String> = Result.success(value)
    private fun failure(): Result<String> = Result.failure(IllegalStateException("fixture"))
}

@JvmInline private value class FixtureLabel(val text: String) {
    fun label(prefix: String = "Kotlin"): String = "$prefix:$text"
}

class KotlinAbiProvider : MainAPI() {
    override var name = "KotlinAbiProvider"
    override var mainUrl = "https://fixture.invalid"

    override suspend fun search(query: String): List<SearchResponse> =
        Result.success(listOf(newMovieSearchResponse(FixtureLabel(query).label(), "$mainUrl/title"))).getOrThrow()

    override suspend fun load(url: String): LoadResponse =
        Result.success(newMovieLoadResponse("Kotlin title", url, TvType.Movie, "$mainUrl/embed")).getOrThrow()

    override suspend fun loadLinks(data: String, isCasting: Boolean,
        subtitleCallback: (SubtitleFile) -> Unit, callback: (ExtractorLink) -> Unit): Boolean {
        val link = Result.success(newExtractorLink(name, "Kotlin media", "$mainUrl/video.m3u8", ExtractorLinkType.M3U8)).getOrThrow()
        callback(link)
        return true
    }
}
