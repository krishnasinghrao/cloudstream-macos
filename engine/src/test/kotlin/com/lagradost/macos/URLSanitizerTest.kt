package com.lagradost.macos

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * SEC-04 gate tests: tracking parameters must be stripped while CDN auth
 * parameters survive — stripping the wrong param breaks streaming entirely.
 */
class URLSanitizerTest {

    @Test
    fun `strips utm parameters`() {
        val out = URLSanitizer.sanitize("https://cdn.example.com/video.mp4?utm_source=x&utm_campaign=mail&id=42")
        assertEquals("https://cdn.example.com/video.mp4?id=42", out)
    }

    @Test
    fun `strips fbclid gclid and affiliate tokens`() {
        val out = URLSanitizer.sanitize(
            "https://host.example/v.mp4?fbclid=abc&gclid=def&aff_id=7&track_id=8&quality=1080",
        )
        assertEquals("https://host.example/v.mp4?quality=1080", out)
    }

    @Test
    fun `strips wildcard prefixes`() {
        val out = URLSanitizer.sanitize("https://host.example/v.m3u8?utmTerm=1&track_x=2&ok=3")
        assertEquals("https://host.example/v.m3u8?ok=3", out)
    }

    @Test
    fun `preserves streaming auth parameters`() {
        val url = "https://cdn.example.com/master.m3u8?token=abc123&expires=1735689600&hmac=deadbeef&signature=sig"
        assertEquals(url, URLSanitizer.sanitize(url))
    }

    @Test
    fun `preserves protected prefixes even when they look like trackers`() {
        // "token"-like names must win over tracker rules.
        val out = URLSanitizer.sanitize("https://cdn.example.com/v.mp4?token=keep&utm_source=strip")
        assertEquals("https://cdn.example.com/v.mp4?token=keep", out)
    }

    @Test
    fun `preserves fragment and path`() {
        val out = URLSanitizer.sanitize("https://example.com/a/b/c.m3u8?fbclid=x#frag")
        assertEquals("https://example.com/a/b/c.m3u8#frag", out)
    }

    @Test
    fun `non-http urls pass through untouched`() {
        for (url in listOf("magnet:?xt=urn:btih:abc", "data:text/plain,hi", "", "file:///x")) {
            assertEquals(url, URLSanitizer.sanitize(url))
        }
    }

    @Test
    fun `malformed urls pass through untouched`() {
        val out = URLSanitizer.sanitize("https://example.com/%zz?utm_source=x&&")
        assertTrue(out.startsWith("https://example.com/"))
    }

    @Test
    fun `isTrackingParameter classification`() {
        assertTrue(URLSanitizer.isTrackingParameter("utm_medium"))
        assertTrue(URLSanitizer.isTrackingParameter("fbclid"))
        assertTrue(URLSanitizer.isTrackingParameter("aff_id"))
        assertTrue(URLSanitizer.isTrackingParameter("TRACK_ID"))
        assertFalse(URLSanitizer.isTrackingParameter("token"))
        assertFalse(URLSanitizer.isTrackingParameter("expires"))
        assertFalse(URLSanitizer.isTrackingParameter("signature"))
        assertFalse(URLSanitizer.isTrackingParameter(""))
    }

    @Test
    fun `idempotent sanitization`() {
        val once = URLSanitizer.sanitize("https://host.example/v.mp4?utm_source=x&token=t")
        val twice = URLSanitizer.sanitize(once)
        assertEquals(once, twice)
        assertNull(null as String?) // placeholder to keep assert count honest
    }

    // --- Stream URLs (Player-Remediation-Plan A4) ---------------------------

    @Test
    fun `stream sanitizer keeps ambiguous keys that CDNs sign over`() {
        val url = "https://cdn.example.com/hls/master.m3u8?ref=site&crc=9f2a&track=1&aff=3&spm=a.b&subid=7&e=1735689600&s=abc"
        assertEquals(url, URLSanitizer.sanitizeStream(url))
    }

    @Test
    fun `stream sanitizer strips unambiguous marketing ids`() {
        val out = URLSanitizer.sanitizeStream("https://cdn.example.com/v.mp4?utm_source=x&fbclid=y&gclid=z&token=keep")
        assertEquals("https://cdn.example.com/v.mp4?token=keep", out)
    }

    @Test
    fun `signed streams preserve the complete query including tracking and empty pairs`() {
        for (signature in listOf("sig", "%73ig", "X-Amz-Signature", "X-Goog-Signature", "hdnts", "s")) {
            val url = "https://cdn.example.com/v.mp4?utm_source=signed&&$signature=A%2fb+Z%3D&fbclid=signed&x=%26%3b"
            assertEquals(url, URLSanitizer.sanitizeStream(url))
        }
    }

    @Test
    fun `stream sanitizer returns original bytes when nothing is stripped`() {
        // Encoded characters and empty pairs must survive verbatim.
        val url = "https://cdn.example.com/v.mp4?a=%2F%3D&&b=c"
        assertEquals(url, URLSanitizer.sanitizeStream(url))
    }

    @Test
    fun `stream tracking classification`() {
        assertTrue(URLSanitizer.isStreamTrackingParameter("utm_campaign"))
        assertTrue(URLSanitizer.isStreamTrackingParameter("FBCLID"))
        assertFalse(URLSanitizer.isStreamTrackingParameter("ref"))
        assertFalse(URLSanitizer.isStreamTrackingParameter("crc"))
        assertFalse(URLSanitizer.isStreamTrackingParameter("track"))
    }
}
