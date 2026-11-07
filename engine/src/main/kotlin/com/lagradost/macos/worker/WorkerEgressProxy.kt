package com.lagradost.macos.worker

import com.lagradost.cloudstream3.app
import com.lagradost.macos.DaemonLog
import com.lagradost.macos.RepositoryTransport
import kotlinx.serialization.Serializable
import java.io.DataInputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.HexFormat
import java.util.concurrent.Executors
import java.util.concurrent.Semaphore
import java.util.concurrent.atomic.AtomicLong

/** How a worker reaches the network: the engine's egress proxy (sent in INIT, never on argv). */
@Serializable
internal data class EgressSettings(val host: String, val port: Int, val username: String, val password: String)

/**
 * The only way out of a sandboxed worker (security audit H1, LAN follow-up).
 * The worker sandbox allows TCP to this one loopback port and nothing else;
 * inside, a ProxySelector sends every connection here. This SOCKS5 server
 * (RFC 1928, username/password RFC 1929, CONNECT only) resolves names with the
 * engine's own resolver (the user's DNS-over-HTTPS setting) and connects only
 * to public addresses: loopback, private, link-local, CGNAT, multicast and
 * documentation ranges are refused, so an extension reaches neither this Mac's
 * services nor the local network. It connects directly, never through the
 * system proxy, so the address check always applies (as for the media relay).
 */
