package com.lagradost.cloudstream3.network

import com.lagradost.cloudstream3.USER_AGENT
import com.lagradost.cloudstream3.mvvm.debugException
import com.lagradost.cloudstream3.mvvm.logError
import com.lagradost.nicehttp.requestCreator
import kotlinx.coroutines.runBlocking
import okhttp3.Headers.Companion.toHeaders
import okhttp3.Interceptor
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response

/**
 * A page load a JVM host performs in a real browser engine on behalf of
 * [WebViewResolver]. Patterns are matched by the host with JVM regex
 * semantics, like Android's `containsMatchIn`.
 */
data class WebViewHostRequest(
    val url: String,
    val method: String,
    val headers: Map<String, String>,
    val interceptUrl: Regex,
    val additionalUrls: List<Regex>,
    val userAgent: String?,
    val script: String?,
    val timeoutMs: Long,
)

/** One request the page made that matched a pattern, with the headers a client needs to repeat it. */
data class WebViewHostMatch(val url: String, val method: String, val headers: Map<String, String>)

data class WebViewHostResult(
    /** The request matching `interceptUrl`, if any. */
    val intercepted: WebViewHostMatch?,
    /** Requests matching `additionalUrls`, in the order the page made them. */
    val additional: List<WebViewHostMatch>,
    val scriptResult: String?,
)

/**
 * JVM hosts with a browser engine (the macOS app's WebKit) resolve pages
 * here. Without a host the resolver is unavailable, as before.
 */
object WebViewHost {
    @Volatile
    var resolver: (suspend (WebViewHostRequest) -> WebViewHostResult?)? = null
}

/**
 * When used as Interceptor additionalUrls cannot be returned, use WebViewResolver(...).resolveUsingWebView(...)
 * @param interceptUrl will stop the WebView when reaching this url.
 * @param additionalUrls this will make resolveUsingWebView also return all other requests matching the list of Regex.
 * @param userAgent if null then will use the default user agent
 * @param useOkhttp will try to use the okhttp client as much as possible, but this might cause some requests to fail. Disable for cloudflare.
 * @param script pass custom js to execute
 * @param scriptCallback will be called with the result from custom js
 * @param timeout close webview after timeout
 * */
class WebViewResolver(
    private val interceptUrl: Regex,
    private val additionalUrls: List<Regex> = emptyList(),
    private val userAgent: String? = USER_AGENT,
    useOkhttp: Boolean = true,
    private val script: String? = null,
    private val scriptCallback: ((String) -> Unit)? = null,
    private val timeout: Long = DEFAULT_TIMEOUT
) :
    Interceptor {

    /** As on Android: the page's matching request replaces the original one. */
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        if (WebViewHost.resolver == null) return chain.proceed(request)
        val fixed = runBlocking { resolveUsingWebView(request).first }
        return chain.proceed(fixed ?: request)
    }

    companion object {
        val DEFAULT_TIMEOUT: Long = 60_000L
        var webViewUserAgent: String? = null
    }

    suspend fun resolveUsingWebView(
        url: String,
        referer: String? = null,
        method: String = "GET",
        requestCallBack: (Request) -> Boolean = { false },
    ): Pair<Request?, List<Request>> =
        resolveUsingWebView(url, referer, emptyMap(), method, requestCallBack)

    suspend fun resolveUsingWebView(
        url: String,
        referer: String? = null,
        headers: Map<String, String> = emptyMap(),
        method: String = "GET",
        requestCallBack: (Request) -> Boolean = { false },
    ): Pair<Request?, List<Request>> {
        return try {
            resolveUsingWebView(
                requestCreator(method, url, referer = referer, headers = headers), requestCallBack
            )
        } catch (e: java.lang.IllegalArgumentException) {
            logError(e)
            debugException { "ILLEGAL URL IN resolveUsingWebView!" }
            return null to emptyList()
        }
    }

    suspend fun resolveUsingWebView(
        request: Request,
        requestCallBack: (Request) -> Boolean = { false }
    ): Pair<Request?, List<Request>> {
        val host = WebViewHost.resolver ?: TODO("Not yet implemented")
        val result = host(
            WebViewHostRequest(
                url = request.url.toString(),
                method = request.method,
                headers = request.headers.toMap(),
                interceptUrl = interceptUrl,
                additionalUrls = additionalUrls,
                userAgent = userAgent,
                script = script,
                timeoutMs = timeout,
            )
        ) ?: return null to emptyList()
        result.scriptResult?.let { scriptCallback?.invoke(it) }
        // Android reports matches to requestCallBack as they happen and stops when it returns true.
        val extra = mutableListOf<Request>()
        for (match in result.additional) {
            val built = match.toRequest() ?: continue
            extra += built
            if (requestCallBack(built)) return null to extra
        }
        val fixed = result.intercepted?.toRequest()?.also { requestCallBack(it) }
        return fixed to extra
    }

    private fun WebViewHostMatch.toRequest(): Request? = try {
        val verb = method.uppercase()
        // OkHttp requires a body for POST/PUT/PATCH; the page's body is not observable, so it is empty.
        val body = if (okhttp3.internal.http.HttpMethod.requiresRequestBody(verb)) ByteArray(0).toRequestBody() else null
        Request.Builder().url(url).headers(headers.toHeaders()).method(verb, body).build()
    } catch (e: IllegalArgumentException) {
        logError(e)
        null
    }
}
