package com.lagradost.macos

import com.lagradost.macos.models.PluginDto
import com.lagradost.macos.models.RepoPluginDto
import com.lagradost.macos.models.RepositoryDto
import com.lagradost.macos.models.SkippedRepositoryDto
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.net.URI

/**
 * Repository management (plan WS-2.1 + WS-4.2).
 *
 * • HTTPS-only repo URLs (SEC posture; the UI enforces this too, the daemon
 *   no longer trusts that alone).
 * • Optional Ed25519 manifest signatures with TOFU pinning (RepoSignature).
 * • Every sync persists the manifest + plugin lists into [DaemonState] so a
 *   restarted daemon can boot its plugins from the local cache without
 *   network access.
 * • SEC-07 integrity gate: plugins verify SHA-256 against catalog metadata; signed detached-list binding remains required.
 */
object RepositoryService {
    private val shortenerHosts = setOf("cutt.ly", "py.md", "bit.ly", "tinyurl.com")

    private val json = Json { ignoreUnknownKeys = true }
    internal val transport: RepositoryFetcher = RepositoryContentFetcher(RepositoryTransport())
    /** The single lifecycle authority (replaceable only by tests). */
    @Volatile internal var installations = InstallationManager(BridgeExtensionRuntime, transport)
    internal fun defaultInstallations() = InstallationManager(BridgeExtensionRuntime, transport)

    /** Managed cache location; OS-enforced worker confinement is a separate requirement. */
    val pluginCacheDir: File get() = CloudDirs.pluginCacheDir

    private val cs3StoreDir: File get() = CloudDirs.cs3StoreDir

    @Serializable
    data class RepositoryManifest(
        val name: String = "Unknown Repository",
        val description: String? = null,
        val iconUrl: String? = null,
        val manifestVersion: Int = 0,
        val pluginLists: List<String> = emptyList(),
        val catalogVersion: Long? = null,
        val expiresAt: String? = null,
        val pluginListHashes: Map<String, String> = emptyMap(),
    )

    /**
     * Android installs every catalog entry except status 0 (`PROVIDER_STATUS_DOWN`):
     * 1 ok, 2 slow and 3 beta are all installable (A6). Unknown future values
     * follow the same rule.
     */
    internal const val STATUS_DOWN = 0
    internal fun isInstallable(status: Int): Boolean = status != STATUS_DOWN

    /** Mirrors the community repo.json plugin entry schema. */
    @Serializable
    data class SitePlugin(
        val url: String = "",
        val status: Int = 1,
        val version: Int = 0,
        val apiVersion: Int = 0,
        val name: String = "Unknown",
        val internalName: String = "",
        val authors: List<String> = emptyList(),
        val description: String? = null,
        val repositoryUrl: String? = null,
        val tvTypes: List<String>? = null,
        val language: String? = null,
        val iconUrl: String? = null,
        val fileSize: Long? = null,
        val fileHash: String? = null,
    )

    data class SyncOutcome(
        val repository: RepositoryDto,
        val manifest: RepositoryManifest,
        val plugins: List<SitePlugin>,
        val verified: Boolean,
        val keyFingerprint: String?,
        /** Repositories whose catalogs this sync committed (aggregate children included). */
        val committedRepositories: List<String> = emptyList(),
    )

    fun listRepositories(): List<RepositoryDto> {
        val state = DaemonState.snapshot()
        return state.repos.map { repo -> repositoryDto(state, repo) }
    }

    private fun repositoryDto(state: DaemonState.PersistedState, repo: DaemonState.PersistedRepository): RepositoryDto {
        val plugins = decodePersistedPlugins(repo)
        val manifest = repo.manifestJson?.let { runCatching { json.decodeFromString<RepositoryManifest>(it) }.getOrNull() }
        val catalog = runCatching { CatalogTrust.restoreCatalog(repo, state.repositoryTrust[repo.url], requireFresh = false) }
        val verified = catalog.getOrNull()?.tier == DaemonState.TrustTier.VERIFIED
        val integrityError = if (repo.lastSyncedAt > 0 && catalog.isFailure) "Saved catalog evidence is incomplete. Sync this repository again." else null
        val policy = DaemonRuntime.policy
        return RepositoryDto(
            name = manifest?.name ?: repo.url.substringAfterLast('/'), url = repo.url,
            description = manifest?.description, iconUrl = manifest?.iconUrl,
            manifestVersion = manifest?.manifestVersion ?: 0,
            pluginCount = plugins.count { isInstallable(it.status) },
            status = when {
                integrityError != null -> "needs_sync"
                repo.lastError != null && repo.lastAttemptAt > repo.lastSyncedAt -> "error"
                repo.lastSyncedAt == 0L -> "not_synced"
                else -> "ok"
            },
            error = integrityError ?: repo.lastError?.takeIf { repo.lastAttemptAt > repo.lastSyncedAt },
            verified = verified && policy.keyPinned(repo.url),
            keyFingerprint = state.repositoryTrust[repo.url]?.keyFingerprint ?: repo.pinnedKeyFingerprint,
            tier = (if (repo.signed) DaemonState.TrustTier.VERIFIED else DaemonState.TrustTier.COMMUNITY).wire(repo.url),
            consented = repo.consent != null,
            consentRequired = policy.needsConsent(if (repo.signed) DaemonState.TrustTier.VERIFIED else DaemonState.TrustTier.COMMUNITY, repo.url),
            lastSyncedAt = repo.lastSyncedAt.takeIf { it > 0 },
            lastAttemptAt = repo.lastAttemptAt.takeIf { it > 0 },
            installedCount = state.installations.values.count { it.repositoryUrl == repo.url },
            discoveredVia = repo.discoveredVia,
            allowedByPolicy = policy.repositoryAllowed(repo.url) &&
                runCatching { policy.requireTier(if (repo.signed) DaemonState.TrustTier.VERIFIED else DaemonState.TrustTier.COMMUNITY, repo.url) }.isSuccess,
        )
    }

