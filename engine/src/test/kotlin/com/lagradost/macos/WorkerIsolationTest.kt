package com.lagradost.macos

import com.lagradost.macos.worker.RemoteProvider
import com.lagradost.macos.worker.WorkerExtensionRuntime
import com.lagradost.macos.worker.WorkerHandle
import com.lagradost.macos.worker.WorkerLauncher
import com.lagradost.macos.worker.WorkerPool
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assume.assumeTrue
import java.io.File
import kotlin.test.*

/**
 * Plan T5.3–T5.6 against real worker JVMs running d8-compiled extensions: the
 * control plane runs no extension code, hard deadlines kill a blocking
 * extension without affecting others, crashes are contained and budgeted, and
 * a sandboxed worker cannot read outside its own home.
 */
class WorkerIsolationTest {
    private val repo = SignedCatalogFixture("https://workers.invalid/repo.json")
    private val fixture = ExtensionTestSupport.extension("fixture")
    private val hostile = ExtensionTestSupport.extension("hostile")
    private lateinit var manager: InstallationManager

    @BeforeTest fun before() {
        ExtensionTestSupport.resetHome()
        WorkerPool.resetForTest()
        ExtensionTestSupport.allowUnsandboxedWorkers()
    }

    @AfterTest fun after() {
        WorkerPool.resetForTest()
        ExtensionTestSupport.resetHome()
    }

    private suspend fun install(sandboxed: Boolean = false, heapMb: Int = 96): Pair<DaemonState.InstalledExtension, DaemonState.InstalledExtension> {
        val fetcher = repo.publish(mapOf("Fixture" to fixture, "Hostile" to hostile), revision = 1)
        val runtime = WorkerExtensionRuntime(WorkerLauncher(sandboxed = sandboxed, heapMb = heapMb))
        manager = ExtensionTestSupport.use(InstallationManager(runtime, fetcher))
        WorkerPool.onQuarantine = { id, reason -> manager.quarantine(id, reason) }
        WorkerPool.onTranslation = { id, generation, hashes -> manager.recordTranslation(id, generation, hashes) }
        WorkerPool.onAssessment = { id, generation, report -> manager.recordAssessment(id, generation, report) }
        return manager.install(repo.url, "Fixture") to manager.install(repo.url, "Hostile")
    }

    private fun provider(record: DaemonState.InstalledExtension) =
        assertIs<RemoteProvider>(PluginBridge.loadedInstallation(record.id)!!.providers.single())

    @Test fun `worker JVM logging never goes to stdout, which carries the frame protocol`() {
        val home = java.nio.file.Files.createTempDirectory("worker-cmd").toFile()
        val command = WorkerLauncher(sandboxed = false).command(home, File(home, "x.cs3"))
        val main = command.indexOf("com.lagradost.macos.MainKt")
        assertTrue(command.indexOf("-Xlog:disable") in 0 until main)
        assertTrue(command.indexOf("-Xlog:all=warning:stderr") in command.indexOf("-Xlog:disable") until main)
        home.deleteRecursively()
    }

    @Test fun `extension code runs in its own worker process and serves the engine's calls`() = runBlocking<Unit> {
        val (record, _) = install()
        val provider = provider(record)
        assertEquals("${record.id}:FixtureProvider", PluginBridge.providerId(provider))
        val home = ProviderExecutor.loadHome(provider, 1)
        assertEquals(listOf("Trending|trending|1", "Latest|latest|1"), home.lists.map { it.name })
        assertEquals("${record.id}:FixtureProvider", home.providerId)
        assertTrue(provider.handle.running)
        val workerPid = assertNotNull(provider.handle.pid)
        assertNotEquals(ProcessHandle.current().pid(), workerPid)
        assertTrue(ProcessHandle.of(workerPid).map { it.isAlive }.orElse(false))
        // Context storage lives in the worker's home, not the engine's.
        assertTrue(File(WorkerHandle.homeFor(record.id), "extension-data/${record.id}/shared_prefs/fixture.json").isFile)
        assertEquals(listOf("FixtureProvider"), DaemonState.snapshot().installations[record.id]!!.providerDescriptors.map { it.name })
        // The control plane holds only a worker handle, never the extension's plugin object.
        assertIs<com.lagradost.macos.worker.WorkerPlugin>(PluginBridge.loadedInstallation(record.id)!!.plugin)
    }

