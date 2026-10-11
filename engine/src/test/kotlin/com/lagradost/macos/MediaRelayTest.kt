package com.lagradost.macos

import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.OkHttpClient
import java.net.InetAddress
import java.net.InetSocketAddress
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import kotlin.test.*

/**
 * Audit A35: a split stream whose video and audio need different request
 * headers is read through session-scoped relay resources. Real listener, real
 * origin fixture; the "player" is an unauthenticated HTTP client.
 */
class MediaRelayTest {
    private lateinit var origin: HttpServer
    private lateinit var other: HttpServer
    private val executor = Executors.newFixedThreadPool(4)
    private val video = ByteArray(300_000) { (it % 251).toByte() }
    private val audio = ByteArray(90_000) { (it % 13).toByte() }
    /** (path, headers) of every request the origins received. */
    private val seen = CopyOnWriteArrayList<Pair<String, Map<String, String>>>()

    private fun record(exchange: HttpExchange) {
        seen += exchange.requestURI.path to exchange.requestHeaders.map { it.key.lowercase() to it.value.joinToString(",") }.toMap()
    }

    /** Serves `bytes` with single-range support when the cookie matches. */
    private fun protectedBytes(exchange: HttpExchange, bytes: ByteArray, cookie: String) {
        record(exchange)
        if (exchange.requestHeaders.getFirst("Cookie") != cookie) {
            val page = "<html>secret error page</html>".toByteArray()
            exchange.sendResponseHeaders(403, page.size.toLong()); exchange.responseBody.use { it.write(page) }; return
        }
        exchange.responseHeaders.add("Content-Type", "video/mp4")
        exchange.responseHeaders.add("Accept-Ranges", "bytes")
        exchange.responseHeaders.add("Set-Cookie", "tracking=1")
        val range = exchange.requestHeaders.getFirst("Range")?.removePrefix("bytes=")?.split("-")
        val head = exchange.requestMethod == "HEAD"
        if (range == null) {
            exchange.sendResponseHeaders(200, if (head) -1 else bytes.size.toLong())
            if (head) exchange.responseHeaders else exchange.responseBody.use { it.write(bytes) }
        } else {
            val start = range[0].toInt()
            val end = range.getOrNull(1)?.toIntOrNull() ?: (bytes.size - 1)
            exchange.responseHeaders.add("Content-Range", "bytes $start-$end/${bytes.size}")
            exchange.sendResponseHeaders(206, (end - start + 1).toLong())
            exchange.responseBody.use { it.write(bytes, start, end - start + 1) }
        }
        exchange.close()
    }

    @BeforeTest fun before() {
        MediaRelay.reset()
        MediaRelay.clientOverride = OkHttpClient.Builder().followRedirects(false).build()
        origin = HttpServer.create(InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0)
        other = HttpServer.create(InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0)
        origin.executor = executor; other.executor = executor
        origin.createContext("/video") { protectedBytes(it, video, "v=1") }
        origin.createContext("/audio") { protectedBytes(it, audio, "a=2") }
        origin.createContext("/list.m3u8") { exchange ->
            val body = "#EXTM3U\n".toByteArray()
            exchange.responseHeaders.add("Content-Type", "application/vnd.apple.mpegurl")
            exchange.sendResponseHeaders(200, body.size.toLong()); exchange.responseBody.use { it.write(body) }
        }
        origin.createContext("/moved-same") { exchange ->
            record(exchange)
            exchange.responseHeaders.add("Location", "/audio"); exchange.sendResponseHeaders(302, -1); exchange.close()
        }
        origin.createContext("/moved-away") { exchange ->
            record(exchange)
            exchange.responseHeaders.add("Location", "http://127.0.0.1:${other.address.port}/landing")
            exchange.sendResponseHeaders(302, -1); exchange.close()
        }
        origin.createContext("/moved-file") { exchange ->
            exchange.responseHeaders.add("Location", "file:///etc/hosts"); exchange.sendResponseHeaders(302, -1); exchange.close()
        }
        other.createContext("/landing") { exchange ->
            record(exchange)
            exchange.responseHeaders.add("Content-Type", "audio/mp4")
            exchange.sendResponseHeaders(200, audio.size.toLong()); exchange.responseBody.use { it.write(audio) }
        }
        origin.start(); other.start()
    }

