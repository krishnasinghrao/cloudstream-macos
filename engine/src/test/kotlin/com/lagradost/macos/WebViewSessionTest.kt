package com.lagradost.macos

import android.webkit.JavascriptInterface
import android.webkit.ValueCallback
import android.webkit.WebView
import android.webkit.WebViewClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.test.*

/**
 * RT-14: an extension's android.webkit.WebView is a handle onto a WebKit
 * session in the app. Here the "app" is a coroutine serving the same pending
 * and complete calls the routes expose; the WebView is the real class.
 */
class WebViewSessionTest {
    private val app = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val commands = CopyOnWriteArrayList<WebViewCommandDto>()

    @BeforeTest fun before() {
        ExtensionTestSupport.resetHome()
        com.lagradost.macos.worker.WorkerPool.resetForTest()
        ExtensionTestSupport.allowUnsandboxedWorkers()
        WebViewSessionBridge.clearForTest()
        WebViewSessions.transport = { request -> WebViewSessionBridge.handle("owner-a", request) }
        app.launch {
            while (isActive) {
                for (command in PendingSignal.awaitNonEmpty(1_000) { WebViewSessionBridge.pending() }) {
                    commands += command
                    when (command.op) {
                        "load" -> {
                            WebViewSessionBridge.complete(WebViewResultDto(command.commandId))
                            WebViewSessionBridge.event(WebViewEventDto(command.session, WebViewEvent("finished", url = command.url)))
                            // The page calls the interface the extension registered, and one it did not.
                            WebViewSessionBridge.event(WebViewEventDto(command.session, WebViewEvent("call", name = "Bridge", method = "deliver", args = listOf("token-42"))))
                            assertFalse(WebViewSessionBridge.event(WebViewEventDto(command.session, WebViewEvent("call", name = "Other", method = "deliver"))))
                        }
                        "eval" -> WebViewSessionBridge.complete(WebViewResultDto(command.commandId, result = "\"" + command.script!!.reversed() + "\""))
                        else -> WebViewSessionBridge.complete(WebViewResultDto(command.commandId))
                    }
                }
            }
        }
    }

    @AfterTest fun after() {
        com.lagradost.macos.worker.WorkerPool.resetForTest()
        ExtensionTestSupport.resetHome()
        app.cancel()
        WebViewSessions.transport = null
        WebViewSessionBridge.clearForTest()
    }

    class Bridge {
        val received = CopyOnWriteArrayList<String>()
        @JavascriptInterface fun deliver(value: String) { received += value }
        fun notExposed(value: String) { received += "leak:$value" }
    }

    @Test fun `a WebView loads, reports the page, evaluates scripts and receives interface calls`() {
        val view = WebView(null)
        val finished = CountDownLatch(1)
        val bridge = Bridge()
        view.addJavascriptInterface(bridge, "Bridge")
        view.setWebViewClient(object : WebViewClient() {
            override fun onPageFinished(view: WebView?, url: String?) { if (url == "https://site.example/page") finished.countDown() }
        })
        view.loadUrl("https://site.example/page")
        assertTrue(finished.await(10, TimeUnit.SECONDS), "onPageFinished arrived")

        val result = CountDownLatch(1)
        var value: String? = null
        var thread: Thread? = null
        view.evaluateJavascript("abc", ValueCallback { value = it; thread = Thread.currentThread(); result.countDown() })
        assertTrue(result.await(10, TimeUnit.SECONDS))
        assertEquals("\"cba\"", value, "the JSON-encoded result, as Android reports it")
        assertSame(android.os.Looper.getMainLooper().getThread(), thread, "callbacks run on the main looper")
        runBlocking { repeat(50) { if (bridge.received.isEmpty()) delay(100) } }
        assertEquals(listOf("token-42"), bridge.received, "only the registered @JavascriptInterface method is reached")

        view.destroy()
        runBlocking { repeat(50) { if (WebViewSessionBridge.sessionCount() > 0 || commands.none { it.op == "destroy" }) delay(100) } }
        assertEquals(0, WebViewSessionBridge.sessionCount())
        assertTrue(commands.any { it.op == "destroy" }, "the app is told to drop the view")
    }

