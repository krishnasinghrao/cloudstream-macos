package com.lagradost.macos

import com.lagradost.cloudstream3.SubtitleFile
import com.lagradost.cloudstream3.utils.CLEARKEY_DRM_UUID
import com.lagradost.cloudstream3.utils.DrmExtractorLink
import com.lagradost.cloudstream3.utils.ExtractorLink
import com.lagradost.cloudstream3.utils.ExtractorLinkPlayList
import com.lagradost.cloudstream3.utils.ExtractorLinkType
import com.lagradost.macos.models.AudioTrackDto
import com.lagradost.macos.models.ClearKeyDto
import com.lagradost.macos.models.LinksResponseDto
import com.lagradost.macos.models.SkippedLinkDto
import com.lagradost.macos.models.StreamLinkDto
import com.lagradost.macos.models.SubtitleDto
import com.lagradost.macos.worker.RemoteProvider
import java.util.Base64

/**
 * Turns what an extension hands its `loadLinks` callbacks into IPC values (L1).
 *
 * On Android the callbacks never throw back into the extension: a link the
 * player cannot use simply fails when chosen. Here every link is checked
 * before it leaves the engine, so a rejection must stay on this side of the
 * callback; otherwise one magnet link or one malformed header aborts the
 * extension's whole `loadLinks` and every later link is lost.
 *
 * Not thread-safe by itself: extensions call back from several coroutines,
 * so callers synchronize (as [ProviderExecutor] does).
 */
internal class LinkIntake {
    val skipped = mutableListOf<SkippedLinkDto>()

    /** The link as an IPC value, or null when it is skipped (recorded in [skipped]). */
    fun link(link: ExtractorLink): StreamLinkDto? {
        val reason = when {
            link.type == ExtractorLinkType.TORRENT || link.type == ExtractorLinkType.MAGNET ||
                link.url.startsWith("magnet:", ignoreCase = true) -> "torrent"
            else -> null
        }
        if (reason != null) return skip(link, reason)
        val drm = if (link is DrmExtractorLink) clearKey(link) ?: return skip(link, "drm") else null
        return try {
            convert(link, drm)
        } catch (_: RejectedMediaResourceException) {
            skip(link, "invalid")
        } catch (_: IllegalArgumentException) {
            skip(link, "invalid")
        }
    }

    /** The subtitle as an IPC value, or null when its address is not a remote http(s) URL. */
    fun subtitle(sub: SubtitleFile): SubtitleDto? = try {
        SubtitleDto(url = sub.url, language = sub.lang, mimeType = guessSubtitleMime(sub.url)).let(RemoteProvider::cleanSubtitle)
    } catch (_: RejectedMediaResourceException) {
        null
    } catch (_: IllegalArgumentException) {
        null
    }

    private fun skip(link: ExtractorLink, reason: String): StreamLinkDto? {
        if (skipped.size < LinksResponseDto.MAX_SKIPPED) {
            skipped += SkippedLinkDto(source = link.source.take(200), name = link.name.take(200), reason = reason)
        }
        return null
    }

    companion object {
        /**
         * Stream URLs go through [URLSanitizer.sanitizeStream], not the general
         * sanitizer: CDN signatures frequently cover the whole query string, and
         * stripping ambiguous keys (`ref`, `crc`, `track`…) turns a valid link
         * into a 403 (Player-Remediation-Plan A4).
         */
        private fun convert(link: ExtractorLink, drm: ClearKeyDto?): StreamLinkDto = StreamLinkDto(
            url = link.url,
            name = link.name,
            source = link.source,
            quality = link.quality,
            type = link.type.name,
            headers = link.getAllHeaders(),
            extractorData = link.extractorData,
            isPlaylist = link is ExtractorLinkPlayList,
            playlist = (link as? ExtractorLinkPlayList)?.playlist?.map { it.url } ?: emptyList(),
            audioTracks = link.audioTracks.map { audio ->
                AudioTrackDto(
                    url = audio.url,
                    label = audio.label,
                    language = audio.language,
                    headers = audio.headers ?: link.getAllHeaders(),
                )
            },
            drm = drm,
        ).let(RemoteProvider::cleanLink)

        /**
         * ClearKey with the key in the link is the only DRM the player can
         * decrypt (FFmpeg's CENC support). Widevine, PlayReady or any key
         * fetched from a licence server needs a platform CDM: null.
         */
        // The host reads what any build of an extension may set; the opt-in guards extension authors.
        @OptIn(com.lagradost.cloudstream3.Prerelease::class)
        internal fun clearKey(link: DrmExtractorLink): ClearKeyDto? {
            if (link.uuid != CLEARKEY_DRM_UUID || !link.licenseUrl.isNullOrBlank()) return null
            val key = link.key?.let(::keyHex) ?: return null
            val kid = link.kid?.takeIf { it.isNotBlank() }?.let { keyHex(it) ?: return null }
            return ClearKeyDto(kid = kid, key = key)
        }

        /**
         * A 128-bit key as lowercase hex. Android passes ClearKey values to
         * ExoPlayer as base64url (the W3C ClearKey JSON format); some
         * extensions give hex instead, which is unambiguous (32 characters,
         * while 16 bytes in base64 are 22–24).
         */
        internal fun keyHex(raw: String): String? {
            val value = raw.trim()
            if (value.length == 32 && value.all { it.isDigit() || it.lowercaseChar() in 'a'..'f' }) return value.lowercase()
            val bytes = runCatching { Base64.getUrlDecoder().decode(value.replace('+', '-').replace('/', '_').trimEnd('=')) }.getOrNull()
            return bytes?.takeIf { it.size == 16 }?.joinToString("") { "%02x".format(it) }
        }

        internal fun guessSubtitleMime(url: String): String? = when {
            url.substringBefore('?').endsWith(".vtt") -> "text/vtt"
            url.substringBefore('?').endsWith(".srt") -> "application/x-subrip"
            else -> null
        }
    }
}