internal class WorkerEgressProxy(
    private val addressAllowed: (InetAddress) -> Boolean = RepositoryTransport::isPublicAddress,
    private val resolve: (String) -> List<InetAddress> = { host -> app.baseClient.dns.lookup(host) },
    private val maxConnections: Int = MAX_CONNECTIONS,
    /** A tunnel with no bytes in either direction for this long is closed, freeing its slot. */
    private val idleTimeoutMs: Long = TUNNEL_IDLE_MS,
) : AutoCloseable {
    private val server = ServerSocket().apply { bind(InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 128) }
    private val username = "worker"
    private val password = HexFormat.of().formatHex(ByteArray(32).also(SecureRandom()::nextBytes))
    private val slots = Semaphore(maxConnections)
    private val pool = Executors.newCachedThreadPool { task -> Thread(task, "worker-egress").apply { isDaemon = true } }
    /** Refusals since start (diagnostics and tests). */
    val refused = AtomicLong()
    private val lastSaturationLog = AtomicLong(0)
    val port: Int get() = server.localPort
    val settings: EgressSettings get() = EgressSettings(InetAddress.getLoopbackAddress().hostAddress, port, username, password)

    init {
        Thread({ acceptLoop() }, "worker-egress-accept").apply { isDaemon = true }.start()
    }

    private fun acceptLoop() {
        while (!server.isClosed) {
            val client = try { server.accept() } catch (_: IOException) { break }
            if (!slots.tryAcquire()) {
                runCatching { client.close() }
                // Callers only see a connection closed at once; say why, at most once a minute.
                val now = System.currentTimeMillis()
                val last = lastSaturationLog.get()
                if (now - last >= 60_000 && lastSaturationLog.compareAndSet(last, now)) {
                    DaemonLog.warn("worker.egress_saturated", mapOf("slots" to maxConnections))
                }
                continue
            }
            pool.execute {
                try { serve(client) } finally { slots.release() }
            }
        }
    }

    private fun serve(client: Socket) {
        client.use { socket ->
            socket.soTimeout = HANDSHAKE_TIMEOUT_MS
            val input = DataInputStream(socket.getInputStream())
            val output = socket.getOutputStream()
            if (!authenticate(input, output)) return
            val target = readConnect(input, output) ?: return
            val upstream = connect(target)
            if (upstream == null) {
                refused.incrementAndGet()
                reply(output, REPLY_NOT_ALLOWED)
                return
            }
            upstream.use { remote ->
                reply(output, REPLY_SUCCEEDED)
                // A tunnel used to hold its slot until both peers closed it, so
                // an upstream that vanished (a NAT or Wi-Fi drop, no FIN) kept
                // it forever and enough of them refused every new connection.
                // Reads now wake up periodically; the tunnel closes once neither
                // direction has moved for idleTimeoutMs. Keepalive detects dead
                // peers below that.
                val poll = idleTimeoutMs.coerceIn(1, IDLE_POLL_MS).toInt()
                socket.soTimeout = poll
                remote.soTimeout = poll
                runCatching { socket.keepAlive = true }
                runCatching { remote.keepAlive = true }
                val activity = AtomicLong(System.currentTimeMillis())
                val back = pool.submit { pipe(remote.getInputStream(), output, socket, activity) }
                pipe(input, remote.getOutputStream(), remote, activity)
                runCatching { back.get() }
            }
        }
    }

    /** Greeting, then RFC 1929 username/password: the worker's per-engine secret. */
    private fun authenticate(input: DataInputStream, output: OutputStream): Boolean {
        if (input.readUnsignedByte() != 5) return false
        val methods = ByteArray(input.readUnsignedByte()).also(input::readFully)
        if (USER_PASSWORD !in methods) {
            output.write(byteArrayOf(5, NO_ACCEPTABLE.toByte())); output.flush()
            return false
        }
        output.write(byteArrayOf(5, USER_PASSWORD)); output.flush()
        if (input.readUnsignedByte() != 1) return false
        val user = ByteArray(input.readUnsignedByte()).also(input::readFully)
        val pass = ByteArray(input.readUnsignedByte()).also(input::readFully)
        val ok = MessageDigest.isEqual(user, username.toByteArray()) && MessageDigest.isEqual(pass, password.toByteArray())
        output.write(byteArrayOf(1, if (ok) 0 else 1)); output.flush()
        return ok
    }

    /** A CONNECT target: a name to resolve, or an address the worker already resolved. */
    private class Target(val host: String?, val address: InetAddress?, val port: Int)

    /** CONNECT request; any other command or address type is refused. */
    private fun readConnect(input: DataInputStream, output: OutputStream): Target? {
        if (input.readUnsignedByte() != 5) return null
        val command = input.readUnsignedByte()
        input.readUnsignedByte() // reserved
        var host: String? = null
        var address: InetAddress? = null
        when (input.readUnsignedByte()) {
            1 -> address = InetAddress.getByAddress(ByteArray(4).also(input::readFully))
            3 -> host = String(ByteArray(input.readUnsignedByte()).also(input::readFully), Charsets.US_ASCII)
            4 -> address = InetAddress.getByAddress(ByteArray(16).also(input::readFully))
            else -> { reply(output, REPLY_ADDRESS_UNSUPPORTED); return null }
        }
        val port = input.readUnsignedShort()
        if (command != CONNECT) { reply(output, REPLY_COMMAND_UNSUPPORTED); return null }
        if (port == 0 || (host != null && (host.isEmpty() || host.length > 253 || host.any { it <= ' ' }))) {
            reply(output, REPLY_NOT_ALLOWED); return null
        }
        return Target(host, address, port)
    }

    /** Resolves names with the engine's resolver; null unless every address is public and one answers. */
    private fun connect(target: Target): Socket? {
        val port = target.port
        val addresses = target.address?.let(::listOf) ?: runCatching { resolve(requireNotNull(target.host)) }.getOrNull().orEmpty()
        if (addresses.isEmpty() || addresses.any { !addressAllowed(it) }) {
            DaemonLog.info("worker.egress_refused", mapOf("reason" to if (addresses.isEmpty()) "unresolved" else "restricted address"))
            return null
        }
        for (address in addresses) {
            val socket = Socket()
            try {
                socket.connect(InetSocketAddress(address, port), CONNECT_TIMEOUT_MS)
                return socket
            } catch (_: IOException) {
                runCatching { socket.close() }
            }
        }
        return null
    }

    private fun reply(output: OutputStream, code: Int) {
        runCatching {
            output.write(byteArrayOf(5, code.toByte(), 0, 1, 0, 0, 0, 0, 0, 0))
            output.flush()
        }
    }

    /** One direction of a tunnel. [activity] is shared by both: a busy download keeps an idle upload alive. */
    private fun pipe(from: InputStream, to: OutputStream, toSocket: Socket, activity: AtomicLong) {
        val buffer = ByteArray(BUFFER_BYTES)
        try {
            while (true) {
                val read = try {
                    from.read(buffer)
                } catch (_: SocketTimeoutException) {
                    if (System.currentTimeMillis() - activity.get() >= idleTimeoutMs) break
                    continue
                }
                if (read < 0) break
                activity.set(System.currentTimeMillis())
                to.write(buffer, 0, read)
                to.flush()
            }
        } catch (_: IOException) {
        } finally {
            runCatching { toSocket.shutdownOutput() }
        }
    }

    override fun close() {
        runCatching { server.close() }
        pool.shutdownNow()
    }

    companion object {
        const val MAX_CONNECTIONS = 256
        private const val HANDSHAKE_TIMEOUT_MS = 10_000
        private const val CONNECT_TIMEOUT_MS = 15_000
        /** Longer than any keep-alive OkHttp or WebKit holds an idle connection for (5 min). */
        const val TUNNEL_IDLE_MS = 10 * 60_000L
        private const val IDLE_POLL_MS = 30_000L
        private const val BUFFER_BYTES = 32 * 1024
        private const val CONNECT = 1
        private const val USER_PASSWORD: Byte = 2
        private const val NO_ACCEPTABLE = 0xff
        private const val REPLY_SUCCEEDED = 0
        private const val REPLY_NOT_ALLOWED = 2
        private const val REPLY_COMMAND_UNSUPPORTED = 7
        private const val REPLY_ADDRESS_UNSUPPORTED = 8

        /** One per engine, started with the first worker. */
        private val shared: WorkerEgressProxy by lazy { WorkerEgressProxy() }

        /** Tests only: a proxy with its own address rule. */
        @Volatile internal var testOverride: WorkerEgressProxy? = null

        /** The proxy new workers are pointed at. */
        val active: WorkerEgressProxy get() = testOverride ?: shared

        /**
         * The proxy the app routes extension-driven WebKit content through
         * (security audit 2026-11, H1): page loads an extension asks for run in
         * the app, outside the worker sandbox, so they get the same public-only
         * address rule. Its own instance, so a busy page cannot use up the
         * workers' connection budget, with its own password (sent only to the
         * authenticated app).
         */
        private val webContentShared: WorkerEgressProxy by lazy { WorkerEgressProxy() }

        /** Tests only. */
        @Volatile internal var webContentTestOverride: WorkerEgressProxy? = null

        val webContent: WorkerEgressProxy get() = webContentTestOverride ?: webContentShared
    }
}