    @Test fun `restored extensions register without starting a worker until first use`() = runBlocking<Unit> {
        val (record, hostileRecord) = install()
        manager.setEnabled(record.id, false)
        manager.setEnabled(hostileRecord.id, false)
        WorkerPool.resetForTest()
        manager.setEnabled(record.id, true)
        assertEquals(0, WorkerPool.runningCount(), "descriptors in the receipt let the stub register lazily")
        val provider = provider(record)
        assertFalse(provider.handle.running)
        assertEquals(2, ProviderExecutor.loadHome(provider, 1).lists.size)
        assertTrue(provider.handle.running)
    }

    @Test fun `a stale compatibility report is reassessed when the worker next starts`() = runBlocking<Unit> {
        val (record, hostileRecord) = install()
        manager.setEnabled(record.id, false)
        manager.setEnabled(hostileRecord.id, false)
        val stale = DaemonState.snapshot().installations.getValue(record.id).let {
            it.copy(compatibility = it.compatibility!!.copy(profile = "cloudstream-macos-runtime-0"))
        }
        DaemonState.update { it.copy(installations = it.installations + (record.id to stale)) }
        WorkerPool.resetForTest()
        manager.setEnabled(record.id, true)
        assertEquals(0, WorkerPool.runningCount(), "a stale report never forces a start by itself")
        assertFalse(RepositoryService.installedPlugin(record.id)!!.compatibility!!.current)

        ProviderExecutor.loadHome(provider(record), 1)
        withTimeout(10_000) {
            while (DaemonState.snapshot().installations.getValue(record.id).compatibility?.profile != RuntimeProfile.VERSION) delay(50)
        }
        assertTrue(RepositoryService.installedPlugin(record.id)!!.compatibility!!.current)
    }

    /** RT-13: compiled resources work inside the sandbox, read from the verified archive only. */
    @Test fun `an extension with compiled Android resources operates in a sandboxed worker`() = runBlocking<Unit> {
        assumeTrue("macOS sandbox required", WorkerLauncher.SANDBOX_AVAILABLE)
        val fetcher = repo.publish(mapOf("AndroidResources" to ExtensionTestSupport.extension("android-resources")), revision = 1)
        manager = ExtensionTestSupport.use(InstallationManager(WorkerExtensionRuntime(WorkerLauncher(sandboxed = true)), fetcher))
        val record = manager.install(repo.url, "AndroidResources")
        val provider = provider(record)
        assertEquals("ResourceProvider", provider.name)
        assertEquals("https://resources.invalid", provider.mainUrl)
        assertEquals(2, ProviderExecutor.loadHome(provider, 1).lists.size)
    }

    @Test fun `a blocking extension is killed at its deadline and others keep working`() = runBlocking<Unit> {
        val (record, hostileRecord) = install()
        val registered = provider(hostileRecord)
        // Give the blocking fixture an explicit short provider hint. The
        // production default is 120 seconds; this test verifies a 5-second
        // hard deadline and cancellation without waiting for that default.
        val hostileProvider = RemoteProvider(registered.handle,
            com.lagradost.macos.worker.ProviderDescriptor(registered.name, registered.mainUrl, searchTimeoutMs = 5_000))
        val started = System.currentTimeMillis()
        val result = ProviderExecutor.searchOne(hostileProvider, "block")
        assertNotNull(result.error)
        assertTrue(System.currentTimeMillis() - started < 15_000, "search budget + margin, not forever")
        withTimeout(10_000) { while (hostileProvider.handle.running) delay(100) }
        // The other extension's worker is untouched.
        assertEquals(2, ProviderExecutor.loadHome(provider(record), 1).lists.size)
        // The killed extension restarts on its next call.
        assertNull(ProviderExecutor.searchOne(hostileProvider, "fine").error)
    }

