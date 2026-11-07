package com.lagradost.macos

import java.io.File
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.util.Base64
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager

/**
 * The certificate roots the user's Mac trusts, in addition to the JDK's
 * bundled `cacerts`.
 *
 * JDK 17 cannot read keychain trust settings itself (`KeychainStore` is empty
 * and there is no `KeychainStore-ROOT`), so a network whose TLS is inspected
 * by a root installed in the keychain (antivirus HTTPS scanning, a company
 * proxy, an MDM profile) failed every engine connection while Safari worked.
 * The app exports the roots the user and admin trust domains mark as trusted
 * for SSL to a PEM file (owner-only) and passes its path at launch; the engine
 * and each worker build one trust manager whose anchors are `cacerts` plus
 * those roots.
 *
 * Used by the verified provider client (`app`), repository traffic, the DoH
 * resolver and the JDK default [SSLContext]. `insecureApp` stays unverified
 * (Android parity), and repository signing does not depend on TLS trust
 * (docs/repository-signing.md).
 */
object SystemTrust {
    /** The worker's copy of the launch option: the path of the exported anchors. */
    const val ANCHORS_PROPERTY = "cs.trust.anchors"
    /** A keychain holds a few hundred roots at most; anything larger is not an export. */
    const val MAX_FILE_BYTES = 1L shl 20
    const val MAX_ANCHORS = 256

    /** A trust manager over `cacerts` plus the extra anchors, and an [SSLContext] using it. */
    class Material(val trustManager: X509TrustManager, val sslContext: SSLContext, val extraAnchors: Int)

    /** The installed material; null trusts `cacerts` only. */
    @Volatile var current: Material? = null
        private set

    /** The anchors file, once [install] accepted one (workers are told to read it). */
    @Volatile var anchorsFile: File? = null
        private set

    /**
     * Startup, before any client is built: trusts the anchors in [path] as
     * well and makes that the JDK default context (URLConnection, extensions'
     * own sockets). A missing, oversized or unreadable file changes nothing.
     */
    @Synchronized
    fun install(path: String?) {
        val file = path?.takeIf { it.isNotBlank() }?.let(::File) ?: return
        val material = runCatching { load(file) }.getOrElse { failure ->
            DaemonLog.warn("trust.anchors_unreadable", mapOf("error" to failure.javaClass.simpleName))
            null
        } ?: return
        current = material
        anchorsFile = file.absoluteFile
        SSLContext.setDefault(material.sslContext)
        DaemonLog.info("trust.anchors_installed", mapOf("anchors" to material.extraAnchors))
    }

    /** Tests: use [material] (or only `cacerts` when null) for the clients [NetworkSetup] builds. */
    @Synchronized
    internal fun useForTest(material: Material?) {
        current = material
        anchorsFile = null
    }

    /** Reads [file]; null when it holds no usable anchor or is larger than [MAX_FILE_BYTES]. */
    fun load(file: File): Material? {
        if (!file.isFile || file.length() > MAX_FILE_BYTES) return null
        val bytes = file.inputStream().use { it.readNBytes((MAX_FILE_BYTES + 1).toInt()) }
        if (bytes.size > MAX_FILE_BYTES) return null
        return material(parse(String(bytes, Charsets.US_ASCII)))
    }

    /**
     * The certificates in PEM [text]. Malformed blocks, non-X.509 content and
     * expired certificates are skipped; at most [MAX_ANCHORS] are kept.
     */
    fun parse(text: String): List<X509Certificate> {
        if (text.length > MAX_FILE_BYTES) return emptyList()
        val factory = CertificateFactory.getInstance("X.509")
        val now = java.util.Date()
        return PEM_BLOCK.findAll(text).mapNotNull { block ->
            runCatching {
                val der = Base64.getMimeDecoder().decode(block.groupValues[1])
                val certificate = factory.generateCertificate(der.inputStream()) as X509Certificate
                certificate.takeIf { now.before(it.notAfter) }
            }.getOrNull()
        }.distinctBy { it.encoded.contentHashCode() to it.subjectX500Principal }
            .take(MAX_ANCHORS).toList()
    }

    /** One trust manager whose anchors are the JDK defaults plus [extra]; null when [extra] is empty. */
    fun material(extra: List<X509Certificate>): Material? {
        if (extra.isEmpty()) return null
        val defaultManager = defaultTrustManager() ?: return null
        val store = KeyStore.getInstance(KeyStore.getDefaultType()).apply { load(null, null) }
        defaultManager.acceptedIssuers.forEachIndexed { index, anchor -> store.setCertificateEntry("jdk-$index", anchor) }
        extra.forEachIndexed { index, anchor -> store.setCertificateEntry("system-$index", anchor) }
        val trustManager = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply { init(store) }
            .trustManagers.filterIsInstance<X509TrustManager>().firstOrNull() ?: return null
        val context = SSLContext.getInstance("TLS").apply { init(null, arrayOf(trustManager), null) }
        return Material(trustManager, context, extra.size)
    }

    private fun defaultTrustManager(): X509TrustManager? =
        TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply { init(null as KeyStore?) }
            .trustManagers.filterIsInstance<X509TrustManager>().firstOrNull()

    private val PEM_BLOCK = Regex("-----BEGIN CERTIFICATE-----([A-Za-z0-9+/=\\s]{1,65536}?)-----END CERTIFICATE-----")
}