    @AfterTest fun after() {
        MediaRelay.reset()
        MediaRelay.clientOverride = null
        MediaRelay.now = System::currentTimeMillis
        origin.stop(0); other.stop(0)
        executor.shutdownNow()
    }

    private fun url(path: String) = "http://127.0.0.1:${origin.address.port}$path"

    private fun register(harness: RouteHarness, vararg resources: Pair<String, Map<String, String>>): Pair<String, List<String>> {
        val body = resources.joinToString(",", "{\"resources\":[", "]}") { (url, headers) ->
            "{\"url\":\"$url\",\"headers\":{" + headers.entries.joinToString(",") { "\"${it.key}\":\"${it.value}\"" } + "}}"
        }
        val response = harness.post("/media/relay", body)
        assertEquals(200, response.status, response.body)
        val json = response.json.jsonObject
        return json["sessionId"]!!.jsonPrimitive.content to json["paths"]!!.jsonArray.map { it.jsonPrimitive.content }
    }

    @Test fun `each resource is fetched with its own headers and the player's are ignored`() = RouteHarness().use { harness ->
        val (_, paths) = register(harness, url("/video") to mapOf("Cookie" to "v=1"), url("/audio") to mapOf("Cookie" to "a=2", "Referer" to "https://a.example/"))
        // The player sends its one global header set to both; none of it may reach an origin.
        val player = mapOf("Cookie" to "v=1", "X-Player" to "yes")
        val full = harness.raw(paths[0], headers = player)
        assertEquals(200, full.status)
        assertContentEquals(video, full.bytes)
        assertEquals("video/mp4", full.headers["content-type"])
        assertEquals(video.size.toString(), full.headers["content-length"])
        assertNull(full.headers["set-cookie"], "origin cookies are not handed to the player")
        val audioResponse = harness.raw(paths[1], headers = player)
        assertContentEquals(audio, audioResponse.bytes)

        val atVideo = seen.single { it.first == "/video" }.second
        val atAudio = seen.single { it.first == "/audio" }.second
        assertEquals("v=1", atVideo["cookie"]); assertNull(atVideo["referer"]); assertNull(atVideo["x-player"])
        assertEquals("a=2", atAudio["cookie"]); assertEquals("https://a.example/", atAudio["referer"]); assertNull(atAudio["x-player"])
        assertNull(atAudio["authorization"]); assertNull(atVideo["authorization"])
    }

    @Test fun `ranges and head pass through with exact bytes`() = RouteHarness().use { harness ->
        val (_, paths) = register(harness, url("/video") to mapOf("Cookie" to "v=1"))
        val middle = harness.raw(paths[0], headers = mapOf("Range" to "bytes=1000-70999"))
        assertEquals(206, middle.status)
        assertContentEquals(video.copyOfRange(1000, 71000), middle.bytes)
        assertEquals("bytes 1000-70999/${video.size}", middle.headers["content-range"])
        val tail = harness.raw(paths[0], headers = mapOf("Range" to "bytes=299000-"))
        assertContentEquals(video.copyOfRange(299000, video.size), tail.bytes)
        // Anything but one simple range is not forwarded.
        assertEquals(200, harness.raw(paths[0], headers = mapOf("Range" to "bytes=0-1, 5-9")).status)
        val head = harness.raw(paths[0], method = "HEAD")
        assertEquals(200, head.status); assertEquals(0, head.bytes.size); assertEquals("bytes", head.headers["accept-ranges"])
    }

