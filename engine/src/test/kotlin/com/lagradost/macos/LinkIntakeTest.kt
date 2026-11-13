package com.lagradost.macos

import com.lagradost.cloudstream3.USER_AGENT
import com.lagradost.cloudstream3.app
import com.lagradost.cloudstream3.utils.ExtractorLinkType
import com.lagradost.cloudstream3.utils.newExtractorLink
import kotlinx.coroutines.runBlocking
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import kotlin.test.*

/** Links carry the scraping session's cookies and User-Agent to the player (M1). */
class LinkIntakeTest {
    private lateinit var original: OkHttpClient

    @BeforeTest fun before() { original = app.baseClient }
    @AfterTest fun after() { app.baseClient = original; SolveBridge.clearCachedCookies() }

    /** A jar holding [cookies] for every host matching their domain, like a session jar. */
    private fun jar(vararg cookies: Cookie) = object : CookieJar {
        override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {}
        override fun loadForRequest(url: HttpUrl): List<Cookie> = cookies.filter { it.matches(url) }
    }

    private fun cookie(name: String, value: String, domain: String) =
        Cookie.Builder().name(name).value(value).domain(domain).path("/").build()

    private fun withJar(jar: CookieJar) { app.baseClient = original.newBuilder().cookieJar(jar).build() }

    @Test fun `cookies from the session jar are added to a link without its own`() = runBlocking<Unit> {
        withJar(jar(cookie("session", "abc", "example.com"), cookie("pref", "1", "example.com"), cookie("other", "x", "elsewhere.com")))
        val link = LinkIntake().link(newExtractorLink("Src", "Name", "https://example.com/video.m3u8", ExtractorLinkType.M3U8))
        assertNotNull(link)
        assertEquals("session=abc; pref=1", link.headers["Cookie"])
        assertFalse("other=x" in link.headers["Cookie"].orEmpty(), "a cookie never reaches a host it was not set for")
    }

    @Test fun `cookies are looked up for the stream URL, not the referer`() = runBlocking<Unit> {
        withJar(jar(cookie("site", "1", "site.com")))
        val link = LinkIntake().link(newExtractorLink("Src", "Name", "https://cdn.example/v.mp4") { referer = "https://site.com/watch" })
        assertNotNull(link)
        assertNull(link.headers["Cookie"])
        assertEquals("https://site.com/watch", link.headers["referer"])
    }

    @Test fun `the extension's own Cookie and User-Agent always win`() = runBlocking<Unit> {
        withJar(jar(cookie("session", "jar", "example.com")))
        val link = LinkIntake().link(newExtractorLink("Src", "Name", "https://example.com/v.mp4") {
            headers = mapOf("cookie" to "session=mine", "user-agent" to "Custom/1")
        })
        assertNotNull(link)
        assertEquals("session=mine", link.headers["cookie"])
        assertEquals("Custom/1", link.headers["user-agent"])
        assertEquals(2, link.headers.size, "no second spelling of a header the extension set")
    }

    @Test fun `a link gets the provider client's User-Agent when it sets none`() = runBlocking<Unit> {
        val link = LinkIntake().link(newExtractorLink("Src", "Name", "https://example.com/v.mp4"))
        assertNotNull(link)
        val expected = app.defaultHeaders.entries.firstOrNull { it.key.equals("user-agent", true) }?.value ?: USER_AGENT
        assertEquals(expected, link.headers["User-Agent"])
        assertNull(link.headers["Cookie"], "no jar cookies, no Cookie header")
    }

    @Test fun `audio tracks get cookies for their own URL`() = runBlocking<Unit> {
        withJar(jar(cookie("a", "1", "audio.example"), cookie("v", "2", "video.example")))
        val link = LinkIntake().link(newExtractorLink("Src", "Name", "https://video.example/v.mp4") {
            audioTracks = listOf(com.lagradost.cloudstream3.newAudioFile("https://audio.example/a.m4a"))
        })
        assertNotNull(link)
        assertEquals("v=2", link.headers["Cookie"])
        assertEquals("a=1", link.audioTracks.single().headers["Cookie"])
    }

    @Test fun `solved challenge cookies go only to the site they were solved for`() = runBlocking<Unit> {
        SolveBridge.applySolvedCookies("https://site.example/challenge", "cf_clearance=ok")
        withJar(jar(cookie("session", "abc", "site.example")))
        val same = LinkIntake().link(newExtractorLink("Src", "Name", "https://site.example/v.m3u8", ExtractorLinkType.M3U8))
        assertEquals("session=abc; cf_clearance=ok", same?.headers?.get("Cookie"))
        val other = LinkIntake().link(newExtractorLink("Src", "Name", "https://cdn.other/v.m3u8", ExtractorLinkType.M3U8) {
            referer = "https://site.example/watch"
        })
        assertNull(other?.headers?.get("Cookie"), "another host never receives them, even with that site as referer")
        val plain = LinkIntake().link(newExtractorLink("Src", "Name", "http://site.example/v.m3u8", ExtractorLinkType.M3U8))
        assertFalse(plain?.headers?.get("Cookie").orEmpty().contains("cf_clearance"), "clearance is never sent without HTTPS")
    }

    @Test fun `a jar that throws never loses the link`() = runBlocking<Unit> {
        withJar(object : CookieJar {
            override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {}
            override fun loadForRequest(url: HttpUrl): List<Cookie> = error("broken jar")
        })
        val intake = LinkIntake()
        assertNotNull(intake.link(newExtractorLink("Src", "Name", "https://example.com/v.mp4")))
        assertTrue(intake.skipped.isEmpty())
    }
}
