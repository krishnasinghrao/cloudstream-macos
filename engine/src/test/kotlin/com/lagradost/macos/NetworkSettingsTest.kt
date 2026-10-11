package com.lagradost.macos

import com.lagradost.cloudstream3.app
import com.lagradost.macos.DaemonState.NetworkSettings
import com.lagradost.macos.network.DnsResolverFactory
import com.lagradost.macos.network.DohProvider
import com.lagradost.macos.network.FallbackDns
import com.lagradost.macos.network.RetryInterceptor
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import okhttp3.Dns
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import java.io.IOException
import java.net.InetAddress
import java.net.UnknownHostException
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Offline-Features-Plan Phase 3: resolver picker, HTTP cache, retries. */
class NetworkSettingsTest {

    @AfterTest
    fun restoreDefaults() {
        NetworkSetup.apply(NetworkSettings())
    }

    // ---- DohProvider

    @Test
    fun `every android resolver is available`() {
        val ids = DohProvider.entries.map { it.id }
        for (id in listOf("system", "google", "cloudflare", "adguard", "dnswatch", "quad9", "dnssb", "canadianshield", "custom")) {
            assertTrue(id in ids, "missing $id")
        }
        DohProvider.entries.filter { it.url != null }.forEach {
            assertTrue(it.url!!.startsWith("https://"))
            assertTrue(it.bootstrap.isNotEmpty(), "${it.id} needs bootstrap IPs")
        }
    }

    @Test
    fun `custom resolver url must be https`() {
        assertEquals("https://dns.example/dns-query", DohProvider.validateCustomUrl(" https://dns.example/dns-query "))
        assertNull(DohProvider.validateCustomUrl("http://dns.example/dns-query"))
        assertNull(DohProvider.validateCustomUrl("dns.example"))
        assertNull(DohProvider.validateCustomUrl(null))
    }

    @Test
    fun `system resolver builds no custom dns`() {
        assertNull(DnsResolverFactory.build(DohProvider.SYSTEM, null, OkHttpClient()))
        assertNull(DnsResolverFactory.build(DohProvider.CUSTOM, "not a url", OkHttpClient()))
        assertIs<FallbackDns>(DnsResolverFactory.build(DohProvider.CLOUDFLARE, null, OkHttpClient()))
    }

    @Test
    fun `fallback dns uses system only when primary cannot answer`() {
        val loopback = listOf(InetAddress.getLoopbackAddress())
        val fallback = Dns { loopback }
        val failing = FallbackDns(Dns { throw UnknownHostException("doh down") }, fallback)
        assertEquals(loopback, failing.lookup("example.com"))

        val primaryAnswer = listOf(InetAddress.getByAddress(byteArrayOf(10, 0, 0, 1)))
        val healthy = FallbackDns(Dns { primaryAnswer }, fallback)
        assertEquals(primaryAnswer, healthy.lookup("example.com"))
    }

    // ---- normalize / apply

    @Test
    fun `normalize clamps cache and maps unknown resolver to system`() {
        val normalized = NetworkSetup.normalize(NetworkSettings(dns = "bogus", httpCacheMb = 99_999))
        assertEquals("system", normalized.dns)
        assertEquals(NetworkSetup.MAX_CACHE_MB, normalized.httpCacheMb)
        assertEquals(0, NetworkSetup.normalize(NetworkSettings(httpCacheMb = -5)).httpCacheMb)
    }

    @Test
    fun `custom resolver without url is rejected`() {
        assertFailsWith<IllegalArgumentException> {
            NetworkSetup.normalize(NetworkSettings(dns = "custom", customDohUrl = "http://insecure"))
        }
    }

    @Test
    fun `re-applying settings never stacks interceptors`() {
        repeat(3) { NetworkSetup.apply(NetworkSettings(dns = "cloudflare")) }
        val interceptors = app.baseClient.interceptors
        assertEquals(1, interceptors.count { it is SolveInterceptor })
        assertEquals(1, interceptors.count { it is RetryInterceptor })

        NetworkSetup.apply(NetworkSettings(retryOnNetworkError = false, httpCacheMb = 0))
        assertEquals(0, app.baseClient.interceptors.count { it is RetryInterceptor })
        assertNull(app.baseClient.cache)
        assertEquals(Dns.SYSTEM, app.baseClient.dns)
    }

    @Test
    fun `resolver choice reaches the provider client`() {
        NetworkSetup.apply(NetworkSettings(dns = "quad9"))
        assertIs<FallbackDns>(app.baseClient.dns)
        assertEquals("quad9", NetworkSetup.current.dns)
    }

    @Test
    fun `legacy state without network block decodes with defaults`() {
        val json = Json { ignoreUnknownKeys = true }
        val state = json.decodeFromString(DaemonState.PersistedState.serializer(), """{"version":1,"repos":[]}""")
        assertEquals(NetworkSettings(), state.network)
    }

    // ---- RetryInterceptor

    private fun ok(request: Request) = Response.Builder()
        .request(request)
        .protocol(Protocol.HTTP_1_1)
        .code(200)
        .message("OK")
        .body("ok".toResponseBody())
        .build()

    private fun client(retry: RetryInterceptor, attempts: AtomicInteger, failures: Int) = OkHttpClient.Builder()
        .addInterceptor(retry)
        .addInterceptor(Interceptor { chain ->
            if (attempts.incrementAndGet() <= failures) throw IOException("connection reset")
            ok(chain.request())
        })
        .build()

    @Test
    fun `idempotent request is retried once after a transport error`() {
        val attempts = AtomicInteger()
        val sleeps = mutableListOf<Long>()
        val http = client(RetryInterceptor(sleeper = { sleeps += it }), attempts, failures = 1)
        http.newCall(Request.Builder().url("https://example.com").build()).execute().use {
            assertEquals(200, it.code)
        }
        assertEquals(2, attempts.get())
        assertEquals(1, sleeps.size)
        assertTrue(sleeps.single() in 300L..800L)
    }

    @Test
    fun `retry budget is bounded`() {
        val attempts = AtomicInteger()
        val http = client(RetryInterceptor(sleeper = {}), attempts, failures = 5)
        assertFailsWith<IOException> {
            http.newCall(Request.Builder().url("https://example.com").build()).execute()
        }
        assertEquals(2, attempts.get())
    }

    @Test
    fun `non idempotent requests are never retried`() {
        val attempts = AtomicInteger()
        val http = client(RetryInterceptor(sleeper = {}), attempts, failures = 1)
        val post = Request.Builder().url("https://example.com").post("x".toByteArray().toRequestBody()).build()
        assertFailsWith<IOException> { http.newCall(post).execute() }
        assertEquals(1, attempts.get())
    }

    // ---- Connectivity

    @Test
    fun `connectivity test reports unreachable hosts without throwing`() = runBlocking {
        val offline = OkHttpClient.Builder()
            .addInterceptor(Interceptor { throw UnknownHostException("blocked.example") })
            .build()
        val results = ConnectivityTester.test(listOf("A" to "https://blocked.example", "B" to "ftp://nope"), offline)
        assertEquals(2, results.size)
        assertFalse(results.any { it.reachable })
        assertTrue(results.first { it.provider == "B" }.error!!.contains("no site URL"))
    }

    @Test
    fun `any http answer counts as reachable`() = runBlocking {
        val blockedButUp = OkHttpClient.Builder()
            .addInterceptor(Interceptor { chain -> ok(chain.request()).newBuilder().code(403).build() })
            .build()
        val result = ConnectivityTester.test(listOf("A" to "https://site.example"), blockedButUp).single()
        assertTrue(result.reachable)
        assertEquals(403, result.status)
    }
}