    @Test fun `memory exhaustion ends only that worker`() = runBlocking<Unit> {
        val (record, hostileRecord) = install(heapMb = 64)
        val result = ProviderExecutor.searchOne(provider(hostileRecord), "oom")
        assertNotNull(result.error)
        assertEquals(2, ProviderExecutor.loadHome(provider(record), 1).lists.size)
    }

    @Test fun `repeated crashes quarantine the extension`() = runBlocking<Unit> {
        val (_, hostileRecord) = install()
        repeat(WorkerPool.CRASH_BUDGET) {
            val current = PluginBridge.loadedInstallation(hostileRecord.id)?.providers?.single() as? RemoteProvider ?: return@repeat
            ProviderExecutor.searchOne(current, "exit")
            withTimeout(10_000) { while (current.handle.running) delay(50) }
        }
        withTimeout(10_000) { while (DaemonState.snapshot().installations[hostileRecord.id]?.quarantinedReason == null) delay(50) }
        assertNull(PluginBridge.loadedInstallation(hostileRecord.id), "quarantined generation is unloaded")
        assertTrue(AuditLog.recent().any { "extension.quarantine" in it })
        assertTrue(manager.retry(hostileRecord.id), "the user can retry")
    }

    @Test fun `without an explicit opt-out an unsandboxed worker never starts (L6)`() = runBlocking<Unit> {
        val (record, _) = install()
        DaemonRuntime.resetForTest() // The default policy: the sandbox is required.
        val reserved = WorkerPool.reservedCount()
        val unsandboxed = WorkerHandle(record, File(WorkerHandle.homeFor(record.id), "x.cs3"), WorkerLauncher(sandboxed = false), false)
        assertFailsWith<PolicyException> { unsandboxed.ensure() }
        assertEquals(reserved, WorkerPool.reservedCount(), "nothing was launched")
        assertFailsWith<SecurityException> { WorkerLauncher(sandboxed = false).command(WorkerHandle.homeFor(record.id), File("x.cs3")) }
    }

    @Test fun `exits after engine shutdown begins never quarantine`() {
        val quarantined = mutableListOf<String>()
        WorkerPool.onQuarantine = { id, _ -> quarantined += id }
        WorkerPool.beginShutdown()
        repeat(WorkerPool.CRASH_BUDGET + 1) { WorkerPool.recordCrash("shutdown-fixture", "exited (code 143)") }
        assertTrue(quarantined.isEmpty())
    }

    @Test fun `packaged relative class path is kept and the worker runs from the engine's directory`() {
        val home = java.nio.file.Files.createTempDirectory("worker-cp").toFile()
        val launcher = WorkerLauncher(classpath = "tools/daemon.jar", sandboxed = false)
        val command = launcher.command(home, File(home, "x.cs3"))
        assertEquals("tools/daemon.jar", command[command.indexOf("-cp") + 1])
        assertEquals(File(System.getProperty("user.dir")).absoluteFile, launcher.workingDirectory(home))
        assertEquals(home, WorkerLauncher(sandboxed = false).workingDirectory(home), "absolute class paths keep the worker's home")
        val cwd = File(System.getProperty("user.dir")).canonicalPath
        assertTrue("(allow file-read* (literal \"$cwd\"))" in launcher.profile(home.canonicalPath, "/x.cs3"),
            "a sandboxed worker can resolve its working directory")
        home.deleteRecursively()
    }

