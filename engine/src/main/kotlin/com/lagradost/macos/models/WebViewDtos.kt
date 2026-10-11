package com.lagradost.macos.models

import kotlinx.serialization.Serializable

@Serializable
data class SolveCallbackRequestDto(
    val taskId: String,
    val targetUrl: String? = null,
    val cookies: String,
)

/** GET /solve/pending entry. */
@Serializable
data class SolvePendingDto(
    val taskId: String,
    val targetUrl: String,
    val ageMs: Long,
    /** The solver must present this User-Agent: clearance is bound to it. */
    val userAgent: String? = null,
)
