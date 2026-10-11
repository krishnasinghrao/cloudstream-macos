package com.lagradost.macos

import com.lagradost.macos.models.DiagnosticsDto
import com.lagradost.macos.models.EndpointStatDto
import com.lagradost.macos.models.ProviderStatDto
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/**
 * In-memory counters surfaced through `GET /diagnostics`. Nothing is exported;
 * observability is strictly local (SEC-03).
 */
object Metrics {
    data class ProviderStat(
        val success: AtomicLong = AtomicLong(0),
        val failure: AtomicLong = AtomicLong(0),
        val lastError: AtomicReference<String?> = AtomicReference(null),
        val lastLatencyMs: AtomicLong = AtomicLong(0),
    )

    private val endpointRequests = ConcurrentHashMap<String, AtomicLong>()
    private val providerStats = ConcurrentHashMap<String, ProviderStat>()
    private val solveTasksCreated = AtomicLong(0)
    private val solveTasksSolved = AtomicLong(0)
    private val requestsServedTotal = AtomicLong(0)

    fun recordRequest(endpoint: String) {
        requestsServedTotal.incrementAndGet()
        endpointRequests.getOrPut(endpoint) { AtomicLong(0) }.incrementAndGet()
    }

    fun recordProviderSuccess(provider: String, latencyMs: Long) {
        stat(provider).success.incrementAndGet()
        stat(provider).lastLatencyMs.set(latencyMs)
    }

    fun recordProviderFailure(provider: String, error: String) {
        stat(provider).failure.incrementAndGet()
        stat(provider).lastError.set(error.take(300))
    }

    fun recordSolveCreated() = solveTasksCreated.incrementAndGet()
    fun recordSolveSolved() = solveTasksSolved.incrementAndGet()

    private fun stat(provider: String) = providerStats.getOrPut(provider) { ProviderStat() }

    fun snapshot(): DiagnosticsDto = DiagnosticsDto(
        uptimeMs = System.currentTimeMillis() - startedAtMs,
        requestsServed = requestsServedTotal.get(),
        // Endpoint errors are a reserved wire field; only provider failures are counted.
        endpoints = endpointRequests.entries
            .map { EndpointStatDto(endpoint = it.key, requests = it.value.get(), errors = 0) }
            .sortedByDescending { it.requests },
        providers = providerStats.entries
            .map { (name, s) ->
                ProviderStatDto(
                    provider = name,
                    success = s.success.get(),
                    failure = s.failure.get(),
                    lastError = s.lastError.get(),
                    lastLatencyMs = s.lastLatencyMs.get(),
                )
            }
            .sortedBy { it.provider },
        solveTasksCreated = solveTasksCreated.get(),
        solveTasksSolved = solveTasksSolved.get(),
    )

    val startedAtMs: Long = System.currentTimeMillis()
}
