package com.lagradost.macos

import com.sun.net.httpserver.HttpsConfigurator
import com.sun.net.httpserver.HttpsServer
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.OkHttpClient
import okhttp3.Request
import java.net.InetAddress
import java.net.InetSocketAddress
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.*

/**
 * Plan T4.6 / N09: a Cloudflare-style challenge is parked for the app's WebKit
 * solver and the request is retried with the clearance cookie — in-process,
 * and from a worker through the engine (ADR-0016).
 */
class ChallengePathTest {
    private lateinit var server: HttpsServer
    private val executor = Executors.newFixedThreadPool(4)
    private val challenged = AtomicInteger()
    private lateinit var client: OkHttpClient
    private val url get() = "https://localhost:${server.address.port}/page"

    @BeforeTest fun before() {
        server = HttpsServer.create(InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0)
        server.httpsConfigurator = HttpsConfigurator(RepositoryTransportTest.tls.first)
        server.executor = executor
        server.createContext("/page") { exchange ->
            val cleared = exchange.requestHeaders.getFirst("Cookie")?.contains("cf_clearance=ok") == true
            val body = (if (cleared) "real content" else "<title>Just a moment...</title><script>cf_chl_opt</script>").toByteArray()
            if (!cleared) { challenged.incrementAndGet(); exchange.responseHeaders.add("Server", "cloudflare") }
            exchange.sendResponseHeaders(if (cleared) 200 else 503, body.size.toLong())
            exchange.responseBody.use { it.write(body) }
        }
        server.createContext("/stubborn") { exchange ->
            // Challenges even with a clearance (as a site that also checks the TLS fingerprint does).
            challenged.incrementAndGet()
            val body = "<title>Just a moment...</title><script>cf_chl_opt</script>".toByteArray()
            exchange.responseHeaders.add("Server", "cloudflare")
            exchange.sendResponseHeaders(503, body.size.toLong())
            exchange.responseBody.use { it.write(body) }
        }
        server.start()
        client = OkHttpClient.Builder()
            .sslSocketFactory(RepositoryTransportTest.tls.first.socketFactory, RepositoryTransportTest.tls.second)
            .addInterceptor(SolveInterceptor()).build()
    }

    @AfterTest fun after() {
        SolveBridge.remoteSolver = null
        SolveBridge.clearCachedCookies()
        server.stop(0)
        executor.shutdownNow()
    }

    private fun fetch(): Pair<Int, String> = client.newCall(Request.Builder().url(url).build()).execute().use { it.code to it.body.string() }

    @Test fun `in-process challenge is parked for the app solver and retried with its cookie`() = runBlocking<Unit> {
        val request = async(kotlinx.coroutines.Dispatchers.IO) { fetch() }
        // The app polls /solve/pending (started before bootstrap) and completes the task.
        val task = withTimeout(10_000) {
            while (true) { SolveBridge.listPending().firstOrNull { it.targetUrl == url }?.let { return@withTimeout it }; delay(20) }
            @Suppress("UNREACHABLE_CODE") error("unreachable")
        }
        assertTrue(SolveBridge.complete(task.taskId, url, "cf_clearance=ok"))
        assertEquals(200 to "real content", request.await())
        assertEquals(1, challenged.get())
    }

    @Test fun `a site that rejects a fresh clearance is not solved again for a while`() = runBlocking<Unit> {
        val stubborn = "https://localhost:${server.address.port}/stubborn"
        var solves = 0
        SolveBridge.remoteSolver = { _, _ -> solves++; "cf_clearance=ok" }
        fun get() = client.newCall(Request.Builder().url(stubborn).build()).execute().use { it.code }
        assertEquals(503, get())
        assertEquals(1, solves, "solved once, retried, still challenged")
        assertTrue(SolveBridge.clearanceRejected(stubborn))
        repeat(3) { assertEquals(503, get()) }
        assertEquals(1, solves, "no further solves while the site rejects clearance")
    }

    @Test fun `a worker's challenge crosses to the engine and only the requester gets the cookie`() = runBlocking<Unit> {
        // Worker side: the interceptor forwards to the engine instead of parking locally.
        val forwarded = mutableListOf<String>()
        val agents = mutableListOf<String?>()
        SolveBridge.remoteSolver = { target, agent -> forwarded += target; agents += agent; "cf_clearance=ok" }
        assertEquals(200 to "real content", fetch())
        assertEquals(listOf(url), forwarded)
        assertNotNull(agents.single(), "the challenged request's User-Agent travels with it: clearance is bound to it")
        assertTrue(SolveBridge.listPending().none { it.targetUrl == url }, "the worker never parks locally")

        // Engine side: the worker's request appears in the queue the app polls; the answer returns to it.
        SolveBridge.remoteSolver = null
        val target = "https://challenge-worker.invalid/x"
        val answer = async(kotlinx.coroutines.Dispatchers.IO) { SolveBridge.solveForWorker(target, "Agent/1") }
        val task = withTimeout(10_000) {
            while (true) { SolveBridge.listPending().firstOrNull { it.targetUrl == target }?.let { return@withTimeout it }; delay(20) }
            @Suppress("UNREACHABLE_CODE") error("unreachable")
        }
        assertEquals("Agent/1", task.userAgent, "the app's solver is told which User-Agent to present")
        assertTrue(SolveBridge.complete(task.taskId, target, "cf_clearance=w"))
        assertEquals("cf_clearance=w", answer.await())
    }

