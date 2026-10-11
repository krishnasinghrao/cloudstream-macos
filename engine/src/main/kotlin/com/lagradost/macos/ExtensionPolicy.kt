package com.lagradost.macos

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/**
 * Organization policy (configuration profile / managed preferences), read by
 * the client and delivered once at launch over stdin. The daemon enforces it on
 * every mutation and on restore; the UI only mirrors it. Immutable for the life
 * of the process so an IPC caller cannot relax it later.
 */
@Serializable
data class ExtensionPolicy(
    /** Repository URLs permitted (canonical match: case, default port, query and fragment ignored); null permits any. */
    val allowedRepositories: List<String>? = null,
    /**
     * Blocked hosts or host + path prefixes. An entry without a path
     * (`https://evil.example` or `evil.example`) blocks that host and its
     * subdomains; one with a path blocks that path and everything below it.
     * Enforced on every redirect hop and on discovered child repositories.
     */
    val blockedRepositories: List<String> = emptyList(),
    /** Repository URL → required Ed25519 public key (base64). Overrides TOFU. */
    val pinnedRepositoryKeys: Map<String, String> = emptyMap(),
    val allowCommunityTier: Boolean = true,
    /** False requires a publisher digest even for consented unsigned catalogs. */
    val allowLocalObservation: Boolean = true,
    /** When false, only policy-allowed repositories can be added. */
    val allowUserRepositories: Boolean = true,
    /** Non-null forces the automatic-update setting. */
    val autoUpdate: Boolean? = null,
    val safeModeOnly: Boolean = false,
    /** False forbids developer mode (local extension files). */
    val allowDeveloperExtensions: Boolean = true,
    /**
     * Extension code must never run outside the macOS sandbox. On by default
     * (L6): a Mac without `sandbox-exec` refuses extensions instead of running
     * them unconfined. An organization may turn it off explicitly.
     */
    val requireSandbox: Boolean = true,
    /** True when any value came from a managed configuration profile. */
    val managed: Boolean = false,
) {
    fun repositoryAllowed(url: String): Boolean {
        if (url == DaemonState.DEVELOPER_SOURCE) return blockedRepositories.none { it.trim() == url } && (allowedRepositories == null || allowlisted(url))
        val canonical = Canonical.of(url) ?: return false // Unreadable addresses fail closed.
        if (blocked(canonical)) return false
        val allowed = allowedRepositories ?: return true
        return allowed.any { Canonical.of(it)?.key == canonical.key }
    }

    /** True when [url]'s host or path falls under a blocklist entry (any request, any redirect hop). */
    fun addressBlocked(url: String): Boolean {
        if (blockedRepositories.isEmpty()) return false
        return Canonical.of(url)?.let(::blocked) ?: true
    }

    private fun blocked(target: Canonical): Boolean = blockedRepositories.any { raw ->
        val entry = Canonical.of(raw) ?: return@any false
        val hostMatches = target.host == entry.host || target.host.endsWith(".${entry.host}")
        when {
            !hostMatches -> false
            entry.path == "/" -> true
            target.host != entry.host -> false
            else -> target.path.trimEnd('/') == entry.path.trimEnd('/') || target.path.startsWith(entry.path.trimEnd('/') + "/")
        }
    }

    private fun allowlisted(url: String): Boolean = allowedRepositories?.any { it.trim() == url } == true

    fun requireRepository(url: String, userInitiated: Boolean) {
        if (!repositoryAllowed(url)) throw PolicyException("Your organization does not allow this repository.")
        if (userInitiated && !allowUserRepositories) {
            val canonical = Canonical.of(url)?.key
            if (allowedRepositories?.any { Canonical.of(it)?.key == canonical && canonical != null } != true) {
                throw PolicyException("Your organization does not allow adding repositories.")
            }
        }
    }

    /** Refuses [url] when it, as reached after redirects, is blocked. */
    fun requireAddressNotBlocked(url: String) {
        if (addressBlocked(url)) throw PolicyException("Your organization does not allow this repository.")
    }

    /**
     * True when the organization vouches for [url]'s publisher key: a policy
     * pin. A signature by itself only proves the catalog came from whoever
     * holds *some* key (trust on first use), so it never stands in for this (M4).
     */
    fun keyPinned(url: String): Boolean = pinnedKeyFor(url) != null

    /** Whether installing from [url] (a [tier] catalog) needs the user's first-time consent: every repository not pinned by policy. */
    fun needsConsent(tier: DaemonState.TrustTier, url: String): Boolean = when (tier) {
        DaemonState.TrustTier.COMMUNITY -> true
        DaemonState.TrustTier.VERIFIED -> !keyPinned(url)
        DaemonState.TrustTier.DEVELOPER -> false
    }

    /**
     * [url] is required for a signed catalog when community repositories are
     * off: "signed only" then means signed by a pinned key, or explicitly
     * allow-listed, never merely signed by a key the publisher generated (M4).
     */
    fun requireTier(tier: DaemonState.TrustTier, url: String? = null) {
        if (tier == DaemonState.TrustTier.COMMUNITY && !allowCommunityTier) {
            throw PolicyException("Your organization allows only repositories it has approved.")
        }
        if (tier == DaemonState.TrustTier.VERIFIED && !allowCommunityTier) {
            val canonical = url?.let { Canonical.of(it)?.key }
            val approved = url != null && (keyPinned(url) || allowedRepositories?.any { canonical != null && Canonical.of(it)?.key == canonical } == true)
            if (!approved) throw PolicyException("Your organization allows only repositories it has approved.")
        }
        if (tier == DaemonState.TrustTier.DEVELOPER && !allowDeveloperExtensions) {
            throw PolicyException("Your organization does not allow extensions from local files.")
        }
    }

    fun requireVerification(mode: DaemonState.ArtifactVerification) {
        if (mode == DaemonState.ArtifactVerification.LOCAL_OBSERVATION && !allowLocalObservation) {
            throw PolicyException("Your organization requires publisher verification of extension downloads.")
        }
    }

    /** Policy-pinned key for [url], matched with the same canonical form as the allow list. */
    fun pinnedKeyFor(url: String): String? {
        val canonical = Canonical.of(url)?.key ?: return null
        return pinnedRepositoryKeys.entries.firstOrNull { Canonical.of(it.key)?.key == canonical }?.value
    }

    /**
     * The form policy compares (M5): lower-case scheme and host (IDN in ASCII),
     * no default port, dot segments resolved, no query, fragment or
     * credentials. `http` counts as `https`, since repositories are upgraded.
     * A bare host (`evil.example`) reads as `https://evil.example/`.
     */
    internal data class Canonical(val host: String, val port: Int, val path: String) {
        val key: String get() = "https://$host${if (port == 443) "" else ":$port"}$path"

        companion object {
            fun of(raw: String): Canonical? {
                val trimmed = raw.trim()
                if (trimmed.isEmpty()) return null
                val withScheme = if ("://" in trimmed) trimmed else "https://$trimmed"
                val url = withScheme.toHttpUrlOrNull() ?: return null
                val port = if (url.scheme == "http" && url.port == 80) 443 else url.port
                // HttpUrl has already resolved dot segments; decode so %2F-style spellings compare equal.
                val path = url.encodedPath.split('/').joinToString("/") {
                    runCatching { java.net.URLDecoder.decode(it.replace("+", "%2B"), Charsets.UTF_8) }.getOrDefault(it).lowercase(java.util.Locale.ROOT)
                }.ifEmpty { "/" }
                return Canonical(url.host.lowercase(java.util.Locale.ROOT).trimEnd('.'), port, path)
            }
        }
    }
}

