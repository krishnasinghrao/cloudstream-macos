package com.lagradost.macos

import com.lagradost.macos.worker.Frame
import com.lagradost.macos.worker.FrameCodec
import com.lagradost.macos.worker.FrameWriter
import com.lagradost.macos.worker.Op
import com.lagradost.macos.worker.WorkerClient
import com.lagradost.macos.worker.WorkerFailure
import com.lagradost.macos.worker.WorkerLauncher
import com.lagradost.macos.worker.WorkerPool
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import java.io.OutputStream
import java.io.ByteArrayOutputStream
import java.io.ByteArrayInputStream
import java.io.DataInputStream
import java.io.IOException
import java.io.File
import java.nio.file.Files
import java.util.Base64
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.test.*

/** Real blocked pipes, not a fake send method that skips the blocking write. */
class WorkerPipeTest {
    @Test fun `never reading worker cannot hold a call past its deadline`() = runBlocking<Unit> {
        val home = Files.createTempDirectory("worker-pipe-").toFile()
        val exited = CompletableDeferred<Unit>()
        val client = WorkerClient("blocked-pipe", listOf("/bin/sh", "-c", "exec sleep 60"), home,
            solve = { null }, onExit = { _, _, _ -> exited.complete(Unit) })
        try {
            val started = System.nanoTime()
            val failure = assertFailsWith<WorkerFailure> {
                client.call(Op.SEARCH, JsonPrimitive("x".repeat(1024 * 1024)), 300)
            }
            assertEquals(WorkerFailure.Kind.TIMEOUT, failure.kind)
            assertTrue((System.nanoTime() - started) / 1_000_000 < 1_500, "caller must not wait for a pipe write")
            withTimeout(5_000) { exited.await() }
            assertFalse(client.alive)
            assertEquals(0, client.activeCalls)
        } finally {
            client.kill("test cleanup")
            withTimeout(5_000) { exited.await() }
            home.deleteRecursively()
        }
    }

    @Test fun `calls racing a worker that exits right after start all fail as crashes and none hang (M4)`() = runBlocking<Unit> {
        val home = Files.createTempDirectory("worker-exit-race-").toFile()
        try {
            repeat(20) { round ->
                val exited = CompletableDeferred<Unit>()
                val client = WorkerClient("exit-race-$round", listOf("/bin/sh", "-c", "exit 0"), home,
                    solve = { null }, onExit = { _, _, _ -> exited.complete(Unit) })
                val calls = (1..50).map {
                    async(kotlinx.coroutines.Dispatchers.IO) { runCatching { client.call(Op.SEARCH, JsonNull, 20_000) } }
                }
                val results = withTimeout(10_000) { calls.map { it.await() } }
                results.forEach { result ->
                    val failure = assertIs<WorkerFailure>(result.exceptionOrNull(), "every racing call fails: $result")
                    assertEquals(WorkerFailure.Kind.CRASHED, failure.kind)
                }
                withTimeout(5_000) { exited.await() }
                assertEquals(0, client.activeCalls, "no entry is left behind after the drain")
            }
        } finally { home.deleteRecursively() }
    }

    @Test fun `worker stderr is counted, not kept, unless verbose logs are enabled (L1)`() = runBlocking<Unit> {
        val home = Files.createTempDirectory("worker-stderr-").toFile()
        val logs = Files.createTempDirectory("worker-stderr-log-").toFile()
        DaemonLog.init(logs)
        try {
            for (verbose in listOf(false, true)) {
                WorkerClient.verboseStderr = verbose
                val exited = CompletableDeferred<Unit>()
                WorkerClient("stderr-$verbose", listOf("/bin/sh", "-c", "echo 'printing mark-$verbose' >&2; exit 0"), home,
                    solve = { null }, onExit = { _, _, _ -> exited.complete(Unit) })
                withTimeout(5_000) { exited.await() }
            }
            val text = withTimeout(5_000) {
                var current = ""
                while ("mark-true" !in current || "stderr_suppressed" !in current) { delay(20); current = File(logs, "daemon.log").readText() }
                current
            }
            assertFalse("mark-false" in text, "stderr is not persisted by default")
            assertTrue("mark-true" in text, "verbose mode keeps the (redacted) line")
        } finally {
            WorkerClient.verboseStderr = false
            DaemonLog.init()
            logs.deleteRecursively()
            home.deleteRecursively()
        }
    }

