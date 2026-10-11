package com.lagradost.macos

import com.lagradost.macos.worker.EgressSettings
import com.lagradost.macos.worker.WorkerEgressProxy
import java.io.DataInputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import kotlin.test.*

/** The worker's only route to the network (security audit H1, LAN follow-up). */
class WorkerEgressProxyTest {
    private val echo = ServerSocket(0, 16, InetAddress.getLoopbackAddress())
    private val listener = Thread {
        while (!echo.isClosed) {
            val client = runCatching { echo.accept() }.getOrNull() ?: break
            Thread { client.use { it.getOutputStream().write("hello-from-origin".toByteArray()) } }.start()
        }
    }.apply { isDaemon = true; start() }

    @AfterTest fun after() = echo.close()

    /** A raw SOCKS5 client, so every byte of the exchange is checked. */
    private fun socks(settings: EgressSettings, host: String?, address: ByteArray?, port: Int,
                      password: String = settings.password): Pair<Int, String> {
        Socket(settings.host, settings.port).use { socket ->
            socket.soTimeout = 5_000
            val output = socket.getOutputStream()
            val input = DataInputStream(socket.getInputStream())
            output.write(byteArrayOf(5, 1, 2)); output.flush()
            assertEquals(5, input.readUnsignedByte())
            assertEquals(2, input.readUnsignedByte(), "username/password is required")
            output.write(byteArrayOf(1, settings.username.length.toByte()) + settings.username.toByteArray() +
                byteArrayOf(password.length.toByte()) + password.toByteArray()); output.flush()
            assertEquals(1, input.readUnsignedByte())
            val auth = input.readUnsignedByte()
            if (auth != 0) return -1 to ""
            val literal = address ?: ByteArray(0)
            val target = if (host != null) byteArrayOf(3, host.length.toByte()) + host.toByteArray() else byteArrayOf(if (literal.size == 4) 1 else 4) + literal
            output.write(byteArrayOf(5, 1, 0) + target + byteArrayOf((port shr 8).toByte(), port.toByte())); output.flush()
            assertEquals(5, input.readUnsignedByte())
            val reply = input.readUnsignedByte()
            input.readFully(ByteArray(8))
            val body = if (reply == 0) String(input.readAllBytes()) else ""
            return reply to body
        }
    }

    @Test fun `public destinations are tunnelled and private ones refused`() {
        val permissive = WorkerEgressProxy(addressAllowed = { true }, resolve = { listOf(InetAddress.getLoopbackAddress()) })
        val strict = WorkerEgressProxy(resolve = { listOf(InetAddress.getLoopbackAddress()) })
        try {
            assertEquals(0 to "hello-from-origin", socks(permissive.settings, "origin.example", null, echo.localPort), "a name resolved by the engine")
            assertEquals(0 to "hello-from-origin", socks(permissive.settings, null, byteArrayOf(127, 0, 0, 1), echo.localPort), "an address literal")
            assertEquals(2, socks(strict.settings, "origin.example", null, echo.localPort).first, "a name resolving to loopback is refused")
            for (literal in listOf(byteArrayOf(127, 0, 0, 1), byteArrayOf(10, 0, 0, 5), byteArrayOf(192.toByte(), 168.toByte(), 1, 1),
                                   byteArrayOf(169.toByte(), 254.toByte(), 169.toByte(), 254.toByte()), byteArrayOf(100, 64, 0, 1))) {
                assertEquals(2, socks(strict.settings, null, literal, 80).first, "private ${literal.joinToString(".") { (it.toInt() and 255).toString() }} is refused")
            }
            assertEquals(2, socks(strict.settings, null, InetAddress.getByName("::1").address, 80).first, "IPv6 loopback is refused")
            assertTrue(strict.refused.get() >= 7)
        } finally {
            permissive.close(); strict.close()
        }
    }

    @Test fun `a wrong password or no authentication is refused before any connection`() {
        val proxy = WorkerEgressProxy(addressAllowed = { true }, resolve = { listOf(InetAddress.getLoopbackAddress()) })
        try {
            assertEquals(-1, socks(proxy.settings, "origin.example", null, echo.localPort, password = "guess").first)
            Socket(proxy.settings.host, proxy.settings.port).use { socket ->
                socket.soTimeout = 5_000
                socket.getOutputStream().write(byteArrayOf(5, 1, 0)); socket.getOutputStream().flush() // offers only "no auth"
                val input = DataInputStream(socket.getInputStream())
                assertEquals(5, input.readUnsignedByte())
                assertEquals(0xff, input.readUnsignedByte(), "no acceptable method")
            }
        } finally { proxy.close() }
    }

    @Test fun `the JDK client in a worker reaches origins only through the proxy`() {
        val proxy = WorkerEgressProxy(addressAllowed = { true }, resolve = { listOf(InetAddress.getLoopbackAddress()) })
        try {
            val settings = proxy.settings
            java.net.Authenticator.setDefault(object : java.net.Authenticator() {
                override fun getPasswordAuthentication() = java.net.PasswordAuthentication(settings.username, settings.password.toCharArray())
            })
            val socks = java.net.Proxy(java.net.Proxy.Type.SOCKS, InetSocketAddress(settings.host, settings.port))
            Socket(socks).use { socket ->
                socket.connect(InetSocketAddress.createUnresolved("origin.example", echo.localPort), 5_000)
                assertEquals("hello-from-origin", String(socket.getInputStream().readAllBytes()))
            }
        } finally {
            java.net.Authenticator.setDefault(null)
            proxy.close()
        }
    }
}