    @Test fun `a sandboxed worker cannot read engine state or another extension's data`() = runBlocking<Unit> {
        assumeTrue("macOS sandbox required", WorkerLauncher.SANDBOX_AVAILABLE)
        val (record, hostileRecord) = install(sandboxed = true)
        val hostileFiles = File(WorkerHandle.homeFor(hostileRecord.id), "extension-data/${hostileRecord.id}/files").apply { mkdirs() }
        fun probe(target: File): String {
            File(hostileFiles, "probe-target.txt").writeText(target.canonicalPath)
            return runBlocking { ProviderExecutor.loadHome(provider(hostileRecord), 1).lists.single().name }
        }
        val own = File(hostileFiles, "own.txt").apply { writeText("mine") }
        assertEquals("read:mine", probe(own), "a worker can use its own storage")
        assertTrue(DaemonState.stateFile.isFile)
        assertTrue(probe(DaemonState.stateFile).startsWith("denied:"), "engine trust state is not readable")
        val otherPrefs = File(WorkerHandle.homeFor(record.id), "extension-data/${record.id}/shared_prefs/fixture.json")
        ProviderExecutor.loadHome(provider(record), 1) // make sure the other worker wrote its preferences
        assertTrue(otherPrefs.isFile)
        assertTrue(probe(otherPrefs).startsWith("denied:"), "another extension's data is not readable")
    }

    private fun hostileProbe(hostileRecord: DaemonState.InstalledExtension): (String) -> String {
        val files = File(WorkerHandle.homeFor(hostileRecord.id), "extension-data/${hostileRecord.id}/files").apply { mkdirs() }
        return { target ->
            File(files, "probe-target.txt").writeText(target)
            runBlocking { ProviderExecutor.loadHome(provider(hostileRecord), 1).lists.single().name }
        }
    }

    /** Serves [secret] to every connection until closed (a stand-in for a Docker or agent socket, or a dev server). */
    private fun serve(channel: java.nio.channels.ServerSocketChannel, secret: String) = Thread {
        while (channel.isOpen) {
            runCatching { channel.accept().use { it.write(java.nio.ByteBuffer.wrap(secret.toByteArray())) } }
        }
    }.apply { isDaemon = true; start() }

    @Test fun `a sandboxed worker cannot connect to local Unix sockets (H1)`() = runBlocking<Unit> {
        assumeTrue("macOS sandbox required", WorkerLauncher.SANDBOX_AVAILABLE)
        val (_, hostileRecord) = install(sandboxed = true)
        val probe = hostileProbe(hostileRecord)
        // Short path: sun_path is limited to 104 bytes on macOS.
        val directory = java.nio.file.Files.createTempDirectory(java.nio.file.Path.of("/tmp"), "cs-h1-")
        val socket = directory.resolve("agent.sock")
        val server = java.nio.channels.ServerSocketChannel.open(java.net.StandardProtocolFamily.UNIX)
            .bind(java.net.UnixDomainSocketAddress.of(socket))
        try {
            serve(server, "agent-secret")
            java.nio.channels.SocketChannel.open(java.net.UnixDomainSocketAddress.of(socket)).use { client ->
                val buffer = java.nio.ByteBuffer.allocate(64)
                client.read(buffer)
                assertEquals("agent-secret", String(buffer.array(), 0, buffer.position()), "the socket works outside the sandbox")
            }
            val outcome = probe("unix:${socket.toRealPath()}")
            assertTrue(outcome.startsWith("denied:"), "Unix-domain sockets are refused, got $outcome")
        } finally {
            server.close()
            directory.toFile().deleteRecursively()
        }
    }

