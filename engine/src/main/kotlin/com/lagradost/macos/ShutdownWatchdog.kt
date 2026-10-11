package com.lagradost.macos

/**
 * Bounds engine shutdown. JVM shutdown hooks run with no time limit, and a
 * hook that never returns (observed: the HTTP server's own hook when SIGTERM
 * arrives while it is still starting) would leave an orphaned engine holding
 * its data-root lock and port. Once shutdown begins, the process ends after
 * [graceMs] whatever the other hooks are doing. Workers end with it: their
 * pipes close.
 */
internal object ShutdownWatchdog {
    const val DEFAULT_GRACE_MS = 10_000L

    fun install(graceMs: Long = DEFAULT_GRACE_MS, halt: () -> Unit = { Runtime.getRuntime().halt(0) }) {
        Runtime.getRuntime().addShutdownHook(Thread({ arm(graceMs, halt) }, "shutdown-watchdog-arm"))
    }

    /** Starts the countdown; returns immediately so this hook never delays a clean shutdown. */
    internal fun arm(graceMs: Long, halt: () -> Unit): Thread = Thread({
        try { Thread.sleep(graceMs) } catch (_: InterruptedException) { return@Thread }
        halt()
    }, "shutdown-watchdog").apply { isDaemon = true; start() }
}
