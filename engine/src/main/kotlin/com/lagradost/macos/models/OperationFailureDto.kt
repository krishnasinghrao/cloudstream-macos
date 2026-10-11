package com.lagradost.macos.models

import kotlinx.serialization.Serializable

/** IPC 5: safe diagnostics for one failed stage; never include URLs or provider data. */
@Serializable
data class OperationFailureDto(
    val code: String,
    val stage: String,
    val requestId: String,
    val publicMessage: String,
    val retryable: Boolean,
    val installationId: String? = null,
    val providerId: String? = null,
    val redactedCause: String? = null,
    val remoteStatus: Int? = null,
    val elapsedMs: Long = 0,
)
