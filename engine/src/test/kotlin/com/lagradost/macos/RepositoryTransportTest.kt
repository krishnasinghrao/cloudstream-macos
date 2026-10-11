package com.lagradost.macos

import com.sun.net.httpserver.HttpsConfigurator
import com.sun.net.httpserver.HttpsServer
import kotlinx.coroutines.*
import okhttp3.OkHttpClient
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.nio.file.Files
import java.security.KeyStore
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.net.ssl.*
import kotlin.test.*

/** Real TLS sockets, headers and streaming bodies; no interceptor fabricates HTTP responses. */
class RepositoryTransportTest {
    private lateinit var server: HttpsServer
    private val executor = Executors.newFixedThreadPool(4)
    private lateinit var client: OkHttpClient
    private lateinit var transport: RepositoryTransport
    private val base get() = "https://localhost:${server.address.port}"

    @BeforeTest fun before() {
        server = HttpsServer.create(InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0)
        server.httpsConfigurator = HttpsConfigurator(tls.first)
        server.executor = executor
        server.start()
        client = OkHttpClient.Builder().sslSocketFactory(tls.first.socketFactory, tls.second).build()
        // Only this test instance allows local addresses; production rejects them.
        transport = RepositoryTransport(client) { it.isLoopbackAddress }
    }

    @AfterTest fun after() {
        transport.close()
        server.stop(0)
        executor.shutdownNow()
        client.dispatcher.executorService.shutdownNow()
        client.connectionPool.evictAll()
    }

    private fun body(path: String, value: String, chunked: Boolean = false, encoding: String? = null) {
        server.createContext(path) { exchange ->
            exchange.use {
                encoding?.let { exchange.responseHeaders.add("Content-Encoding", it) }
                val bytes = value.toByteArray()
                exchange.sendResponseHeaders(200, if (chunked) 0 else bytes.size.toLong())
                exchange.responseBody.write(bytes)
            }
        }
    }

    private fun redirect(path: String, location: String) {
        server.createContext(path) { exchange -> exchange.use {
            exchange.responseHeaders.add("Location", location)
            exchange.sendResponseHeaders(302, -1)
        } }
    }

    /** A shortcode resolves to its target even when the target refuses plain downloads (Codeberg raw returns 403). */
    @Test fun `resolve follows redirects to a target that refuses downloads`() = runBlocking<Unit> {
        redirect("/code", "/raw/repo.json")
        server.createContext("/raw/repo.json") { exchange -> exchange.use { exchange.sendResponseHeaders(403, -1) } }
        assertEquals("$base/raw/repo.json", transport.resolve("$base/code"))
        assertFailsWith<RemoteHttpException> { transport.fetch("$base/code", 1024) }
        redirect("/loop", "/loop2"); redirect("/loop2", "/loop")
        assertFailsWith<IOException> { transport.resolve("$base/loop") }
    }

    @Test fun `relative redirect returns final effective URL and body`() = runBlocking {
        redirect("/start", "/moved/repo.json")
        body("/moved/repo.json", "catalog")
        val result = transport.fetch("$base/start", 1024)
        assertEquals("$base/moved/repo.json", result.effectiveUrl)
        assertEquals("catalog", result.bytes.toString(Charsets.UTF_8))
    }

    @Test fun `redirect to HTTP is followed only over HTTPS and credentials are refused`() = runBlocking {
        body("/upgraded", "over tls")
        redirect("/http", "http://localhost:${server.address.port}/upgraded")
        val document = transport.fetch("$base/http", 100)
        assertEquals("over tls", document.bytes.decodeToString())
        assertEquals("$base/upgraded", document.effectiveUrl)
        redirect("/credentials", "https://user:password@localhost:${server.address.port}/secret")
        assertFailsWith<IllegalArgumentException> { transport.fetch("$base/credentials", 100) }
        Unit
    }

    @Test fun `redirect cycles and excess hops are bounded`() = runBlocking {
        redirect("/cycle", "/cycle")
        for (i in 0..6) redirect("/hop$i", "/hop${i + 1}")
        assertFailsWith<IllegalStateException> { transport.fetch("$base/cycle", 100) }
        assertFailsWith<IllegalStateException> { transport.fetch("$base/hop0", 100) }
        Unit
    }

    @Test fun `known and chunked lengths and unexpected compression are bounded`() = runBlocking {
        body("/known", "12345")
        body("/chunked", "12345", chunked = true)
        body("/gzip", "compressed", encoding = "gzip")
        for (path in listOf("known", "chunked", "gzip")) {
            assertFailsWith<IOException> { transport.fetch("$base/$path", 4) }
        }
        body("/exact", "1234")
        assertEquals(4, transport.fetch("$base/exact", 4).bytes.size)
    }

    @Test fun `non success status never becomes catalog bytes`() = runBlocking {
        server.createContext("/failure") { it.use { it.sendResponseHeaders(404, -1) } }
        assertFailsWith<IOException> { transport.fetch("$base/failure", 100) }
        Unit
    }

