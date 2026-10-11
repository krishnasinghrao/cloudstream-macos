package com.lagradost.macos

import com.lagradost.macos.worker.RemoteProvider
import com.lagradost.macos.worker.WorkerExtensionRuntime
import com.lagradost.macos.worker.WorkerLauncher
import com.lagradost.macos.worker.WorkerPool
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlin.test.*

/**
 * Plan RT-11: an extension's WebViewResolver runs as a page the app loads in
 * WebKit. These tests play the app's part (poll, report requests, complete).
 */
class MediaResolveBridgeTest {
    @BeforeTest fun before() { ExtensionTestSupport.resetHome(); WorkerPool.resetForTest(); MediaResolveBridge.clearForTest(); ExtensionTestSupport.allowUnsandboxedWorkers() }
    @AfterTest fun after() { WorkerPool.resetForTest(); MediaResolveBridge.clearForTest(); ExtensionTestSupport.resetHome() }

    private fun spec(timeoutMs: Long = 10_000) = MediaResolveSpec(
        url = "https://embed.invalid/e/1", intercept = PatternSpec("""\.m3u8"""),
        additional = listOf(PatternSpec("""/subs/[^/]+\.vtt$""")), userAgent = "Fixture-UA", timeoutMs = timeoutMs,
    )

    /** Plays the app: waits for the task, reports requests, completes. */
    private suspend fun actAsApp(reports: List<String>, cookies: Map<String, String> = emptyMap(), script: String? = null): MediaObserveResponseDto {
        val task = withTimeout(10_000) { while (MediaResolveBridge.pending().isEmpty()) delay(20); MediaResolveBridge.pending().single() }
        val response = MediaResolveBridge.observe(MediaObserveRequestDto(task.taskId, reports.map { MediaObservedRequestDto(it) }))
        assertTrue(MediaResolveBridge.complete(MediaCompleteRequestDto(task.taskId, script, cookies, "WebKit-UA", "https://embed.invalid/e/1")))
        return response
    }

    @Test fun `intercept stops the page and matches carry replay headers`() = runBlocking<Unit> {
        val result = async { MediaResolveBridge.resolve(spec()) }
        val response = actAsApp(listOf(
            "https://embed.invalid/e/1", "javascript:alert(1)", "https://cdn.invalid/subs/en.vtt",
            "https://cdn.invalid/hls/master.m3u8?token=signed", "https://cdn.invalid/late.m3u8",
        ), cookies = mapOf("cdn.invalid" to "session=abc"), script = "\"Fixture\"")
        assertTrue(response.stop, "the intercept match tells the app to stop")
        val outcome = assertNotNull(result.await())
        val stream = assertNotNull(outcome.intercepted)
        assertEquals("https://cdn.invalid/hls/master.m3u8?token=signed", stream.url, "signed query preserved; later requests ignored")
        assertEquals("https://embed.invalid/e/1", stream.headers["Referer"])
        assertEquals("WebKit-UA", stream.headers["User-Agent"])
        assertEquals("session=abc", stream.headers["Cookie"], "cookies only for the match's own host")
        assertEquals(listOf("https://cdn.invalid/subs/en.vtt"), outcome.additional.map { it.url })
        assertEquals("\"Fixture\"", outcome.scriptResult)
    }

    @Test fun `a page that never reaches the intercept returns what it collected`() = runBlocking<Unit> {
        val result = async { MediaResolveBridge.resolve(spec(timeoutMs = 1_500)) }
        withTimeout(5_000) { while (MediaResolveBridge.pending().isEmpty()) delay(20) }
        val id = MediaResolveBridge.pending().single().taskId
        assertFalse(MediaResolveBridge.observe(MediaObserveRequestDto(id, listOf(MediaObservedRequestDto("https://cdn.invalid/subs/a.vtt")))).stop)
        val outcome = assertNotNull(result.await(), "timeout keeps partial results, as Android does")
        assertNull(outcome.intercepted)
        assertEquals(1, outcome.additional.size)
        assertEquals(emptyList(), MediaResolveBridge.pending(), "the task is gone after its deadline")
        assertFalse(MediaResolveBridge.observe(MediaObserveRequestDto(id, emptyList())).known)
    }

