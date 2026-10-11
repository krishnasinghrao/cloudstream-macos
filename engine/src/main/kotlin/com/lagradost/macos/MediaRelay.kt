package com.lagradost.macos

import com.lagradost.cloudstream3.USER_AGENT
import com.lagradost.cloudstream3.app
import io.ktor.http.ContentType
import io.ktor.http.Headers
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.OutgoingContent
import io.ktor.server.application.ApplicationCall
import io.ktor.server.response.respond
import io.ktor.utils.io.ByteWriteChannel
import io.ktor.utils.io.writeFully
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.CookieJar
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.net.URI
import java.security.SecureRandom
import java.util.HexFormat
import java.util.Locale
import java.util.concurrent.TimeUnit

/**
 * Session-scoped transport for split streams whose video and audio need
 * different request headers (audit A35). The native player sends one header
 * set to every resource of a merged stream; here each registered resource is
 * fetched with its own headers and the player reads it from this listener.
 *
 * Deliberately narrow:
 *  * only resources registered by the authenticated client, each a validated
 *    HTTP(S) URL with validated headers — never a URL taken from the request;
 *  * an unguessable id per resource is the only way to read one, and it stops
 *    working when the session is revoked, expires or the engine exits;
 *  * the player contributes nothing but `Range`; its own headers are ignored;
 *  * an HLS playlist or DASH manifest is rewritten (ManifestRewriter) so every
 *    URL it names is read through the relay as well: each becomes a path under
 *    a session-scoped directory resource, which reads only below that
 *    directory, with the registered headers (credentials only on the same
 *    origin). A manifest that cannot be expressed that way is refused;
 *  * media bytes are streamed with a fixed buffer, never collected, and each
 *    chunk is flushed so the player gets its first bytes at once.
 */
internal object MediaRelay {
    /** One player session plus parallel credentialed downloads (each relayed, audit A2). */
    const val MAX_SESSIONS = 12
    /** One video plus the player's limit of 32 audio tracks. */
    const val MAX_RESOURCES = 33
    /** Since the last open stream ended; a session with an open stream never expires or is evicted. */
    const val IDLE_LIFETIME_MS = 15 * 60 * 1000L
    private const val MIN_EVICTION_IDLE_MS = 60 * 1000L
    /** A session registered but never read (its client went away first, audit M6) may be evicted sooner. */
    internal const val NEVER_READ_EVICTION_MS = 10 * 1000L
    private const val MAX_REDIRECTS = 5
    private const val BUFFER_BYTES = 64 * 1024
    const val PATH_PREFIX = "/media/relay/"
    /** Directory resources one session's manifests may create. */
    const val MAX_DIRECTORIES = 64
    private const val MAX_MANIFEST_BYTES = 8L * 1024 * 1024

    /** [directory]: a URL prefix ending in `/`, read as `<path>/<rest under it>`. */
    class Resource(val url: String, val headers: Map<String, String>, val directory: Boolean = false)
    private class Session(val resources: MutableList<String>, @Volatile var lastUsed: Long, var openStreams: Int = 0,
                          val directories: MutableMap<String, String> = HashMap(),
                          /** Set by the first read of any of its resources. */
                          @Volatile var everRead: Boolean = false)

    private val random = SecureRandom()
    private val sessions = LinkedHashMap<String, Session>()
    private val resources = HashMap<String, Pair<String, Resource>>()   // resource id -> (session id, resource)
    internal var now: () -> Long = System::currentTimeMillis
    /** Tests supply a client that trusts their fixture; production derives one per request. */
    internal var clientOverride: OkHttpClient? = null

    class Registration(val sessionId: String, val paths: List<String>)

    /** Null when every session slot is in use by an active session. */
    fun register(requested: List<Resource>): Registration? {
        require(requested.isNotEmpty() && requested.size <= MAX_RESOURCES) { "resources" }
        requested.forEach {
            MediaResourcePolicy.remoteURL(it.url)
            MediaResourcePolicy.headers(it.headers)
            checkHostAllowed(it.url)
        }
        synchronized(sessions) {
            expire()
            if (sessions.size >= MAX_SESSIONS) {
                val evictable = sessions.filterValues {
                    it.openStreams == 0 && now() - it.lastUsed >= (if (it.everRead) MIN_EVICTION_IDLE_MS else NEVER_READ_EVICTION_MS)
                }
                val oldest = evictable.minByOrNull { it.value.lastUsed }
                if (oldest != null) {
                    revoke(oldest.key)
                } else {
                    return null
                }
            }
            val sessionId = token()
            val ids = requested.map { resource -> token().also { resources[it] = sessionId to resource } }
            sessions[sessionId] = Session(ids.toMutableList(), now())
            return Registration(sessionId, ids.map { PATH_PREFIX + it })
        }
    }