    @Test fun `a sandboxed worker cannot reach loopback services (H1)`() = runBlocking<Unit> {
        assumeTrue("macOS sandbox required", WorkerLauncher.SANDBOX_AVAILABLE)
        val (record, hostileRecord) = install(sandboxed = true)
        val probe = hostileProbe(hostileRecord)
        val server = java.nio.channels.ServerSocketChannel.open().bind(java.net.InetSocketAddress("::", 0))
        try {
            serve(server, "loopback-secret")
            val port = (server.localAddress as java.net.InetSocketAddress).port
            for (host in listOf("127.0.0.1", "localhost", "::1", "0.0.0.0")) {
                val outcome = probe("tcp:$host:$port")
                assertTrue(outcome.startsWith("denied:"), "loopback $host is refused, got $outcome")
            }
            // The other worker, sandboxed by the same profile, still serves normally.
            assertEquals(2, ProviderExecutor.loadHome(provider(record), 1).lists.size)
        } finally { server.close() }
    }

    @Test fun `a sandboxed worker cannot read other processes' command lines or probe for files (M2)`() = runBlocking<Unit> {
        assumeTrue("macOS sandbox required", WorkerLauncher.SANDBOX_AVAILABLE)
        val (_, hostileRecord) = install(sandboxed = true)
        val probe = hostileProbe(hostileRecord)
        val outside = java.nio.file.Files.createTempFile("cs-m2-", ".txt").toFile().apply { writeText("outside") }
        // Like ffmpeg with -headers: a credential in another process's argv.
        val victim = ProcessBuilder("/bin/sh", "-c", "sleep 30", "Cookie: session=hunter2").start()
        try {
            val arguments = ProcessHandle.of(victim.pid()).flatMap { it.info().arguments() }.map { it.joinToString(" ") }.orElse("")
            assertTrue("hunter2" in arguments, "the argument is visible outside the sandbox")
            val args = probe("args:${victim.pid()}")
            assertTrue(args.startsWith("denied:") && "hunter2" !in args, "another process's arguments are hidden, got $args")
            val stat = probe("stat:${outside.canonicalPath}")
            assertTrue(stat.startsWith("denied:"), "existence outside the sandbox is not observable, got $stat")
            assertEquals("read:exists", probe("stat:${File(WorkerHandle.homeFor(hostileRecord.id), "extension-data").canonicalPath}"),
                "its own home stays observable")
        } finally {
            victim.destroyForcibly()
            outside.delete()
        }
    }

    /** A non-loopback address of this Mac (its LAN address when it has one): a stand-in for any local-network host. */
    private fun localNetworkAddress(): String = java.net.NetworkInterface.networkInterfaces().toList()
        .filter { it.isUp && !it.isLoopback }
        .flatMap { it.inetAddresses.toList() }
        .firstOrNull { it is java.net.Inet4Address && it.isSiteLocalAddress }?.hostAddress
        ?: "192.0.2.1" // TEST-NET-1: never public, refused the same way.

    @Test fun `a sandboxed worker reaches the network only through the engine's egress proxy (H1, LAN)`() = runBlocking<Unit> {
        assumeTrue("macOS sandbox required", WorkerLauncher.SANDBOX_AVAILABLE)
        val (_, hostileRecord) = install(sandboxed = true)
        val probe = hostileProbe(hostileRecord)
        val server = java.nio.channels.ServerSocketChannel.open().bind(java.net.InetSocketAddress("0.0.0.0", 0))
        try {
            serve(server, "lan-secret")
            val port = (server.localAddress as java.net.InetSocketAddress).port
            val lan = localNetworkAddress()
            // Bypassing the proxy, the sandbox refuses every destination: LAN, loopback and public alike.
            for (target in listOf("$lan:$port", "127.0.0.1:$port", "1.1.1.1:443")) {
                val outcome = probe("direct:$target")
                assertTrue(outcome.startsWith("denied:") && "Operation not permitted" in outcome, "direct $target: $outcome")
            }
            // Through the proxy, a local-network or loopback destination is refused by the engine.
            for (target in listOf("$lan:$port", "127.0.0.1:$port")) {
                val outcome = probe("tcp:$target")
                assertTrue(outcome.startsWith("denied:") && "ruleset" in outcome, "proxied $target: $outcome")
                assertFalse("lan-secret" in outcome)
            }
        } finally { server.close() }
    }