    @Test fun `production address policy rejects literals DNS and mixed answers before connection`() = runBlocking {
        val production = RepositoryTransport(client)
        assertFailsWith<IllegalArgumentException> { production.fetch("https://127.0.0.1:${server.address.port}/", 100) }
        assertFailsWith<IOException> { production.fetch(base, 100) }
        val mixed = RepositoryTransport(client.newBuilder().dns {
            listOf(InetAddress.getByName("8.8.8.8"), InetAddress.getByName("10.0.0.1"))
        }.build())
        assertFailsWith<IOException> { mixed.fetch("https://dns-fixture.invalid/", 100) }
        Unit
    }

    @Test fun `cancellation aborts a stalled response and releases its request`() = runBlocking {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        server.createContext("/slow") { exchange -> exchange.use {
            exchange.sendResponseHeaders(200, 0)
            exchange.responseBody.write(1)
            exchange.responseBody.flush()
            entered.countDown()
            release.await(5, TimeUnit.SECONDS)
        } }
        val job = launch(Dispatchers.Default) { transport.fetch("$base/slow", 1024) }
        try {
            assertTrue(withContext(Dispatchers.IO) { entered.await(3, TimeUnit.SECONDS) })
            withTimeout(1_000) { job.cancelAndJoin() }
            assertTrue(job.isCancelled)
        } finally { release.countDown() }
    }

    @Test fun `TLS certificate and hostname verification remain enabled`() = runBlocking {
        body("/tls", "ok")
        RepositoryTransport(OkHttpClient()) { it.isLoopbackAddress }.use { untrusted ->
            assertFailsWith<IOException> { untrusted.fetch("$base/tls", 100) }
        }
        RepositoryTransport(client.newBuilder().dns { listOf(InetAddress.getLoopbackAddress()) }.build()) { it.isLoopbackAddress }.use { wrongHost ->
            assertFailsWith<IOException> { wrongHost.fetch("https://wrong-host.invalid:${server.address.port}/tls", 100) }
        }
        Unit
    }

    @Test fun `global provider client mutation cannot alter repository HTTP`() = runBlocking {
        body("/independent", "trusted transport")
        val previous = com.lagradost.cloudstream3.app.baseClient
        try {
            com.lagradost.cloudstream3.app.baseClient = previous.newBuilder().addInterceptor { error("plugin client used") }.build()
            assertEquals("trusted transport", transport.fetch("$base/independent", 100).bytes.toString(Charsets.UTF_8))
        } finally { com.lagradost.cloudstream3.app.baseClient = previous }
    }

    @Test fun `origin clearance never follows a cross origin redirect`() = runBlocking {
        SolveBridge.applySolvedCookies("$base/start-cookie", "cf_clearance=private")
        redirect("/start-cookie", "https://127.0.0.1:${server.address.port}/other-cookie")
        val received = CompletableDeferred<String?>()
        server.createContext("/other-cookie") { exchange -> exchange.use {
            received.complete(exchange.requestHeaders.getFirst("Cookie"))
            exchange.sendResponseHeaders(200, 2)
            exchange.responseBody.write("ok".toByteArray())
        } }
        transport.fetch("$base/start-cookie", 100)
        assertNull(received.await())
    }

    @Test fun `reserved and transition addresses are rejected while normal public addresses pass`() {
        for (address in listOf("0.0.0.0", "127.0.0.1", "10.0.0.1", "172.16.0.1", "192.168.0.1", "100.64.0.1",
            "169.254.169.254", "198.18.0.1", "224.0.0.1", "::1", "fc00::1", "fe80::1", "2002:a00:1::1", "2001:db8::1", "3fff::1", "192.0.2.1", "192.88.99.1")) {
            assertFalse(RepositoryTransport.isPublicAddress(InetAddress.getByName(address)), address)
        }
        for (address in listOf("8.8.8.8", "1.1.1.1", "192.2.1.1", "2606:4700:4700::1111")) {
            assertTrue(RepositoryTransport.isPublicAddress(InetAddress.getByName(address)), address)
        }
    }

    companion object {
        internal val tls: Pair<SSLContext, X509TrustManager> by lazy {
            val directory = Files.createTempDirectory("repository-tls-test-").toFile()
            try {
                val storeFile = File(directory, "fixture.p12")
                val log = File(directory, "keytool.log")
                val process = ProcessBuilder(File(System.getProperty("java.home"), "bin/keytool").path,
                    "-genkeypair", "-alias", "fixture", "-keyalg", "RSA", "-keysize", "2048", "-validity", "1",
                    "-dname", "CN=localhost", "-ext", "SAN=dns:localhost,ip:127.0.0.1", "-storetype", "PKCS12",
                    "-keystore", storeFile.path, "-storepass", "fixture-password", "-noprompt")
                    .redirectErrorStream(true).redirectOutput(log).start()
                check(process.waitFor(20, TimeUnit.SECONDS)) { process.destroyForcibly(); "keytool timed out" }
                check(process.exitValue() == 0) { log.readText() }
                val store = KeyStore.getInstance("PKCS12").apply {
                    storeFile.inputStream().use { load(it, "fixture-password".toCharArray()) }
                }
                val keys = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).apply { init(store, "fixture-password".toCharArray()) }
                val trust = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply { init(store) }
                val manager = trust.trustManagers.filterIsInstance<X509TrustManager>().single()
                SSLContext.getInstance("TLS").apply { init(keys.keyManagers, arrayOf(manager), null) } to manager
            } finally { directory.deleteRecursively() }
        }
    }
}
