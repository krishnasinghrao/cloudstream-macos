package com.lagradost.macos.models

import kotlinx.serialization.Serializable

@Serializable
data class ResolverOptionDto(val id: String, val label: String)

@Serializable
data class NetworkSettingsDto(
    val dns: String = "system",
    val customDohUrl: String? = null,
    val httpCacheMb: Int = 50,
    val retryOnNetworkError: Boolean = true,
    /** Download GitHub-hosted repositories through jsDelivr (N2). Null in a request keeps the current value. */
    val githubMirror: Boolean? = null,
    /** Response only: selectable resolvers. */
    val resolvers: List<ResolverOptionDto> = emptyList(),
    /** Response only: bytes currently held by the HTTP cache. */
    val cacheSizeBytes: Long = 0,
)

/** POST /network/test — reachability of each enabled provider's site. */
@Serializable
data class ConnectivityTestRequestDto(
    /** Provider names; empty = every enabled provider. */
    val providers: List<String> = emptyList(),
)

@Serializable
data class ConnectivityResultDto(
    val provider: String,
    val url: String,
    val reachable: Boolean,
    val status: Int? = null,
    val latencyMs: Long? = null,
    val error: String? = null,
)
