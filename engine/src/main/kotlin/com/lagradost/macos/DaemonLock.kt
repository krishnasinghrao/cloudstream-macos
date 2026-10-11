package com.lagradost.macos

/**
 * SEC-08: Synchronizes daemon control plane with native application lock state.
 * When locked:
 * - In-memory clearance cookies in [SolveBridge] are purged.
 * - Incoming data and provider requests are rejected with 423 Locked, except
 *   [downloadPaths] and relay reads: downloads continue behind the lock.
 */
object DaemonLock {
    val downloadPaths = setOf("/links", "/links/verify/start", "/links/verify/stop", "/media/relay", "/media/relay/revoke")

    @Volatile
    var isLocked: Boolean = false
        private set

    fun setLocked(locked: Boolean) {
        isLocked = locked
        if (locked) {
            SolveBridge.clearCachedCookies()
            DaemonLog.info("app.locked", mapOf("action" to "purge_caches"))
        } else {
            DaemonLog.info("app.unlocked", emptyMap())
        }
    }

    /** Reset state for tests. */
    internal fun resetForTest() {
        isLocked = false
    }
}
