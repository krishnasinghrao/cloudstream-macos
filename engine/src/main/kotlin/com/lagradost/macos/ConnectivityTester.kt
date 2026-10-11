package com.lagradost.macos

import com.lagradost.cloudstream3.app
import com.lagradost.macos.models.ConnectivityResultDto
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.TimeUnit

/**
 * "Test Connection" (Settings ▸ Network): resolves and fetches each
 * provider's site through the configured stack (DoH resolver included), so
 * the user can tell a blocked site from a broken plugin. Any HTTP answer —
 * even 403/503 — counts as reachable: the host resolved and responded.
 */
object ConnectivityTester {
    private const val TIMEOUT_SECONDS = 8L
    private const val PARALLELISM = 6

    suspend fun test(targets: List<Pair<String, String>>, client: OkHttpClient = app.baseClient): List<ConnectivityResultDto> {
        val probe = client.newBuilder()
            .callTimeout(TIMEOUT_SECONDS, TimeUnit.SECONDS)
            // No cached answers: this measures the network, not the disk.
            .cache(null)
            .build()
        val permits = Semaphore(PARALLELISM)
        return coroutineScope {
            targets.map { (provider, url) ->
                async(Dispatchers.IO) { permits.withPermit { probeOne(probe, provider, url) } }
            }.awaitAll()
        }.sortedWith(compareBy({ !it.reachable }, { it.latencyMs ?: Long.MAX_VALUE }))
    }

    private suspend fun probeOne(client: OkHttpClient, provider: String, url: String): ConnectivityResultDto =
        withContext(Dispatchers.IO) {
            if (!(url.startsWith("https://", true) || url.startsWith("http://", true))) {
                return@withContext ConnectivityResultDto(provider, url, reachable = false, error = "no site URL")
            }
            val start = System.nanoTime()
            try {
                val request = Request.Builder().url(url).get().header("Range", "bytes=0-0").build()
                client.newCall(request).execute().use { response ->
                    ConnectivityResultDto(
                        provider = provider,
                        url = url,
                        reachable = true,
                        status = response.code,
                        latencyMs = (System.nanoTime() - start) / 1_000_000,
                    )
                }
            } catch (e: Exception) {
                ConnectivityResultDto(
                    provider = provider,
                    url = url,
                    reachable = false,
                    latencyMs = (System.nanoTime() - start) / 1_000_000,
                    error = e.javaClass.simpleName + (e.message?.let { ": " + it.take(160) } ?: ""),
                )
            }
        }
}
