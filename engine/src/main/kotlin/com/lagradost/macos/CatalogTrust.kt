package com.lagradost.macos

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import kotlinx.serialization.json.jsonObject
import java.time.Instant

/** Authenticated root -> exact list bytes -> artifact digest. Persisted flags
 * and normalized display metadata are never sufficient execution authority. */
internal object CatalogTrust {
    private val json = Json { ignoreUnknownKeys = true }
    /** Catalog entries as Android's Jackson reads them: unknown keys ignored,
     * a null or quoted value for a field with a default read leniently. */
    private val entryJson = Json { ignoreUnknownKeys = true; coerceInputValues = true; isLenient = true }
    data class Root(
        val manifest: RepositoryService.RepositoryManifest,
        val publicKey: String,
        val fingerprint: String,
        val digest: String,
        val version: Long,
        val expiresAt: Long,
    )

    fun authenticateRoot(body: String, pinnedKey: String?, previous: DaemonState.RepositoryTrustAnchor?,
        now: Instant = Instant.now(), requireFresh: Boolean = true): Root {
        val verification = RepoSignature.verify(body, pinnedKey)
            ?: throw SecurityException("A signed repository manifest is required")
        if (!verification.valid) throw SecurityException("Repository signature rejected: ${verification.reason}")
        val element = RepositoryJson.parse(body).jsonObject
        val manifest = json.decodeFromJsonElement(RepositoryService.RepositoryManifest.serializer(), element)
        val version = manifest.catalogVersion
            ?: throw SecurityException("Signed manifest requires catalogVersion")
        if (version !in 1..9_007_199_254_740_991L) throw SecurityException("Invalid catalogVersion")
        val expiry = try { Instant.parse(manifest.expiresAt) } catch (_: Exception) {
            throw SecurityException("Signed manifest requires an ISO-8601 expiresAt")
        }
        if (requireFresh && (!expiry.isAfter(now) || expiry.isAfter(now.plusSeconds(30 * 86400L)))) {
            throw SecurityException("Catalog expired or its expiry is more than 30 days away")
        }
        val lists = manifest.pluginLists
        if (lists.size > 16 || lists.distinct().size != lists.size || manifest.pluginListHashes.keys != lists.toSet()) {
            throw SecurityException("Signed manifest must bind every plugin list exactly once")
        }
        if (manifest.pluginListHashes.values.any { RepositoryService.normalizedHash(it) == null }) {
            throw SecurityException("Invalid signed plugin-list digest")
        }
        val digest = ArtifactDigest.sha256(RepoSignature.canonicalize(JsonObject(element - "signature")).toByteArray())
        if (previous != null && (version < previous.catalogVersion ||
            version == previous.catalogVersion && previous.catalogDigest != null && digest != previous.catalogDigest)) {
            throw SecurityException("Catalog rollback or revision reuse rejected")
        }
        return Root(manifest, requireNotNull(verification.publicKey), requireNotNull(verification.keyFingerprint), digest, version, expiry.toEpochMilli())
    }

    /**
     * One plugin list as catalog entries. A malformed entry is left out rather
     * than failing the whole repository (Android's parser is equally forgiving);
     * entries keep their list order. Addresses: see [artifactUrl] and [iconUrl].
     */
    fun decodeList(root: Root?, listReference: String, bytes: ByteArray, effectiveUrl: String, repositoryUrl: String): List<RepositoryService.SitePlugin> {
        if (root != null && ArtifactDigest.sha256(bytes) != RepositoryService.normalizedHash(root.manifest.pluginListHashes[listReference])) {
            throw SecurityException("Plugin list does not match its signed digest")
        }
        val text = RepositoryDocument(bytes, effectiveUrl).text()
        val entries = RepositoryJson.parse(text) as? JsonArray ?: throw IllegalArgumentException("A plugin list must be a JSON array")
        return entries.mapNotNull { element ->
            val plugin = try {
                entryJson.decodeFromJsonElement(RepositoryService.SitePlugin.serializer(), element)
            } catch (_: IllegalArgumentException) { return@mapNotNull null } // SerializationException included
            // Outside the per-entry recovery: a signed entry without a digest fails the whole catalog.
            if (root != null && RepositoryService.normalizedHash(plugin.fileHash) == null) {
                throw SecurityException("Every signed catalog entry must provide an artifact SHA-256")
            }
            try {
                val name = plugin.internalName.ifBlank { plugin.url.substringAfterLast('/').removeSuffix(".cs3") }
                if (name.isBlank() || name.length > 256) return@mapNotNull null
                plugin.copy(
                    internalName = name,
                    url = artifactUrl(effectiveUrl, plugin.url),
                    iconUrl = plugin.iconUrl?.let { iconUrl(effectiveUrl, it) },
                    repositoryUrl = repositoryUrl,
                )
            } catch (_: RuntimeException) { null } // One malformed entry never costs the rest of the list.
        }
    }

