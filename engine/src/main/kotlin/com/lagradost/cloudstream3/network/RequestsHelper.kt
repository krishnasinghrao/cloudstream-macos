package com.lagradost.cloudstream3.network

import android.content.Context
import com.lagradost.cloudstream3.USER_AGENT
import com.lagradost.cloudstream3.UnsafeSSL
import com.lagradost.cloudstream3.app
import com.lagradost.cloudstream3.insecureApp
import com.lagradost.nicehttp.Requests
import okhttp3.Headers
import okhttp3.Headers.Companion.toHeaders
import okhttp3.OkHttpClient

// Android app helper ABI (app/src/main/java/.../network/RequestsHelper.kt): same
// signatures, so extensions compiled against the Android app link unchanged.
// The engine returns its own configured client instead of building a new one,
// so extension requests keep the user's DNS, cache and challenge handling.

// Backwards compatible constructor, mark as deprecated later
fun Requests.initClient(context: Context) {
    this.baseClient = buildDefaultClient(context)
}

/** Only use ignoreSSL if you know what you are doing*/
fun Requests.initClient(context: Context, ignoreSSL: Boolean = false) {
    this.baseClient = buildDefaultClient(context, ignoreSSL)
}

// Backwards compatible constructor, mark as deprecated later
fun buildDefaultClient(context: Context): OkHttpClient = buildDefaultClient(context, false)

/** Only use ignoreSSL if you know what you are doing*/
@Suppress("UNUSED_PARAMETER")
@OptIn(UnsafeSSL::class) // ABI shim: hands extensions the host-owned insecure client when they ask for it
fun buildDefaultClient(context: Context, ignoreSSL: Boolean = false): OkHttpClient =
    (if (ignoreSSL) insecureApp else app).baseClient

private val DEFAULT_HEADERS = mapOf("user-agent" to USER_AGENT)

/**
 * Set headers > Set cookies > Default headers > Default Cookies
 */
fun getHeaders(
    headers: Map<String, String>,
    cookie: Map<String, String>
): Headers {
    val cookieMap =
        if (cookie.isNotEmpty()) mapOf(
            "Cookie" to cookie.entries.joinToString(" ") {
                "${it.key}=${it.value};"
            }) else mapOf()
    val tempHeaders = (DEFAULT_HEADERS + headers + cookieMap)
    return tempHeaders.toHeaders()
}