    @Test fun `allowed destinations are reached through the egress proxy from a sandboxed worker`() = runBlocking<Unit> {
        assumeTrue("macOS sandbox required", WorkerLauncher.SANDBOX_AVAILABLE)
        // A proxy whose address rule admits this test's loopback origin, standing in for a public host.
        val permissive = com.lagradost.macos.worker.WorkerEgressProxy(addressAllowed = { true })
        com.lagradost.macos.worker.WorkerEgressProxy.testOverride = permissive
        val server = java.nio.channels.ServerSocketChannel.open().bind(java.net.InetSocketAddress("127.0.0.1", 0))
        try {
            serve(server, "via-egress")
            val (_, hostileRecord) = install(sandboxed = true)
            val probe = hostileProbe(hostileRecord)
            val port = (server.localAddress as java.net.InetSocketAddress).port
            assertEquals("read:via-egress", probe("tcp:127.0.0.1:$port"), "the worker's socket went through the proxy")
            assertTrue(probe("direct:127.0.0.1:$port").startsWith("denied:"), "and could not have gone around it")
        } finally {
            server.close()
            com.lagradost.macos.worker.WorkerEgressProxy.testOverride = null
            permissive.close()
        }
    }

    @Test fun `workers inherit none of the engine's environment (H1)`() = runBlocking<Unit> {
        val (_, hostileRecord) = install()
        val probe = hostileProbe(hostileRecord)
        val home = WorkerHandle.homeFor(hostileRecord.id).canonicalPath
        assertEquals("read:$home", probe("env:HOME"))
        assertEquals("read:$home/tmp/", probe("env:TMPDIR"))
        assertEquals("read:/usr/bin:/bin", probe("env:PATH"))
        for (name in listOf("SSH_AUTH_SOCK", "CS_DAEMON_TOKEN", "CS_DAEMON_OPTIONS", "JAVA_TOOL_OPTIONS", "USER", "DOCKER_HOST")) {
            assertEquals("read:<unset>", probe("env:$name"), "$name is not inherited")
        }
    }

    @Test fun `the worker profile narrows system sysctl, process and socket grants after importing system rules`() {
        val home = java.nio.file.Files.createTempDirectory("worker-profile").toFile()
        val profile = WorkerLauncher(sandboxed = true).profile(home.canonicalPath, "/x.cs3")
        val import = profile.indexOf("(import \"system.sb\")")
        assertTrue(import >= 0)
        assertTrue(profile.indexOf("(deny sysctl-read)") > import, "system.sb allows every sysctl; the deny must follow it")
        assertTrue(profile.indexOf("(deny process-info*)") > import)
        assertTrue("(allow process-info* (target self))" in profile)
        assertFalse("(allow sysctl-read)\n" in profile)
        assertFalse("(allow file-read-metadata)\n" in profile, "metadata is limited to listed paths")
        assertFalse("(allow network-outbound)\n" in profile, "no general outbound grant")
        assertTrue("(deny network-outbound (remote tcp \"*:*\") (remote udp \"*:*\"))" in profile)
        assertTrue("(allow network-outbound (remote tcp \"localhost:${com.lagradost.macos.worker.WorkerEgressProxy.active.port}\"))" in profile,
            "the egress proxy's port is the only TCP destination")
        assertFalse("remote ip" in profile, "remote ip would override the loopback deny")
        assertTrue("(deny network-outbound (remote unix-socket))" in profile)
        assertTrue(profile.indexOf("(path-literal \"${WorkerLauncher.MDNS_RESPONDER}\")") > profile.indexOf("(deny network-outbound (remote unix-socket))"),
            "name resolution's socket is re-allowed after the Unix-socket deny")
        home.deleteRecursively()
    }
}
