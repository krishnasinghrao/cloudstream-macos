package com.lagradost.macos.models

import kotlinx.serialization.Serializable

/** Versioned loopback IPC health, errors and application lock state. */
@Serializable
data class HealthDto(
    val status: String = "ok",
    val version: String = DAEMON_VERSION,
    val ipcVersion: Int = IPC_VERSION,
    val uptimeMs: Long,
    val providersLoaded: Int,
    val recoveryError: String? = null,
    val extensions: ExtensionHealthDto = ExtensionHealthDto(),
    val safeMode: Boolean = false,
    val policyManaged: Boolean = false,
    val isolation: IsolationHealthDto = IsolationHealthDto(),
    /**
     * Proof that this listener holds the launch token (audit M1): hex
     * HMAC-SHA256(token, "cloudstream-health-v1:" + nonce) for the client's
     * `X-CloudStream-Nonce`. The token itself is never sent to /health.
     */
    val proof: String? = null,
) {
    companion object {
        const val DAEMON_VERSION: String = "1.2.0"

        /** Bump on any breaking IPC change; the client checks this at connect. */
        const val IPC_VERSION: Int = 6
    }
}

/** How extension code is hosted (ADR-0016). */
@Serializable
data class IsolationHealthDto(
    /** `worker` or `in-process`. */
    val mode: String = "in-process",
    /** Workers run inside the macOS sandbox. */
    val sandboxed: Boolean = false,
    val runningWorkers: Int = 0,
)

/** Background extension restore progress (daemon serves requests before it finishes). */
@Serializable
data class ExtensionHealthDto(
    val phase: String = "idle",
    val restored: Int = 0,
    val failed: Int = 0,
    val quarantined: Int = 0,
)

@Serializable
data class ErrorResponseDto(
    val error: String,
    val detail: String? = null,
    val failure: OperationFailureDto? = null,
)

@Serializable
data class AppLockRequestDto(
    val locked: Boolean,
)

@Serializable
data class AppLockResponseDto(
    val locked: Boolean,
)
