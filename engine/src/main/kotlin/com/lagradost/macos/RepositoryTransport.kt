package com.lagradost.macos

import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withTimeout
import okhttp3.*
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.InetAddress
import java.net.Proxy
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal data class RepositoryDocument(val bytes: ByteArray, val effectiveUrl: String) {
    fun text(): String = Charsets.UTF_8.newDecoder()
        .onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
        .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT)
        .decode(java.nio.ByteBuffer.wrap(bytes)).toString()
}

internal fun interface RepositoryFetcher {
    suspend fun fetch(url: String, maxBytes: Int): RepositoryDocument

    /**
     * Where [url] redirects to, whatever that final address answers. Shortcode
     * resolution needs only the target: a host may refuse plain downloads of it
     * (Codeberg raw) yet serve it through another interface.
     */
    suspend fun resolve(url: String): String = fetch(url, RepositoryTransport.MAX_MANIFEST_BYTES).effectiveUrl
}

/** Repository traffic never uses a plugin's mutable nicehttp client. Every
 * redirect repeats URL and connect-time DNS validation. No proxy or cookie jar
 * can silently route a repository request to a different security context. */
internal class RepositoryTransport(
    private val baseClient: OkHttpClient? = null,
    private val addressAllowed: (InetAddress) -> Boolean = ::isPublicAddress,
) : RepositoryFetcher, java.io.Closeable {
    private val permits = Semaphore(LANES)
    private val executor = java.util.concurrent.ThreadPoolExecutor(LANES, LANES, 30, TimeUnit.SECONDS,
        java.util.concurrent.ArrayBlockingQueue(4 * LANES), java.util.concurrent.ThreadFactory { action ->
            Thread(action, "repository-http").apply { isDaemon = true }
        }, java.util.concurrent.ThreadPoolExecutor.AbortPolicy()).apply { allowCoreThreadTimeOut(true) }
    private val dispatcher = Dispatcher(executor).apply { maxRequests = Int.MAX_VALUE; maxRequestsPerHost = Int.MAX_VALUE }
    @Volatile private var snapshot: Pair<OkHttpClient, OkHttpClient>? = null
    @Volatile private var closed = false

    @Synchronized private fun clientForPolicy(): OkHttpClient {
        check(!closed) { "Repository transport is closed" }
        val base = baseClient ?: NetworkSetup.repositoryClient()
        snapshot?.takeIf { it.first === base }?.let { return it.second }
        snapshot?.second?.connectionPool?.evictAll()
        return boundedClient(base).also { snapshot = base to it }
    }

    private fun boundedClient(baseClient: OkHttpClient) = baseClient.newBuilder()
        .dispatcher(dispatcher).connectionPool(ConnectionPool(LANES, 2, TimeUnit.MINUTES))
        .followRedirects(false).followSslRedirects(false)
        .retryOnConnectionFailure(false).proxy(Proxy.NO_PROXY)
        .cookieJar(CookieJar.NO_COOKIES).cache(null)
        .authenticator(Authenticator.NONE).proxyAuthenticator(Authenticator.NONE)
        .connectTimeout(10, TimeUnit.SECONDS).readTimeout(15, TimeUnit.SECONDS)
        .callTimeout(30, TimeUnit.SECONDS)
        .dns { hostname ->
            val addresses = baseClient.dns.lookup(hostname)
            if (addresses.isEmpty() || addresses.any { !addressAllowed(it) }) {
                throw IOException("Repository hostname resolves to a restricted address")
            }
            addresses
        }.build()

    override fun close() {
        closed = true
        dispatcher.cancelAll()
        executor.shutdownNow()
        snapshot?.second?.connectionPool?.evictAll()
    }

    override suspend fun resolve(url: String): String {
        val client = clientForPolicy()
        return withTimeout(30_000) {
            permits.withPermit {
                var current = checkedUrl(url)
                repeat(6) {
                    val reply = request(client, current, MAX_MANIFEST_BYTES, null, readBody = false)
                    val location = reply.location ?: return@withPermit current.toString()
                    current = checkedUrl(upgraded(current.resolve(location) ?: throw IOException("Invalid repository redirect")).toString())
                }
                throw IOException("Too many repository redirects")
            }
        }
    }

    override suspend fun fetch(url: String, maxBytes: Int): RepositoryDocument {
        require(maxBytes in 1..MAX_RESPONSE_BYTES)
        val client = clientForPolicy()
        // The optional jsDelivr mirror (N2) changes only where bytes come from:
        // the document keeps its original address as its identity.
        val mirror = if (com.lagradost.macos.network.GitHubMirror.enabled) com.lagradost.macos.network.GitHubMirror.mirrorOf(url) else null
        return withTimeout(60_000) {
            permits.withPermit {
                var current = checkedUrl(mirror ?: url)
                val visited = mutableSetOf<String>()
                var redirects = 0
                var solved = false
                while (true) {
                    check(visited.add(current.toString()) || solved) { "Repository redirect cycle" }
                    val cookie = SolveBridge.cookieHeaderFor(current.toString())
                    val reply = request(client, current, maxBytes, cookie)
                    if (reply.location != null) {
                        check(redirects++ < 5) { "Too many repository redirects" }
                        val target = current.resolve(reply.location) ?: throw IOException("Invalid repository redirect")
                        current = checkedUrl(upgraded(target).toString())
                        solved = false
                        continue
                    }
                    if (reply.challenge && !solved) {
                        val task = SolveBridge.newTask(current.toString())
                        val solution = SolveBridge.awaitSolution(task)
                            ?: throw IOException("Repository challenge was not solved")
                        check(solution.cookies.isNotBlank())
                        solved = true
                        continue
                    }
                    if (reply.status != 200) throw RemoteHttpException(reply.status, current.toString())
                    return@withPermit RepositoryDocument(reply.bytes, if (mirror != null) url else current.toString())
                }
                @Suppress("UNREACHABLE_CODE") error("unreachable")
            }
        }
    }

    private data class Reply(val status: Int, val bytes: ByteArray, val location: String?, val challenge: Boolean)

    private suspend fun request(client: OkHttpClient, url: HttpUrl, limit: Int, cookie: String?,
        readBody: Boolean = true): Reply = suspendCancellableCoroutine { continuation ->
        val request = Request.Builder().url(url).header("User-Agent", "CloudStream-macOS/1")
            // Explicit identity encoding makes compressed and expanded budgets
            // identical. Unexpected content encodings are rejected, not inflated.
             .header("Accept-Encoding", "identity").apply {
                // Only clearance the user's own challenge solve produced for this origin;
                // no host gets a hard-coded header or cookie (RT-09).
                if (cookie != null) header("Cookie", cookie)
            }.build()
        val call = client.newCall(request)
        continuation.invokeOnCancellation { call.cancel() }
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) { continuation.resumeWithException(e) }
            override fun onResponse(call: Call, response: Response) {
                try {
                    val reply = response.use {
                        if (it.code in REDIRECTS) {
                            val location = it.header("Location") ?: throw IOException("Redirect has no Location")
                            Reply(it.code, byteArrayOf(), location, false)
                        } else {
                            val challenge = it.code in setOf(403, 503) && it.header("Server").orEmpty().contains("cloudflare", true)
                            if (it.code != 200 || !readBody) Reply(it.code, byteArrayOf(), null, challenge)
                            else {
                                val encoding = it.header("Content-Encoding")
                                if (encoding != null && !encoding.equals("identity", true)) throw IOException("Unsupported repository content encoding")
                                val body = it.body
                                if (body.contentLength() > limit) throw IOException("Repository response exceeds byte limit")
                                val capacity = body.contentLength().takeIf { size -> size in 0..limit.toLong() }?.toInt() ?: minOf(limit, 8192)
                                val output = ByteArrayOutputStream(capacity)
                                body.byteStream().use { input ->
                                    val buffer = ByteArray(8192)
                                    while (true) {
                                        val count = input.read(buffer)
                                        if (count == -1) break
                                        if (count > limit - output.size()) throw IOException("Repository response exceeds byte limit")
                                        output.write(buffer, 0, count)
                                    }
                                }
                                Reply(it.code, output.toByteArray(), null, false)
                            }
                        }
                    }
                    continuation.resume(reply)
                } catch (failure: Exception) { continuation.resumeWithException(failure) }
            }
        })
    }

    private fun checkedUrl(raw: String): HttpUrl {
        val url = requireHttpsUrl(raw)
        // Every hop, including redirect targets, is held to the blocklist (M5).
        DaemonRuntime.policy.requireAddressNotBlocked(url.toString())
        // OkHttp skips Dns.lookup for literals; enforce the same policy here.
        if (url.host.contains(':') || url.host.all { it in '0'..'9' || it == '.' }) {
            require(addressAllowed(InetAddress.getByName(url.host))) { "Restricted repository address" }
        }
        return url
    }

    companion object {
        /** Concurrent repository requests. */
        const val LANES = 4
        const val MAX_RESPONSE_BYTES = 48 * 1024 * 1024
        const val MAX_MANIFEST_BYTES = 2 * 1024 * 1024
        const val MAX_LIST_BYTES = 8 * 1024 * 1024
        const val MAX_ARTIFACT_BYTES = 32 * 1024 * 1024
        private val REDIRECTS = setOf(301, 302, 303, 307, 308)

        /**
         * The HTTPS form of a plain-HTTP address (same host and path; the
         * default port becomes 443). Repository traffic never falls back to HTTP:
         * a host without HTTPS simply fails.
         */
        fun upgraded(url: HttpUrl): HttpUrl =
            if (url.scheme != "http") url
            else url.newBuilder().scheme("https").apply { if (url.port == 80) port(443) }.build()

        fun requireHttpsUrl(raw: String): HttpUrl {
            require(raw.length <= 8192 && raw.none { it.code < 32 || it == '\\' }) { "Invalid repository URL" }
            val url = raw.toHttpUrlOrNull() ?: throw IllegalArgumentException("Invalid repository URL")
            require(url.isHttps && url.username.isEmpty() && url.password.isEmpty() && url.fragment == null) {
                "Repository URL must use HTTPS without credentials or a fragment"
            }
            return url
        }

        // Conservative repository destination policy, checked against IANA:
        // https://www.iana.org/assignments/iana-ipv4-special-registry/
        // https://www.iana.org/assignments/iana-ipv6-special-registry/
        fun isPublicAddress(address: InetAddress): Boolean {
            if (address.isAnyLocalAddress || address.isLoopbackAddress || address.isLinkLocalAddress ||
                address.isSiteLocalAddress || address.isMulticastAddress) return false
            val b = address.address.map { it.toInt() and 255 }
            return when (b.size) {
                4 -> !(b[0] == 0 || b[0] >= 224 || b[0] == 100 && b[1] in 64..127 ||
                    b[0] == 192 && (b[1] == 168 || b[1] == 0 && b[2] in setOf(0, 2) || b[1] == 88 && b[2] == 99) ||
                    b[0] == 198 && (b[1] in 18..19 || b[1] == 51 && b[2] == 100) ||
                    b[0] == 203 && b[1] == 0 && b[2] == 113)
                // Only ordinary global unicast; exclude transition/tunnel and
                // documentation ranges that can embed restricted IPv4 targets.
                16 -> b[0] in 0x20..0x3f && !(b[0] == 0x3f && b[1] == 0xff && b[2] < 16) &&
                    !(b[0] == 0x20 && b[1] == 0x02) &&
                    !(b[0] == 0x20 && b[1] == 0x01 && (b[2] < 2 || b[2] == 0x0d && b[3] == 0xb8))
                else -> false
            }
        }
    }
}