    /**
     * Every repository whose key the organization has not pinned needs explicit
     * consent before anything from it can be installed (M4): a signature only
     * shows the catalog came from whoever holds the key.
     */
    fun setConsent(repoUrl: String, allow: Boolean, actor: String = "user"): RepositoryDto {
        DaemonState.requireHealthy()
        val state = DaemonState.snapshot()
        val repo = state.repos.singleOrNull { it.url == repoUrl }
            ?: throw ExtensionException(ExtensionException.Code.UNKNOWN_REPOSITORY, "This repository is not added.")
        if (allow) {
            val tier = if (repo.signed) DaemonState.TrustTier.VERIFIED else DaemonState.TrustTier.COMMUNITY
            if (!DaemonRuntime.policy.needsConsent(tier, repoUrl)) {
                throw ExtensionException(ExtensionException.Code.CONFLICT, "Your organization already approved this repository's key.")
            }
            DaemonRuntime.policy.requireRepository(repoUrl, userInitiated = false)
            DaemonRuntime.policy.requireTier(tier, repoUrl)
        }
        DaemonState.update { s -> s.copy(repos = s.repos.map {
            if (it.url != repoUrl) it else it.copy(consent = if (allow) it.consent ?: DaemonState.RepositoryConsent(System.currentTimeMillis()) else null)
        }) }
        AuditLog.record(if (allow) "repository.consent" else "repository.consent_revoked", mapOf("repository" to repoUrl), actor)
        return repositoryDto(DaemonState.snapshot(), DaemonState.snapshot().repos.single { it.url == repoUrl })
    }

    /** One-time offline migration. The durable marker makes retries safe even
     * if a prior response was lost and a user subsequently removes a repository. */
    fun importLegacyRepositories(urls: List<String>) {
        val migration = "swift-repositories-v1"
        DaemonState.requireHealthy()
        if (migration in DaemonState.snapshot().completedMigrations) return
        require(urls.size <= 64) { "Too many legacy repositories" }
        val normalized = urls.map { raw ->
            val uri = try { URI(raw.trim()) } catch (failure: java.net.URISyntaxException) {
                throw IllegalArgumentException("Invalid saved repository URL", failure)
            }
            require(uri.scheme.equals("https", ignoreCase = true) && uri.host != null && uri.userInfo == null && uri.fragment == null) {
                "Saved repository must be an HTTPS URL without credentials or a fragment"
            }
            uri.toASCIIString()
        }.distinct().filter { DaemonRuntime.policy.repositoryAllowed(it) }
        DaemonState.update { state ->
            if (migration in state.completedMigrations) state else state.copy(
                completedMigrations = state.completedMigrations + migration,
                repos = state.repos + normalized.filter { url -> state.repos.none { it.url == url } }
                    .map { DaemonState.PersistedRepository(url = it) },
            )
        }
    }

    /**
     * Ordinary, repeatable registration of saved repository addresses (backup
     * restore). Unlike [importLegacyRepositories] it has no one-time marker.
     * It only records the address: nothing is fetched, installed or trusted,
     * and no community consent is created. Each address gets its own outcome.
     */
    fun registerRepositories(urls: List<String>): List<com.lagradost.macos.models.RepoRegistrationDto> {
        DaemonState.requireHealthy()
        require(urls.size <= 64) { "Too many repositories" }
        val seen = HashSet<String>()
        val outcomes = urls.map { raw ->
            val reject = { reason: String -> com.lagradost.macos.models.RepoRegistrationDto(raw.take(512), "rejected", reason) }
            if (raw.length > 8192) return@map reject("The address is too long.")
            val uri = runCatching { URI(raw.trim()) }.getOrNull() ?: return@map reject("The address is not a valid URL.")
            if (!uri.scheme.equals("https", ignoreCase = true) || uri.host == null || uri.userInfo != null || uri.fragment != null) {
                return@map reject("Repositories must be HTTPS addresses without credentials or a fragment.")
            }
            val url = uri.toASCIIString()
            // Restoring a backup is a user action: the same policy as adding by hand.
            runCatching { DaemonRuntime.policy.requireRepository(url, userInitiated = true) }.exceptionOrNull()?.let {
                return@map reject(it.message ?: "This repository is not allowed.")
            }
            if (!seen.add(url)) return@map com.lagradost.macos.models.RepoRegistrationDto(url, "already_present")
            com.lagradost.macos.models.RepoRegistrationDto(url, "applied")
        }
        val wanted = outcomes.filter { it.status == "applied" }.map { it.url }
        var present = emptySet<String>()
        DaemonState.update { state ->
            present = state.repos.map { it.url }.toSet()
            val missing = wanted.filter { it !in present }
            if (missing.isEmpty()) state else state.copy(repos = state.repos + missing.map { DaemonState.PersistedRepository(url = it) })
        }
        return outcomes.map { if (it.status == "applied" && it.url in present) it.copy(status = "already_present") else it }
    }

    suspend fun parseRepoUrl(rawUrl: String): String = parseRepoUrl(rawUrl, transport)

