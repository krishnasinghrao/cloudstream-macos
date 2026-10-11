package fixture

import android.content.Context
import com.lagradost.cloudstream3.*
import com.lagradost.cloudstream3.network.WebViewResolver
import com.lagradost.cloudstream3.plugins.Plugin
import com.lagradost.cloudstream3.utils.ExtractorLink
import com.lagradost.cloudstream3.utils.ExtractorLinkType
import com.lagradost.cloudstream3.utils.newExtractorLink

/** RT-11: a provider whose stream URL only appears when a browser runs the embed page. */
class WebViewPlugin : Plugin() {
    override fun load(context: Context) {
        registerMainAPI(WebViewProvider())
    }
}

class WebViewProvider : MainAPI() {
    override var name = "WebViewProvider"
    override var mainUrl = "https://webview.invalid"

    override suspend fun loadLinks(data: String, isCasting: Boolean,
        subtitleCallback: (SubtitleFile) -> Unit, callback: (ExtractorLink) -> Unit): Boolean {
        var title: String? = null
        val resolver = WebViewResolver(
            interceptUrl = Regex("""\.m3u8"""),
            additionalUrls = listOf(Regex("""/subs/[^/]+\.vtt$""")),
            script = "document.title",
            scriptCallback = { title = it },
        )
        val (stream, extras) = resolver.resolveUsingWebView(data, referer = "$mainUrl/")
        stream ?: return false
        callback(newExtractorLink(name, "WebView ${title.orEmpty()}", stream.url.toString(), ExtractorLinkType.M3U8) {
            referer = stream.header("Referer").orEmpty()
            headers = stream.headers.toMap().filterKeys { it != "Referer" }
        })
        extras.forEach { subtitleCallback(newSubtitleFile("en", it.url.toString())) }
        return true
    }
}