    fun revoke(sessionId: String) {
        synchronized(sessions) { sessions.remove(sessionId)?.resources?.forEach(resources::remove) }
    }

    val activeSessions: Int get() = synchronized(sessions) { expire(); sessions.size }

    internal fun reset() = synchronized(sessions) { sessions.clear(); resources.clear() }

    private fun expire() {
        val cutoff = now() - IDLE_LIFETIME_MS
        sessions.entries.filter { it.value.openStreams == 0 && it.value.lastUsed < cutoff }.forEach { (id, session) ->
            sessions.remove(id); session.resources.forEach(resources::remove)
        }
    }

    private fun lookup(id: String): Pair<String, Resource>? = synchronized(sessions) {
        expire()
        val entry = resources[id] ?: return null
        sessions[entry.first]?.let { it.lastUsed = now(); it.everRead = true }
        entry
    }

    /**
     * The relay path that reads [url] for session [sessionId]: a directory
     * resource for the URL's directory (created once per directory and header
     * set) plus the rest of the URL. Headers follow the redirect rule:
     * credentials only on [owner]'s origin.
     */
    private fun pathFor(sessionId: String, url: String, headers: Map<String, String>, owner: String): String {
        MediaResourcePolicy.remoteURL(url)
        checkHostAllowed(url)
        val uri = URI(url)
        val path = uri.rawPath.orEmpty().ifEmpty { "/" }
        val directory = path.substring(0, path.lastIndexOf('/') + 1)
        val base = "${uri.scheme.lowercase(Locale.ROOT)}://${uri.rawAuthority}$directory"
        val rest = path.substring(directory.length) + (uri.rawQuery?.let { "?$it" } ?: "")
        val inherited = if (origin(uri) == origin(URI(owner))) headers else headers.filterKeys { it.lowercase(Locale.ROOT) in shareable }
        synchronized(sessions) {
            val session = sessions[sessionId] ?: throw RejectedMediaResourceException("session")
            val key = base + "\n" + inherited.entries.sortedBy { it.key }.joinToString("\n")
            val id = session.directories[key] ?: run {
                if (session.directories.size >= MAX_DIRECTORIES) throw RejectedMediaResourceException("directories")
                token().also {
                    resources[it] = sessionId to Resource(base, inherited, directory = true)
                    session.resources += it
                    session.directories[key] = it
                }
            }
            return "$PATH_PREFIX$id/$rest"
        }
    }

    /** [rest] (raw path and query) under directory resource [base]; null when it would leave it. */
    private fun under(base: String, rest: String): String? {
        if (rest.isEmpty() || '#' in rest) return null
        // Servers decode before resolving, so an encoded dot segment or
        // separator would leave the directory there even though it does not
        // here: refuse any segment that decodes to one.
        val segments = rest.substringBefore('?').split('/')
        if (segments.any { segment ->
                val decoded = runCatching { java.net.URLDecoder.decode(segment.replace("+", "%2B"), Charsets.UTF_8) }.getOrNull()
                decoded == null || decoded == "." || decoded == ".." || '/' in decoded || '\\' in decoded
            }) return null
        val target = runCatching { URI(base + rest).normalize() }.getOrNull() ?: return null
        val resolved = target.toString()
        return resolved.takeIf { it.startsWith(base) && target.rawPath?.contains("/../") != true }
    }

    /** Marks a response streaming from resource [id]; while one is open its session stays alive. */
    private fun streaming(id: String, open: Boolean) = synchronized(sessions) {
        val session = resources[id]?.first?.let(sessions::get) ?: return@synchronized
        session.openStreams += if (open) 1 else -1
        session.lastUsed = now()
    }

    private fun token(): String = HexFormat.of().formatHex(ByteArray(32).also(random::nextBytes))

    // ---- Serving

    /** Not credentials: may follow a redirect to another origin. */
    private val shareable = setOf("user-agent", "referer", "origin", "accept", "accept-language")
    private val passedThrough = listOf("Content-Range", "Accept-Ranges", "ETag", "Last-Modified")
    private val rangePattern = Regex("""bytes=\d*-\d*""")

    internal var addressAllowed: (java.net.InetAddress) -> Boolean =
        // End-to-end tests run their origin on loopback; only whoever starts
        // the engine can set this, and they already control what it does.
        if (System.getProperty("cs.test.relayAllowsLoopback") == "true") { address -> address.isLoopbackAddress || RepositoryTransport.isPublicAddress(address) }
        else RepositoryTransport::isPublicAddress

