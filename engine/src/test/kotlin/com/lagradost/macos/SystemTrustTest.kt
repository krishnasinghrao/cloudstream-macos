package com.lagradost.macos

import com.lagradost.macos.worker.WorkerLauncher
import com.sun.net.httpserver.HttpsConfigurator
import com.sun.net.httpserver.HttpsServer
import okhttp3.Request
import java.io.File
import java.net.InetAddress
import java.net.InetSocketAddress
import java.nio.file.Files
import java.security.KeyStore
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLException
import kotlin.test.*

/**
 * Roots the Mac trusts (exported from the keychain by the app) are trusted by
 * the verified clients in addition to the JDK's: a server whose chain ends at
 * such a root, as behind a TLS-inspecting proxy or antivirus, is accepted only
 * when that root was supplied.
 */
class SystemTrustTest {
    private lateinit var server: HttpsServer
    private val executor = Executors.newFixedThreadPool(2)
    private val directory = Files.createTempDirectory("system-trust-test-").toFile()
    private val url get() = "https://127.0.0.1:${server.address.port}/ok"

    @BeforeTest fun before() {
        server = HttpsServer.create(InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0)
        server.httpsConfigurator = HttpsConfigurator(fixture.serverContext)
        server.executor = executor
        server.createContext("/ok") { exchange -> exchange.use {
            val bytes = "ok".toByteArray()
            exchange.sendResponseHeaders(200, bytes.size.toLong())
            exchange.responseBody.write(bytes)
        } }
        server.start()
    }

    @AfterTest fun after() {
        SystemTrust.useForTest(null)
        NetworkSetup.apply(DaemonState.NetworkSettings())
        server.stop(0)
        executor.shutdownNow()
        directory.deleteRecursively()
    }

    private fun anchors(text: String): File = File(directory, "anchors-${System.nanoTime()}.pem").apply { writeText(text) }

    private fun fetchBoth() {
        val request = Request.Builder().url(url).build()
        // Fresh connections each time: a pooled one would skip the handshake under test.
        NetworkSetup.connectionPool.evictAll()
        com.lagradost.cloudstream3.app.baseClient.newCall(request).execute().use { assertEquals("ok", it.body.string()) }
        NetworkSetup.repositoryClient().newCall(request).execute().use { assertEquals("ok", it.body.string()) }
    }

    private fun assertBothRefuse() {
        val request = Request.Builder().url(url).build()
        NetworkSetup.connectionPool.evictAll()
        assertFailsWith<SSLException> { com.lagradost.cloudstream3.app.baseClient.newCall(request).execute().close() }
        assertFailsWith<SSLException> { NetworkSetup.repositoryClient().newCall(request).execute().close() }
    }

    @Test fun `a server signed by a supplied anchor is trusted only with that anchor`() {
        SystemTrust.useForTest(null)
        NetworkSetup.apply(DaemonState.NetworkSettings(httpCacheMb = 0))
        assertBothRefuse()

        // Another root the Mac trusts does not vouch for this server.
        SystemTrust.useForTest(SystemTrust.load(anchors(fixture.unrelatedPem)))
        NetworkSetup.apply(DaemonState.NetworkSettings(httpCacheMb = 0))
        assertBothRefuse()

        SystemTrust.useForTest(assertNotNull(SystemTrust.load(anchors(fixture.unrelatedPem + fixture.rootPem))))
        NetworkSetup.apply(DaemonState.NetworkSettings(httpCacheMb = 0))
        fetchBoth()

        // Hostname verification still applies to a chain ending at a supplied anchor.
        val wrongHost = com.lagradost.cloudstream3.app.baseClient.newBuilder().dns { listOf(InetAddress.getLoopbackAddress()) }.build()
        assertFailsWith<SSLException> {
            wrongHost.newCall(Request.Builder().url("https://wrong-host.invalid:${server.address.port}/ok").build()).execute().close()
        }

        SystemTrust.useForTest(null)
        NetworkSetup.apply(DaemonState.NetworkSettings(httpCacheMb = 0))
        assertBothRefuse()
    }

    @Test fun `the JDK roots stay trusted alongside the supplied anchors`() {
        val material = assertNotNull(SystemTrust.material(SystemTrust.parse(fixture.rootPem)))
        val jdk = javax.net.ssl.TrustManagerFactory.getInstance(javax.net.ssl.TrustManagerFactory.getDefaultAlgorithm())
            .apply { init(null as KeyStore?) }.trustManagers.filterIsInstance<javax.net.ssl.X509TrustManager>().single()
        val issuers = material.trustManager.acceptedIssuers.toSet()
        assertTrue(issuers.containsAll(jdk.acceptedIssuers.toList()))
        assertEquals(jdk.acceptedIssuers.size + 1, issuers.size)
        assertEquals(1, material.extraAnchors)
    }

    @Test fun `malformed input is skipped and only well formed certificates are kept`() {
        val noise = """
            -----BEGIN CERTIFICATE-----
            not base64 at all !!!
            -----END CERTIFICATE-----
            -----BEGIN CERTIFICATE-----
            ${java.util.Base64.getEncoder().encodeToString(ByteArray(300) { it.toByte() })}
            -----END CERTIFICATE-----
            -----BEGIN CERTIFICATE-----
            ${fixture.rootPem.lines().filter { !it.startsWith("-----") }.joinToString("").take(200)}
            -----END CERTIFICATE-----
            -----BEGIN PRIVATE KEY-----
            AAAA
            -----END PRIVATE KEY-----
            -----BEGIN CERTIFICATE-----
        """.trimIndent()
        assertEquals(emptyList(), SystemTrust.parse(noise))
        assertNull(SystemTrust.load(anchors(noise)))
        assertNull(SystemTrust.load(anchors("")))
        assertNull(SystemTrust.load(File(directory, "missing.pem")))
        assertNull(SystemTrust.material(emptyList()))

        val mixed = SystemTrust.parse(noise + "\n" + fixture.rootPem + fixture.rootPem)
        assertEquals(1, mixed.size, "duplicates collapse and malformed blocks are skipped")
        assertEquals(fixture.rootSubject, mixed.single().subjectX500Principal.name)
    }