    internal suspend fun parseRepoUrl(rawUrl: String, fetcher: RepositoryFetcher): String {
        require(rawUrl.length <= 8192) { "Repository input is too long" }
        var value = rawUrl.trim().trim('"', '\'').trim()
        Regex("""^\[[^\]]*]\(([^\r\n]+)\)$""").matchEntire(value)?.let { value = it.groupValues[1].trim() }
        Regex("""^<a\s+href=["']([^"']+)["'][^>]*>[^<]*</a>$""", RegexOption.IGNORE_CASE)
            .matchEntire(value)?.let { value = it.groupValues[1].trim() }
        value = value.removePrefix("<").removeSuffix(">").trim()
        for (scheme in listOf("cloudstreamrepo://", "cloudstreamrepo:", "cloudstream://", "cloudstream:",
            "cs.repo://", "cs.repo:", "cs3://", "cs3:", "cloudstreamapp://")) {
            if (value.startsWith(scheme, true)) { value = value.substring(scheme.length).trim(); break }
        }
        // Repositories are only ever fetched over HTTPS; a plain-HTTP address means its HTTPS form.
        if (value.startsWith("http://", true)) value = "https://" + value.substring("http://".length)
        // Android's resolver uses cutt.ly for normal codes and py.md for !codes.
        // Explicit URLs are user-owned identities and are never source aliases.
        if (Regex("!?[A-Za-z0-9_-]+").matches(value)) {
            val target = RepositoryTransport.requireHttpsUrl(
                if (value.startsWith("!")) "https://py.md/" else "https://cutt.ly/")
                .newBuilder().addPathSegment(value.removePrefix("!")).build()
            return resolvedShortener(target.toString(), fetcher)
        }
        if (!value.contains("://")) value = "https://$value"
        // Fragments are client-side navigation only, never repository identity.
        value = value.substringBefore('#')
        var url = RepositoryTransport.requireHttpsUrl(value)
        if (url.host == "cs.repo") {
            require(url.queryParameterValues("url").size == 1) { "Repository wrapper requires one url parameter" }
            value = requireNotNull(url.queryParameter("url"))
            url = RepositoryTransport.requireHttpsUrl(value)
        }
        if (url.host in shortenerHosts) return resolvedShortener(url.toString(), fetcher)
        return url.toString()
    }

    private suspend fun resolvedShortener(target: String, fetcher: RepositoryFetcher): String {
        val finalUrl = RepositoryTransport.requireHttpsUrl(fetcher.resolve(target))
        require(finalUrl.toString() != target && !(finalUrl.host in shortenerHosts &&
            (finalUrl.encodedPath == "/" || finalUrl.encodedPath.startsWith("/404")))) {
            "The repository code did not resolve to a repository address"
        }
        return finalUrl.toString()
    }

    fun extractRepositoriesFromHtml(html: String): List<String> {
        val repos = mutableSetOf<String>()
        val csRegex = Regex("""cloudstreamrepo://([^\s"'<>]+)""", RegexOption.IGNORE_CASE)
        for (m in csRegex.findAll(html)) {
            val candidate = m.groupValues[1].trim()
            if (candidate.isNotBlank() && !candidate.contains("cloudstream-apk.com", ignoreCase = true)) {
                // `cloudstreamrepo://host/path` and `https://host/path` name the same repository.
                val first = candidate.removePrefix("https://").removePrefix("http://").substringBefore('/')
                repos.add(if ('.' in first && '/' in candidate) "https://" + candidate.removePrefix("https://").removePrefix("http://")
                    else "cloudstreamrepo://$candidate")
            }
        }
        val urlRegex = Regex("""href=["'](https?://[^\s"'<>]+)["']""", RegexOption.IGNORE_CASE)
        for (m in urlRegex.findAll(html)) {
            val candidate = m.groupValues[1].trim()
            if (candidate.contains("cloudstream-apk.com", ignoreCase = true) ||
                candidate.contains("wp-json", ignoreCase = true) ||
                candidate.contains("/feed", ignoreCase = true) ||
                candidate.endsWith(".html", ignoreCase = true) ||
                candidate.endsWith(".htm", ignoreCase = true) ||
                candidate.endsWith(".php", ignoreCase = true)) {
                continue
            }
            if (candidate.endsWith(".json", ignoreCase = true) ||
                candidate.contains("/raw/", ignoreCase = true) ||
                candidate.contains("/builds/", ignoreCase = true) ||
                candidate.contains("pastebin.com/raw/", ignoreCase = true)) {
                repos.add(candidate)
            }
        }
        return repos.toList()
    }

    /** [target] against [base], a plain-HTTP address read as its HTTPS form (never fetched over HTTP). */
    fun resolveUrl(base: String, target: String): String {
        val resolved = RepositoryTransport.requireHttpsUrl(base).resolve(target.trim())
            ?: throw IllegalArgumentException("Invalid relative repository URL")
        return RepositoryTransport.requireHttpsUrl(RepositoryTransport.upgraded(resolved).toString()).toString()
    }

    /**
     * Fetches `repoUrl`, verifies authenticity, persists state, and returns
     * the sync outcome.
     */
    suspend fun sync(rawRepoUrl: String, userInitiated: Boolean = true): SyncOutcome = sync(rawRepoUrl, transport, userInitiated = userInitiated)

    /** Fetches, verifies and commits a catalog, records the attempt, and then
     * applies it to installations (revocation, re-proof, legacy adoption). */
    internal suspend fun sync(rawRepoUrl: String, fetcher: RepositoryFetcher, rotateKey: Boolean = false,
        userInitiated: Boolean = true, timeoutMs: Long = SYNC_TIMEOUT_MS): SyncOutcome {
        val outcome = try {
            withTimeout(timeoutMs) {
                syncCandidate(rawRepoUrl, rotateKey, fetcher, 0, mutableSetOf(), userInitiated, null,
                    timeoutMs - minOf(COMMIT_RESERVE_MS, timeoutMs / 4))
            }
        } catch (failure: Throwable) {
            recordSyncFailure(rawRepoUrl, failure)
            throw failure
        }
        AuditLog.record(if (rotateKey) "repository.retrust" else "repository.sync", mapOf("repository" to outcome.repository.url,
            "tier" to (if (outcome.verified) "verified" else "community"), "key" to outcome.keyFingerprint,
            "catalogVersion" to outcome.manifest.catalogVersion))
        for (url in outcome.committedRepositories) installations.reconcile(url)
        installations.migrateLegacyArtifacts()
        return outcome
    }