    internal fun client(): OkHttpClient = clientOverride ?: app.baseClient.newBuilder().apply {
        // The connection pool and resolver are shared; provider interceptors,
        // the response cache and cookies are not part of a media byte fetch.
        interceptors().clear()
        networkInterceptors().clear()
        cache(null)
        cookieJar(CookieJar.NO_COOKIES)
        // The engine runs with useSystemProxies (N1). Through an HTTP proxy or
        // PAC file OkHttp never resolves the target, which would skip the
        // address check below (L2): media fetches always connect directly.
        proxy(java.net.Proxy.NO_PROXY)
        followRedirects(false)
        followSslRedirects(false)
        connectTimeout(15, TimeUnit.SECONDS)
        readTimeout(30, TimeUnit.SECONDS)
        callTimeout(0, TimeUnit.SECONDS)
        // SEC-02: DNS validation against private, loopback and link-local addresses (SSRF defense)
        dns { hostname ->
            val addresses = app.baseClient.dns.lookup(hostname)
            if (addresses.isEmpty() || addresses.any { !addressAllowed(it) }) {
                throw RejectedMediaResourceException("restricted destination address")
            }
            addresses
        }
    }.build()

    private fun origin(uri: URI): String {
        val scheme = uri.scheme.lowercase(Locale.ROOT)
        return "$scheme://${uri.host.lowercase(Locale.ROOT)}:${if (uri.port != -1) uri.port else if (scheme == "https") 443 else 80}"
    }


    /** Fetches `resource`, following only valid HTTP(S) redirects. The caller closes the response. */
    private fun open(resource: Resource, head: Boolean, range: String?): Response {
        val http = client()
        var url = resource.url
        var headers = resource.headers
        val firstOrigin = origin(URI(url))
        repeat(MAX_REDIRECTS + 1) {
            val request = Request.Builder().url(url).apply {
                if (head) head()
                if (headers.keys.none { it.equals("User-Agent", ignoreCase = true) }) header("User-Agent", USER_AGENT)
                headers.forEach { (name, value) -> header(name, value) }
                // Exact bytes: ranges and lengths must describe what is relayed.
                header("Accept-Encoding", "identity")
                range?.let { header("Range", it) }
            }.build()
            val response = http.newCall(request).execute()
            if (response.code !in setOf(301, 302, 303, 307, 308)) return response
            val location = response.header("Location")
            response.close()
            val next = location?.let { runCatching { URI(url).resolve(it).toString() }.getOrNull() }
                ?: throw RejectedMediaResourceException("redirect")
            MediaResourcePolicy.remoteURL(next, "redirect")
            checkHostAllowed(next)
            if (origin(URI(next)) != firstOrigin) headers = headers.filterKeys { it.lowercase(Locale.ROOT) in shareable }
            url = next
        }
        throw RejectedMediaResourceException("redirect")
    }

    private fun checkHostAllowed(rawUrl: String) {
        if (clientOverride != null) return
        val uri = runCatching { URI(rawUrl) }.getOrNull() ?: throw RejectedMediaResourceException("url")
        val host = uri.host ?: throw RejectedMediaResourceException("host")
        if (host.contains(':') || host.all { it in '0'..'9' || it == '.' }) {
            val addr = runCatching { java.net.InetAddress.getByName(host) }.getOrNull()
                ?: throw RejectedMediaResourceException("invalid address")
            if (!addressAllowed(addr)) {
                throw RejectedMediaResourceException("restricted destination address")
            }
        }
    }

