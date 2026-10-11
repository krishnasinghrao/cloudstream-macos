package com.lagradost.macos

import com.lagradost.macos.worker.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.builtins.serializer
import java.io.File
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.*

/** Real child processes hold initialization/shutdown behind filesystem gates. */
class WorkerAdmissionTest {
    private lateinit var root: File
    private lateinit var script: File
    private val owned = mutableListOf<WorkerHandle>()

    @BeforeTest fun before() {
        WorkerPool.resetForTest()
        ExtensionTestSupport.resetHome()
        ExtensionTestSupport.allowUnsandboxedWorkers()
        root = Files.createTempDirectory("worker-admission-").toFile()
        script = File(root, "worker.py").apply { writeText(PYTHON_WORKER) }
    }

    @AfterTest fun after() {
        owned.forEach { it.retire() }
        WorkerPool.resetForTest() // Waits for confirmed exit before deleting homes.
        root.deleteRecursively()
        ExtensionTestSupport.resetHome()
    }

    private fun home(index: Int) = File(root, "home-$index").apply { mkdirs() }

    private fun handle(index: Int, mode: String = "normal", timeout: Long = WorkerHandle.INIT_TIMEOUT_MS,
                       prepare: (() -> File)? = null,
                       command: ((File, File) -> List<String>)? = null): WorkerHandle {
        val directory = home(index)
        val record = DaemonState.InstalledExtension(index.toString().padStart(64, '0'), "https://fixture.invalid/repo",
            "fixture-$index", "a".repeat(64), "generation-$index", "b".repeat(64), 1,
            RepositoryService.SitePlugin(name = "fixture-$index"))
        return WorkerHandle(record, script, WorkerLauncher(sandboxed = false), false, timeout,
            prepare ?: { directory }, command ?: { _, _ -> listOf("/usr/bin/python3", script.path, directory.path, mode) })
            .also { owned += it }
    }

    private suspend fun until(predicate: () -> Boolean) = withTimeout(5_000) {
        while (!predicate()) delay(10)
    }

    private fun allow(index: Int) = File(home(index), "allow-init").writeText("ready")
    private fun pid(index: Int): Long? = File(home(index), "pid").takeIf { it.isFile }?.readText()?.toLongOrNull()
    private fun alive(index: Int) = pid(index)?.let { ProcessHandle.of(it).map { process -> process.isAlive }.orElse(false) } == true

    @Test fun `concurrent cold starts reserve base and overflow, and excess starts wait for a free worker`() = runBlocking<Unit> {
        WorkerPool.maxRunning = 1
        val handles = (1..10).map { handle(it) }
        val starts = handles.map { async { runCatching { it.ensure() } } }
        until { (1..10).count { alive(it) } == 5 }
        delay(200)
        assertEquals(5, WorkerPool.reservedCount(), "One base slot plus four overflow slots, including startup")
        assertEquals(5, WorkerPool.runningCount(), "Processes in init already consume capacity")
        assertEquals(0, starts.count { it.isCompleted }, "Excess starts wait instead of being refused")
        (1..10).forEach(::allow)
        val results = withTimeout(20_000) { starts.awaitAll() }
        assertTrue(results.all { it.isSuccess }, "Each waiting start takes an idle worker's place")
        assertTrue((1..10).count { alive(it) } <= 5)
    }

    @Test fun `a start is refused only after waiting while every worker stays busy`() = runBlocking<Unit> {
        WorkerPool.maxRunning = 1
        WorkerPool.capacityWaitMs = 300
        val starts = (1..6).map { handle(it) }.map { async { runCatching { it.ensure() } } }
        until { starts.count { it.isCompleted } == 1 }
        val refused = starts.single { it.isCompleted }.await().exceptionOrNull()
        assertIs<WorkerCapacityException>(refused)
        assertEquals(5, WorkerPool.reservedCount())
        (1..6).forEach(::allow)
        starts.awaitAll()
    }

