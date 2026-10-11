package com.lagradost.macos.network

import com.lagradost.macos.DaemonLog
import okhttp3.Interceptor
import okhttp3.MediaType
import okhttp3.Response
import okhttp3.ResponseBody
import okio.Buffer
import okio.BufferedSource
import okio.ForwardingSource
import okio.buffer
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * Reclaims response bodies extensions forget to close (Remediation 5.1).
 * Scrapers often read a response's headers or part of its body and drop it;
 * OkHttp then holds the connection until the body is garbage collected and
 * logs "A connection to … was leaked", while the worker runs out of sockets.
 *
 * Every response body passing [interceptor] is tracked until it is closed or
 * fully read. Calls overlap in a worker, so a body cannot be attributed to one
 * of them; instead, whenever the last operation in flight finishes
 * ([operationStarted] / [operationFinished]), every body still open belongs
 * to no live operation and is closed, which returns its connection.
 */
object ResponseTracker {
    private val open = ConcurrentHashMap<Long, TrackedBody>()
    private val ids = AtomicLong()
    private val inFlight = AtomicInteger()
    /** Reclaimed since start (diagnostics and tests). */
    val reclaimed = AtomicLong()

    val openBodies: Int get() = open.size

    val interceptor = Interceptor { chain ->
        val response = chain.proceed(chain.request())
        val body = response.body
        val id = ids.incrementAndGet()
        val tracked = TrackedBody(id, body)
        open[id] = tracked
        response.newBuilder().body(tracked).build()
    }

    fun operationStarted() {
        inFlight.incrementAndGet()
    }

    fun operationFinished() {
        if (inFlight.decrementAndGet() > 0) return
        val leftovers = open.values.toList()
        if (leftovers.isEmpty()) return
        leftovers.forEach { it.close() }
        reclaimed.addAndGet(leftovers.size.toLong())
        DaemonLog.info("network.responses_reclaimed", mapOf("count" to leftovers.size))
    }

    /** Runs [block] as one tracked operation. */
    suspend fun <T> operation(block: suspend () -> T): T {
        operationStarted()
        try { return block() } finally { operationFinished() }
    }

    internal fun resetForTest() {
        open.values.toList().forEach { it.close() }
        open.clear()
        inFlight.set(0)
        reclaimed.set(0)
    }

    private class TrackedBody(private val id: Long, private val delegate: ResponseBody) : ResponseBody() {
        private val source: BufferedSource by lazy {
            object : ForwardingSource(delegate.source()) {
                override fun read(sink: Buffer, byteCount: Long): Long {
                    val read = try { super.read(sink, byteCount) } catch (failure: java.io.IOException) {
                        open.remove(id); throw failure
                    }
                    if (read == -1L) open.remove(id) // Fully read: OkHttp already released the connection.
                    return read
                }

                override fun close() {
                    open.remove(id)
                    super.close()
                }
            }.buffer()
        }

        override fun contentType(): MediaType? = delegate.contentType()
        override fun contentLength(): Long = delegate.contentLength()
        override fun source(): BufferedSource = source

        override fun close() {
            open.remove(id)
            // Closing an unread body closes the underlying stream and frees the connection.
            runCatching { delegate.close() }
        }
    }
}
