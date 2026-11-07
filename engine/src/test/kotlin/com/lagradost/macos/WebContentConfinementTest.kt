package com.lagradost.macos

import com.lagradost.macos.worker.WorkerEgressProxy
import kotlinx.coroutines.runBlocking
import okhttp3.ResponseBody.Companion.toResponseBody
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.*

/**
 * Security audit 2026-11: extension-driven WebKit content runs in the app,
 * outside the worker sandbox (H1), and the loopback listener must not answer
 * a DNS-rebinding page (L1) or let the connectivity test reach local hosts (L2).
 */
class WebContentConfinementTest {
    @Test fun `local destinations are recognised in every spelling browsers accept`() {
        val local = listOf(
            "http://localhost/", "http://LOCALHOST./", "http://api.localhost:8080/", "http://127.0.0.1:11434/api/tags",
            "http://2130706433/", "http://0x7f.1/", "http://0177.0.0.1/", "http://127.1/", "http://0.0.0.0/",
            "http://[::1]/", "http://[::ffff:127.0.0.1]/", "http://[0:0:0:0:0:0:0:1]/",
            "http://10.1.2.3/", "http://192.168.1.1/", "http://172.16.0.1/", "http://172.31.255.255/", "http://100.64.0.1/",
            "http://169.254.169.254/latest/meta-data/", "http://[fe80::1]/", "http://[fd00::1]/",
            "http://printer.local/", "http://nas.lan/", "http://db.internal/", "http://router.home.arpa/", "http://router/",
            "http://1.2.3.256/", "file:///etc/passwd", "not a url",
        )
        local.forEach { assertTrue(WebDestination.isLocal(it), "$it should be local") }
        val remote = listOf(
            "https://example.com/", "http://93.184.216.34/", "https://8.8.8.8/", "https://[2606:4700:4700::1111]/",
            "https://10.example.com/", "https://cdn.example.org:8443/x?y=1", "https://embed.invalid/e/1",
            // Only resolution can tell: the proxy decides those.
            "http://127.0.0.1.nip.io/",
        )
        remote.forEach { assertFalse(WebDestination.isLocal(it), "$it should not be local by spelling") }
    }

    @Test fun `IPv4 is parsed as browsers parse it`() {
        assertContentEquals(byteArrayOf(127, 0, 0, 1), WebDestination.ipv4("2130706433"))
        assertContentEquals(byteArrayOf(127, 0, 0, 1), WebDestination.ipv4("0x7f.1"))
        assertContentEquals(byteArrayOf(127, 0, 0, 1), WebDestination.ipv4("0177.0.0.1"))
        assertContentEquals(byteArrayOf(10, 0, 1, 2), WebDestination.ipv4("10.258"))
        assertNull(WebDestination.ipv4("256.0.0.1"))
        assertNull(WebDestination.ipv4("1.2.3.4.5"))
        assertNull(WebDestination.ipv4("4294967296"))
    }

    @Test fun `extension WebViews cannot open or take the origin of a local address`() = runBlocking<Unit> {
        val session = java.util.UUID.randomUUID().toString()
        assertFailsWith<IllegalArgumentException> {
            WebViewSessionBridge.handle("owner-local", WebViewRequest(session, "load", url = "http://127.0.0.1:11434/api/tags"))
        }
        assertFailsWith<IllegalArgumentException> {
            WebViewSessionBridge.handle("owner-local", WebViewRequest(session, "load", html = "<script>fetch('/')</script>",
                baseUrl = "http://169.254.169.254/"))
        }
        assertFalse(WebViewSessionBridge.handle("owner-local", WebViewRequest(session, "poll")).alive, "no session was created")
    }

    @Test fun `WebViewResolver pages and worker challenges cannot target local addresses`() = runBlocking<Unit> {
        assertFailsWith<IllegalArgumentException> {
            MediaResolveBridge.resolve(MediaResolveSpec(url = "http://192.168.1.1/admin", intercept = PatternSpec("x"), timeoutMs = 1_000))
        }
        assertTrue(MediaResolveBridge.pending().isEmpty(), "nothing was parked for the app")
        assertFailsWith<IllegalArgumentException> { SolveBridge.solveForWorker("https://localhost/") }
        assertTrue(SolveBridge.listPending().none { it.targetUrl == "https://localhost/" })
    }