    @Test fun `nested extraction at full capacity is refused at once instead of waiting`() = runBlocking<Unit> {
        WorkerPool.maxRunning = 1
        WorkerPool.capacityWaitMs = 20_000
        val busy = (1..5).map { handle(it) }.map { async { runCatching { it.ensure() } } }
        until { WorkerPool.reservedCount() == 5 }
        val nested = handle(6)
        val started = System.nanoTime()
        val refused = runCatching { nested.call("gated-call", JsonNull, Boolean.serializer(), 5_000, waitForCapacity = false) }
        val elapsedMs = (System.nanoTime() - started) / 1_000_000
        assertIs<WorkerCapacityException>(refused.exceptionOrNull())
        assertTrue(elapsedMs < 2_000, "A nested caller must not wait on its own busy capacity (took ${elapsedMs}ms)")
        assertEquals(0, nested.awaitingOrActiveCalls)
        (1..5).forEach(::allow)
        busy.awaitAll()
    }

    @Test fun `a top-level start waits for capacity and is admitted when a slot is released`() = runBlocking<Unit> {
        WorkerPool.maxRunning = 1
        WorkerPool.capacityWaitMs = 20_000
        val handles = (1..5).map { handle(it) }
        val busy = handles.map { async { runCatching { it.ensure() } } }
        until { WorkerPool.reservedCount() == 5 }
        allow(6)
        val waiting = async { runCatching { handle(6).ensure() } }
        delay(300)
        assertFalse(waiting.isCompleted, "A top-level start waits rather than being refused")
        handles.first().retire()
        val admitted = withTimeout(10_000) { waiting.await() }
        assertTrue(admitted.isSuccess, "The waiting start takes the released slot: ${admitted.exceptionOrNull()}")
        (2..5).forEach(::allow)
        busy.awaitAll()
    }

    @Test fun `an idle worker grown past its memory budget is recycled, a busy one never (Remediation 5_2)`() = runBlocking<Unit> {
        allow(1); allow(2)
        val idle = handle(1)
        val busy = handle(2)
        idle.ensure()
        val call = async { busy.call("gated-call", JsonNull, Boolean.serializer(), 10_000) }
        until { File(home(2), "call-active").isFile }
        WorkerPool.maxIdleResidentBytes = 1024
        WorkerPool.residentBytes = { 10L * 1024 * 1024 * 1024 } // Every worker "uses" 10 GB.
        WorkerPool.reapIdle()
        until { !alive(1) }
        assertTrue(alive(2), "a worker with a call in progress is never recycled")
        File(home(2), "allow-call").writeText("ready")
        assertTrue(call.await())
        // The recycled worker starts again on its next use.
        WorkerPool.residentBytes = { 1L }
        idle.ensure()
        until { alive(1) }
    }

    @Test fun `the real resident-size probe reads a live process`() {
        WorkerPool.resetForTest()
        val probe = WorkerPool.residentBytes(ProcessHandle.current().pid())
        assertNotNull(probe)
        assertTrue(probe > 1024 * 1024, "a JVM uses more than a megabyte: $probe")
        assertNull(WorkerPool.residentBytes(Long.MAX_VALUE / 2))
    }

    @Test fun `caller cancellation preserves shared startup but retirement kills it`() = runBlocking<Unit> {
        val handle = handle(1)
        val first = async { handle.ensure() }
        val second = async { handle.ensure() }
        until { alive(1) }
        val originalPid = pid(1)
        first.cancelAndJoin()
        assertEquals(1, WorkerPool.reservedCount())
        allow(1)
        val worker = second.await()
        assertEquals(originalPid, worker.pid)
        handle.retire()
        until { WorkerPool.reservedCount() == 0 }
        assertFalse(alive(1))
        assertFailsWith<IllegalStateException> { handle.ensure() }
    }

    @Test fun `failed preparation command and initialization release their reservations`() = runBlocking<Unit> {
        val preparation = handle(1, prepare = { throw java.io.IOException("prepare fixture") })
        assertFailsWith<java.io.IOException> { preparation.ensure() }
        assertEquals(0, WorkerPool.reservedCount())
        val launch = handle(2, command = { _, _ -> listOf(File(root, "absent-program").path) })
        assertFailsWith<java.io.IOException> { launch.ensure() }
        assertEquals(0, WorkerPool.reservedCount())
        allow(3)
        val invalid = handle(3, mode = "invalid-init")
        assertFailsWith<IllegalArgumentException> { invalid.ensure() }
        until { WorkerPool.reservedCount() == 0 }
        assertFalse(alive(3), "Initialized child is reaped before its slot can be reused")
    }

