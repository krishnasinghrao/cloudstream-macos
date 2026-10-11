package com.lagradost.macos.worker

import java.io.File

/**
 * Builds the command line for one extension's worker JVM (ADR-0016): the same
 * runtime and classpath as the control plane, a bounded heap, and — when the
 * macOS sandbox is available — a deny-by-default profile that confines the
 * worker to its own home directory and one verified artifact.
 */
internal class WorkerLauncher(
    private val java: String = File(System.getProperty("java.home"), "bin/java").path,
    private val classpath: String = System.getProperty("java.class.path"),
    private val runtimeRoot: String = System.getProperty("java.home"),
    val sandboxed: Boolean = SANDBOX_AVAILABLE,
    private val heapMb: Int = DEFAULT_HEAP_MB,
    /** Extra paths the worker may read (tests put build output here). */
    private val extraReadPaths: List<String> = emptyList(),
    /** The loopback port of the engine's egress proxy, the worker's only network destination. */
    private val egressPort: () -> Int = { WorkerEgressProxy.active.port },
) {
    /** [heapMb] overrides the launcher's cap for one start (an extension that ran out of memory, W2). */
    fun command(workerHome: File, artifact: File, heapMb: Int = this.heapMb): List<String> {
        val home = canonical(workerHome.path)
        val jvm = buildList {
            add(canonical(java))
            // Start small and give freed heap back: an idle worker should cost
            // little, while a busy one may still grow to its cap.
            add("-Xms16m")
            add("-Xmx${heapMb}m")
            add("-XX:MinHeapFreeRatio=10")
            add("-XX:MaxHeapFreeRatio=30")
            add("-Xss512k")
            add("-XX:+UseSerialGC")
            add("-XX:TieredStopAtLevel=1")
            add("-XX:+ExitOnOutOfMemoryError")
            add("-XX:ActiveProcessorCount=2")
            add("-XX:-UsePerfData")
            // stdout carries the frame protocol: JVM warnings (e.g. an archive
            // that fails to map) must go to stderr, never corrupt a frame.
            add("-Xlog:disable")
            add("-Xlog:all=warning:stderr")
            // The same module options as the engine: workers map its AppCDS
            // archive, which was recorded with them.
            parentArguments().filter { it.startsWith("--add-modules=") || it.startsWith("--enable-native-access=") }.forEach(::add)
            // The packaging gate runs the engine with -Xshare:on so that an
            // archive a worker cannot map fails the build instead of being skipped.
            sharedArchive()?.let { add("-XX:SharedArchiveFile=$it"); add(if (parentArguments().contains("-Xshare:on")) "-Xshare:on" else "-Xshare:auto") }
            add("-XX:ErrorFile=$home/tmp/hs_err_pid%p.log")
            add("-Djava.awt.headless=true")
            // Extension traffic goes only through the engine's egress proxy
            // (installed at INIT), which connects to public addresses directly.
            add("-Djava.io.tmpdir=$home/tmp")
            add("-Dcs.cloudstream.home=$home")
            add("-cp")
            // Relative entries stay relative: JDK 17 matches an AppCDS archive
            // against the class path as written, so the packaged app records
            // and runs it as `tools/daemon.jar` from Contents/Resources, which
            // keeps the archive valid wherever the app is copied (see
            // [workingDirectory]).
            add(classpathEntries().joinToString(File.pathSeparator) { if (File(it).isAbsolute) canonical(it) else it })
            add("com.lagradost.macos.MainKt")
            add("--worker")
        }
        if (!sandboxed) {
            if (com.lagradost.macos.DaemonRuntime.policy.requireSandbox) {
                throw SecurityException("Sandbox is required by policy but macOS sandbox-exec is not available")
            }
            com.lagradost.macos.DaemonLog.warn("worker.unsandboxed", mapOf("home" to home, "artifact" to artifact.name))
            return jvm
        }
        return listOf(SANDBOX_EXEC, "-p", profile(home, canonical(artifact.path))) + jvm
    }

    /**
     * The worker's current directory: the engine's own when the class path is
     * relative (the packaged app), so the entries resolve to the same jar;
     * otherwise the worker's home.
     */
    fun workingDirectory(workerHome: File): File =
        if (classpathEntries().any { !File(it).isAbsolute }) File(System.getProperty("user.dir")).absoluteFile else workerHome

    private fun classpathEntries(): List<String> = classpath.split(File.pathSeparator).filter { it.isNotBlank() }

    /**
     * The worker's complete environment (H1). Nothing is inherited from the
     * engine: no `SSH_AUTH_SOCK`, agent sockets, credentials, `CS_DAEMON_*`
     * launch values or `JAVA_TOOL_OPTIONS`. `HOME` and `TMPDIR` point into the
     * worker's own sandboxed home.
     */
    fun environment(workerHome: File): Map<String, String> = isolatedEnvironment(canonical(workerHome.path))

    /**
     * Deny-by-default SBPL for one worker. Paths are embedded as literals.
     *
     * Rules later in a profile take precedence, and the imported `system.sb`
     * grants every `sysctl-read`, so the narrowing below comes after the
     * import (H1, M2):
     * - sysctl: only hardware, CPU and OS-version names the JVM needs; never
     *   `kern.proc*` / `kern.procargs*`, which expose other processes' command
     *   lines (ffmpeg headers, other apps' secrets).
     * - process-info: the worker's own process only.
     * - file metadata: only the paths it may read and their ancestor
     *   directories, so it cannot probe whether arbitrary files exist.
     * - network: TCP/UDP to remote hosts only. Loopback and every Unix-domain
     *   socket (Docker, ssh-agent, 1Password, gpg-agent) are refused, except
     *   mDNSResponder, which name resolution needs. `remote ip` is deliberately
     *   not used: it overrides the protocol-specific loopback deny.
     * SBPL cannot express LAN ranges; LAN hosts stay reachable as on Android.
     */
    internal fun profile(home: String, artifact: String): String {
        val archive = sharedArchive()?.let { listOf(canonical(it)) }.orEmpty()
        val reads = (listOf(canonical(runtimeRoot)) + classpathEntries().map { canonical(it) } +
            extraReadPaths.map { canonical(it) } + archive).distinct()
        val workingDirectory = if (classpathEntries().any { !File(it).isAbsolute }) canonical(System.getProperty("user.dir")) else null
        val metadata = metadataPaths(reads + listOfNotNull(home, artifact, workingDirectory, canonical(java)))
        return buildString {
            appendLine("(version 1)")
            appendLine("(deny default)")
            appendLine("(import \"system.sb\")")
            appendLine("(allow process-exec (literal ${quote(canonical(java))}))")
            appendLine("(allow file-read* ${reads.joinToString(" ") { "(subpath ${quote(it)})" }} (literal ${quote(artifact)}))")
            appendLine("(allow file-read* file-write* (subpath ${quote(home)}))")
            // The JVM resolves its working directory at startup; a packaged
            // worker runs in the engine's (Contents/Resources). Only that
            // directory entry is readable, not what is in it.
            if (workingDirectory != null) {
                appendLine("(allow file-read* (literal ${quote(workingDirectory)}))")
            }
            appendLine("""(allow file-read*
    (subpath "/private/etc") (subpath "/private/var/db/timezone") (subpath "/usr/share/zoneinfo")
    (subpath "/System/Library/Security") (literal "/Library/Preferences/com.apple.security.plist")
    (literal "/dev/urandom") (literal "/dev/random") (literal "/dev/null") (literal "/dev/dtracehelper")
    (literal "/private/var/run/resolv.conf"))""")
            appendLine("(allow file-read-metadata ${metadata.joinToString(" ") { "(literal ${quote(it)})" }})")
            appendLine("(deny sysctl-read)")
            appendLine("(allow sysctl-read ${SYSCTL_PREFIXES.joinToString(" ") { "(sysctl-name-prefix ${quote(it)})" }}")
            appendLine("    (sysctl-name ${SYSCTL_NAMES.joinToString(" ") { quote(it) }}))")
            appendLine("(deny process-info*)")
            appendLine("(allow process-info* (target self))")
            appendLine("""(allow mach-lookup
    (global-name "com.apple.system.opendirectoryd.libinfo") (global-name "com.apple.dnssd.service")
    (global-name "com.apple.SystemConfiguration.configd") (global-name "com.apple.SystemConfiguration.DNSConfiguration")
    (global-name "com.apple.trustd") (global-name "com.apple.trustd.agent")
    (global-name "com.apple.system.notification_center") (global-name "com.apple.logd") (global-name "com.apple.diagnosticd"))""")
            // The worker talks to the control plane over its pipes and reaches
            // the network only through the engine's egress proxy, on one
            // loopback port; no other TCP or UDP destination, LAN included.
            appendLine("(allow system-socket)")
            appendLine("(deny network-outbound (remote tcp \"*:*\") (remote udp \"*:*\"))")
            appendLine("(allow network-outbound (remote tcp \"localhost:${egressPort()}\"))")
            appendLine("(deny network-outbound (remote unix-socket))")
            appendLine("(allow network-outbound (remote unix-socket (path-literal \"$MDNS_RESPONDER\")))")
        }
    }

    /** Every ancestor directory of [paths] (path resolution stats each one), plus the symlinked system roots. */
    private fun metadataPaths(paths: List<String>): List<String> {
        val result = sortedSetOf("/", "/private", "/var", "/tmp", "/etc", "/private/var", "/private/tmp")
        for (path in paths) {
            var parent = File(path).parentFile
            while (parent != null) { result += parent.path; parent = parent.parentFile }
        }
        return result.toList()
    }

    /** The control plane's AppCDS archive, reused by workers with the same runtime and jar.
     * Archive-consumer hash validation is owned by the engine lifecycle/package gates. */
    private fun sharedArchive(): String? = parentArguments()
        .firstOrNull { it.startsWith("-XX:SharedArchiveFile=") }?.substringAfter('=')

    private fun parentArguments(): List<String> = ProcessHandle.current().info().arguments().orElse(emptyArray()).toList()

    companion object {
        const val SANDBOX_EXEC = "/usr/bin/sandbox-exec"
        /** Name resolution goes through this Unix socket; it is the only one a worker may connect to. */
        const val MDNS_RESPONDER = "/private/var/run/mDNSResponder"
        /** sysctl names the JVM reads at startup (CPU count, page and cache sizes, memory, OS version). */
        internal val SYSCTL_PREFIXES = listOf("hw.", "machdep.")
        internal val SYSCTL_NAMES = listOf("kern.osrelease", "kern.ostype", "kern.osversion", "kern.osproductversion", "kern.version")
        private val SAFE_LANG = Regex("^[A-Za-z]{2,3}(_[A-Za-z]{2})?(\\.[A-Za-z0-9-]+)?$")

        /** The full environment for a worker whose home is [home]: nothing else is inherited. */
        fun isolatedEnvironment(home: String): Map<String, String> = linkedMapOf(
            "HOME" to home,
            "TMPDIR" to "$home/tmp/",
            "PATH" to "/usr/bin:/bin",
            "LANG" to (System.getenv("LANG")?.takeIf { SAFE_LANG.matches(it) } ?: "en_US.UTF-8"),
        )
        const val DEFAULT_HEAP_MB = 256
        /** The cap after an extension's worker ran out of memory once (W2). */
        const val RAISED_HEAP_MB = 512
        val SANDBOX_AVAILABLE: Boolean get() = File(SANDBOX_EXEC).canExecute() &&
            System.getProperty("os.name").orEmpty().startsWith("Mac")

        /** Sandbox rules match resolved paths (/private/var, not /var). */
        fun canonical(path: String): String = runCatching { File(path).canonicalPath }.getOrDefault(path)

        private fun quote(value: String): String {
            require('\u0000' !in value && '\n' !in value) { "Unsupported character in sandbox path" }
            return "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
        }
    }
}
