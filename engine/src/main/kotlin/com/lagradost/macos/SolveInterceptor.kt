package com.lagradost.macos

import okhttp3.Interceptor
import okhttp3.Response

/**
 * OkHttp interceptor completing the anti-bot circuit (plan WS-1.3).
 *
 * Installed on every HTTP client providers use (the global `app` and
 * `insecureApp`). For each request:
 *
 * 1. If clearance cookies exist for the host (from a previous solve), inject
 *    them as a Cookie header.
 * 2. If the response is a bot challenge (403/503 + Cloudflare markers), park
 *    the request in [SolveBridge] — the native client's offscreen WebKit runs
 *    the challenge and posts the cookies back — then retry once.
 *
 * Runs on OkHttp worker threads; the bounded park uses `runBlocking`, the
 * same pattern CloudStream's Android-side CloudflareKiller uses.
 */
class SolveInterceptor : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()

        // One retry per request; never re-park a retried request (loop guard).
        if (request.header(RETRY_HEADER) != null) {
            return chain.proceed(request)
        }

        // 1. Pre-inject previously solved cookies for this origin. A cookie
        // the provider set itself (its login) keeps its own value.
        val prepared = SolveBridge.cookieHeaderFor(request.url.toString())
            ?.let { cached -> request.newBuilder().header("Cookie", mergeCookies(request.header("Cookie"), cached, overlayWins = false)).build() }
            ?: request

        val response = chain.proceed(prepared)

        if (!isChallenge(response)) return response

        // A site that keeps challenging even with a fresh clearance (it also
        // checks the TLS fingerprint, for example) is not solved again for a
        // while: parking would only repeat the same failure.
        if (SolveBridge.clearanceRejected(prepared.url.toString())) return response

        // 2. Park the request and wait for the WebKit solver.
        val challengeStatus = response.code
        response.close()

        val remoteSolver = SolveBridge.remoteSolver
        // Clearance is bound to the User-Agent that earned it: the solver
        // presents this request's, which OkHttp fills in when it has none.
        val agent = prepared.header("User-Agent") ?: "okhttp/${okhttp3.OkHttp.VERSION}"
        val cookieHeader = if (!prepared.url.isHttps) {
            // WebKit solver and SolveBridge require an HTTPS origin; skip solving for plain HTTP.
            null
        } else if (remoteSolver != null) {
            // Worker process: the control plane parks the challenge; cookies come back only to us.
            runCatching { kotlinx.coroutines.runBlocking { remoteSolver(prepared.url.toString(), agent) } }.getOrNull()
                // Invalid clearance bytes are neither cached nor sent.
                ?.takeIf { cookies -> runCatching { SolveBridge.applySolvedCookies(prepared.url.toString(), cookies) }.isSuccess }
        } else {
            val task = SolveBridge.newTask(prepared.url.toString(), agent)
            val solution = kotlinx.coroutines.runBlocking { SolveBridge.awaitSolution(task) }
            (solution?.cookies ?: SolveBridge.cookieHeaderFor(prepared.url.toString()))
                ?.takeIf(SolveBridge::validCookieHeader)
        }

        return if (cookieHeader != null) {
            DaemonLog.info("solve.retry", mapOf("host" to prepared.url.host))
            val retried = chain.proceed(
                prepared.newBuilder()
                    // Same request, same origin: the provider's session cookies
                    // stay; only the cookies the solver returned are replaced.
                    .header("Cookie", mergeCookies(prepared.header("Cookie"), cookieHeader, overlayWins = true))
                    .header(RETRY_HEADER, "1")
                    .build(),
            )
            if (isChallenge(retried)) {
                SolveBridge.rejectClearance(prepared.url.toString())
                DaemonLog.warn("solve.clearance_rejected", mapOf("host" to prepared.url.host))
            }
            retried
        } else {
            // Solver unavailable/timed out — proceed without clearance; the
            // caller sees the challenge page and the provider barrier reports it.
            DaemonLog.warn(
                "solve.unavailable",
                mapOf("host" to prepared.url.host, "status" to challengeStatus),
            )
            chain.proceed(prepared)
        }
    }

    private fun isChallenge(response: Response): Boolean {
        if (response.code != 403 && response.code != 503) return false
        val server = response.header("server")?.lowercase().orEmpty()
        val via = response.header("via")?.lowercase().orEmpty()
        if ("cloudflare" !in server && "cloudflare" !in via) return false
        return try {
            val body = response.peekBody(128 * 1024).string()
            CHALLENGE_MARKERS.any { it in body }
        } catch (_: Exception) {
            true // status + server markers alone are enough to try solving
        }
    }

    companion object {
        private const val RETRY_HEADER = "X-CS-Solve-Retry"

        /**
         * Merges two Cookie headers by cookie name, keeping [base] order. A
         * name present in both takes the [overlay] value when [overlayWins].
         * Parts of [base] that are not `name=value` are kept as they are.
         */
        internal fun mergeCookies(base: String?, overlay: String, overlayWins: Boolean): String {
            fun parts(header: String) = header.split(';').map { it.trim() }.filter { it.isNotEmpty() }
            fun name(part: String) = part.substringBefore('=', "").takeIf { '=' in part && it.isNotEmpty() }
            val overlayParts = parts(overlay)
            val overlayByName = overlayParts.mapNotNull { part -> name(part)?.let { it to part } }.toMap(LinkedHashMap())
            val used = HashSet<String>()
            val merged = ArrayList<String>()
            for (part in base?.let(::parts).orEmpty()) {
                val key = name(part)
                val replacement = key?.let(overlayByName::get)
                if (key != null && !used.add(key)) continue
                merged += if (replacement != null && overlayWins) replacement else part
            }
            for (part in overlayParts) {
                val key = name(part) ?: continue
                if (used.add(key)) merged += part
            }
            return merged.joinToString("; ")
        }

        private val CHALLENGE_MARKERS = listOf(
            "cf-browser-verification",
            "cf_chl_opt",
            "cf-challenge",
            "challenge-platform",
            "just a moment",
            "cf-turnstile",
            "checking if the site connection is secure",
        )
    }
}
