package com.lagradost.macos

import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.net.InetAddress

/**
 * Where an extension may ask the app's WebKit to go (security audit 2026-11, H1).
 *
 * An extension can load pages in the app's WebKit (WebViewResolver, its own
 * WebViews, challenge solves) and read what they return. WebKit runs in the
 * app, outside the worker sandbox, so the app routes that web content through
 * the engine's web-content egress proxy, which connects only to public
 * addresses. WebKit connects to loopback and link-local destinations without
 * asking any proxy, and the app blocks those itself; this check refuses them,
 * and every other destination named as this Mac or the local network by its
 * spelling alone, before a request reaches the app. Names that only resolve to
 * a local address are left to the proxy, which resolves them once and connects
 * to exactly the address it checked (so DNS rebinding cannot slip past it).
 */
internal object WebDestination {
    /** Special-use names that are never public (RFC 6761, RFC 6762, RFC 8375) and common LAN suffixes. */
    private val localSuffixes = listOf(".localhost", ".local", ".home.arpa", ".internal", ".lan")

    /** True when [url] is not an http(s) URL, or names this Mac or the local network by its spelling. */
    fun isLocal(url: String): Boolean {
        val parsed = url.toHttpUrlOrNull() ?: return true
        return isLocalHost(parsed.host)
    }

    /** [host] as OkHttp canonicalizes it: lowercase, IPv6 without brackets. */
    fun isLocalHost(rawHost: String): Boolean {
        val host = rawHost.lowercase(java.util.Locale.ROOT).trimEnd('.')
        if (host.isEmpty() || host == "localhost" || localSuffixes.any { host.endsWith(it) }) return true
        if (':' in host) {
            val address = runCatching { InetAddress.getByName(host) }.getOrNull() ?: return true
            return !RepositoryTransport.isPublicAddress(address)
        }
        if (lastLabelIsNumeric(host)) {
            // Browsers read "2130706433", "0x7f.1" and "0177.0.0.1" as 127.0.0.1 (WHATWG URL).
            val bytes = ipv4(host) ?: return true
            return !RepositoryTransport.isPublicAddress(InetAddress.getByAddress(bytes))
        }
        // A single label is completed with the Mac's search domains: a LAN host.
        return '.' !in host
    }

    fun requireRemote(url: String, what: String) {
        require(!isLocal(url)) { "$what must be a public web address" }
    }

    private fun lastLabelIsNumeric(host: String): Boolean {
        val last = host.split('.').lastOrNull { it.isNotEmpty() } ?: return false
        return last.all { it in '0'..'9' } || (last.startsWith("0x") && last.drop(2).all { it in '0'..'9' || it in 'a'..'f' })
    }

    /** WHATWG IPv4 parsing: one to four parts, each decimal, octal (leading 0) or hex (0x); null when invalid. */
    internal fun ipv4(host: String): ByteArray? {
        val parts = host.split('.').let { if (it.size > 1 && it.last().isEmpty()) it.dropLast(1) else it }
        if (parts.isEmpty() || parts.size > 4) return null
        val numbers = parts.map { part -> number(part) ?: return null }
        if (numbers.dropLast(1).any { it > 255 }) return null
        val last = numbers.last()
        if (last >= 1L shl (8 * (5 - numbers.size))) return null
        var value = last
        numbers.dropLast(1).forEachIndexed { index, part -> value += part shl (8 * (3 - index)) }
        return ByteArray(4) { index -> (value shr (8 * (3 - index))).toByte() }
    }

    private fun number(part: String): Long? {
        if (part.isEmpty()) return null
        val (digits, radix) = when {
            part.startsWith("0x") -> part.drop(2) to 16
            part.length > 1 && part.startsWith("0") -> part.drop(1) to 8
            else -> part to 10
        }
        if (digits.isEmpty()) return 0
        if (digits.length > 12) return null
        return digits.toLongOrNull(radix)
    }
}
