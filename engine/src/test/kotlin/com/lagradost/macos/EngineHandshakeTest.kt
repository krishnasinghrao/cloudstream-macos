package com.lagradost.macos

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import java.io.File
import java.util.concurrent.TimeUnit
import kotlin.test.*

/** The app authenticates its engine without sending it the token first (audit M1), and nothing is cacheable (M3). */
class EngineHandshakeTest {
    private val token = "route-harness-token-0123456789"
    private val nonce = "0123456789abcdef0123456789abcdef"

    @Test fun `health answers a nonce with an HMAC of the launch token and never needs the token`() = RouteHarness().use { http ->
        val health = http.raw("/health", headers = mapOf(EngineHandshake.NONCE_HEADER to nonce))
        assertEquals(200, health.status)
        val proof = Json.parseToJsonElement(String(health.bytes)).jsonObject["proof"]?.jsonPrimitive?.content
        assertEquals(EngineHandshake.proof(token, nonce), proof)
        val mac = javax.crypto.Mac.getInstance("HmacSHA256").apply {
            init(javax.crypto.spec.SecretKeySpec(token.toByteArray(), "HmacSHA256"))
        }
        assertEquals(java.util.HexFormat.of().formatHex(mac.doFinal("cloudstream-health-v1:$nonce".toByteArray())), proof)
        val other = http.raw("/health", headers = mapOf(EngineHandshake.NONCE_HEADER to nonce.reversed()))
        assertNotEquals(proof, Json.parseToJsonElement(String(other.bytes)).jsonObject["proof"]?.jsonPrimitive?.content,
            "each nonce gets its own proof")
    }

    @Test fun `malformed nonces get no proof`() {
        assertNull(EngineHandshake.proof(token, "short"))
        assertNull(EngineHandshake.proof(token, "Z".repeat(32)))
        assertNull(EngineHandshake.proof(token, "a".repeat(129)))
        assertNull(EngineHandshake.proof("", nonce))
        assertNotNull(EngineHandshake.proof(token, "a".repeat(64)))
    }

    @Test fun `every engine response is marked no-store (M3)`() = RouteHarness().use { http ->
        assertEquals("no-store", http.raw("/health").headers["cache-control"])
        assertEquals("no-store", http.raw("/plugins").headers["cache-control"], "even a refused request")
        assertEquals("no-store", http.raw("/plugins", headers = mapOf("Authorization" to "Bearer $token")).headers["cache-control"])
        assertEquals("no-store", http.raw("/media/relay/unknown").headers["cache-control"])
    }

    @Test fun `the announcement carries the bound port and the engine's pid`() {
        val line = EngineHandshake.announcement(51234)
        assertTrue(line.startsWith(EngineHandshake.PREFIX))
        val json = Json.parseToJsonElement(line.removePrefix(EngineHandshake.PREFIX)).jsonObject
        assertEquals(51234, json["port"]!!.jsonPrimitive.int)
        assertEquals(ProcessHandle.current().pid(), json["pid"]!!.jsonPrimitive.long)
    }

    @Test fun `a real engine on port 0 announces the port it bound and proves the token there`() {
        val jar = File("build/libs/daemon.jar").takeIf { it.isFile } ?: File(System.getProperty("user.dir"), "engine/build/libs/daemon.jar")
        val classpath = if (jar.isFile) jar.path else System.getProperty("java.class.path")
        val home = java.nio.file.Files.createTempDirectory("engine-handshake-").toFile()
        val javaBinary = File(System.getProperty("java.home"), "bin/java").path
        val process = ProcessBuilder(javaBinary, "-Dcs.cloudstream.home=${home.path}", "-cp", classpath, "com.lagradost.macos.MainKt", "0")
            .redirectError(ProcessBuilder.Redirect.DISCARD).start()
        try {
            process.outputStream.bufferedWriter().apply {
                write("handshake-test-token-0123456789\n")
                write("""{"policy":{"requireSandbox":false},"safeMode":true}""" + "\n")
                flush()
            }
            val reader = process.inputStream.bufferedReader()
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(60)
            var port: Int? = null
            while (port == null && System.nanoTime() < deadline) {
                val line = reader.readLine() ?: break
                if (line.startsWith(EngineHandshake.PREFIX)) {
                    val json = Json.parseToJsonElement(line.removePrefix(EngineHandshake.PREFIX)).jsonObject
                    assertEquals(process.pid(), json["pid"]!!.jsonPrimitive.long)
                    port = json["port"]!!.jsonPrimitive.int
                }
            }
            val bound = assertNotNull(port, "the engine announced its port")
            assertTrue(bound in 1024..65535)
            val connection = java.net.URI("http://127.0.0.1:$bound/health").toURL().openConnection() as java.net.HttpURLConnection
            connection.setRequestProperty(EngineHandshake.NONCE_HEADER, nonce)
            val body = connection.inputStream.use { String(it.readBytes()) }
            assertEquals(EngineHandshake.proof("handshake-test-token-0123456789", nonce),
                Json.parseToJsonElement(body).jsonObject["proof"]?.jsonPrimitive?.content)
        } finally {
            process.destroy()
            if (!process.waitFor(10, TimeUnit.SECONDS)) process.destroyForcibly()
            home.deleteRecursively()
        }
    }
}
