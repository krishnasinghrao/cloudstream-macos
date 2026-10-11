package com.lagradost.macos

import com.lagradost.cloudstream3.UnsafeSSL
import com.lagradost.cloudstream3.app
import com.lagradost.cloudstream3.insecureApp
import com.lagradost.macos.DaemonState.NetworkSettings
import com.lagradost.macos.network.DnsResolverFactory
import com.lagradost.macos.network.DohProvider
import com.lagradost.macos.network.RetryInterceptor
import okhttp3.Cache
import okhttp3.OkHttpClient
import java.io.File

/**
 * Builds the HTTP stack every provider uses (Android `buildDefaultClient`
 * parity): DNS-over-HTTPS resolver, on-disk response cache, the anti-bot
 * [SolveInterceptor] and a transport-level [RetryInterceptor].
 *
 * Both global clients (`app` for verified TLS, `insecureApp` for broken-host
 * TLS) expose a settable `baseClient`. The clients as the library created
 * them are captured once; every [apply] rebuilds from those pristine
 * builders, so re-applying settings never stacks interceptors.
 */
object NetworkSetup {
    const val MAX_CACHE_MB = 500
    private const val MB = 1024L * 1024L

    private var pristine: Pair<OkHttpClient, OkHttpClient>? = null
    private var cache: Cache? = null
    @Volatile private var repositorySnapshot = OkHttpClient()

    /** Immutable trusted configuration, independent of extension-mutated app clients. */
    internal fun repositoryClient(): OkHttpClient = repositorySnapshot

    @Volatile
    var current: NetworkSettings = NetworkSettings()
        private set

    val cacheDir: File get() = File(CloudDirs.home, "cache/http")

    /** Startup: applies the persisted settings, falling back to defaults. */
    fun install() {
        val persisted = runCatching { DaemonState.networkSettings() }.getOrDefault(NetworkSettings())
        val applied = runCatching { apply(persisted) }.getOrElse { error ->
            DaemonLog.warn("network.apply_failed", mapOf("error" to (error.message ?: "")))
            apply(NetworkSettings())
        }
        DaemonLog.info("network.installed", mapOf("dns" to applied.dns, "cacheMb" to applied.httpCacheMb))
    }

    /**
     * Normalises [settings] (unknown resolver → system, cache clamped) and
     * rebuilds both clients. Throws [IllegalArgumentException] for a custom
     * resolver without a valid https URL.
     */
    @Synchronized
    @OptIn(UnsafeSSL::class) // the engine owns the insecure client and applies the same DNS/cache/retry stack to it
    fun apply(settings: NetworkSettings): NetworkSettings {
        val normalized = normalize(settings)
        val (verified, insecure) = pristine ?: (app.baseClient to insecureApp.baseClient).also { pristine = it }

        val cacheBytes = normalized.httpCacheMb * MB
        if (cache?.maxSize() != cacheBytes) {
            runCatching { cache?.close() }
            cache = if (cacheBytes > 0) Cache(cacheDir.apply { mkdirs() }, cacheBytes) else null
        }

        // The resolver's own queries go over the pristine client: no cache, no
        // interceptors, and no recursion through the DoH resolver itself.
        val dns = DnsResolverFactory.build(
            DohProvider.fromId(normalized.dns) ?: DohProvider.SYSTEM,
            normalized.customDohUrl,
            verified,
        )

        app.baseClient = rebuild(verified, dns, normalized)
        insecureApp.baseClient = rebuild(insecure, dns, normalized)
        repositorySnapshot = verified.newBuilder().apply {
            interceptors().clear()
            networkInterceptors().clear()
            cache(null)
            dns(dns ?: okhttp3.Dns.SYSTEM)
            retryOnConnectionFailure(false)
            if (normalized.retryOnNetworkError) addInterceptor(RetryInterceptor())
        }.build()
        current = normalized
        return normalized
    }

    /**
     * One pool for both provider clients, with idle connections evicted
     * quickly: scrapers touch many hosts once, and each idle socket is a file
     * descriptor the (sandboxed, bounded) worker keeps (Remediation 5.1).
     */
    internal val connectionPool = okhttp3.ConnectionPool(MAX_IDLE_CONNECTIONS, KEEP_ALIVE_SECONDS, java.util.concurrent.TimeUnit.SECONDS)
    const val MAX_IDLE_CONNECTIONS = 5
    const val KEEP_ALIVE_SECONDS = 30L

    private fun rebuild(base: OkHttpClient, dns: okhttp3.Dns?, settings: NetworkSettings): OkHttpClient =
        base.newBuilder().apply {
            // Outermost: sees the final response, after challenges and retries,
            // and reclaims its body if the extension never closes it.
            interceptors().add(0, com.lagradost.macos.network.ResponseTracker.interceptor)
            connectionPool(connectionPool)
            cache(cache)
            dns?.let { dns(it) }
            // Order: challenge handling wraps transport retries, so a request
            // retried after a reset still gets its clearance cookies.
            addInterceptor(SolveInterceptor())
            if (settings.retryOnNetworkError) addInterceptor(RetryInterceptor())
        }.build()

    fun normalize(settings: NetworkSettings): NetworkSettings {
        val provider = DohProvider.fromId(settings.dns) ?: DohProvider.SYSTEM
        val custom = if (provider == DohProvider.CUSTOM) {
            DohProvider.validateCustomUrl(settings.customDohUrl)
                ?: throw IllegalArgumentException("A custom resolver needs an https:// DNS-over-HTTPS URL")
        } else {
            settings.customDohUrl?.let(DohProvider::validateCustomUrl)
        }
        return settings.copy(
            dns = provider.id,
            customDohUrl = custom,
            httpCacheMb = settings.httpCacheMb.coerceIn(0, MAX_CACHE_MB),
        )
    }

    /** Bytes the HTTP cache currently holds on disk. */
    @Synchronized
    fun cacheSizeBytes(): Long = runCatching { cache?.size() ?: 0L }.getOrDefault(0L)

    @Synchronized
    fun clearCache() {
        runCatching { cache?.evictAll() }
            .onFailure { DaemonLog.warn("network.cache_clear_failed", mapOf("error" to (it.message ?: ""))) }
    }
}
