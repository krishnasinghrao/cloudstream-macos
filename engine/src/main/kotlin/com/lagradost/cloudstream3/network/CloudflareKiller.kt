package com.lagradost.cloudstream3.network

import com.lagradost.macos.SolveBridge
import com.lagradost.macos.SolveInterceptor
import okhttp3.Headers
import okhttp3.Interceptor
import okhttp3.Response
import java.net.URI
import java.util.concurrent.ConcurrentHashMap

/** Android helper ABI delegates to the native challenge bridge in this worker. */
class CloudflareKiller : Interceptor {
    companion object {
        const val TAG = "CloudflareKiller"
        fun parseCookieMap(cookie: String): Map<String, String> = cookie.split(';').mapNotNull { part ->
            val pair = part.trim().split('=', limit = 2)
            if (pair.size == 2 && pair[0].isNotBlank() && pair[1].isNotBlank()) pair[0] to pair[1] else null
        }.toMap()
    }

    val savedCookies: MutableMap<String, Map<String, String>> = ConcurrentHashMap()
    private val delegate = SolveInterceptor()

    fun getCookieHeaders(url: String): Headers {
        val host = URI(url).host ?: throw IllegalArgumentException("Cookie target has no host")
        SolveBridge.cookieHeaderFor(url)?.let { savedCookies[host] = parseCookieMap(it) }
        return Headers.Builder().apply {
            WebViewResolver.webViewUserAgent?.let { set("User-Agent", it) }
            savedCookies[host]?.takeIf { it.isNotEmpty() }?.let { cookies ->
                set("Cookie", cookies.entries.joinToString("; ") { "${it.key}=${it.value}" })
            }
        }.build()
    }

    override fun intercept(chain: Interceptor.Chain): Response {
        val original = chain.request()
        val cookies = savedCookies[original.url.host]
        val prepared = if (cookies.isNullOrEmpty()) original else original.newBuilder().apply {
            val existing = parseCookieMap(original.header("Cookie").orEmpty())
            header("Cookie", (cookies + existing).entries.joinToString("; ") { "${it.key}=${it.value}" })
            WebViewResolver.webViewUserAgent?.let { header("User-Agent", it) }
        }.build()
        val response = delegate.intercept(object : Interceptor.Chain by chain {
            override fun request() = prepared
        })
        SolveBridge.cookieHeaderFor(original.url.toString())?.let { savedCookies[original.url.host] = parseCookieMap(it) }
        return response
    }
}
