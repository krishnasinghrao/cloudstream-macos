package com.lagradost.macos.worker

import java.io.BufferedOutputStream
import java.io.DataOutputStream
import java.io.IOException
import java.io.OutputStream
import java.util.ArrayDeque
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * One ordered, byte-bounded writer. Producers never perform pipe IO, and a
 * deadline thread never acquires the output stream's monitor. The owner must
 * terminate the process on failure to unblock a pipe that no longer drains.
 */
internal class FrameWriter(
    output: OutputStream,
    name: String,
    private val onFailure: (Exception) -> Unit,
    private val maximumBytes: Long = 2L * (FrameCodec.MAX_FRAME_BYTES + 4),
    // Tiny streamed link events can legitimately arrive in a burst. The byte
    // cap is the primary budget; this cap bounds object/timer overhead too.
    private val maximumFrames: Int = 4_096,
) : AutoCloseable {
    private class Write(val bytes: ByteArray) {
        // pending / delivered / expired; delivery and the watchdog race once.
        val state = AtomicInteger(0)
        var timeout: ScheduledFuture<*>? = null
    }

    // wait()/notifyAll() need a java.lang.Object monitor, which Kotlin's Any does not expose.
    @Suppress("PLATFORM_CLASS_MAPPED_TO_KOTLIN")
    private val lock = Object()
    private val queue = ArrayDeque<Write>()
    private val closed = AtomicBoolean(false)
    private val failed = AtomicBoolean(false)
    private var retainedBytes = 0L
    private var retainedFrames = 0
    private val deadlines = Executors.newSingleThreadScheduledExecutor { action ->
        Thread(action, "$name-deadlines").apply { isDaemon = true }
    }
    private val stream = DataOutputStream(BufferedOutputStream(output))
    private val thread = Thread({ drain() }, name).apply { isDaemon = true; start() }

    /** Budget includes serialization and waiting behind earlier frames. */
    fun send(frame: Frame, budgetMs: Long = MAX_WRITE_MS) {
        val started = System.nanoTime()
        check(!closed.get()) { "Worker writer is closed" }
        val write = Write(FrameCodec.encode(frame))
        val remaining = TimeUnit.MILLISECONDS.toNanos(budgetMs.coerceIn(1, MAX_WRITE_MS)) - (System.nanoTime() - started)
        synchronized(lock) {
            check(!closed.get()) { "Worker writer is closed" }
            if (remaining <= 0 || retainedBytes + write.bytes.size + 4 > maximumBytes || retainedFrames >= maximumFrames) {
                val failure = IOException("Worker outbound deadline or capacity exceeded")
                fault(failure)
                throw failure
            }
            retainedBytes += write.bytes.size + 4
            retainedFrames++
            write.timeout = deadlines.schedule({
                if (write.state.compareAndSet(0, 2)) fault(IOException("Worker protocol pipe did not drain in time"))
            }, remaining, TimeUnit.NANOSECONDS)
            queue.addLast(write)
            lock.notifyAll()
        }
    }

    private fun fault(failure: Exception) {
        if (!closed.get() && failed.compareAndSet(false, true)) onFailure(failure)
    }

    private fun drain() {
        try {
            while (true) {
                val write = synchronized(lock) {
                    while (queue.isEmpty() && !closed.get()) lock.wait()
                    if (closed.get()) return
                    queue.removeFirst()
                }
                try {
                    FrameCodec.write(stream, write.bytes)
                    write.state.compareAndSet(0, 1)
                } finally {
                    write.timeout?.cancel(false)
                    synchronized(lock) {
                        retainedBytes -= write.bytes.size + 4
                        retainedFrames--
                    }
                }
            }
        } catch (_: InterruptedException) {
            // Explicit lifecycle closure. The owner kills a blocked process.
        } catch (failure: Exception) {
            fault(failure)
        } finally {
            close()
            // Only this thread ever closes the buffered output stream. Neither
            // stop nor a timeout waits for a monitor held by a blocked write.
            runCatching { stream.close() }
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        synchronized(lock) {
            queue.forEach { it.timeout?.cancel(false) }
            queue.clear()
            lock.notifyAll()
        }
        deadlines.shutdownNow()
        thread.interrupt()
    }

    companion object {
        private const val MAX_WRITE_MS = 5_000L
    }
}