    @Test fun `external SIGTERM is not reported as a crash, other exits are`() = runBlocking<Unit> {
        val home = Files.createTempDirectory("worker-sigterm-").toFile()
        try {
            for ((script, expectedExit) in listOf("kill -TERM $$; sleep 5" to true, "exit 3" to false)) {
                val result = CompletableDeferred<Pair<Boolean, String>>()
                val client = WorkerClient("sigterm", listOf("/bin/sh", "-c", script), home,
                    solve = { null }, onExit = { _, expected, reason -> result.complete(expected to reason) })
                val (expected, reason) = withTimeout(5_000) { result.await() }
                assertEquals(expectedExit, expected, reason)
                client.kill("test cleanup")
            }
        } finally { home.deleteRecursively() }
    }

    @Test fun `an out of memory exit is named and raises that extension's heap`() = runBlocking<Unit> {
        val home = Files.createTempDirectory("worker-oom-").toFile()
        val id = "e".repeat(64)
        try {
            val exited = CompletableDeferred<WorkerClient>()
            // -XX:+ExitOnOutOfMemoryError exits with status 3; the call is in flight when it happens.
            val client = WorkerClient(id, listOf("/bin/sh", "-c", "sleep 0.3; exit 3"), home,
                solve = { null }, onExit = { exitedClient, _, _ -> exitedClient.takeIf { it.outOfMemory }?.let { WorkerPool.raiseHeap(id) }; exited.complete(exitedClient) })
            val failure = assertFailsWith<WorkerFailure> { client.call(Op.SEARCH, JsonPrimitive("q"), 5_000) }
            assertEquals(WorkerFailure.Kind.CRASHED, failure.kind)
            assertEquals(WorkerFailure.OUT_OF_MEMORY, failure.code)
            assertTrue(withTimeout(5_000) { exited.await() }.outOfMemory)
            assertEquals("worker_out_of_memory", OperationFailures.capture(null, "search", failure).failure.code)
            assertEquals(WorkerLauncher.RAISED_HEAP_MB, WorkerPool.heapFor(id))
            assertTrue(WorkerLauncher(sandboxed = true).command(home, File(home, "x.cs3"), WorkerPool.heapFor(id)!!).contains("-Xmx512m"))
        } finally { WorkerPool.resetForTest(); home.deleteRecursively() }
    }

    @Test fun `stop and caller cancellation do not wait for a blocked writer`() = runBlocking<Unit> {
        val home = Files.createTempDirectory("worker-stop-").toFile()
        val exited = CompletableDeferred<Unit>()
        val client = WorkerClient("blocked-stop", listOf("/bin/sh", "-c", "exec sleep 60"), home,
            solve = { null }, onExit = { _, _, _ -> exited.complete(Unit) })
        try {
            val call = async { client.call(Op.SEARCH, JsonPrimitive("x".repeat(1024 * 1024)), 30_000) }
            delay(200)
            call.cancel()
            val started = System.nanoTime()
            client.stop()
            assertTrue((System.nanoTime() - started) / 1_000_000 < 500)
            withTimeout(4_000) { exited.await(); call.join() }
            assertFalse(client.alive)
            assertEquals(0, client.activeCalls)
        } finally {
            client.kill("test cleanup")
            withTimeout(5_000) { exited.await() }
            home.deleteRecursively()
        }
    }