    @Test fun `only registered ids are readable and registration needs the token`() = RouteHarness().use { harness ->
        val (session, paths) = register(harness, url("/video") to mapOf("Cookie" to "v=1"))
        assertEquals(404, harness.raw("/media/relay/" + "0".repeat(64)).status)
        assertEquals(404, harness.raw("/media/relay/" + url("/video")).status, "no URL-forwarding form exists")
        assertEquals(401, harness.post("/media/relay", "{\"resources\":[{\"url\":\"${url("/video")}\"}]}", auth = false).status)
        assertEquals(401, harness.post("/media/relay/revoke", "{\"sessionId\":\"$session\"}", auth = false).status)
        assertEquals(200, harness.raw(paths[0]).status, "an unauthenticated revoke changed nothing")
        // Other endpoints stay behind the token.
        assertEquals(401, harness.get("/providers", auth = false).status)

        assertEquals(200, harness.post("/media/relay/revoke", "{\"sessionId\":\"$session\"}").status)
        assertEquals(404, harness.raw(paths[0]).status)
        assertEquals(0, MediaRelay.activeSessions)
    }

    @Test fun `invalid resources are refused at registration without echoing them`() = RouteHarness().use { harness ->
        for (body in listOf(
            "{\"resources\":[]}",
            "{\"resources\":[{\"url\":\"file:///etc/passwd\"}]}",
            "{\"resources\":[{\"url\":\"http://user:secret@127.0.0.1/x\"}]}",
            "{\"resources\":[{\"url\":\"${url("/video")}\",\"headers\":{\"Host\":\"evil\"}}]}",
            "{\"resources\":[" + (0..MediaRelay.MAX_RESOURCES).joinToString(",") { "{\"url\":\"${url("/video")}\"}" } + "]}",
        )) {
            val response = harness.post("/media/relay", body)
            assertEquals(400, response.status, body)
            assertFalse("secret" in response.body || "passwd" in response.body)
        }
        assertEquals(0, MediaRelay.activeSessions)
    }

    @Test fun `upstream refusals and unsafe redirects never forward a body`() = RouteHarness().use { harness ->
        val (_, paths) = register(harness,
            url("/video") to mapOf("Cookie" to "wrong"), url("/moved-file") to emptyMap())
        val denied = harness.raw(paths[0])
        assertEquals(403, denied.status); assertEquals(0, denied.bytes.size)
        assertEquals(502, harness.raw(paths[1]).status)
    }

    private fun serve(server: com.sun.net.httpserver.HttpServer, path: String, type: String, body: String, cookie: String? = null) {
        server.createContext(path) { exchange ->
            record(exchange)
            if (cookie != null && exchange.requestHeaders.getFirst("Cookie") != cookie) {
                exchange.sendResponseHeaders(403, -1); exchange.close(); return@createContext
            }
            val bytes = body.toByteArray()
            exchange.responseHeaders.add("Content-Type", type)
            exchange.sendResponseHeaders(200, bytes.size.toLong()); exchange.responseBody.use { it.write(bytes) }
        }
    }

