package com.lagradost.macos.models

import kotlinx.serialization.Serializable

@Serializable
data class EndpointStatDto(
    val endpoint: String,
    val requests: Long,
    val errors: Long,
)

@Serializable
data class ProviderStatDto(
    val provider: String,
    val success: Long,
    val failure: Long,
    val lastError: String? = null,
    val lastLatencyMs: Long = 0,
)

/** GET /diagnostics response (authenticated; local-only observability). */
@Serializable
data class DiagnosticsDto(
    val uptimeMs: Long,
    val requestsServed: Long,
    val endpoints: List<EndpointStatDto> = emptyList(),
    val providers: List<ProviderStatDto> = emptyList(),
    val solveTasksCreated: Long = 0,
    val solveTasksSolved: Long = 0,
)

@Serializable
data class ProviderTestRequestDto(
    /** Provider names; empty = every enabled provider. */
    val providers: List<String> = emptyList(),
    val query: String? = null,
)

@Serializable
data class ProviderTestStepDto(
    /** "homepage" | "search" | "details" | "links" */
    val name: String,
    val ok: Boolean,
    val latencyMs: Long? = null,
    val detail: String? = null,
)

@Serializable
data class ProviderTestResultDto(
    val provider: String,
    /** "pass" | "partial" | "fail" */
    val status: String,
    val steps: List<ProviderTestStepDto> = emptyList(),
)

/** One NDJSON line of POST /test/run. */
@Serializable
data class ProviderTestEventDto(
    /** "result" | "done" */
    val type: String,
    val result: ProviderTestResultDto? = null,
    val total: Int? = null,
)