    @Test fun `process exit cancels owned bridge jobs`() = runBlocking<Unit> {
        val home = Files.createTempDirectory("worker-bridge-").toFile()
        val exited = CompletableDeferred<Unit>()
        val bridgeStarted = CompletableDeferred<Unit>()
        val bridgeCancelled = CompletableDeferred<Unit>()
        val frame = Base64.getEncoder().encodeToString(FrameCodec.encode(Frame(-1, Op.SOLVE,
            FrameCodec.json.parseToJsonElement("""{"targetUrl":"https://fixture.invalid"}"""))))
        val script = """
            import base64,struct,sys,time
            size=struct.unpack('>i',sys.stdin.buffer.read(4))[0]
            sys.stdin.buffer.read(size)
            frame=base64.b64decode(sys.argv[1])
            sys.stdout.buffer.write(struct.pack('>i',len(frame))+frame)
            sys.stdout.buffer.flush()
            time.sleep(60)
        """.trimIndent()
        val client = WorkerClient("bridge-exit", listOf("python3", "-c", script, frame), home,
            solve = {
                bridgeStarted.complete(Unit)
                try { awaitCancellation() } finally { bridgeCancelled.complete(Unit) }
            }, onExit = { _, _, _ -> exited.complete(Unit) })
        try {
            val call = async { runCatching { client.call(Op.SEARCH, JsonNull, 10_000) } }
            withTimeout(3_000) { bridgeStarted.await() }
            client.kill("fixture exit")
            withTimeout(3_000) { exited.await(); bridgeCancelled.await(); call.await() }
            assertEquals(0, client.activeCalls)
        } finally {
            client.kill("test cleanup")
            withTimeout(5_000) { exited.await() }
            home.deleteRecursively()
        }
    }

    @Test fun `writer deadline runs independently of its blocked stream monitor`() {
        val entered = CountDownLatch(1)
        val unblock = CountDownLatch(1)
        val failed = CountDownLatch(1)
        val blocked = object : OutputStream() {
            override fun write(value: Int) {
                entered.countDown()
                unblock.await(3, TimeUnit.SECONDS)
            }
        }
        val writer = FrameWriter(blocked, "fixture-writer", onFailure = {
            failed.countDown()
            unblock.countDown() // Simulates the owner killing the child.
        })
        try {
            writer.send(Frame(1, Op.SEARCH), 100)
            assertTrue(entered.await(1, TimeUnit.SECONDS))
            assertTrue(failed.await(1, TimeUnit.SECONDS))
        } finally { unblock.countDown(); writer.close() }
    }

    @Test fun `valid streamed event bursts preserve every frame in FIFO order`() {
        val count = 500
        val delivered = CountDownLatch(count)
        val bytes = object : ByteArrayOutputStream() {
            override fun flush() { delivered.countDown() }
        }
        val writer = FrameWriter(bytes, "fixture-burst", onFailure = { throw AssertionError(it) })
        try {
            for (id in 1..count) writer.send(Frame(id.toLong(), Op.EVENT, JsonPrimitive("event-$id")))
            assertTrue(delivered.await(3, TimeUnit.SECONDS))
            val input = DataInputStream(ByteArrayInputStream(bytes.toByteArray()))
            for (id in 1..count) {
                val frame = assertNotNull(FrameCodec.read(input))
                assertEquals(id.toLong(), frame.id)
                assertEquals(JsonPrimitive("event-$id"), frame.payload)
            }
            assertNull(FrameCodec.read(input))
        } finally { writer.close() }
    }

    @Test fun `outbound byte budget includes the in flight write`() {
        val entered = CountDownLatch(1)
        val unblock = CountDownLatch(1)
        val failed = CountDownLatch(1)
        val blocked = object : OutputStream() {
            override fun write(value: Int) { entered.countDown(); unblock.await(3, TimeUnit.SECONDS) }
        }
        val writer = FrameWriter(blocked, "fixture-budget", maximumBytes = 128, onFailure = {
            failed.countDown(); unblock.countDown()
        })
        try {
            writer.send(Frame(1, Op.SEARCH))
            assertTrue(entered.await(1, TimeUnit.SECONDS))
            assertFailsWith<IOException> { writer.send(Frame(2, Op.SEARCH, JsonPrimitive("x".repeat(100)))) }
            assertTrue(failed.await(1, TimeUnit.SECONDS))
        } finally { unblock.countDown(); writer.close() }
    }
}