    @Test fun `the web-content proxy refuses local destinations and is not the workers' proxy`() {
        val proxy = WorkerEgressProxy.webContent
        assertNotSame(WorkerEgressProxy.active, proxy)
        assertEquals("127.0.0.1", proxy.settings.host)
        assertTrue(proxy.settings.password.length >= 32)
        // Same address rule as the workers' proxy: public unicast only.
        assertFalse(RepositoryTransport.isPublicAddress(java.net.InetAddress.getByName("127.0.0.1")))
        assertFalse(RepositoryTransport.isPublicAddress(java.net.InetAddress.getByName("169.254.169.254")))
    }

    @Test fun `the app gets the web-content proxy only with the bearer token`() = RouteHarness().use<RouteHarness, Unit> { harness ->
        assertEquals(401, harness.get("/webview/egress", auth = false).status)
        val response = harness.get("/webview/egress")
        assertEquals(200, response.status)
        val body = response.json.jsonObject
        assertEquals(WorkerEgressProxy.webContent.port, body["port"]!!.jsonPrimitive.content.toInt())
        assertEquals("127.0.0.1", body["host"]!!.jsonPrimitive.content)
        assertNotNull(body["password"])
    }

    @Test fun `the listener answers loopback Host names only`() = RouteHarness().use<RouteHarness, Unit> { harness ->
        val port = harness.listeningPort
        assertEquals(200, harness.statusWithHost("/health", "127.0.0.1:$port", auth = false))
        assertEquals(200, harness.statusWithHost("/health", "localhost:$port", auth = false))
        assertEquals(200, harness.statusWithHost("/health", "[::1]:$port", auth = false))
        // A rebinding page sends its own name; even unauthenticated routes refuse it.
        assertEquals(403, harness.statusWithHost("/health", "attacker.example:$port", auth = false))
        assertEquals(403, harness.statusWithHost("/media/relay/${"a".repeat(64)}", "attacker.example:$port", auth = false))
        assertEquals(403, harness.statusWithHost("/providers", "127.0.0.1.attacker.example:$port"))
        assertEquals(403, harness.statusWithHost("/providers", "127.0.0.1:$port@attacker.example"))
    }

    @Test fun `Host values are matched exactly`() {
        assertTrue(LoopbackHost.allowed("127.0.0.1:1234"))
        assertTrue(LoopbackHost.allowed("LOCALHOST"))
        assertTrue(LoopbackHost.allowed("[::1]:80"))
        assertFalse(LoopbackHost.allowed(null))
        assertFalse(LoopbackHost.allowed(""))
        assertFalse(LoopbackHost.allowed("127.0.0.1:"))
        assertFalse(LoopbackHost.allowed("127.0.0.1:12a"))
        assertFalse(LoopbackHost.allowed("127.0.0.2:80"))
        assertFalse(LoopbackHost.allowed("localhost.:80"))
        assertFalse(LoopbackHost.allowed("[::1]x"))
    }

    @Test fun `the connectivity test never contacts a local site URL`() = runBlocking<Unit> {
        val contacted = java.util.concurrent.atomic.AtomicInteger()
        val recording = okhttp3.OkHttpClient.Builder().addInterceptor(okhttp3.Interceptor { chain ->
            contacted.incrementAndGet()
            okhttp3.Response.Builder().request(chain.request()).protocol(okhttp3.Protocol.HTTP_1_1).code(200).message("OK")
                .body("".toResponseBody(null)).build()
        }).build()
        val results = ConnectivityTester.test(listOf("A" to "http://127.0.0.1:11434/", "B" to "http://router/",
            "C" to "http://169.254.169.254/", "D" to "https://site.example/"), recording)
        assertEquals(setOf("D"), results.filter { it.reachable }.map { it.provider }.toSet())
        assertTrue(results.filter { it.provider != "D" }.all { it.error == "not a public address" })
        assertEquals(1, contacted.get(), "only the public site was contacted")
    }
}
