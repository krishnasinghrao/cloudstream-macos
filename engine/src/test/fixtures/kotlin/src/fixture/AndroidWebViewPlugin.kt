package fixture

import android.content.Context
import android.webkit.JavascriptInterface
import android.webkit.WebView
import android.webkit.WebViewClient
import com.lagradost.cloudstream3.*
import com.lagradost.cloudstream3.plugins.Plugin
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout

/**
 * RT-14: a provider that runs its own script in a hidden android.webkit.WebView,
 * as StreamPlay's EnmaDecryptor does: page-finished callback, a JavaScript
 * interface the page calls, and evaluateJavascript.
 */
class AndroidWebViewPlugin : Plugin() {
    override fun load(context: Context) {
        registerMainAPI(AndroidWebViewProvider(context))
    }
}

class AndroidWebViewProvider(private val context: Context) : MainAPI() {
    override var name = "AndroidWebViewProvider"
    override var mainUrl = "https://decrypt.invalid"

    class Receiver(private val delivered: CompletableDeferred<String>) {
        @JavascriptInterface fun deliver(value: String) { delivered.complete(value) }
    }

    override suspend fun search(query: String): List<SearchResponse> {
        val delivered = CompletableDeferred<String>()
        val finished = CompletableDeferred<String>()
        val evaluated = CompletableDeferred<String>()
        val view = withContext(Dispatchers.Main) {
            WebView(context).apply {
                settings.javaScriptEnabled = true
                addJavascriptInterface(Receiver(delivered), "Decryptor")
                webViewClient = object : WebViewClient() {
                    override fun onPageFinished(view: WebView?, url: String?) { finished.complete(url.orEmpty()) }
                }
                loadDataWithBaseURL("$mainUrl/", "<script>Decryptor.deliver(location.host)</script>", "text/html", "utf-8", null)
            }
        }
        return withTimeout(30_000) {
            finished.await()
            withContext(Dispatchers.Main) { view.evaluateJavascript("decrypt('$query')") { evaluated.complete(it) } }
            val result = "${delivered.await()}|${evaluated.await()}"
            withContext(Dispatchers.Main) { view.destroy() }
            listOf(newMovieSearchResponse(result, "$mainUrl/1", TvType.Movie))
        }
    }
}