    @Test fun `sessions belong to their installation and are bounded`() = runBlocking<Unit> {
        val id = java.util.UUID.randomUUID().toString()
        WebViewSessionBridge.handle("owner-a", WebViewRequest(id, "load", url = "https://a.example/"))
        assertFalse(WebViewSessionBridge.handle("owner-b", WebViewRequest(id, "eval", script = "1")).alive, "another installation cannot use it")
        assertFalse(WebViewSessionBridge.handle("owner-b", WebViewRequest(id, "load", url = "https://b.example/")).alive)
        repeat(WebViewSessionBridge.MAX_SESSIONS_PER_INSTALLATION - 1) {
            WebViewSessionBridge.handle("owner-a", WebViewRequest(java.util.UUID.randomUUID().toString(), "load", url = "https://a.example/"))
        }
        assertFalse(WebViewSessionBridge.handle("owner-a", WebViewRequest(java.util.UUID.randomUUID().toString(), "load", url = "https://a.example/")).alive)
        assertFailsWith<IllegalArgumentException> {
            WebViewSessionBridge.handle("owner-c", WebViewRequest(java.util.UUID.randomUUID().toString(), "load", url = "file:///etc/hosts"))
        }
        WebViewSessionBridge.release("owner-a")
        assertEquals(0, WebViewSessionBridge.sessionCount())
    }

    /** End to end: a Kotlin-compiled extension's WebView, in its own worker, served by the "app". */
    @Test fun `an extension's WebView runs through its worker, the engine and the app`() = runBlocking<Unit> {
        app.cancel() // this test's app answers for the fixture's page
        val served = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        served.launch {
            while (isActive) {
                for (command in PendingSignal.awaitNonEmpty(1_000) { WebViewSessionBridge.pending() }) when (command.op) {
                    "load" -> {
                        assertEquals(listOf("Decryptor"), command.interfaces)
                        WebViewSessionBridge.complete(WebViewResultDto(command.commandId))
                        WebViewSessionBridge.event(WebViewEventDto(command.session, WebViewEvent("call", name = "Decryptor", method = "deliver", args = listOf("decrypt.invalid"))))
                        WebViewSessionBridge.event(WebViewEventDto(command.session, WebViewEvent("finished", url = command.baseUrl)))
                    }
                    "eval" -> WebViewSessionBridge.complete(WebViewResultDto(command.commandId, result = "\"plain:" + command.script + "\""))
                    else -> WebViewSessionBridge.complete(WebViewResultDto(command.commandId))
                }
            }
        }
        try {
            WebViewSessions.transport = null // the worker carries its own transport
            val repo = SignedCatalogFixture("https://decrypt.invalid/repo.json")
            val fetcher = repo.publish(mapOf("AndroidWebView" to ExtensionTestSupport.extension("android-webview")), revision = 1)
            val manager = ExtensionTestSupport.use(InstallationManager(com.lagradost.macos.worker.WorkerExtensionRuntime(com.lagradost.macos.worker.WorkerLauncher(sandboxed = false)), fetcher))
            val record = manager.install(repo.url, "AndroidWebView")
            val provider = assertIs<com.lagradost.macos.worker.RemoteProvider>(PluginBridge.loadedInstallation(record.id)!!.providers.single())
            val result = ProviderExecutor.searchOne(provider, "x")
            assertNull(result.error, result.error)
            assertEquals("decrypt.invalid|\"plain:decrypt('x')\"", result.results.single().name)
            com.lagradost.macos.worker.WorkerPool.resetForTest()
            assertEquals(0, WebViewSessionBridge.sessionCount(), "its sessions end with the worker")
        } finally { served.cancel() }
    }

    @Test fun `without a host, evaluateJavascript fails by name instead of inventing a result`() {
        WebViewSessions.transport = null
        val failure = assertFailsWith<UnsupportedOperationException> { WebView(null).evaluateJavascript("1", null) }
        assertEquals(WebView.UNAVAILABLE, failure.message)
    }
}
