package com.lagradost.macos.network

import okhttp3.Dns
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.dnsoverhttps.DnsOverHttps
import java.net.InetAddress
import java.net.UnknownHostException

/**
 * DNS-over-HTTPS resolvers (Android `network/DohProviders.kt` parity, plus a
 * user-supplied endpoint). Bootstrap IPs let the resolver itself be reached
 * without the system resolver — the point of DoH on ISP-filtered networks.
 */
enum class DohProvider(val id: String, val label: String, val url: String?, val bootstrap: List<String>) {
    SYSTEM("system", "System", null, emptyList()),
    GOOGLE("google", "Google", "https://dns.google/dns-query", listOf("8.8.4.4", "8.8.8.8")),
    CLOUDFLARE(
        "cloudflare", "Cloudflare", "https://cloudflare-dns.com/dns-query",
        listOf("1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"),
    ),
    ADGUARD("adguard", "AdGuard", "https://dns.adguard.com/dns-query", listOf("94.140.14.140", "94.140.14.141")),
    DNS_WATCH("dnswatch", "DNS.Watch", "https://resolver2.dns.watch/dns-query", listOf("84.200.69.80", "84.200.70.40")),
    QUAD9("quad9", "Quad9", "https://dns.quad9.net/dns-query", listOf("9.9.9.9", "149.112.112.112")),
    DNS_SB("dnssb", "DNS.SB", "https://doh.dns.sb/dns-query", listOf("185.222.222.222", "45.11.45.11")),
    CANADIAN_SHIELD(
        "canadianshield", "Canadian Shield", "https://private.canadianshield.cira.ca/dns-query",
        listOf("149.112.121.10", "149.112.122.10"),
    ),
    CUSTOM("custom", "Custom", null, emptyList());

    companion object {
        fun fromId(id: String?): DohProvider? = entries.firstOrNull { it.id.equals(id, ignoreCase = true) }

        /** A custom endpoint must be an absolute https URL (DoH is TLS by definition). */
        fun validateCustomUrl(url: String?): String? {
            val trimmed = url?.trim().orEmpty()
            val parsed = trimmed.toHttpUrlOrNull() ?: return null
            if (!parsed.isHttps || parsed.host.isBlank()) return null
            return parsed.toString()
        }
    }
}

object DnsResolverFactory {
    /**
     * Builds the resolver for [provider]. Returns null for SYSTEM (OkHttp's
     * default). DoH resolvers fall back to the system resolver only when the
     * DoH endpoint itself is unreachable, so a resolver outage degrades to
     * "works like before" instead of "nothing loads".
     */
    fun build(provider: DohProvider, customUrl: String?, transport: OkHttpClient): Dns? {
        val url = when (provider) {
            DohProvider.SYSTEM -> return null
            DohProvider.CUSTOM -> DohProvider.validateCustomUrl(customUrl) ?: return null
            else -> provider.url ?: return null
        }
        val builder = DnsOverHttps.Builder()
            .client(transport)
            .url(url.toHttpUrlOrNull() ?: return null)
            .includeIPv6(true)
        if (provider.bootstrap.isNotEmpty()) {
            builder.bootstrapDnsHosts(provider.bootstrap.map { InetAddress.getByName(it) })
        }
        return FallbackDns(builder.build(), Dns.SYSTEM)
    }
}

/** Primary resolver with a system fallback when the primary cannot answer at all. */
class FallbackDns(private val primary: Dns, private val fallback: Dns) : Dns {
    override fun lookup(hostname: String): List<InetAddress> = try {
        primary.lookup(hostname)
    } catch (e: UnknownHostException) {
        com.lagradost.macos.DaemonLog.warn(
            "network.doh_fallback",
            mapOf("host" to hostname, "error" to (e.message ?: "")),
        )
        fallback.lookup(hostname)
    }
}
