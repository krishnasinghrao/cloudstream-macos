package com.lagradost.macos

import com.lagradost.cloudstream3.USER_AGENT
import com.lagradost.cloudstream3.app
import okhttp3.OkHttpClient
import okhttp3.RequestBody.Companion.toRequestBody
import org.schabi.newpipe.extractor.downloader.Downloader
import org.schabi.newpipe.extractor.downloader.Response
import org.schabi.newpipe.extractor.exceptions.ReCaptchaException

/**
 * Bridges NewPipeExtractor (used by the official YouTube provider) to a plain
 * OkHttp client on the headless JVM. Mirrors the Android app's downloader:
 * NewPipe must be initialized once at daemon startup (`NewPipe.init(...)`)
 * or every provider that delegates to it fails with `downloader is null`.
 */
class NewPipeBridge(private val client: () -> OkHttpClient = { app.baseClient }) : Downloader() {

    override fun execute(request: org.schabi.newpipe.extractor.downloader.Request): Response {
        val httpMethod: String = request.httpMethod()
        val url: String = request.url()
        val headers: Map<String, List<String>> = request.headers()
        val dataToSend: ByteArray? = request.dataToSend()

        val requestBody = dataToSend?.toRequestBody(null, 0, dataToSend.size)

        val requestBuilder = okhttp3.Request.Builder()
            .method(httpMethod, requestBody)
            .url(url)
            .addHeader("User-Agent", USER_AGENT)

        for ((headerName, headerValueList) in headers) {
            if (headerName.equals("User-Agent", ignoreCase = true)) continue
            if (headerValueList.size > 1) {
                requestBuilder.removeHeader(headerName)
                for (headerValue in headerValueList) {
                    requestBuilder.addHeader(headerName, headerValue)
                }
            } else if (headerValueList.size == 1) {
                requestBuilder.header(headerName, headerValueList[0])
            }
        }

        return client().newCall(requestBuilder.build()).execute().use { response ->
            if (response.code == 429) throw ReCaptchaException("reCaptcha Challenge requested", url)
            Response(response.code, response.message, response.headers.toMultimap(),
                response.body.string(), response.request.url.toString())
        }
    }
}