    private fun recordSyncFailure(rawRepoUrl: String, failure: Throwable) {
        if (DaemonState.recoveryError != null || failure is kotlinx.coroutines.CancellationException && failure !is TimeoutCancellationException) return
        val message = (ExtensionException.from(failure).message ?: failure.javaClass.simpleName).take(500)
        runCatching {
            DaemonState.update { s -> s.copy(repos = s.repos.map {
                if (it.url == rawRepoUrl.trim()) it.copy(lastAttemptAt = System.currentTimeMillis(), lastError = message) else it
            }) }
        }
    }

    private suspend fun syncCandidate(rawRepoUrl: String, rotateKey: Boolean, fetcher: RepositoryFetcher,
        depth: Int, visited: MutableSet<String>, userInitiated: Boolean, discoveredVia: String?,
        /** Time this candidate may spend before it must commit (RT-10). */
        budgetMs: Long): SyncOutcome {
        val startedAt = System.nanoTime()
        DaemonState.requireHealthy()
        require(depth <= 3) { "Repository discovery is too deep" }
        val repoUrl = parseRepoUrl(rawRepoUrl, fetcher)
        val policy = DaemonRuntime.policy
        val known = DaemonState.snapshot().repos.any { it.url == repoUrl }
        policy.requireRepository(repoUrl, userInitiated = userInitiated && !known)
        val policyKey = policy.pinnedKeyFor(repoUrl)
        synchronized(visited) {
            require(visited.size <= MAX_DISCOVERED_REPOSITORIES * 2 && visited.add(repoUrl)) { "Repository discovery cycle or limit exceeded" }
        }
        if (!repoUrl.startsWith("https://")) {
            throw SecurityException("Repositories must use https://")
        }
        OwnerOnly.mkdirs(cs3StoreDir)
        OwnerOnly.mkdirs(pluginCacheDir)

        val persisted = DaemonState.snapshot().repos.firstOrNull { it.url == repoUrl }
        val anchor = DaemonState.snapshot().repositoryTrust[repoUrl]
        require(!rotateKey || persisted != null || anchor != null) { "Repository must have saved trust before re-trust" }
        val document = fetcher.fetch(repoUrl, RepositoryTransport.MAX_MANIFEST_BYTES)
        // Where the address actually led is held to the blocklist too (M5).
        policy.requireAddressNotBlocked(document.effectiveUrl)
        val manifestBody = document.text()
        val manifestBase = document.effectiveUrl

        // Check if fetched content is an HTML repository listing webpage (e.g. cloudstream-apk.com)
        val isHtml = manifestBody.trimStart().let {
            it.startsWith("<!DOCTYPE", ignoreCase = true) ||
            it.startsWith("<html", ignoreCase = true) ||
            it.contains("<head", ignoreCase = true) ||
            it.contains("<body", ignoreCase = true)
        }

        if (isHtml) {
            if (persisted?.pinnedPublicKey != null || anchor != null || rotateKey || policyKey != null) {
                throw SecurityException("A trusted repository cannot downgrade to an HTML catalog")
            }
            val linked = extractRepositoriesFromHtml(manifestBody)
            val extractedRepos = linked.take(MAX_DISCOVERED_REPOSITORIES)
            if (linked.isEmpty()) {
                throw IllegalArgumentException("The link points to a webpage, but no CloudStream repository links were found on it.")
            }
            val compositePlugins = java.util.Collections.synchronizedList(mutableListOf<SitePlugin>())
            val committedChildren = java.util.Collections.synchronizedList(mutableListOf<String>())
            val skipped = java.util.Collections.synchronizedList(linked.drop(MAX_DISCOVERED_REPOSITORIES).map {
                SkippedRepositoryDto(it.take(2_000), "The page lists more than $MAX_DISCOVERED_REPOSITORIES repositories")
            }.toMutableList())
            val loadedReposCount = java.util.concurrent.atomic.AtomicInteger(0)
            // One discovery deadline for the whole page, inside this candidate's
            // budget: children still queued when it passes are reported as
            // skipped and the ones that loaded are committed (RT-10).
            val discoveryDeadline = startedAt + budgetMs * 1_000_000
            fun remainingMs() = (discoveryDeadline - System.nanoTime()) / 1_000_000

            coroutineScope {
                // As many child catalogs as transport lanes. Waiting for
                // admission consumes the discovery deadline; a child's own
                // service time starts when it is admitted.
                val childPermits = kotlinx.coroutines.sync.Semaphore(RepositoryTransport.LANES)
                extractedRepos.map { subRepoRaw ->
                    async {
                        fun skip(reason: String) {
                            skipped += SkippedRepositoryDto(subRepoRaw.take(2_000), reason.take(200))
                            DaemonLog.warn("html_subrepo_sync_failed", mapOf("repo" to subRepoRaw, "error" to reason))
                        }
                        val admitted = withTimeoutOrNull(remainingMs().coerceAtLeast(0)) { childPermits.acquire() }
                        if (admitted == null) {
                            skip("Not reached before the discovery deadline")
                            return@async
                        }
                        try {
                            val childBudget = minOf(CHILD_SYNC_TIMEOUT_MS, remainingMs())
                            if (childBudget < MIN_CHILD_BUDGET_MS) { skip("Not reached before the discovery deadline"); return@async }
                            withTimeout(childBudget) {
                                val subRepoUrl = parseRepoUrl(subRepoRaw, fetcher)
                                // Linked twice (or already synced in this discovery): not a failure.
                                if (subRepoUrl != repoUrl && synchronized(visited) { subRepoUrl !in visited }) {
                                    val subOutcome = syncCandidate(subRepoUrl, false, fetcher, depth + 1, visited, userInitiated, repoUrl,
                                        childBudget - minOf(COMMIT_RESERVE_MS / 2, childBudget / 4))
                                    synchronized(compositePlugins) {
                                        require(subOutcome.plugins.size <= 10_000 - compositePlugins.size) { "Aggregate catalog exceeds extension limit" }
                                        compositePlugins.addAll(subOutcome.plugins)
                                    }
                                    committedChildren.addAll(subOutcome.committedRepositories)
                                    loadedReposCount.incrementAndGet()
                                }
                            }
                        } catch (t: Exception) {
                            if (t is CancellationException && t !is TimeoutCancellationException) throw t
                            skip(if (t is TimeoutCancellationException) "Timed out" else t.message ?: t.javaClass.simpleName)
                        } finally { childPermits.release() }
                    }
                }.awaitAll()
            }

            if (compositePlugins.isEmpty()) {
                throw IllegalArgumentException("Discovered ${extractedRepos.size} repositories on page, but none could be loaded.")
            }
            val titleMatch = Regex("""<title>(.*?)</title>""", RegexOption.IGNORE_CASE).find(manifestBody)
            val pageTitle = titleMatch?.groupValues?.get(1)?.substringBefore(" -")?.substringBefore(" |")?.trim()
                ?.replace("&amp;", "&")
                ?.replace("&#038;", "&")
                ?.replace("&#8211;", "–")
                ?.replace("&quot;", "\"")
                ?: "CloudStream Community Catalog"

            // Identity is (child repository, internal name): same-named extensions
            // from different child repositories are both kept.
            val distinctPlugins = compositePlugins.distinctBy { (it.repositoryUrl ?: "") + "\u0000" + it.internalName }
            val enabledPlugins = distinctPlugins.filter { isInstallable(it.status) }

            val syntheticManifest = RepositoryManifest(
                name = pageTitle,
                description = "Aggregated from $repoUrl (${loadedReposCount.get()} repositories, ${enabledPlugins.size} plugins" +
                    (if (skipped.isEmpty()) ")" else "; ${skipped.size} could not be loaded)"),
                pluginLists = emptyList()
            )

            DaemonState.update { state ->
                check(state.repos.firstOrNull { it.url == repoUrl } == persisted) { "Repository changed during sync; retry required" }
                check(state.repositoryTrust[repoUrl] == anchor) { "Repository trust changed during sync; retry required" }
                val now = System.currentTimeMillis()
                val updated = DaemonState.PersistedRepository(
                    url = repoUrl,
                    pinnedPublicKey = null,
                    pinnedKeyFingerprint = null,
                    signed = false,
                    manifestJson = json.encodeToString(syntheticManifest),
                    pluginListsJson = emptyList(),
                    pluginsJson = json.encodeToString(enabledPlugins),
                    lastSyncedAt = now,
                    lastAttemptAt = now,
                    discoveredVia = persisted?.discoveredVia ?: discoveredVia,
                )
                state.copy(repos = state.repos.filter { it.url != repoUrl } + updated)
            }

            return SyncOutcome(
                repository = RepositoryDto(
                    name = syntheticManifest.name,
                    url = repoUrl,
                    description = syntheticManifest.description,
                    iconUrl = null,
                    manifestVersion = 1,
                    pluginCount = enabledPlugins.size,
                    status = "ok",
                    error = null,
                    verified = false,
                    keyFingerprint = null,
                    skippedRepositories = skipped.toList(),
                ),
                manifest = syntheticManifest,
                plugins = enabledPlugins,
                verified = false,
                keyFingerprint = null,
                committedRepositories = committedChildren.toList() + repoUrl,
            )
        }

        // Authenticity (TOFU pinning per repository URL)
        if (policyKey != null && rotateKey) throw PolicyException("Your organization manages this repository's signing key.")
        val expectedKey = policyKey ?: if (rotateKey) null else anchor?.publicKey ?: persisted?.pinnedPublicKey
        val verification = RepoSignature.verify(manifestBody, expectedKey)
        if (rotateKey && verification == null) throw SecurityException("Re-trust requires a signed manifest")
        if (!rotateKey && anchor == null && persisted?.pinnedPublicKey == null && policyKey == null && verification == null) {
            policy.requireTier(DaemonState.TrustTier.COMMUNITY)
        }
        if (verification != null && !verification.valid) {
            throw SecurityException("Repository signature rejected: ${verification.reason}")
        }
        val signed = verification != null
        val pinnedKey = verification?.publicKey ?: persisted?.pinnedPublicKey
        val fingerprint = verification?.keyFingerprint
            ?: persisted?.pinnedKeyFingerprint
            ?: verification?.publicKey?.let { RepoSignature.keyFingerprintFromB64(it) }

        val manifest = json.decodeFromJsonElement(RepositoryManifest.serializer(), RepositoryJson.parse(manifestBody))
        val authenticatedRoot = if (signed) CatalogTrust.authenticateRoot(manifestBody, expectedKey, anchor) else null

        require(manifest.pluginLists.size <= 16) { "Too many plugin lists" }
        val plugins = mutableListOf<SitePlugin>()
        val authenticatedLists = mutableListOf<DaemonState.AuthenticatedCatalogList>()
        var catalogBytes = 0
        for (pluginListUrl in manifest.pluginLists) {
            val absoluteListUrl = resolveUrl(manifestBase, pluginListUrl)
            require(catalogBytes < RepositoryTransport.MAX_LIST_BYTES) { "Combined plugin lists exceed byte limit" }
            val listDocument = fetcher.fetch(absoluteListUrl, RepositoryTransport.MAX_LIST_BYTES - catalogBytes)
            catalogBytes += listDocument.bytes.size
            val body = listDocument.text()
            val rawPlugins = CatalogTrust.decodeList(authenticatedRoot, pluginListUrl, listDocument.bytes, listDocument.effectiveUrl, repoUrl)
            require(rawPlugins.size <= 10_000 - plugins.size) { "Too many extensions in repository" }
            plugins += rawPlugins
            // Exact bytes are evidence for both tiers (signed binding, or community consent).
            authenticatedLists += DaemonState.AuthenticatedCatalogList(pluginListUrl, listDocument.effectiveUrl, body)
        }
        val catalog = CatalogTrust.distinctEntries(plugins)
        val enabledPlugins = catalog.filter { isInstallable(it.status) }

        // Persist for catalog browsing and boot-from-cache
        DaemonState.update { state ->
            check(state.repos.firstOrNull { it.url == repoUrl } == persisted) { "Repository changed during sync; retry required" }
            check(state.repositoryTrust[repoUrl] == anchor) { "Repository trust changed during sync; retry required" }
            val updated = DaemonState.PersistedRepository(
                url = repoUrl,
                pinnedPublicKey = pinnedKey,
                pinnedKeyFingerprint = fingerprint,
                signed = signed,
                manifestJson = manifestBody,
                pluginListsJson = manifest.pluginLists.map { listUrl ->
                    resolveUrl(manifestBase, listUrl)
                },
                pluginsJson = json.encodeToString(catalog),
                lastSyncedAt = System.currentTimeMillis(),
                authenticatedLists = authenticatedLists,
                // Consent was given to this publisher as it was then: it does not
                // survive a change of tier or of signing key.
                consent = persisted?.let { previous ->
                    previous.consent?.takeIf { previous.signed == signed && !rotateKey &&
                        (!signed || previous.pinnedKeyFingerprint == null || previous.pinnedKeyFingerprint == fingerprint) }
                },
                lastAttemptAt = System.currentTimeMillis(),
                lastError = null,
                discoveredVia = persisted?.discoveredVia ?: discoveredVia,
            )
            state.copy(repos = state.repos.filter { it.url != repoUrl } + updated,
                repositoryTrust = if (authenticatedRoot == null) state.repositoryTrust else state.repositoryTrust +
                    (repoUrl to DaemonState.RepositoryTrustAnchor(authenticatedRoot.publicKey, authenticatedRoot.fingerprint,
                        authenticatedRoot.version, authenticatedRoot.digest)))
        }

        return SyncOutcome(
            repository = RepositoryDto(
                name = manifest.name,
                url = repoUrl,
                description = manifest.description,
                iconUrl = manifest.iconUrl,
                manifestVersion = manifest.manifestVersion,
                pluginCount = enabledPlugins.size,
                status = "ok",
                error = null,
                verified = signed,
                keyFingerprint = fingerprint,
            ),
            manifest = manifest,
            plugins = enabledPlugins,
            verified = signed,
            keyFingerprint = fingerprint,
            committedRepositories = listOf(repoUrl),
        )
    }

