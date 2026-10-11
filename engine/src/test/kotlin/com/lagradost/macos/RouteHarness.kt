package com.lagradost.macos

import io.ktor.server.engine.EmbeddedServer
import io.ktor.server.engine.embeddedServer
import io.ktor.server.netty.Netty
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import java.net.HttpURLConnection
import java.net.URI

/** Real Ktor stack on an ephemeral loopback port with a test bearer token. */
internal class RouteHarness : AutoCloseable {
    private val token = "route-harness-token-0123456789"
    private val field = Class.forName("com.lagradost.macos.MainKt").getDeclaredField("bearerToken").apply { isAccessible = true }
    private val previous = field.get(null)
    private val server: EmbeddedServer<*, *>
    private val port: Int

    init {
        field.set(null, token)
        server = embeddedServer(Netty, host = "127.0.0.1", port = 0) { module() }.start(false)
        port = kotlinx.coroutines.runBlocking { server.engine.resolvedConnectors().single().port }
    }

    data class Response(val status: Int, val body: String) {
        val json: JsonElement get() = Json.parseToJsonElement(body)
    }

    fun get(path: String, auth: Boolean = true) = request(path, null, auth)
    fun post(path: String, body: String, auth: Boolean = true) = request(path, body, auth)

    /** Raw streaming connection so tests can reproduce a real disconnect/RST. */
    fun streamSocket(path: String): java.net.Socket = java.net.Socket("127.0.0.1", port).apply {
        soTimeout = 5_000
        getOutputStream().write(("GET $path HTTP/1.1\r\nHost: 127.0.0.1:$port\r\n" +
            "Authorization: Bearer $token\r\nConnection: close\r\n\r\n").toByteArray())
        getOutputStream().flush()
    }

    class Raw(val status: Int, val headers: Map<String, String>, val bytes: ByteArray)

    /** Unauthenticated byte-level request, as the native player makes it. */
    fun raw(path: String, method: String = "GET", headers: Map<String, String> = emptyMap()): Raw {
        val conn = URI("http://127.0.0.1:$port$path").toURL().openConnection() as HttpURLConnection
        conn.connectTimeout = 5000; conn.readTimeout = 30_000
        conn.requestMethod = method
        headers.forEach(conn::setRequestProperty)
        val status = conn.responseCode
        val bytes = (if (status < 400) conn.inputStream else conn.errorStream)?.use { it.readBytes() } ?: ByteArray(0)
        val fields = conn.headerFields.filterKeys { it != null }.map { it.key.lowercase() to it.value.joinToString(",") }.toMap()
        conn.disconnect()
        return Raw(status, fields, bytes)
    }

    private fun request(path: String, body: String?, auth: Boolean): Response {
        val conn = URI("http://127.0.0.1:$port$path").toURL().openConnection() as HttpURLConnection
        conn.connectTimeout = 5000; conn.readTimeout = 30_000
        if (auth) conn.setRequestProperty("Authorization", "Bearer $token")
        if (body != null) {
            conn.requestMethod = "POST"; conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/json")
            conn.outputStream.use { it.write(body.toByteArray()) }
        }
        val status = conn.responseCode
        val text = (if (status < 400) conn.inputStream else conn.errorStream)?.bufferedReader()?.use { it.readText() }.orEmpty()
        conn.disconnect()
        return Response(status, text)
    }

    override fun close() {
        server.stop(0, 1000)
        field.set(null, previous)
    }
}
