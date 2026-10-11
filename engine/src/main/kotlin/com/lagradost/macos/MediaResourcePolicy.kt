package com.lagradost.macos

import com.lagradost.macos.models.StreamLinkDto
import java.net.URI
import java.util.Locale

/** A terminal provider-output rejection; never carry URL/header secret values. */
internal class RejectedMediaResourceException(val field: String) : IllegalArgumentException("Unsupported provider media resource: $field")

/** Validation is separate from tracking cleanup. Worker output has no authority
 * to name local files or native pseudo-protocols, even inside a valid link. The
 * native consumer applies the same boundary again before acquiring privileges. */
internal object MediaResourcePolicy {
    fun remoteURL(raw: String, field: String = "url"): String {
        if (raw.isEmpty() || raw.any { it.isWhitespace() || it.isISOControl() }) reject(field)
        val uri = try { URI(raw) } catch (_: Exception) { reject(field) }
        if (uri.scheme?.lowercase(Locale.ROOT) !in setOf("http", "https") || uri.host.isNullOrEmpty() || uri.rawUserInfo != null) reject(field)
        return raw
    }

    private val forbiddenHeaders = setOf("host", "content-length", "transfer-encoding", "connection",
        "proxy-connection", "upgrade", "trailer", "te", "proxy-authorization")
    private val tokenPunctuation = "!#$%&'*+-.^_`|~"

    fun headers(headers: Map<String, String>) {
        val seen = mutableSetOf<String>()
        headers.forEach { (name, value) ->
            val folded = name.lowercase(Locale.ROOT)
            if (name.isEmpty() || name.any { it !in 'a'..'z' && it !in 'A'..'Z' && it !in '0'..'9' && it !in tokenPunctuation } ||
                folded in forbiddenHeaders || !seen.add(folded) || value.any { it.isISOControl() || it == '\u2028' || it == '\u2029' }) reject("headers")
        }
    }

    /**
     * Extensions often reuse their request headers (`Host`, `Connection`…) for
     * a stream. Those describe one HTTP connection, not the media, and the
     * player sets them itself, so they are dropped rather than failing the
     * whole link (L2). Names that differ only in case collapse to the last
     * one, as a map lookup on Android would. Everything else is left for
     * [headers] to validate.
     */
    fun normalizedHeaders(headers: Map<String, String>): Map<String, String> {
        val byName = LinkedHashMap<String, Pair<String, String>>()
        headers.forEach { (name, value) ->
            val folded = name.trim().lowercase(Locale.ROOT)
            if (folded in forbiddenHeaders || folded.startsWith("proxy-")) return@forEach
            byName.remove(folded)
            byName[folded] = name.trim() to value
        }
        return byName.values.associate { it }
    }

    fun link(link: StreamLinkDto) {
        remoteURL(link.url)
        headers(link.headers)
        link.drm?.let { drm ->
            if (!drm.key.isHexKey() || drm.kid?.isHexKey() == false) reject("drm")
        }
        if (link.isPlaylist && link.playlist.isEmpty() || link.playlist.size > 500 || link.audioTracks.size > 32) reject("playlist")
        link.playlist.forEach { remoteURL(it, "playlist.url") }
        link.audioTracks.forEach { remoteURL(it.url, "audio.url"); headers(it.headers) }
    }

    /** A 128-bit content key or key ID in lowercase hex, as FFmpeg's `decryption_keys` takes it. */
    private fun String.isHexKey() = length == 32 && all { it in '0'..'9' || it in 'a'..'f' }

    private fun reject(field: String): Nothing = throw RejectedMediaResourceException(field)
}