    /** Explicit re-trust after a pinned key change (user action required). */
    suspend fun reTrust(repoUrl: String): RepositoryDto =
        sync(repoUrl, transport, rotateKey = true, userInitiated = false).repository

    fun getRepoPlugins(repoUrl: String): List<RepoPluginDto> {
        val state = DaemonState.snapshot()
        val repo = state.repos.firstOrNull { it.url == repoUrl.trim() } ?: return emptyList()
        val plugins = decodePersistedPlugins(repo)
        val evidence = mutableMapOf<String, Result<CatalogTrust.TrustedCatalog>>()
        val policy = DaemonRuntime.policy
        return plugins.map { plugin ->
            val source = plugin.repositoryUrl ?: repo.url
            val sourceRepo = state.repos.singleOrNull { it.url == source }
            val catalog = evidence.getOrPut(source) { runCatching {
                CatalogTrust.restoreCatalog(requireNotNull(sourceRepo) { "Repository removed" }, state.repositoryTrust[source], requireFresh = true)
            } }
            val tier = catalog.getOrNull()?.tier ?: sourceRepo?.tier
            val blocked = when {
                !isInstallable(plugin.status) -> "The publisher marked this extension unavailable."
                plugin.url.isEmpty() -> INSECURE_DOWNLOAD_REASON
                sourceRepo == null -> "Add the extension's source repository to install it."
                !policy.repositoryAllowed(source) -> "Your organization does not allow this repository."
                tier != null && runCatching { policy.requireTier(tier, source) }.isFailure -> "Your organization allows only repositories it has approved."
                catalog.isFailure -> "Sync this repository to obtain a current catalog."
                plugin !in catalog.getOrThrow().plugins -> "Catalog metadata changed. Sync this repository before installing."
                !plugin.fileHash.isNullOrBlank() && normalizedHash(plugin.fileHash) == null -> "The publisher provided an invalid SHA-256 digest."
                plugin.fileHash.isNullOrBlank() && !policy.allowLocalObservation -> "Your organization requires publisher verification of extension downloads."
                tier != null && policy.needsConsent(tier, source) && sourceRepo.consent == null -> CONSENT_REQUIRED_REASON
                else -> null
            }
            val installed = state.installations[InstallationProofStore.installationId(source, plugin.internalName)]
            val updateState = installed?.let { UpdatePolicy.evaluate(it, plugin) } ?: UpdatePolicy.State.NONE

            RepoPluginDto(
                id = plugin.internalName.ifBlank { plugin.fileHash ?: plugin.name },
                name = plugin.name,
                internalName = plugin.internalName,
                version = plugin.version,
                apiVersion = plugin.apiVersion,
                url = plugin.url,
                repositoryUrl = source,
                description = plugin.description,
                authors = plugin.authors,
                tvTypes = plugin.tvTypes ?: emptyList(),
                language = plugin.language,
                iconUrl = plugin.iconUrl,
                fileSize = plugin.fileSize,
                fileHash = plugin.fileHash,
                status = plugin.status,
                isInstalled = installed != null,
                isUpdateAvailable = updateState == UpdatePolicy.State.UPDATE,
                installationAllowed = blocked == null,
                installationBlockedReason = blocked,
                tier = tier?.wire(source),
                installationId = installed?.id,
                installedVersion = installed?.metadata?.version,
                updateState = updateState.name.lowercase(),
                requiresConsent = blocked == CONSENT_REQUIRED_REASON,
                verificationMode = if (tier == DaemonState.TrustTier.VERIFIED) "signed_catalog"
                    else if (normalizedHash(plugin.fileHash) != null) "publisher_digest" else "local_observation",
            )
        }
    }