class PolicyException(message: String) : SecurityException(message)

/** Second stdin line from the supervisor. Invalid (or, when launched over stdin, missing) → fail closed. */
@Serializable
data class LaunchOptions(
    val policy: ExtensionPolicy = ExtensionPolicy(),
    /** Start without loading any extension (user request or crash-loop protection). */
    val safeMode: Boolean = false,
    /** `worker` (one sandboxed process per extension, production) or `in-process` (development, tests). */
    val isolation: String = ISOLATION_IN_PROCESS,
) {
    companion object {
        private val json = Json { ignoreUnknownKeys = true }
        const val ISOLATION_WORKER = "worker"
        const val ISOLATION_IN_PROCESS = "in-process"

        /** Nothing may load and nothing may be added: used when the managed policy is unknown. */
        val FAIL_CLOSED = LaunchOptions(ExtensionPolicy(allowCommunityTier = false, allowUserRepositories = false,
            allowedRepositories = emptyList(), safeModeOnly = true, requireSandbox = true, allowDeveloperExtensions = false,
            managed = true), safeMode = true,
            isolation = ISOLATION_WORKER)

        /** [required]: the supervisor always sends this line, so its absence must
         * not silently drop an organization's policy. */
        fun parse(line: String?, required: Boolean = false): LaunchOptions {
            if (line.isNullOrBlank()) {
                if (!required) return LaunchOptions()
                DaemonLog.warn("launch_options.missing", emptyMap())
                return FAIL_CLOSED
            }
            return try { json.decodeFromString<LaunchOptions>(line) } catch (failure: Exception) {
                DaemonLog.warn("launch_options.invalid", mapOf("error" to failure.javaClass.simpleName))
                // Fail closed: invalid managed policy must not silently widen access.
                FAIL_CLOSED
            }
        }
    }
}

/** Process-wide policy and safe-mode state, fixed at startup. */
object DaemonRuntime {
    @Volatile var options: LaunchOptions = LaunchOptions()
        private set
    private var configured = false

    val policy: ExtensionPolicy get() = options.policy
    val safeMode: Boolean get() = options.safeMode || options.policy.safeModeOnly

    @Synchronized fun configure(value: LaunchOptions) {
        check(!configured) { "Launch options are immutable once set" }
        options = value
        configured = true
    }

    /** Tests only. */
    @Synchronized internal fun resetForTest(value: LaunchOptions = LaunchOptions()) {
        options = value
        configured = false
    }
}