    @Test fun `idle eviction waits for confirmed exit rather than freeing a stopping process`() = runBlocking<Unit> {
        WorkerPool.maxRunning = 1
        allow(1)
        val old = handle(1, mode = "ignore-shutdown")
        old.ensure()
        allow(2)
        val replacement = handle(2)
        val start = async { replacement.ensure() }
        delay(200)
        assertTrue(alive(1))
        assertFalse(alive(2), "No replacement process launches while the idle victim is stopping")
        assertFalse(start.isCompleted)
        assertEquals(1, WorkerPool.reservedCount())
        withTimeout(5_000) { start.await() }
        assertFalse(alive(1))
        assertTrue(alive(2))
        assertEquals(1, WorkerPool.reservedCount())
    }

    @Test fun `active call lease prevents eviction and permits bounded routed overflow`() = runBlocking<Unit> {
        WorkerPool.maxRunning = 1
        val provider = handle(1)
        val call = async { provider.call("gated-call", JsonNull, Boolean.serializer(), 5_000) }
        until { alive(1) }
        assertEquals(1, provider.awaitingOrActiveCalls, "The caller is protected before startup publishes a client")
        allow(2)
        handle(2).ensure()
        allow(1)
        until { File(home(1), "call-active").isFile }
        assertTrue(alive(1), "A provider awaiting a nested operation must retain its process")
        assertTrue(alive(2))
        assertEquals(2, WorkerPool.reservedCount())
        File(home(1), "allow-call").writeText("ready")
        assertTrue(call.await())
        assertEquals(0, provider.awaitingOrActiveCalls)
    }

    @Test fun `startup deadline is independent and releases only after child exit`() = runBlocking<Unit> {
        val blocked = handle(1, mode = "ignore-shutdown", timeout = 400)
        assertFailsWith<TimeoutCancellationException> { blocked.ensure() }
        assertEquals(1, WorkerPool.reservedCount(), "A deadline does not instantly reap the child")
        until { WorkerPool.reservedCount() == 0 }
        assertFalse(alive(1))
    }

    @Test fun `retirement during preparation never launches a process`() = runBlocking<Unit> {
        val entered = CountDownLatch(1)
        val resume = CountDownLatch(1)
        val launches = AtomicInteger()
        val delayed = handle(1, prepare = {
            entered.countDown()
            check(resume.await(5, TimeUnit.SECONDS))
            home(1)
        }, command = { _, _ -> launches.incrementAndGet(); listOf("/usr/bin/true") })
        val startup = async { runCatching { delayed.ensure() } }
        assertTrue(withContext(Dispatchers.IO) { entered.await(2, TimeUnit.SECONDS) })
        delayed.retire()
        resume.countDown()
        assertTrue(startup.await().isFailure)
        until { WorkerPool.reservedCount() == 0 }
        assertEquals(0, launches.get())
    }

    companion object {
        private val PYTHON_WORKER = """
            import json, os, struct, sys, time
            home, mode = sys.argv[1:3]
            with open(os.path.join(home, 'pid'), 'w') as file: file.write(str(os.getpid()))
            def wait(name):
                while not os.path.exists(os.path.join(home, name)): time.sleep(0.01)
            while True:
                prefix = sys.stdin.buffer.read(4)
                if len(prefix) != 4: break
                frame = json.loads(sys.stdin.buffer.read(struct.unpack('>I', prefix)[0]))
                op = frame['type']
                if op == 'shutdown':
                    if mode == 'ignore-shutdown': time.sleep(60)
                    break
                if op == 'init':
                    wait('allow-init')
                    payload = {'providers': [], 'extractorCount': 0, 'jarHashes': []}
                    if mode == 'invalid-init': payload['providers'] = [{'name': '', 'mainUrl': ''}]
                else:
                    with open(os.path.join(home, 'call-active'), 'w') as file: file.write('ready')
                    wait('allow-call')
                    payload = True
                data = json.dumps({'id': frame['id'], 'type': 'result', 'payload': payload, 'protocolVersion': 2}).encode()
                sys.stdout.buffer.write(struct.pack('>I', len(data)) + data)
                sys.stdout.buffer.flush()
        """.trimIndent()
    }
}
