package com.lagradost.macos

import com.lagradost.cloudstream3.MainAPI
import com.lagradost.cloudstream3.SubtitleFile
import com.lagradost.cloudstream3.newSubtitleFile
import com.lagradost.cloudstream3.utils.CLEARKEY_DRM_UUID
import com.lagradost.cloudstream3.utils.ExtractorLink
import com.lagradost.cloudstream3.utils.ExtractorLinkType
import com.lagradost.cloudstream3.utils.WIDEVINE_DRM_UUID
import com.lagradost.cloudstream3.utils.newDrmExtractorLink
import com.lagradost.cloudstream3.utils.newExtractorLink
import com.lagradost.macos.models.StreamLinkDto
import kotlinx.coroutines.runBlocking
import kotlin.test.*

/** L1–L4: what an extension hands its link callbacks never aborts it. */
class LinkPipelineTest {
    @BeforeTest fun before() = ExtensionTestSupport.resetHome()
    @AfterTest fun after() = ExtensionTestSupport.resetHome()

    private fun provider(block: suspend ((ExtractorLink) -> Unit, (SubtitleFile) -> Unit) -> Unit) = object : MainAPI() {
        override var name = "Pipeline"
        override suspend fun loadLinks(data: String, isCasting: Boolean, subtitleCallback: (SubtitleFile) -> Unit,
            callback: (ExtractorLink) -> Unit): Boolean { block(callback, subtitleCallback); return true }
    }

    @Test fun `unusable links are skipped and every later link still arrives`() = runBlocking<Unit> {
        val emitted = mutableListOf<StreamLinkDto>()
        val response = ProviderExecutor.loadLinksStreaming(provider { callback, subtitles ->
            callback(newExtractorLink("Torrentio", "Magnet", "magnet:?xt=urn:btih:abc", ExtractorLinkType.MAGNET))
            callback(newExtractorLink("Host", "First", "https://cdn.invalid/one.mp4") {
                headers = mapOf("Host" to "cdn.invalid", "Connection" to "keep-alive", "Referer" to "https://p.invalid/")
            })
            callback(newExtractorLink("Bad", "Injected", "https://cdn.invalid/bad.mp4") { headers = mapOf("X" to "a\r\nInjected: 1") })
            subtitles(newSubtitleFile("English", "file:///tmp/sentinel.vtt"))
            subtitles(newSubtitleFile("English", "https://subs.invalid/en.vtt"))
            callback(newExtractorLink("Later", "Second", "https://cdn.invalid/two.m3u8", ExtractorLinkType.M3U8))
        }, "fixture", emitted::add, {})
        assertEquals(listOf("https://cdn.invalid/one.mp4", "https://cdn.invalid/two.m3u8"), emitted.map { it.url })
        assertEquals(mapOf("Referer" to "https://p.invalid/"), emitted.first().headers)
        assertEquals(listOf("torrent", "invalid"), response.skipped.map { it.reason })
        assertEquals(listOf("https://subs.invalid/en.vtt"), response.subtitles.map { it.url })
        assertEquals("success", response.outcome)
        assertFalse(response.skipped.toString().contains("magnet:"), "skipped links never carry their URL")
    }

    @Test fun `a provider with only torrent sources says so instead of failing generically`() = runBlocking<Unit> {
        val response = ProviderExecutor.loadLinks(provider { callback, _ ->
            callback(newExtractorLink("Torrentio", "1080p", "https://torrents.invalid/a.torrent", ExtractorLinkType.TORRENT))
        }, "fixture")
        val failure = response.failures.single()
        assertEquals("unsupported_sources", failure.code)
        assertFalse(failure.retryable)
        assertTrue("torrent" in failure.publicMessage)
        assertEquals(422, OperationFailures.status(failure))
        assertEquals("failure", response.outcome)
    }

    @OptIn(com.lagradost.cloudstream3.Prerelease::class)
    @Test fun `clear key links carry hex keys and other DRM systems are skipped`() = runBlocking<Unit> {
        // W3C ClearKey JSON values: base64url without padding, as Android hands them to ExoPlayer.
        val kid = "nrQFDeRLSAKTLifXUIPiZg"
        val key = "FmY0xnWCPCNaSpRG-tUuTQ"
        val response = ProviderExecutor.loadLinks(provider { callback, _ ->
            callback(newDrmExtractorLink("Live", "ClearKey", "https://live.invalid/a.mpd", ExtractorLinkType.DASH, CLEARKEY_DRM_UUID) {
                this.kid = kid; this.key = key
            })
            callback(newDrmExtractorLink("Live", "Widevine", "https://live.invalid/b.mpd", ExtractorLinkType.DASH, WIDEVINE_DRM_UUID) {
                licenseUrl = "https://license.invalid/"
            })
            callback(newDrmExtractorLink("Live", "Licence", "https://live.invalid/c.mpd", ExtractorLinkType.DASH, CLEARKEY_DRM_UUID) {
                licenseUrl = "https://license.invalid/"
            })
        }, "fixture")
        val drm = response.links.single().drm!!
        assertEquals("9eb4050de44b4802932e27d75083e266", drm.kid)
        assertEquals("166634c675823c235a4a9446fad52e4d", drm.key)
        assertEquals(listOf("drm", "drm"), response.skipped.map { it.reason })
    }

    @Test fun `key conversion accepts base64url base64 and hex and nothing else`() {
        assertEquals("9eb4050de44b4802932e27d75083e266", LinkIntake.keyHex("nrQFDeRLSAKTLifXUIPiZg"))
        assertEquals("9eb4050de44b4802932e27d75083e266", LinkIntake.keyHex("nrQFDeRLSAKTLifXUIPiZg=="))
        assertEquals("9eb4050de44b4802932e27d75083e266", LinkIntake.keyHex("9EB4050DE44B4802932E27D75083E266"))
        assertNull(LinkIntake.keyHex("too-short"))
        assertNull(LinkIntake.keyHex("nrQFDeRLSAKTLifXUIPiZgAA")) // 18 bytes
        val bad = StreamLinkDto("https://a.invalid/v.mpd", "n", "s", 0, "DASH", drm = com.lagradost.macos.models.ClearKeyDto(key = "zz"))
        assertFailsWith<RejectedMediaResourceException> { MediaResourcePolicy.link(bad) }
    }

    @Test fun `routed extraction skips the same links without failing`() = runBlocking<Unit> {
        val intake = LinkIntake()
        assertNull(intake.link(newExtractorLink("x", "y", "magnet:?xt=urn:btih:abc")))
        assertNotNull(intake.link(newExtractorLink("x", "y", "https://cdn.invalid/v.mp4")))
        assertEquals("torrent", intake.skipped.single().reason)
    }
}