    /** One entry per extension identity, the first listed winning, as on Android. */
    fun distinctEntries(plugins: List<RepositoryService.SitePlugin>): List<RepositoryService.SitePlugin> =
        plugins.distinctBy { it.internalName }

    /**
     * The download address, or "" when the publisher's address is not a usable
     * HTTPS address. Such an entry stays listed but cannot be installed
     * ([RepositoryService.INSECURE_DOWNLOAD_REASON]).
     */
    private fun artifactUrl(base: String, raw: String): String =
        runCatching { RepositoryService.resolveUrl(base, raw) }.getOrDefault("")

    /**
     * Icons are cosmetic: an unusable or private-network address is dropped,
     * never fatal. A hostname is never resolved here; only an IPv6 literal or a
     * strict dotted-quad IPv4 literal is checked, and [java.net.InetAddress.getByName]
     * parses those without DNS. Digits-and-dots hosts that are not a valid IPv4
     * address (`999.999.999.999`, `1.2.3.4.5`) are dropped.
     */
    internal fun iconUrl(base: String, raw: String): String? = runCatching {
        val url = RepositoryService.resolveUrl(base, raw).toHttpUrlOrNull() ?: return@runCatching null
        val host = url.host
        when {
            host.contains(':') || IPV4_LITERAL.matches(host) ->
                url.toString().takeIf { RepositoryTransport.isPublicAddress(java.net.InetAddress.getByName(host)) }
            host.all { it in '0'..'9' || it == '.' } -> null
            else -> url.toString()
        }
    }.getOrNull()

    private val IPV4_LITERAL = Regex("^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(\\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])){3}$")

    data class TrustedCatalog(val tier: DaemonState.TrustTier, val plugins: List<RepositoryService.SitePlugin>)

    /** Reconstruct a catalog from the exact bytes saved at the last sync.
     * VERIFIED: full signed chain against the durable anchor. COMMUNITY: the
     * saved list bytes; a repository that ever had a trust anchor, or that
     * policy pins, can never be read as community. */
    fun restoreCatalog(repo: DaemonState.PersistedRepository, anchor: DaemonState.RepositoryTrustAnchor?,
        requireFresh: Boolean): TrustedCatalog {
        if (repo.signed) return TrustedCatalog(DaemonState.TrustTier.VERIFIED, restore(repo, anchor, requireFresh))
        if (anchor != null || repo.pinnedPublicKey != null || DaemonRuntime.policy.pinnedKeyFor(repo.url) != null) {
            throw SecurityException("A trusted repository cannot be read as a community catalog")
        }
        if (repo.authenticatedLists.isEmpty()) throw SecurityException("Sync this repository to capture its catalog")
        val plugins = distinctEntries(repo.authenticatedLists.flatMap { list ->
            decodeList(null, list.reference, list.body.toByteArray(Charsets.UTF_8), list.effectiveUrl, repo.url)
        })
        require(plugins.size <= 10_000) { "Catalog exceeds extension limit" }
        return TrustedCatalog(DaemonState.TrustTier.COMMUNITY, plugins)
    }

    /** Reconstruct execution metadata from preserved signed evidence. Never
     * trust pluginsJson, signed=true, or an unauthenticated provenance string. */
    fun restore(repo: DaemonState.PersistedRepository, anchor: DaemonState.RepositoryTrustAnchor?, requireFresh: Boolean): List<RepositoryService.SitePlugin> {
        if (anchor == null || !repo.signed) throw SecurityException("Repository has no authenticated catalog")
        val root = authenticateRoot(requireNotNull(repo.manifestJson), anchor.publicKey, anchor, requireFresh = requireFresh)
        if (root.digest != anchor.catalogDigest || root.version != anchor.catalogVersion) throw SecurityException("Saved catalog does not match trust anchor")
        if (repo.authenticatedLists.map { it.reference } != root.manifest.pluginLists) throw SecurityException("Saved list evidence is incomplete")
        val plugins = distinctEntries(repo.authenticatedLists.flatMap { list ->
            decodeList(root, list.reference, list.body.toByteArray(Charsets.UTF_8), list.effectiveUrl, repo.url)
        })
        require(plugins.size <= 10_000) { "Catalog exceeds extension limit" }
        return plugins
    }
}