    /** Whole sync, HTML discovery included (RT-10). */
    const val SYNC_TIMEOUT_MS = 120_000L
    /** Kept back from a candidate's budget to commit what it loaded. */
    const val COMMIT_RESERVE_MS = 10_000L
    /** Service time of one admitted HTML child. */
    const val CHILD_SYNC_TIMEOUT_MS = 60_000L
    private const val MIN_CHILD_BUDGET_MS = 3_000L
    /** Child repositories one discovery page may contribute. */
    const val MAX_DISCOVERED_REPOSITORIES = 64

    const val INSECURE_DOWNLOAD_REASON = "The publisher's download address is not a valid HTTPS address."
    const val CONSENT_REQUIRED_REASON = "Allow installs from this community repository to install its extensions."

    fun installedPlugins(): List<PluginDto> {
        val state = DaemonState.snapshot()
        val catalogs = CatalogCache(state)
        return state.installations.values.sortedBy { it.metadata.name.lowercase() }.map { installationDto(state, it, catalogs) }
    }

    fun installedPlugin(id: String): PluginDto? = DaemonState.snapshot().let { state -> state.installations[id]?.let { installationDto(state, it, CatalogCache(state)) } }

    /** Verifies each repository's saved catalog at most once per request (signature + list decoding are costly). */
    internal class CatalogCache(private val state: DaemonState.PersistedState) {
        private val byRepository = HashMap<String, Map<String, SitePlugin>?>()
        fun entry(repositoryUrl: String, internalName: String): SitePlugin? = byRepository.getOrPut(repositoryUrl) {
            val repo = state.repos.singleOrNull { it.url == repositoryUrl } ?: return@getOrPut null
            runCatching { CatalogTrust.restoreCatalog(repo, state.repositoryTrust[repo.url], requireFresh = false) }.getOrNull()
                ?.plugins?.associateBy { it.internalName }
        }?.get(internalName)
    }

