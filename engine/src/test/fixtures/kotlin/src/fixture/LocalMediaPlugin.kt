package fixture

import android.content.Context
import com.lagradost.cloudstream3.*
import com.lagradost.cloudstream3.plugins.Plugin
import com.lagradost.cloudstream3.utils.ExtractorLink
import com.lagradost.cloudstream3.utils.ExtractorLinkType
import com.lagradost.cloudstream3.utils.Qualities
import com.lagradost.cloudstream3.utils.newExtractorLink

/**
 * RT-17 without third-party content: an Android-compiled extension whose links
 * point at the origin passed as its load data (a local CDN simulator in the
 * provisioned test run), with the request headers real providers attach.
 */
class LocalMediaPlugin : Plugin() {
    override fun load(context: Context) {
        registerMainAPI(LocalMediaProvider())
    }
}

class LocalMediaProvider : MainAPI() {
    override var name = "LocalMediaProvider"
    override var mainUrl = "https://local-media.invalid"

    override suspend fun search(query: String): List<SearchResponse> =
        listOf(newMovieSearchResponse("Local media", query))

    override suspend fun load(url: String): LoadResponse =
        newMovieLoadResponse("Local media", url, TvType.Movie, url)

    override suspend fun loadLinks(data: String, isCasting: Boolean,
        subtitleCallback: (SubtitleFile) -> Unit, callback: (ExtractorLink) -> Unit): Boolean {
        val origin = data.trimEnd('/')
        callback(newExtractorLink(name, "HLS", "$origin/hls/index.m3u8", ExtractorLinkType.M3U8) {
            referer = "https://local-media.invalid/"
            quality = Qualities.P720.value
            headers = mapOf("X-Provider-Key" to "hls-fixture")
        })
        callback(newExtractorLink(name, "MP4", "$origin/muxed.mp4", ExtractorLinkType.VIDEO) {
            referer = "https://local-media.invalid/"
            quality = Qualities.P1080.value
        })
        return true
    }
}