    @Test fun `an HLS playlist is rewritten so every URL it names goes through the relay`() = RouteHarness().use { harness ->
        val otherBase = "http://127.0.0.1:${other.address.port}"
        serve(origin, "/hls/master.m3u8", "application/vnd.apple.mpegurl",
            "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nv1/index.m3u8?token=a%20b\n", cookie = "s=1")
        serve(origin, "/hls/v1/index.m3u8", "application/vnd.apple.mpegurl",
            "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n#EXTINF:4,\nseg0.ts\n#EXTINF:4,\n$otherBase/cdn/seg1.ts\n#EXT-X-ENDLIST\n", cookie = "s=1")
        serve(origin, "/hls/v1/seg0.ts", "video/mp2t", "segment-zero", cookie = "s=1")
        serve(origin, "/hls/v1/key.bin", "application/octet-stream", "0123456789abcdef", cookie = "s=1")
        serve(other, "/cdn/seg1.ts", "video/mp2t", "segment-one")
        val (_, paths) = register(harness, url("/hls/master.m3u8") to mapOf("Cookie" to "s=1", "Referer" to "https://site.example/"))

        val master = harness.raw(paths[0])
        assertEquals(200, master.status)
        val variant = String(master.bytes).lines().single { it.startsWith("/media/relay/") }
        assertTrue(variant.endsWith("/index.m3u8?token=a%20b"), variant)
        val media = String(harness.raw(variant).bytes)
        assertFalse("http://" in media, "no URL bypasses the relay:\n$media")
        val key = Regex("""URI="([^"]+)"""").find(media)!!.groupValues[1]
        assertEquals("0123456789abcdef", String(harness.raw(key).bytes))
        val segments = media.lines().filter { it.startsWith("/media/relay/") }
        assertEquals(listOf("segment-zero", "segment-one"), segments.map { String(harness.raw(it).bytes) })
        assertEquals("s=1", seen.last { it.first == "/hls/v1/seg0.ts" }.second["cookie"])
        val foreign = seen.single { it.first == "/cdn/seg1.ts" }.second
        assertNull(foreign["cookie"], "credentials stay on the provider's origin")
        assertEquals("https://site.example/", foreign["referer"])
    }

    @Test fun `a playlist served with a media content type through the production client is still rewritten`() = RouteHarness().use { harness ->
        MediaRelay.clientOverride = null
        val allowed = MediaRelay.addressAllowed
        MediaRelay.addressAllowed = { true }
        try {
            serve(origin, "/plain/index.m3u8", "video/mp4", "#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:2.0,\nseg000.ts\n#EXT-X-ENDLIST\n", cookie = "h=3")
            serve(origin, "/plain/seg000.ts", "video/mp4", "zero", cookie = "h=3")
            val (_, paths) = register(harness, url("/plain/index.m3u8") to mapOf("Cookie" to "h=3"))
            val playlist = harness.raw(paths[0], headers = mapOf("Range" to "bytes=0-"))
            assertEquals(200, playlist.status, String(playlist.bytes))
            val segment = String(playlist.bytes).lines().single { it.startsWith("/media/relay/") }
            assertEquals("zero", String(harness.raw(segment).bytes))
        } finally { MediaRelay.addressAllowed = allowed }
    }

    @Test fun `a directory resource reads only below its directory`() = RouteHarness().use { harness ->
        serve(origin, "/hls/list.m3u8", "application/vnd.apple.mpegurl", "#EXTM3U\n#EXTINF:4,\nseg.ts\n")
        val (_, paths) = register(harness, url("/hls/list.m3u8") to emptyMap())
        val segment = String(harness.raw(paths[0]).bytes).lines().single { it.startsWith("/media/relay/") }
        val directory = segment.substringBeforeLast('/')
        assertEquals(404, harness.raw("$directory/../video").status)
        assertEquals(404, harness.raw("$directory/%2e%2e/video").status)
        assertEquals(404, harness.raw("$directory/..%2fvideo").status)
        assertTrue(seen.none { it.first == "/video" }, "nothing outside the directory reached the origin")
        assertEquals(404, harness.raw(directory.substringBeforeLast('/') + "/" + "0".repeat(64) + "/seg.ts").status)
    }

    @Test fun `a DASH manifest gets a relay base URL`() = RouteHarness().use { harness ->
        val mpd = """<?xml version="1.0"?><MPD xmlns="urn:mpeg:dash:schema:mpd:2011"><Period><AdaptationSet>""" +
            """<Representation id="v"><SegmentTemplate media="seg-${'$'}Number${'$'}.m4s" initialization="init.mp4"/></Representation>""" +
            """</AdaptationSet></Period></MPD>"""
        serve(origin, "/dash/manifest.mpd", "application/dash+xml", mpd)
        serve(origin, "/dash/init.mp4", "video/mp4", "init")
        val (_, paths) = register(harness, url("/dash/manifest.mpd") to emptyMap())
        val rewritten = String(harness.raw(paths[0]).bytes)
        val base = Regex("<BaseURL>([^<]+)</BaseURL>").find(rewritten)!!.groupValues[1]
        assertTrue(base.startsWith("/media/relay/") && base.endsWith("/"), rewritten)
        assertEquals("init", String(harness.raw(base + "init.mp4").bytes))
    }

    @Test fun `absolute DASH segment URLs and templates are relayed instead of refused (Remediation 3_1)`() = RouteHarness().use { harness ->
        val cdn = "http://127.0.0.1:${other.address.port}"
        val mpd = """<?xml version="1.0"?><MPD xmlns="urn:mpeg:dash:schema:mpd:2011"><Period><AdaptationSet>""" +
            """<Representation id="v1"><SegmentTemplate media="$cdn/cdn/${'$'}RepresentationID${'$'}/chunk_${'$'}Number%05d${'$'}.m4s?tok=1" """ +
            """initialization="$cdn/cdn/init.mp4"/></Representation></AdaptationSet></Period></MPD>"""
        serve(origin, "/abs/manifest.mpd", "application/dash+xml", mpd, cookie = "m=1")
        serve(other, "/cdn/init.mp4", "video/mp4", "absolute-init")
        serve(other, "/cdn/v1/chunk_00001.m4s", "video/mp4", "chunk-one")
        val (_, paths) = register(harness, url("/abs/manifest.mpd") to mapOf("Cookie" to "m=1", "Referer" to "https://site.example/"))
        val response = harness.raw(paths[0])
        assertEquals(200, response.status, "no longer 415")
        val rewritten = String(response.bytes)
        assertFalse(cdn in rewritten, "no segment URL bypasses the relay:\n$rewritten")
        val media = Regex("""media="([^"]+)"""").find(rewritten)!!.groupValues[1].replace("&amp;", "&")
        val init = Regex("""initialization="([^"]+)"""").find(rewritten)!!.groupValues[1]
        assertTrue(media.startsWith("/media/relay/") && media.endsWith("/${'$'}RepresentationID${'$'}/chunk_${'$'}Number%05d${'$'}.m4s?tok=1"), media)
        assertEquals("absolute-init", String(harness.raw(init).bytes))
        // The player expands the template; the relay reads it below the CDN directory.
        val expanded = media.replace("${'$'}RepresentationID${'$'}", "v1").replace("${'$'}Number%05d${'$'}", "00001")
        assertEquals("chunk-one", String(harness.raw(expanded).bytes))
        val foreign = seen.last { it.first == "/cdn/v1/chunk_00001.m4s" }.second
        assertNull(foreign["cookie"], "credentials stay on the manifest's origin")
        assertEquals("https://site.example/", foreign["referer"])
    }

    @Test fun `a template identifier inside a host name is refused`() = RouteHarness().use { harness ->
        val mpd = """<?xml version="1.0"?><MPD xmlns="urn:mpeg:dash:schema:mpd:2011"><Period><AdaptationSet>""" +
            """<Representation id="v"><SegmentTemplate media="http://${'$'}RepresentationID${'$'}.cdn.example/seg.m4s"/></Representation>""" +
            """</AdaptationSet></Period></MPD>"""
        serve(origin, "/abs/host.mpd", "application/dash+xml", mpd)
        val (_, paths) = register(harness, url("/abs/host.mpd") to emptyMap())
        assertEquals(415, harness.raw(paths[0]).status)
    }

    @Test fun `a redirect keeps credentials on the same origin and drops them for another`() = RouteHarness().use { harness ->
        val headers = mapOf("Cookie" to "a=2", "Authorization" to "Bearer provider", "Referer" to "https://a.example/", "User-Agent" to "UA/1")
        val (_, paths) = register(harness, url("/moved-same") to headers, url("/moved-away") to headers)
        assertContentEquals(audio, harness.raw(paths[0]).bytes)
        assertEquals("a=2", seen.single { it.first == "/audio" }.second["cookie"])
        assertContentEquals(audio, harness.raw(paths[1]).bytes)
        val landing = seen.single { it.first == "/landing" }.second
        assertNull(landing["cookie"]); assertNull(landing["authorization"])
        assertEquals("https://a.example/", landing["referer"]); assertEquals("UA/1", landing["user-agent"])
    }

    @Test fun `sessions are bounded and expire when idle`() = RouteHarness().use { harness ->
        var clock = 1_000_000L
        MediaRelay.now = { clock }
        val first = register(harness, url("/video") to mapOf("Cookie" to "v=1"))
        repeat(MediaRelay.MAX_SESSIONS - 1) { register(harness, url("/audio") to emptyMap()) }
        assertEquals(503, harness.post("/media/relay", "{\"resources\":[{\"url\":\"${url("/video")}\"}]}").status)
        // Use keeps the first session alive past the others' idle limit.
        clock += MediaRelay.IDLE_LIFETIME_MS - 1000
        assertEquals(200, harness.raw(first.second[0]).status)
        clock += 2000
        assertEquals(1, MediaRelay.activeSessions)
        assertEquals(200, harness.raw(first.second[0]).status)
        clock += MediaRelay.IDLE_LIFETIME_MS + 1
        assertEquals(404, harness.raw(first.second[0]).status)
    }

    @Test fun `a full relay evicts a never-read session after 10 s but a read one only after a minute (M6)`() = RouteHarness().use { harness ->
        var clock = 1_000_000L
        MediaRelay.now = { clock }
        assertEquals(12, MediaRelay.MAX_SESSIONS, "one player plus parallel credentialed downloads (A2)")
        val read = register(harness, url("/video") to mapOf("Cookie" to "v=1"))
        assertEquals(200, harness.raw(read.second[0]).status)
        repeat(MediaRelay.MAX_SESSIONS - 1) { register(harness, url("/audio") to emptyMap()) }
        clock += MediaRelay.NEVER_READ_EVICTION_MS - 1
        assertEquals(503, harness.post("/media/relay", "{\"resources\":[{\"url\":\"${url("/video")}\"}]}").status,
            "nothing is evictable yet")
        clock += 2
        repeat(MediaRelay.MAX_SESSIONS - 1) {
            assertEquals(200, harness.post("/media/relay", "{\"resources\":[{\"url\":\"${url("/audio")}\"}]}").status,
                "abandoned registrations give way")
        }
        assertEquals(200, harness.raw(read.second[0]).status, "a session in use is not evicted for them")
        assertEquals(503, harness.post("/media/relay", "{\"resources\":[{\"url\":\"${url("/video")}\"}]}").status)
    }

    @Test fun `a session with an open stream neither expires nor is evicted`() = RouteHarness().use { harness ->
        var clock = 1_000_000L
        MediaRelay.now = { clock }
        val release = java.util.concurrent.CountDownLatch(1)
        // Large enough that the relay's response buffer flushes before the origin pauses.
        val film = ByteArray(4 * 1024 * 1024)
        origin.createContext("/slow") { exchange ->
            exchange.responseHeaders.add("Content-Type", "video/mp4")
            exchange.sendResponseHeaders(200, film.size.toLong())
            exchange.responseBody.use { body ->
                body.write(film, 0, film.size / 2); body.flush()
                release.await(10, java.util.concurrent.TimeUnit.SECONDS)
                body.write(film, film.size / 2, film.size / 2)
            }
        }
        val playing = register(harness, url("/slow") to emptyMap())
        repeat(MediaRelay.MAX_SESSIONS - 1) { register(harness, url("/audio") to emptyMap()) }
        val socket = harness.streamSocket(playing.second[0])
        try {
            // Bytes reached the player, so the relay response is streaming.
            val first = ByteArray(1024)
            assertTrue(socket.getInputStream().read(first) > 0)
            // Past the eviction age, a new registration evicts an idle session, never the playing one.
            clock += 2 * 60 * 1000L
            register(harness, url("/audio") to emptyMap())
            // Past the idle lifetime, idle sessions expire; the streaming one survives.
            clock += MediaRelay.IDLE_LIFETIME_MS + 1
            assertEquals(1, MediaRelay.activeSessions)
        } finally {
            release.countDown()
            socket.close()
        }
        // Once the stream ends, its idle lifetime starts.
        val deadline = System.nanoTime() + 5_000_000_000L
        while (MediaRelay.activeSessions > 0 && System.nanoTime() < deadline) {
            clock += MediaRelay.IDLE_LIFETIME_MS + 1
            Thread.sleep(50)
        }
        assertEquals(0, MediaRelay.activeSessions)
    }

    @Test fun `private and intranet IP literals are rejected when clientOverride is unset`() {
        MediaRelay.clientOverride = null
        try {
            val privateTargets = listOf(
                "http://127.0.0.1/video.mp4",
                "http://169.254.169.254/latest/meta-data",
                "http://10.0.0.1/stream.mp4",
                "http://192.168.1.1/video.mp4",
            )
            for (target in privateTargets) {
                assertFailsWith<RejectedMediaResourceException>("Expected rejection for $target") {
                    MediaRelay.register(listOf(MediaRelay.Resource(target, emptyMap())))
                }
            }
        } finally {
            MediaRelay.clientOverride = OkHttpClient.Builder().followRedirects(false).build()
        }
    }

    @Test fun `HEAD on a relayed manifest answers with the manifest type instead of 415 (Q3)`() = RouteHarness().use { harness ->
        serve(origin, "/head/index.m3u8", "application/vnd.apple.mpegurl", "#EXTM3U\n#EXTINF:2.0,\nseg.ts\n#EXT-X-ENDLIST\n", cookie = "h=1")
        serve(origin, "/head/manifest.mpd", "application/dash+xml", "<MPD><Period><AdaptationSet><Representation><BaseURL>v/</BaseURL></Representation></AdaptationSet></Period></MPD>")
        val (_, paths) = register(harness, url("/head/index.m3u8") to mapOf("Cookie" to "h=1"), url("/head/manifest.mpd") to emptyMap())
        val hls = harness.raw(paths[0], method = "HEAD")
        assertEquals(200, hls.status)
        assertEquals("application/vnd.apple.mpegurl", hls.headers["content-type"])
        assertEquals(0, hls.bytes.size)
        val dash = harness.raw(paths[1], method = "HEAD")
        assertEquals(200, dash.status)
        assertEquals("application/dash+xml", dash.headers["content-type"])
        // A GET after the HEAD still serves the rewritten playlist.
        assertTrue(String(harness.raw(paths[0]).bytes).lines().any { it.startsWith("/media/relay/") })
    }

    @Test fun `the production relay client never goes through the system proxy (L2)`() = RouteHarness().use { harness ->
        val proxied = java.util.concurrent.atomic.AtomicInteger()
        val proxy = HttpServer.create(InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0).apply {
            executor = this@MediaRelayTest.executor
            createContext("/") { exchange -> proxied.incrementAndGet(); exchange.sendResponseHeaders(502, -1); exchange.close() }
            start()
        }
        val previousSelector = java.net.ProxySelector.getDefault()
        val allowed = MediaRelay.addressAllowed
        MediaRelay.clientOverride = null
        MediaRelay.addressAllowed = { true }
        java.net.ProxySelector.setDefault(object : java.net.ProxySelector() {
            // Only the media origin is proxied; the harness's own engine requests are not.
            override fun select(uri: java.net.URI) =
                listOf(if (uri.port == origin.address.port) java.net.Proxy(java.net.Proxy.Type.HTTP, proxy.address) else java.net.Proxy.NO_PROXY)
            override fun connectFailed(uri: java.net.URI, sa: java.net.SocketAddress, ioe: java.io.IOException) {}
        })
        try {
            assertEquals(java.net.Proxy.NO_PROXY, MediaRelay.client().proxy)
            serve(origin, "/direct/file.bin", "application/octet-stream", "direct-bytes")
            val (_, paths) = register(harness, url("/direct/file.bin") to emptyMap())
            assertEquals("direct-bytes", String(harness.raw(paths[0]).bytes))
            assertEquals(0, proxied.get(), "a proxy would resolve the host itself and skip the address check")
        } finally {
            java.net.ProxySelector.setDefault(previousSelector)
            MediaRelay.addressAllowed = allowed
            proxy.stop(0)
        }
    }
}
