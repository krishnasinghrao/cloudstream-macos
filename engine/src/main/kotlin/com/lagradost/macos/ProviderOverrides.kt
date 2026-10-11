package com.lagradost.macos

import com.lagradost.cloudstream3.MainAPI
import com.lagradost.cloudstream3.ProvidersInfoJson
import com.lagradost.macos.models.PluginConfigResponseDto
import java.util.concurrent.ConcurrentHashMap

/**
 * Clone-site URL and credential overrides, keyed by stable provider ID.
 * URLs persist in state; credentials live only in memory — the client stores
 * them in the Keychain and re-sends them after each engine start. Overrides are
 * applied to a prepared generation before it is published, so reloads and
 * updates keep the configuration.
 */
object ProviderOverrides {
    private val credentials = ConcurrentHashMap<String, String>()

    /** Called for each prepared generation before publication. */
    fun apply(providers: List<MainAPI>) {
        for (provider in providers) {
            val id = PluginBridge.providerId(provider)
            val url = DaemonState.overrideFor(id)?.url
            val credential = credentials[id]
            if (url == null && credential == null) continue
            try {
                provider.overrideWithNewData(ProvidersInfoJson(provider.name, url ?: provider.mainUrl, credential ?: provider.storedCredentials, 1))
            } catch (failure: Exception) {
                DaemonLog.warn("provider.override_failed", mapOf("provider" to id, "error" to failure.javaClass.simpleName))
            }
        }
    }

    /**
     * Each setting is unchanged (null), set (non-empty) or cleared (explicit
     * flag or empty value). A cleared credential is removed from the live
     * provider at once: it never falls back to the previous secret.
     */
    fun configure(provider: MainAPI, url: String?, credential: String?, reset: Boolean,
                  clearUrl: Boolean = false, clearCredentials: Boolean = false): PluginConfigResponseDto {
        val id = PluginBridge.providerId(provider)
        val clearingUrl = clearUrl || url?.isBlank() == true
        val clearingCredential = reset || clearCredentials || credential?.isEmpty() == true
        val setUrl = url?.trim()?.takeIf { it.isNotEmpty() && !clearingUrl }
        if (setUrl != null) {
            val parsed = runCatching { java.net.URI(setUrl) }.getOrNull()
            require(parsed != null && parsed.scheme?.lowercase() in setOf("https", "http") && parsed.host != null && parsed.userInfo == null) {
                "Provider URL must be an http(s) URL without credentials"
            }
        }
        if (!provider.canBeOverridden) {
            return PluginConfigResponseDto(id, provider.mainUrl, applied = false, detail = "This provider does not support custom settings.")
        }
        val previous = DaemonState.overrideFor(id)
        if (clearingCredential) credentials.remove(id) else credential?.let { credentials[id] = it }
        if (reset) {
            DaemonState.setProviderOverride(id, null)
        } else {
            val nextUrl = if (clearingUrl) null else setUrl ?: previous?.url
            val next = DaemonState.ProviderOverride(url = nextUrl, hasCredentials = credentials.containsKey(id))
            DaemonState.setProviderOverride(id, next.takeIf { it.url != null || it.hasCredentials })
        }
        // The desired state above is what every later load applies. Now make
        // the live provider agree with it.
        val restoresDefaultUrl = (reset || clearingUrl) && previous?.url != null
        applyLive(provider, clearingCredential)
        var applied = true
        var pending = false
        var detail: String? = null
        if (provider is com.lagradost.macos.worker.RemoteProvider) {
            if (restoresDefaultUrl) {
                // Only a reload knows the extension's own address.
                provider.handle.stop()
                applied = false; pending = true
                detail = "Defaults apply after the extension reloads."
            } else {
                // The worker holds the real provider; a stopped worker picks this up at its next start.
                val failure = runCatching {
                    kotlinx.coroutines.runBlocking { provider.configureRemote(DaemonState.overrideFor(id)?.url, credentials[id], clearingCredential) }
                }.exceptionOrNull()
                if (failure != null) {
                    DaemonLog.warn("provider.remote_configure_failed", mapOf("provider" to id, "error" to failure.javaClass.simpleName))
                    // The running extension may still hold the old secret or
                    // address: stop it, so it can only restart with the new ones.
                    provider.handle.stop()
                    applied = false; pending = true
                    detail = "The running extension did not accept the change, so it was stopped. The new settings apply when it next starts."
                }
            }
        } else if (restoresDefaultUrl) {
            applied = false; pending = true
            detail = "Defaults apply after the extension reloads."
        }
        ProviderExecutor.invalidateProvider(id)
        AuditLog.record("provider.configure", mapOf("provider" to id, "reset" to reset, "url" to (url != null || clearUrl),
            "credentials" to (credential != null || clearCredentials), "applied" to applied))
        return PluginConfigResponseDto(id, provider.mainUrl, applied = applied, detail = detail, pending = pending)
    }

    private fun applyLive(provider: MainAPI, clearCredential: Boolean) {
        val id = PluginBridge.providerId(provider)
        val url = DaemonState.overrideFor(id)?.url
        val credential = if (clearCredential) null else credentials[id] ?: provider.storedCredentials
        try {
            provider.overrideWithNewData(ProvidersInfoJson(provider.name, url ?: provider.mainUrl, credential, 1))
        } catch (failure: Exception) {
            DaemonLog.warn("provider.override_failed", mapOf("provider" to id, "error" to failure.javaClass.simpleName))
        }
    }

    /**
     * Credentials for a provider of an installed extension that has not loaded
     * yet (the engine restores extensions in the background, while the client
     * re-sends Keychain credentials on connect). Held in memory and applied when
     * the generation is prepared. Returns null for an unknown provider ID.
     */
    fun configurePending(providerId: String, credential: String?, reset: Boolean, clearCredentials: Boolean = false): PluginConfigResponseDto? {
        val installationId = providerId.substringBefore(':', "")
        val name = providerId.substringAfter(':', "")
        if (RepositoryService.normalizedHash(installationId) != installationId || name.isBlank()) return null
        if (DaemonState.snapshot().installations[installationId] == null) return null
        if (reset || clearCredentials || credential?.isEmpty() == true) credentials.remove(providerId)
        else if (credential != null) credentials[providerId] = credential
        return PluginConfigResponseDto(providerId, mainUrl = "", applied = false, pending = true,
            detail = "Saved; it applies when the extension finishes loading.")
    }

    /**
     * Clone-site URL and in-memory credentials for a worker's providers, keyed
     * by provider name. Taken from the settings themselves, not from a list of
     * names: a worker that starts before its providers were ever recorded
     * (first start after an install) must still receive them.
     */
    internal fun workerConfig(installationId: String): Map<String, com.lagradost.macos.worker.ProviderConfig> {
        val prefix = "$installationId:"
        val urls = DaemonState.snapshot().providerOverrides.filterKeys { it.startsWith(prefix) }
        return (urls.keys + credentials.keys.filter { it.startsWith(prefix) }).mapNotNull { id ->
            val url = urls[id]?.url
            val credential = credentials[id]
            if (url == null && credential == null) null else id.removePrefix(prefix) to com.lagradost.macos.worker.ProviderConfig(url, credential)
        }.toMap()
    }

    /** Tests only. */
    internal fun clearForTest() = credentials.clear()
}
