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

    /** Completes a CONNECT to 127.0.0.1:[port] and returns the open tunnel. */
    private fun tunnel(settings: EgressSettings, port: Int): Socket {
        val socket = Socket(settings.host, settings.port)
        socket.soTimeout = 5_000
        val output = socket.getOutputStream()
        val input = DataInputStream(socket.getInputStream())
        output.write(byteArrayOf(5, 1, 2))
        output.write(byteArrayOf(1, settings.username.length.toByte()) + settings.username.toByteArray() +
            byteArrayOf(settings.password.length.toByte()) + settings.password.toByteArray())
        output.write(byteArrayOf(5, 1, 0, 1, 127, 0, 0, 1, (port shr 8).toByte(), port.toByte()))
        output.flush()
        input.readFully(ByteArray(2 + 2))
        assertEquals(5, input.readUnsignedByte())
        assertEquals(0, input.readUnsignedByte(), "tunnel established")
        input.readFully(ByteArray(8))
        return socket
    }

    /** An origin that accepts and then, per connection, runs [behaviour]. */
    private fun origin(behaviour: (Socket) -> Unit): ServerSocket = ServerSocket(0, 16, InetAddress.getLoopbackAddress()).also { server ->
        Thread {
            while (!server.isClosed) {
                val client = runCatching { server.accept() }.getOrNull() ?: break
                Thread { runCatching { client.use(behaviour) } }.apply { isDaemon = true }.start()
            }
        }.apply { isDaemon = true }.start()
    }

    @Test fun `an idle tunnel to a silent upstream is closed and frees its slot`() {
        // Accepts, then neither sends nor closes: a peer that vanished without a FIN.
        val silent = origin { Thread.sleep(30_000) }
        val proxy = WorkerEgressProxy(addressAllowed = { true }, maxConnections = 1, idleTimeoutMs = 300)
        try {
            val first = tunnel(proxy.settings, silent.localPort)
            first.use { assertEquals(-1, it.getInputStream().read(), "the proxy closed the idle tunnel") }
            // The only slot is free again: a new tunnel is admitted.
            tunnel(proxy.settings, silent.localPort).close()
        } finally {
            proxy.close(); silent.close()
        }
    }

    @Test fun `a tunnel with steady traffic outlives the idle timeout`() {
        val ticking = origin { socket ->
            repeat(10) { socket.getOutputStream().apply { write(it); flush() }; Thread.sleep(100) }
        }
        val proxy = WorkerEgressProxy(addressAllowed = { true }, idleTimeoutMs = 300)
        try {
            tunnel(proxy.settings, ticking.localPort).use { socket ->
                // One direction carries data for ~1 s, three times the idle timeout.
                assertEquals((0 until 10).map { it.toByte() }, socket.getInputStream().readAllBytes().toList())
            }
        } finally {
            proxy.close(); ticking.close()
        }
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