    @Test fun `an authenticated challenged request keeps its session cookie and gains clearance`() = runBlocking<Unit> {
        val seen = java.util.concurrent.CopyOnWriteArrayList<String>()
        server.createContext("/account") { exchange ->
            val cookie = exchange.requestHeaders.getFirst("Cookie").orEmpty()
            seen += cookie
            val cleared = "cf_clearance=ok" in cookie
            val body = (if (cleared) "account" else "<title>Just a moment...</title><script>cf_chl_opt</script>").toByteArray()
            if (!cleared) exchange.responseHeaders.add("Server", "cloudflare")
            exchange.sendResponseHeaders(if (cleared) 200 else 503, body.size.toLong())
            exchange.responseBody.use { it.write(body) }
        }
        val account = "https://localhost:${server.address.port}/account"
        fun fetchAccount(cookie: String) = client.newCall(Request.Builder().url(account).header("Cookie", cookie).build())
            .execute().use { it.code to it.body.string() }
        SolveBridge.remoteSolver = { _, _ -> "cf_clearance=ok; __cf_bm=fresh" }
        assertEquals(200 to "account", fetchAccount("session=login; cf_clearance=stale; theme=dark"))
        assertEquals("session=login; cf_clearance=ok; theme=dark; __cf_bm=fresh", seen.last(),
            "login cookies survive the retry; only solver cookies are replaced")

        // A later authenticated request receives cached clearance without losing or overriding its own cookies.
        seen.clear()
        assertEquals(200 to "account", fetchAccount("session=other"))
        assertEquals(listOf("session=other; cf_clearance=ok; __cf_bm=fresh"), seen.toList())

        // Clearance is cached for this origin only, and never carries the login cookie.
        assertNull(SolveBridge.cookieHeaderFor("https://other.invalid/account"))
        assertFalse(SolveBridge.cookieHeaderFor(account)!!.contains("session"))
    }

    @Test fun `cookie merge is by name and rejected clearance is not sent`() = runBlocking<Unit> {
        assertEquals("a=1; b=9; c=3", SolveInterceptor.mergeCookies("a=1; b=2", "b=9; c=3", overlayWins = true))
        assertEquals("a=1; b=2; c=3", SolveInterceptor.mergeCookies("a=1; b=2", "b=9; c=3", overlayWins = false))
        assertEquals("b=9", SolveInterceptor.mergeCookies(null, "b=9", overlayWins = true))
        assertEquals("flag; a=1; b=9", SolveInterceptor.mergeCookies("flag; a=1; a=dup", "b=9", overlayWins = true))
        // A solver answer with control bytes is neither cached nor retried with.
        SolveBridge.remoteSolver = { _, _ -> "cf_clearance=ok\r\nX-Injected: 1" }
        assertEquals(503, fetch().first)
        assertNull(SolveBridge.cookieHeaderFor(url))
    }

    @Test fun `Android CloudflareKiller class resolves challenges and exposes saved headers`() {
        val killer = com.lagradost.cloudstream3.network.CloudflareKiller()
        val builder = client.newBuilder()
        builder.interceptors().clear()
        client = builder.addInterceptor(killer).build()
        SolveBridge.remoteSolver = { _, _ -> "cf_clearance=ok" }
        assertEquals(200 to "real content", fetch())
        assertEquals(1, challenged.get())
        assertEquals("ok", killer.savedCookies["localhost"]?.get("cf_clearance"))
        assertEquals("cf_clearance=ok", killer.getCookieHeaders(url)["Cookie"])
        assertEquals(200 to "real content", fetch())
        assertEquals(1, challenged.get())
    }

    @Test fun `clearance cookie headers tolerate empty parts but need one valid pair`() {
        assertTrue(SolveBridge.validCookieHeader("cf_clearance=ok;"))
        assertTrue(SolveBridge.validCookieHeader("cf_clearance=ok; ; __cf_bm=x"))
        assertFalse(SolveBridge.validCookieHeader(";"))
        assertFalse(SolveBridge.validCookieHeader("cf_clearance"))
        assertFalse(SolveBridge.validCookieHeader("bad name=x"))
    }
}