    @Test fun `oversized input is ignored`() {
        val padding = "#".repeat((SystemTrust.MAX_FILE_BYTES).toInt())
        assertNull(SystemTrust.load(anchors(fixture.rootPem + padding)))
        assertEquals(emptyList(), SystemTrust.parse(fixture.rootPem + padding))
        val many = (1..SystemTrust.MAX_ANCHORS + 10).joinToString("") { fixture.rootPem }
        assertTrue(SystemTrust.parse(many).size <= SystemTrust.MAX_ANCHORS)
    }

    @Test fun `install ignores an absent path and leaves the default trust`() {
        SystemTrust.useForTest(null)
        SystemTrust.install(null)
        SystemTrust.install("")
        SystemTrust.install(File(directory, "missing.pem").path)
        assertNull(SystemTrust.current)
        assertNull(SystemTrust.anchorsFile)
    }

    @Test fun `workers are told about the anchors and may read only that file`() {
        val file = anchors(fixture.rootPem)
        val launcher = WorkerLauncher(sandboxed = true, egressPort = { 1 }, trustAnchors = { file })
        val home = File(directory, "worker-home").apply { mkdirs() }
        val artifact = File(directory, "x.cs3").apply { writeText("") }
        val canonical = file.canonicalPath
        val profile = launcher.profile(home.canonicalPath, artifact.canonicalPath)
        assertTrue(profile.contains("(allow file-read* (literal \"$canonical\"))"), profile)
        assertFalse(profile.contains("(subpath \"${file.parentFile.canonicalPath}\")"), profile)
        val command = launcher.command(home, artifact)
        assertTrue(command.contains("-D${SystemTrust.ANCHORS_PROPERTY}=$canonical"), command.toString())

        val without = WorkerLauncher(sandboxed = true, egressPort = { 1 }, trustAnchors = { null })
        assertFalse(without.command(home, artifact).any { it.startsWith("-D${SystemTrust.ANCHORS_PROPERTY}") })
    }

    private class Fixture(val serverContext: SSLContext, val rootPem: String, val rootSubject: String, val unrelatedPem: String)

    companion object {
        private const val PASSWORD = "fixture-password"

        /** A root CA, a server certificate it issued for localhost/127.0.0.1, and an unrelated root. */
        private val fixture: Fixture by lazy {
            val directory = Files.createTempDirectory("system-trust-fixture-").toFile()
            try {
                val ca = File(directory, "ca.p12").path
                val other = File(directory, "other.p12").path
                val serverStore = File(directory, "server.p12").path
                val csr = File(directory, "server.csr").path
                val issued = File(directory, "server.pem").path
                val rootPem = File(directory, "root.pem").path
                val otherPem = File(directory, "other.pem").path
                val rootSubject = "CN=CloudStream Test Inspection Root"
                fun store(path: String) = arrayOf("-storetype", "PKCS12", "-keystore", path, "-storepass", PASSWORD, "-noprompt")
                keytool("-genkeypair", "-alias", "ca", "-keyalg", "RSA", "-keysize", "2048", "-validity", "2",
                    "-dname", rootSubject, "-ext", "bc:c", *store(ca))
                keytool("-genkeypair", "-alias", "other", "-keyalg", "RSA", "-keysize", "2048", "-validity", "2",
                    "-dname", "CN=CloudStream Unrelated Root", "-ext", "bc:c", *store(other))
                keytool("-genkeypair", "-alias", "server", "-keyalg", "RSA", "-keysize", "2048", "-validity", "1",
                    "-dname", "CN=localhost", *store(serverStore))
                keytool("-certreq", "-alias", "server", "-file", csr, *store(serverStore))
                keytool("-gencert", "-alias", "ca", "-infile", csr, "-outfile", issued, "-rfc", "-validity", "1",
                    "-ext", "SAN=dns:localhost,ip:127.0.0.1", "-ext", "EKU=serverAuth", *store(ca))
                keytool("-exportcert", "-alias", "ca", "-rfc", "-file", rootPem, *store(ca))
                keytool("-exportcert", "-alias", "other", "-rfc", "-file", otherPem, *store(other))
                keytool("-importcert", "-alias", "ca", "-file", rootPem, *store(serverStore))
                keytool("-importcert", "-alias", "server", "-file", issued, *store(serverStore))

                val keys = KeyStore.getInstance("PKCS12").apply { File(serverStore).inputStream().use { load(it, PASSWORD.toCharArray()) } }
                val managers = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).apply { init(keys, PASSWORD.toCharArray()) }
                val context = SSLContext.getInstance("TLS").apply { init(managers.keyManagers, null, null) }
                Fixture(context, File(rootPem).readText(), rootSubject, File(otherPem).readText())
            } finally { directory.deleteRecursively() }
        }

        private fun keytool(vararg arguments: String) {
            val log = Files.createTempFile("keytool-", ".log").toFile()
            try {
                val process = ProcessBuilder(File(System.getProperty("java.home"), "bin/keytool").path, *arguments)
                    .redirectErrorStream(true).redirectOutput(log).start()
                check(process.waitFor(30, TimeUnit.SECONDS)) { process.destroyForcibly(); "keytool timed out" }
                check(process.exitValue() == 0) { "keytool ${arguments.first()}: ${log.readText()}" }
            } finally { log.delete() }
        }
    }
}
