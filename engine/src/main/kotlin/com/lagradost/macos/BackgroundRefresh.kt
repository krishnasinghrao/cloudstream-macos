package com.lagradost.macos

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay

/**
 * Periodic catalog refresh (plan T3.9). Repository sync is otherwise only
 * user-initiated, so without this job publisher revocations would not be seen
 * and automatic updates would never run. Each top-level repository is synced
 * without user attribution (policy still applies; discovered child repositories
 * refresh through their parent), then, when automatic updates are on, its
 * installations are updated one at a time. Never runs in safe mode or recovery.
 */
internal object BackgroundRefresh {
    const val INTERVAL_MS = 6 * 60 * 60 * 1000L
    const val INITIAL_DELAY_MS = 30_000L

    data class Result(val at: Long, val repositories: Int, val syncFailures: Int, val updated: List<String>, val updateFailures: List<String>)

    @Volatile var last: Result? = null
        private set

    suspend fun loop() {
        delay(INITIAL_DELAY_MS)
        while (true) {
            runCatching { runOnce() }.onFailure { failure ->
                if (failure is CancellationException) throw failure
                DaemonLog.warn("background_refresh.failed", mapOf("error" to failure.javaClass.simpleName))
            }
            delay(INTERVAL_MS)
        }
    }

    suspend fun runOnce(sync: suspend (String) -> Unit = { RepositoryService.sync(it, userInitiated = false) }): Result? {
        if (DaemonRuntime.safeMode || DaemonState.recoveryError != null) return null
        val urls = DaemonState.snapshot().repos.filter { it.discoveredVia == null }.map { it.url }
        var syncFailures = 0
        for (url in urls) {
            try { sync(url) } catch (failure: Exception) {
                if (failure is CancellationException) throw failure
                syncFailures++ // recorded on the repository by sync itself
            }
        }
        val updated = mutableListOf<String>()
        val failed = mutableListOf<String>()
        if (effectiveSettings().autoUpdate) {
            for (result in RepositoryService.installations.updateAll(actor = InstallationManager.AUTO_UPDATE_ACTOR)) {
                if (result.error == null) updated += result.name else failed += result.name
            }
        }
        return Result(System.currentTimeMillis(), urls.size, syncFailures, updated, failed).also {
            last = it
            DaemonLog.info("background_refresh.done", mapOf("repositories" to it.repositories, "syncFailures" to syncFailures,
                "updated" to updated.size, "updateFailures" to failed.size))
        }
    }

    /** Tests only. */
    internal fun resetForTest() { last = null }
}
