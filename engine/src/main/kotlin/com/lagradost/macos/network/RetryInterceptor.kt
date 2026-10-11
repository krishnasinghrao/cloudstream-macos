package com.lagradost.macos.network

import okhttp3.Interceptor
import okhttp3.Response
import java.io.IOException
import java.io.InterruptedIOException
import java.net.SocketTimeoutException
import kotlin.random.Random

/**
 * One jittered retry for idempotent requests that failed at the transport
 * layer (connection reset, timeout, DNS hiccup). HTTP error statuses are
 * never retried here — they are the provider's answer, and anti-bot
 * challenges are handled by `SolveInterceptor`.
 */
class RetryInterceptor(
    private val maxRetries: Int = 1,
    private val backoffMs: LongRange = 300L..800L,
    private val sleeper: (Long) -> Unit = { Thread.sleep(it) },
) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        if (request.method !in IDEMPOTENT) return chain.proceed(request)

        var attempt = 0
        while (true) {
            try {
                return chain.proceed(request)
            } catch (e: IOException) {
                // A cancelled call surfaces as InterruptedIOException("Canceled"):
                // never resurrect work the caller abandoned. Timeouts are the
                // exception — they are exactly what a retry is for.
                val cancelled = e is InterruptedIOException && e !is SocketTimeoutException
                if (cancelled || chain.call().isCanceled() || attempt >= maxRetries) throw e
                attempt++
                com.lagradost.macos.DaemonLog.info(
                    "network.retry",
                    mapOf("host" to request.url.host, "attempt" to attempt, "error" to (e.javaClass.simpleName)),
                )
                sleeper(Random.nextLong(backoffMs.first, backoffMs.last + 1))
            }
        }
    }

    companion object {
        private val IDEMPOTENT = setOf("GET", "HEAD", "OPTIONS")
    }
}
