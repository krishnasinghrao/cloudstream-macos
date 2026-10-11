package com.lagradost.macos

import com.lagradost.cloudstream3.MainAPI
import com.lagradost.cloudstream3.SubtitleFile
import com.lagradost.cloudstream3.utils.ExtractorLink
import com.lagradost.cloudstream3.utils.newExtractorLink
import com.lagradost.macos.models.AudioTrackDto
import com.lagradost.macos.models.StreamLinkDto
import com.lagradost.macos.models.SubtitleDto
import com.lagradost.macos.worker.RemoteProvider
import kotlinx.coroutines.runBlocking
import kotlin.test.*

class MediaResourcePolicyTest {
    private fun link(url: String = "https://cdn.invalid/v.mp4", playlist: List<String> = emptyList(),
                     audio: List<AudioTrackDto> = emptyList(), headers: Map<String, String> = emptyMap()) =
        StreamLinkDto(url, "Fixture", "fixture", 720, "VIDEO", headers, isPlaylist = playlist.isNotEmpty(), playlist = playlist, audioTracks = audio)

    @Test fun `remote validation preserves signed bytes and rejects privileged URI forms`() {
        val signed = "https://cdn.invalid/v.mp4?sparams=a,b;c&sig=A%2fb+Z%3D&x=%26%3b"
        assertEquals(signed, MediaResourcePolicy.remoteURL(signed))
        for (bad in listOf("/tmp/movie", "file:///tmp/movie", "edl://file:///tmp/movie", "concat:https://a|https://b",
            "data:abc", "pipe:0", "magnet:?xt=urn:x", "https://user:secret@cdn.invalid/video",
            "https:///video", "https://cdn.invalid/%zz", " https://cdn.invalid/video", "https://cdn.invalid/v\r\n")) {
            assertFailsWith<RejectedMediaResourceException>(bad) { MediaResourcePolicy.remoteURL(bad) }
        }
    }

    @Test fun `worker rejects unsafe root nested subtitle and header resources before cleanup`() {
        for (bad in listOf(link("file:///tmp/sentinel"), link(playlist = listOf("https://cdn.invalid/a", "/tmp/sentinel")),
            link(audio = listOf(AudioTrackDto("data:abc"))), link(headers = mapOf("Cookie" to "secret\r\nInjected: yes")),
            link(headers = mapOf("Bad Name" to "x")), link(audio = listOf(AudioTrackDto("https://a.invalid/a", headers = mapOf("X" to "a\nb")))))) {
            assertFailsWith<RejectedMediaResourceException> { RemoteProvider.cleanLink(bad) }
        }
        assertFailsWith<RejectedMediaResourceException> { RemoteProvider.cleanSubtitle(SubtitleDto("file:///tmp/sentinel", "en")) }
        val valid = link(audio = listOf(AudioTrackDto("https://audio.invalid/a?sig=A%2fb", headers = mapOf("Cookie" to "audio=1"))),
            headers = mapOf("Authorization" to "Bearer fixture", "Referer" to "https://provider.invalid/", "X-Comma" to "a, b"))
        assertEquals(valid, RemoteProvider.cleanLink(valid))
    }

    @Test fun `transport headers are dropped and case duplicates collapse instead of failing the link`() {
        val cleaned = RemoteProvider.cleanLink(link(
            headers = mapOf("Host" to "video.invalid", "Connection" to "keep-alive", "Content-Length" to "7",
                "Proxy-Authorization" to "x", "Cookie" to "one", "cookie" to "two", "Referer" to "https://p.invalid/"),
            audio = listOf(AudioTrackDto("https://a.invalid/a", headers = mapOf("host" to "a.invalid", "Origin" to "https://p.invalid")))))
        assertEquals(mapOf("cookie" to "two", "Referer" to "https://p.invalid/"), cleaned.headers)
        assertEquals(mapOf("Origin" to "https://p.invalid"), cleaned.audioTracks.single().headers)
        // Still validated after normalization: the policy itself keeps rejecting what it always did.
        assertFailsWith<RejectedMediaResourceException> { MediaResourcePolicy.headers(mapOf("Host" to "x")) }
    }

    @Test fun `resource failures are typed terminal and redact secret values`() {
        val error = assertFailsWith<RejectedMediaResourceException> { MediaResourcePolicy.remoteURL("https://user:secret@cdn.invalid/v?sig=secret") }
        val failure = OperationFailures.capture(null, "loadLinks", error).failure
        assertEquals("rejected_media_resource", failure.code)
        assertFalse(failure.retryable)
        assertEquals(422, OperationFailures.status(failure))
        assertFalse(failure.toString().contains("secret"))
        assertFalse(failure.toString().contains("cdn.invalid"))
    }

    @Test fun `legacy provider callback cannot export local resources in batch or streaming`() = runBlocking<Unit> {
        val provider = object : MainAPI() {
            override suspend fun loadLinks(data: String, isCasting: Boolean, subtitleCallback: (SubtitleFile) -> Unit,
                callback: (ExtractorLink) -> Unit): Boolean {
                callback(newExtractorLink("fixture", "Unsafe", "file:///tmp/sentinel?secret=fixture"))
                return true
            }
        }
        val emitted = mutableListOf<StreamLinkDto>()
        val response = ProviderExecutor.loadLinksStreaming(provider, "fixture", emitted::add, {})
        assertTrue(emitted.isEmpty())
        assertTrue(response.links.isEmpty())
        assertEquals("failure", response.outcome)
        assertEquals("rejected_media_resource", response.failures.single().code)
        assertFalse(response.failures.single().retryable)
    }
}