    private fun installationDto(state: DaemonState.PersistedState, record: DaemonState.InstalledExtension, catalogs: CatalogCache): PluginDto {
        val plugin = record.metadata
        val loaded = PluginBridge.loadedInstallation(record.id)?.takeIf { it.generation == record.generation }
        val repo = state.repos.singleOrNull { it.url == record.repositoryUrl }
        val latest = catalogs.entry(record.repositoryUrl, record.internalName)
        val updateState = latest?.let { UpdatePolicy.evaluate(record, it) } ?: UpdatePolicy.State.NONE
        val error = installations.lastError(record.id)
        // Registration is not a running process: a worker starts on first use (RT-16).
        val handle = (loaded?.plugin as? com.lagradost.macos.worker.WorkerPlugin)?.handle
        val process = when {
            loaded == null -> null
            handle == null -> "in_process"
            handle.running -> "running"
            else -> "not_started"
        }
        val runState = when {
            record.revokedReason != null -> "revoked"
            record.quarantinedReason != null -> "quarantined"
            !record.enabled -> "disabled"
            DaemonRuntime.safeMode -> "safe_mode"
            installations.isRunning(record) -> if (process == "not_started") "ready" else "running"
            error != null -> "failed"
            else -> "starting"
        }
        return PluginDto(id = record.id, name = plugin.name, internalName = record.internalName,
            version = plugin.version, apiVersion = plugin.apiVersion, language = plugin.language,
            description = plugin.description, authors = plugin.authors, tvTypes = plugin.tvTypes.orEmpty(),
            iconUrl = plugin.iconUrl, repositoryUrl = record.repositoryUrl, mainUrl = loaded?.providers?.firstOrNull()?.mainUrl,
            fileSize = plugin.fileSize ?: 0, sha256 = record.artifactHash, providers = record.providerNames,
            verificationMode = record.verificationMode.name.lowercase(), publisherHash = record.publisherHash, proofFormatVersion = record.proofFormatVersion,
            enabled = record.enabled, verified = record.tier == DaemonState.TrustTier.VERIFIED && DaemonRuntime.policy.keyPinned(record.repositoryUrl),
            lastError = record.revokedReason ?: record.quarantinedReason ?: error,
            state = runState, tier = record.tier.wire(record.repositoryUrl), installedAt = record.installedAt,
            availableVersion = latest?.version?.takeIf { updateState != UpdatePolicy.State.NONE },
            updateAvailable = updateState == UpdatePolicy.State.UPDATE,
            previousVersion = record.previous?.metadata?.version,
            missingFromCatalog = record.missingFromCatalog,
            // Developer imports never had a repository; "repository removed" would be misleading.
            repositoryPresent = repo != null || record.tier == DaemonState.TrustTier.DEVELOPER,
            extractorCount = record.extractorCount,
            providerIds = loaded?.providers?.map(PluginBridge::providerId) ?: record.providerNames.map { "${record.id}:$it" },
            unsupportedFeatures = loaded?.unsupportedFeatures.orEmpty(),
            process = process,
            health = OperationHealth.forGeneration(record.id, record.generation).take(32),
            sharedProviderNames = record.providerNames.mapNotNull { name ->
                val others = state.installations.values.filter { it.id != record.id && it.enabled && name in it.providerNames }
                    .map { it.metadata.name.ifBlank { it.internalName } }
                if (others.isEmpty()) null else com.lagradost.macos.models.SharedProviderNameDto(name, others.sorted().take(8))
            },
            compatibility = record.compatibility?.let { report ->
                com.lagradost.macos.models.CompatibilityDto(
                    profile = report.profile,
                    current = report.profile == RuntimeProfile.VERSION,
                    coreCode = report.missing.filter { it.role != "other" }.map { readableHostSymbol(it.type) },
                    otherCode = report.missing.filter { it.role == "other" }.map { readableHostSymbol(it.type) },
                    truncated = report.truncated,
                )
            },
        )
    }

