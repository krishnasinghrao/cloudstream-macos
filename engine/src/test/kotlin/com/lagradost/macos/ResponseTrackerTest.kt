package com.lagradost.macos

import com.lagradost.cloudstream3.UnsafeSSL
import com.lagradost.macos.network.ResponseTracker
import com.sun.net.httpserver.HttpServer
import kotlinx.coroutines.runBlocking
import okhttp3.ConnectionPool
import okhttp3.OkHttpClient
import okhttp3.Request
import java.net.InetAddress
import java.net.InetSocketAddress
import java.util.concurrent.TimeUnit
import kotlin.test.*

/** Response bodies an extension never closes are reclaimed once no operation is running (Remediation 5.1). */
class ResponseTrackerTest {
    private lateinit var server: HttpServer
    private val pool = ConnectionPool(5, 30, TimeUnit.SECONDS)
    private val client = OkHttpClient.Builder().addInterceptor(ResponseTracker.interceptor).connectionPool(pool).build()

    @BeforeTest fun before() {
        ResponseTracker.resetForTest()
        server = HttpServer.create(InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0)
        server.createContext("/big") { exchange ->
            val body = ByteArray(512 * 1024) { 1 }
            exchange.sendResponseHeaders(200, body.size.toLong())
            runCatching { exchange.responseBody.use { it.write(body) } }
        }
        server.createContext("/small") { exchange ->
            exchange.sendResponseHeaders(200, 2); exchange.responseBody.use { it.write("ok".toByteArray()) }
        }
        server.start()
    }

    @AfterTest fun after() {
        ResponseTracker.resetForTest()
        server.stop(0)
        pool.evictAll()
    }

    private fun url(path: String) = "http://127.0.0.1:${server.address.port}$path"

    @Test fun `a body dropped by an extension is closed when its operation ends`() = runBlocking<Unit> {
        ResponseTracker.operation {
            val response = client.newCall(Request.Builder().url(url("/big")).build()).execute()
            assertEquals(200, response.code) // Headers read; the body is never consumed or closed.
            assertEquals(1, ResponseTracker.openBodies)
        }
        assertEquals(0, ResponseTracker.openBodies)
        assertEquals(1, ResponseTracker.reclaimed.get())
    }

    @Test fun `bodies that are read or closed are not tracked, and overlapping operations keep theirs`() = runBlocking<Unit> {
        ResponseTracker.operationStarted()
        assertEquals("ok", client.newCall(Request.Builder().url(url("/small")).build()).execute().body.string())
        client.newCall(Request.Builder().url(url("/big")).build()).execute().close()
        assertEquals(0, ResponseTracker.openBodies, "consumed and closed bodies untrack themselves")
        val held = client.newCall(Request.Builder().url(url("/big")).build()).execute()
        ResponseTracker.operationStarted() // A second, overlapping operation.
        ResponseTracker.operationFinished()
        assertEquals(1, ResponseTracker.openBodies, "a body may belong to the operation still running")
        assertEquals(512 * 1024, held.body.bytes().size, "and stays readable")
        ResponseTracker.operationFinished()
        assertEquals(0, ResponseTracker.reclaimed.get())
    }

    @OptIn(UnsafeSSL::class)
    @Test fun `the engine's provider clients carry the tracker and a short-lived shared pool`() {
        NetworkSetup.apply(DaemonState.NetworkSettings(httpCacheMb = 0))
        for (built in listOf(com.lagradost.cloudstream3.app.baseClient, com.lagradost.cloudstream3.insecureApp.baseClient)) {
            assertSame(ResponseTracker.interceptor, built.interceptors.first())
            assertSame(NetworkSetup.connectionPool, built.connectionPool)
        }
        NetworkSetup.apply(DaemonState.NetworkSettings(httpCacheMb = 0))
        assertEquals(1, com.lagradost.cloudstream3.app.baseClient.interceptors.count { it === ResponseTracker.interceptor },
            "re-applying settings never stacks the tracker")
    }
}
