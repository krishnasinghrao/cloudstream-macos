package com.lagradost.macos

import com.lagradost.cloudstream3.MainAPI
import com.lagradost.cloudstream3.SearchResponse
import com.lagradost.cloudstream3.plugins.BasePlugin
import kotlinx.coroutines.*
import kotlin.test.*

class SearchStreamRouteTest {
    private val installation = "d".repeat(64)

    @BeforeTest fun before() = ExtensionTestSupport.resetHome()
    @AfterTest fun after() = ExtensionTestSupport.resetHome()

    @Test fun `stream emits a fast result and disconnect cancels unfinished provider work`() = runBlocking<Unit> {
        val entered = CompletableDeferred<Unit>()
        val cancelled = CompletableDeferred<Unit>()
        val gate = CompletableDeferred<Unit>()
        val slow = object : MainAPI() {
            override var name = "RouteSlow"
            override suspend fun search(query: String): List<SearchResponse> {
                entered.complete(Unit)
                try { gate.await(); return emptyList() } finally { cancelled.complete(Unit) }
            }
        }
        val fast = object : MainAPI() {
            override var name = "RouteFast"
            override suspend fun search(query: String): List<SearchResponse> {
                entered.await()
                return emptyList()
            }
        }
        PluginBridge.publish(PluginBridge.LoadedPlugin(installation, "search-route", "e".repeat(64), null,
            object : BasePlugin() {}, listOf(slow, fast), emptyList(), emptyList(), emptyList()))
        RouteHarness().use { routes ->
            val socket = withContext(Dispatchers.IO) { routes.streamSocket("/search/stream?q=fixture&plugins=RouteFast,RouteSlow") }
            try {
                val line = withContext(Dispatchers.IO) {
                    val reader = socket.getInputStream().bufferedReader()
                    var line: String
                    do { line = reader.readLine() ?: error("Stream closed before the first provider result") }
                    while (!line.contains("provider_result"))
                    line
                }
                assertTrue(line.contains("RouteFast"))
                assertFalse(cancelled.isCompleted, "Progressive output does not wait for the slow provider")
                socket.setSoLinger(true, 0)
                socket.close()
                withTimeout(3_000) { cancelled.await() }
            } finally {
                socket.close()
                gate.complete(Unit)
            }
        }
    }
}
