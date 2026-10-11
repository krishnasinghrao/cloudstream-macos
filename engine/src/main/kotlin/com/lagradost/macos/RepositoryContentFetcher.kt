package com.lagradost.macos

import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.IOException
import java.util.Base64

/** Codeberg's contents API is an explicit compatibility mapping. Relative
 * references still use the logical raw-file URL, not the API wrapper path. */
internal class RepositoryContentFetcher(private val http: RepositoryFetcher) : RepositoryFetcher {
    override suspend fun resolve(url: String): String = http.resolve(url)

    override suspend fun fetch(url: String, maxBytes: Int): RepositoryDocument {
        val parsed = RepositoryTransport.requireHttpsUrl(url)
        val segments = parsed.pathSegments
        if (parsed.host != "codeberg.org" || segments.size < 5 || segments[2] !in setOf("raw", "src")) {
            return http.fetch(url, maxBytes)
        }
        val refIndex = if (segments[3] in setOf("branch", "tag", "commit")) 4 else 3
        if (segments.size <= refIndex + 1) return http.fetch(url, maxBytes)
        val api = parsed.newBuilder().encodedPath("/api/v1/repos/")
            .addPathSegment(segments[0]).addPathSegment(segments[1]).addPathSegment("contents")
            .apply { segments.drop(refIndex + 1).forEach { addPathSegment(it) } }.query(null)
            .addQueryParameter("ref", segments[refIndex]).build()
        try {
            // JSON/base64 creates several representations. Cap that adapter
            // independently of raw downloads to fit the daemon's 192 MiB heap.
            // Larger resources use the bounded raw HTTPS fallback below.
            val decodedLimit = minOf(maxBytes, RepositoryTransport.MAX_MANIFEST_BYTES)
            val wrapperLimit = decodedLimit * 4 / 3 + 65_536
            val response = http.fetch(api.toString(), wrapperLimit)
            val root = RepositoryJson.parse(response.text(), RepositoryTransport.MAX_RESPONSE_BYTES,
                wrapperLimit).jsonObject
            if (root["encoding"]?.jsonPrimitive?.content != "base64") throw IOException("Unsupported Codeberg content encoding")
            val content = root["content"]?.jsonPrimitive?.content ?: throw IOException("Missing Codeberg content")
            // MIME decoder silently ignores arbitrary punctuation. Permit only
            // the API's documented line wrapping in addition to base64 bytes.
            val compact = content.replace("\r", "").replace("\n", "")
            if (compact.length > (decodedLimit + 2L) / 3 * 4) throw IOException("Codeberg content exceeds byte limit")
            val decoded = Base64.getDecoder().decode(compact)
            if (decoded.size > decodedLimit) throw IOException("Codeberg content exceeds byte limit")
            return RepositoryDocument(decoded, parsed.toString())
        } catch (failure: Exception) {
            if (failure is CancellationException) throw failure
            // Raw HTTPS remains a bounded, authenticated transport fallback.
            return http.fetch(url, maxBytes)
        }
    }
}