    @Test fun `requests and patterns are bounded`() = runBlocking<Unit> {
        assertFailsWith<IllegalArgumentException> { MediaResolveBridge.resolve(spec().copy(url = "file:///etc/passwd")) }
        assertFailsWith<IllegalArgumentException> { MediaResolveBridge.resolve(spec().copy(method = "DELETE")) }
        assertFailsWith<IllegalArgumentException> { MediaResolveBridge.resolve(spec().copy(intercept = PatternSpec("a".repeat(2_001)))) }
        // A catastrophic pattern against a crafted URL is cut off by the matching budget instead of hanging.
        val evil = spec(timeoutMs = 3_000).copy(intercept = PatternSpec("""^(a+)+$"""))
        val result = async { MediaResolveBridge.resolve(evil) }
        withTimeout(5_000) { while (MediaResolveBridge.pending().isEmpty()) delay(20) }
        val started = System.nanoTime()
        val response = MediaResolveBridge.observe(MediaObserveRequestDto(MediaResolveBridge.pending().single().taskId,
            listOf(MediaObservedRequestDto("https://x.invalid/" + "a".repeat(5_000) + "!"))))
        assertFalse(response.stop)
        assertTrue((System.nanoTime() - started) / 1_000_000 < 1_000, "matching is time-bounded")
        result.await()
        // Headers with control characters, a Host override or an invalid name never reach the app.
        val headers = async { MediaResolveBridge.resolve(spec(timeoutMs = 1_500).copy(userAgent = "UA\r\nX-Injected: 1",
            headers = mapOf("X-Ok" to "fine", "X-Split" to "a\r\nSet-Cookie: x=1", "Host" to "evil.invalid", "Bad Name" to "v"))) }
        withTimeout(5_000) { while (MediaResolveBridge.pending().isEmpty()) delay(20) }
        val pending = MediaResolveBridge.pending().single()
        assertEquals(mapOf("X-Ok" to "fine"), pending.headers)
        assertNull(pending.userAgent)
        headers.await()
        // At most MAX_PENDING pages wait at once.
        val waiting = (1..MediaResolveBridge.MAX_PENDING).map { async { MediaResolveBridge.resolve(spec(timeoutMs = 2_000)) } }
        withTimeout(5_000) { while (MediaResolveBridge.pending().size < MediaResolveBridge.MAX_PENDING) delay(20) }
        assertFailsWith<WorkerCapacityException> { MediaResolveBridge.resolve(spec()) }
        waiting.forEach { it.await() }
    }

    /** End to end: a Kotlin-compiled extension's WebViewResolver, in its worker, resolved by the "app". */
    @Test fun `an extension's WebViewResolver resolves through the engine and the app`() = runBlocking<Unit> {
        val repo = SignedCatalogFixture("https://webview.invalid/repo.json")
        val fetcher = repo.publish(mapOf("WebView" to ExtensionTestSupport.extension("webview")), revision = 1)
        val manager = ExtensionTestSupport.use(InstallationManager(WorkerExtensionRuntime(WorkerLauncher(sandboxed = false)), fetcher))
        val record = manager.install(repo.url, "WebView")
        val provider = assertIs<RemoteProvider>(PluginBridge.loadedInstallation(record.id)!!.providers.single())
        val links = async { ProviderExecutor.loadLinks(provider, "https://embed.invalid/e/42") }
        actAsApp(listOf("https://cdn.invalid/subs/en.vtt", "https://cdn.invalid/hls/42.m3u8"),
            cookies = mapOf("cdn.invalid" to "token=t"), script = "\"Episode 42\"")
        val response = links.await()
        val link = response.links.single()
        assertEquals("https://cdn.invalid/hls/42.m3u8", link.url)
        assertEquals("WebView \"Episode 42\"", link.name, "scriptCallback receives the JSON-encoded result, as on Android")
        assertEquals("https://embed.invalid/e/1", link.headers["referer"] ?: link.headers["Referer"])
        assertEquals("token=t", link.headers["Cookie"])
        assertEquals(listOf("https://cdn.invalid/subs/en.vtt"), response.subtitles.map { it.url })
    }
}