    /** [rest]: the raw path and query below a directory resource, or null for a registered resource itself. */
    suspend fun serve(call: ApplicationCall, id: String, head: Boolean, rest: String? = null) {
        val (sessionId, registered) = lookup(id) ?: run { call.respond(HttpStatusCode.NotFound, ""); return }
        val resource = when {
            rest == null && !registered.directory -> registered
            rest != null && registered.directory -> under(registered.url, rest)?.let { Resource(it, registered.headers) }
            else -> null
        } ?: run { call.respond(HttpStatusCode.NotFound, ""); return }
        // A manifest is rewritten whole: the player's range (ffmpeg asks for
        // bytes=0-) is not forwarded for one.
        val range = call.request.headers["Range"]?.takeIf { rangePattern.matches(it) }
            ?.takeIf { ManifestRewriter.kind(resource.url, null) == null }
        var response = try {
            withContext(Dispatchers.IO) { open(resource, head, range) }
        } catch (failure: Exception) {
            if (failure is kotlinx.coroutines.CancellationException) throw failure
            DaemonLog.warn("relay.upstream_failed", mapOf("error" to failure.javaClass.simpleName))
            call.respond(HttpStatusCode.BadGateway, ""); return
        }
        val encoding = response.header("Content-Encoding")?.lowercase(Locale.ROOT)
        val manifest = ManifestRewriter.kind(response.request.url.toString(), response.header("Content-Type"))
            ?: ManifestRewriter.kind(resource.url, response.header("Content-Type"))
        val refused = when {
            encoding != null && encoding != "identity" -> HttpStatusCode.BadGateway
            else -> null
        }
        if (refused != null) {
            response.close()
            DaemonLog.warn("relay.refused", mapOf("status" to refused.value))
            call.respond(refused, ""); return
        }
        if (manifest != null && response.code == 206) {
            // Recognised only by its content type: fetch it whole.
            response.close()
            response = try {
                withContext(Dispatchers.IO) { open(resource, head, null) }
            } catch (failure: Exception) {
                if (failure is kotlinx.coroutines.CancellationException) throw failure
                call.respond(HttpStatusCode.BadGateway, ""); return
            }
        }
        if (manifest != null && head && response.code == 200) {
            // A HEAD carries no body to rewrite: answer with the manifest type
            // and no length (the rewritten size is unknown until it is read).
            response.close()
            call.respond(object : OutgoingContent.NoContent() {
                override val status = HttpStatusCode.OK
                override val contentType = manifestType(manifest)
            })
            return
        }
        if (manifest != null && response.code == 200) {
            serveManifest(call, response, manifest, sessionId, resource, head)
            return
        }
        if (manifest != null) {
            response.close()
            call.respond(if (response.code in setOf(200, 206)) HttpStatusCode.UnsupportedMediaType else HttpStatusCode.fromValue(response.code), "")
            return
        }
        val status = HttpStatusCode.fromValue(response.code)
        val length = response.header("Content-Length")?.toLongOrNull()?.takeIf { it >= 0 }
        val type = response.header("Content-Type")?.let { runCatching { ContentType.parse(it) }.getOrNull() }
        val extra = Headers.build { passedThrough.forEach { name -> response.header(name)?.let { append(name, it) } } }
        // Error statuses carry no upstream body: nothing a provider page says
        // is forwarded to the player.
        if (head || response.code !in setOf(200, 206)) {
            response.close()
            call.respond(object : OutgoingContent.NoContent() {
                override val status = status
                override val headers = extra
                override val contentType = type
                override val contentLength = if (head) length else 0L
            })
            return
        }
        try {
            call.respond(object : OutgoingContent.WriteChannelContent() {
                override val status = status
                override val headers = extra
                override val contentType = type
                override val contentLength = length
                override suspend fun writeTo(channel: ByteWriteChannel) = withContext(Dispatchers.IO) {
                    // Closing the response cancels the upstream transfer when the
                    // player disconnects or seeks elsewhere.
                    streaming(id, open = true)
                    try {
                        response.use {
                            val input = it.body.byteStream()
                            val buffer = ByteArray(BUFFER_BYTES)
                            var remaining = length ?: Long.MAX_VALUE
                            while (remaining > 0) {
                                val read = input.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
                                if (read < 0) break
                                channel.writeFully(buffer, 0, read)
                                // Without this the server holds about 1 MB
                                // before the player sees its first byte.
                                channel.flush()
                                remaining -= read
                            }
                        }
                    } finally {
                        streaming(id, open = false)
                    }
                }
            })
        } catch (t: Throwable) {
            response.close()
            throw t
        }
    }

    private fun manifestType(kind: ManifestRewriter.Kind): ContentType =
        ContentType.parse(if (kind == ManifestRewriter.Kind.HLS) "application/vnd.apple.mpegurl" else "application/dash+xml")

    /** A manifest is read whole (bounded), rewritten and served as text. */
    private suspend fun serveManifest(call: ApplicationCall, response: Response, kind: ManifestRewriter.Kind, sessionId: String,
                                      resource: Resource, head: Boolean) {
        val manifestUrl = response.request.url.toString()
        val text = withContext(Dispatchers.IO) {
            response.use {
                val source = it.body.source()
                if (source.request(MAX_MANIFEST_BYTES + 1)) null else source.readUtf8()
            }
        }
        val rewritten = text?.let {
            try {
                ManifestRewriter.rewrite(kind, it, manifestUrl) { url -> pathFor(sessionId, url, resource.headers, resource.url) }
            } catch (failure: Exception) {
                if (failure !is ManifestRewriter.Unsupported && failure !is RejectedMediaResourceException && failure !is IllegalArgumentException) throw failure
                DaemonLog.warn("relay.manifest_refused", mapOf("kind" to kind.name, "reason" to (failure.message ?: failure.javaClass.simpleName)))
                null
            }
        }
        if (rewritten == null) { call.respond(HttpStatusCode.UnsupportedMediaType, ""); return }
        val bytes = rewritten.toByteArray()
        call.respond(object : OutgoingContent.ByteArrayContent() {
            override val status = HttpStatusCode.OK
            // Always the manifest type: the relay path has no extension, and
            // players recognise a playlist only by one or the other.
            override val contentType = manifestType(kind)
            override val contentLength = bytes.size.toLong()
            override fun bytes(): ByteArray = if (head) ByteArray(0) else bytes
        })
    }
}
