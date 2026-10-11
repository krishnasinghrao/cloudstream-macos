package com.lagradost.macos

import java.net.URI
import java.net.URLDecoder

/**
 * SEC-04: URL Sanitization Gate.
 *
 * Every scraped link must pass through [URLSanitizer.sanitize] before it is
 * handed to libmpv, ffmpeg, or persisted by the client. Tracking and affiliate
 * parameters are stripped while legitimate streaming parameters (HLS token,
 * expiry, signature) are preserved.
 */
object URLSanitizer {
    /** Tracking / affiliate parameters to strip. Prefix rules end with '*'. */
    private val TRACKING_RULES = listOf(
        // Google Analytics / Ads
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
        "utm_id", "utm_source_platform", "utm_creative_format", "utm_marketing_tactic",
        "gclid", "gclsrc", "dclid", "wbraid", "gbraid",
        // Social & affiliate trackers
        "fbclid", "igshid", "mc_eid", "mc_cid", "_hsenc", "_hsmi", "vero_id",
        "wickedid", "ttclid", "twclid", "msclkid", "li_fat_id",
        "aff_id", "affiliate_id", "aff_track", "ref", "ref_src", "ref_url",
        "referrer", "affiliate", "aff", "click_id", "clickid", "subid",
        "subid1", "subid2", "track", "tracking", "track_id",
        // Platform telemetry
        "spm", "scid", "crc", "share_app_id", "share_link_id", "xlink",
        "_openstat", "yclid", "action_ref_map", "action_type_map",
    )

    /** Streams break if these are stripped; they carry CDN auth payloads. */
    private val PROTECTED_PREFIXES = listOf(
        "token", "auth", "key", "sig", "signature", "expires", "expire",
        "hmac", "hash", "id", "cont", "session", "device", "cdn",
    )

    fun isTrackingParameter(name: String): Boolean {
        val lower = name.trim().lowercase()
        if (lower.isBlank()) return false
        if (PROTECTED_PREFIXES.any { lower.startsWith(it) }) return false
        return TRACKING_RULES.any { rule ->
            if (rule.endsWith("*")) lower.startsWith(rule.removeSuffix("*")) else lower == rule
        } || lower.startsWith("utm") || lower.startsWith("track_") ||
            lower.startsWith("aff_") || lower.startsWith("mtm_")
    }

    /**
     * Unambiguous marketing click-IDs. Only these are removed from *stream*
     * URLs without an explicit signature. A signed query may include any
     * parameter, including marketing keys; preserve its complete spelling.
     * Generic keys like `ref`, `crc`, `track` or `aff` remain untouched too.
     */
    private val STREAM_SAFE_TRACKING = setOf(
        "gclid", "gclsrc", "dclid", "wbraid", "gbraid", "fbclid", "igshid",
        "msclkid", "ttclid", "twclid", "yclid", "mc_eid", "mc_cid", "_hsenc", "_hsmi",
    )

    fun isStreamTrackingParameter(name: String): Boolean {
        val lower = name.trim().lowercase()
        return lower.startsWith("utm_") || lower in STREAM_SAFE_TRACKING
    }

    /**
     * SEC-04 for playable media (stream, audio, subtitle URLs): strips only
     * unambiguous marketing parameters and otherwise preserves the query
     * byte-for-byte (Player-Remediation-Plan A4).
     */
    private val SIGNATURE_PARAMETERS = setOf(
        "sig", "signature", "hmac", "hash", "s", "policy", "hdnts", "hdnea",
        "x-amz-signature", "x-goog-signature", "__gda__", "__hdnea__",
    )

    fun sanitizeStream(url: String): String {
        val query = try { URI(url).rawQuery } catch (_: Exception) { null }
        if (query != null && query.split('&').any {
                decodeParam(it.substringBefore('=')).lowercase() in SIGNATURE_PARAMETERS
            }) return url
        return sanitizeWith(url, ::isStreamTrackingParameter)
    }

    /**
     * Strips tracking/affiliate query parameters from [url].
     * Non-URL strings (e.g. data: URIs, magnet links) pass through untouched.
     */
    fun sanitize(url: String): String = sanitizeWith(url, ::isTrackingParameter)

    private fun sanitizeWith(url: String, isTracking: (String) -> Boolean): String {
        val trimmed = url.trim()
        if (trimmed.isBlank()) return trimmed
        if (!trimmed.startsWith("http://") && !trimmed.startsWith("https://")) return trimmed

        return try {
            val uri = URI(trimmed)
            val query = uri.rawQuery ?: return trimmed
            val pairs = query.split('&').filter { it.isNotBlank() }
            val kept = pairs.filterNot { pair -> isTracking(pair.substringBefore('=')) }
            // Nothing to strip → hand back the original bytes untouched.
            if (kept.size == pairs.size) return trimmed

            val newQuery = kept.joinToString("&")
            val rebuilt = StringBuilder().apply {
                append(uri.scheme).append("://")
                if (uri.rawAuthority != null) append(uri.rawAuthority)
                append(uri.rawPath ?: "")
                if (newQuery.isNotEmpty()) append('?').append(newQuery)
                if (uri.rawFragment != null) append('#').append(uri.rawFragment)
            }
            rebuilt.toString()
        } catch (_: Exception) {
            trimmed
        }
    }

    /** Decodes a query value if percent-encoded; used when logging sanitized links. */
    fun decodeParam(value: String): String = try {
        URLDecoder.decode(value, Charsets.UTF_8)
    } catch (_: Exception) {
        value
    }
}