    /**
     * The tier as shown (M4): `verified` only for a signed catalog whose key the
     * organization pinned; any other signed catalog is `signed` (trust on first
     * use, shown with its key fingerprint); then `community` and `developer`.
     */
    private fun DaemonState.TrustTier.wire(url: String) = when (this) {
        DaemonState.TrustTier.VERIFIED -> if (DaemonRuntime.policy.keyPinned(url)) "verified" else "signed"
        else -> name.lowercase()
    }

    /**
     * A missing type as a dotted name; a missing member (A3, `owner.name(…)…`
     * or `owner.name:…`) as `Owner.name()` / `Owner.name`, which reads well
     * where the client shows only the last part.
     */
    internal fun readableHostSymbol(symbol: String): String {
        val memberStart = symbol.indexOfFirst { it == '(' || it == ':' }
        if (memberStart < 0) return symbol.replace('/', '.')
        val qualified = symbol.substring(0, memberStart)
        val owner = qualified.substringBeforeLast('.').substringAfterLast('/').substringAfterLast('$')
        val member = qualified.substringAfterLast('.')
        return if (symbol[memberStart] == '(') "$owner.$member()" else "$owner.$member"
    }

    /**
     * SEC-07 gate: downloads the plugin and verifies its SHA-256 against the
     * repository catalog digest.
     */
    suspend fun fetchVerifiedCs3(plugin: SitePlugin): File = fetchVerifiedCs3(plugin, transport)

    internal suspend fun fetchVerifiedCs3(plugin: SitePlugin, fetcher: RepositoryFetcher): File =
        fetchArtifact(plugin, fetcher, allowLocalObservation = false).file

    internal data class DownloadedArtifact(val file: File, val hash: String, val effectiveUrl: String)

    internal suspend fun fetchArtifact(plugin: SitePlugin, fetcher: RepositoryFetcher, allowLocalObservation: Boolean): DownloadedArtifact {
        val expected = normalizedHash(plugin.fileHash)
        if (!plugin.fileHash.isNullOrBlank() && expected == null) throw SecurityException("Invalid publisher SHA-256 digest")
        if (expected == null && !allowLocalObservation) throw SecurityException("Publisher verification is required for this download")
        val document = fetcher.fetch(plugin.url, RepositoryTransport.MAX_ARTIFACT_BYTES)
        val body = document.bytes
        require(body.isNotEmpty() && body.size <= RepositoryTransport.MAX_ARTIFACT_BYTES) { "Invalid artifact size" }
        val effectiveUrl = RepositoryTransport.requireHttpsUrl(document.effectiveUrl).toString()
        val hash = ArtifactDigest.sha256(body)
        if (expected != null && hash != expected) throw SecurityException("SHA-256 mismatch for '${plugin.name}'")
        if (plugin.fileSize != null && plugin.fileSize > 0 && body.size.toLong() != plugin.fileSize) {
            throw SecurityException("Artifact length does not match the catalog")
        }
        val file = ArtifactStore.source(hash)
        // AtomicFiles uses a unique bounded staging file before publication.
        AtomicFiles.write(file.toPath(), body)
        return DownloadedArtifact(file, hash, effectiveUrl)
    }

    internal fun normalizedHash(raw: String?): String? {
        val value = raw?.trim()?.lowercase()?.removePrefix("sha256-") ?: return null
        return value.takeIf { it.length == 64 && it.all { c -> c in '0'..'9' || c in 'a'..'f' } }
    }

    // ------------------------------------------------------------------

    private fun decodePersistedPlugins(repo: DaemonState.PersistedRepository): List<SitePlugin> {
        val persisted = repo.pluginsJson ?: return emptyList()
        return runCatching { json.decodeFromString<List<SitePlugin>>(persisted) }
            .getOrElse {
                DaemonLog.warn("state.plugins_decode_failed", mapOf("repo" to repo.url))
                emptyList()
            }
    }

    // Frozen audit probes call these entry points; keep their replay compatibility.
    @Deprecated("Use ArtifactDigest.sha256")
    fun sha256(bytes: ByteArray): String = ArtifactDigest.sha256(bytes)

    @Deprecated("Use ArtifactDigest.sha256")
    fun sha256(file: File): String = ArtifactDigest.sha256(file)
}
