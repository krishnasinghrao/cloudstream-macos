package com.lagradost.macos

import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.time.Instant

/** Immutable, content-addressed catalog evidence. Publishing a proof does not
 * install anything; only the committed state record grants ownership.
 * VERIFIED proofs carry the signed root and list bytes; COMMUNITY proofs carry
 * the exact list bytes plus the consent under which they were accepted. */
internal class InstallationProofStore(private val directory: File = File(CloudDirs.stateDir, "installation-proofs")) {
    @Serializable
    data class ArtifactObservation(val internalName: String, val catalogUrl: String, val resolvedUrl: String,
        val artifactHash: String, val observedAt: Long)

    @Serializable
    data class Proof(
        val repository: DaemonState.PersistedRepository,
        val anchor: DaemonState.RepositoryTrustAnchor? = null,
        val acceptedAt: Long,
        val tier: DaemonState.TrustTier = DaemonState.TrustTier.VERIFIED,
        /** Developer tier: the imported file's digest (there is no catalog to bind it). */
        val artifactHash: String? = null,
        /** Absent on legacy receipts; default 1 preserves the old reader contract. */
        val formatVersion: Int = 1,
        val observation: ArtifactObservation? = null,
    )
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    fun put(repo: DaemonState.PersistedRepository, anchor: DaemonState.RepositoryTrustAnchor?, observation: ArtifactObservation? = null): String {
        val catalog = CatalogTrust.restoreCatalog(repo, anchor, requireFresh = true)
        if (catalog.tier == DaemonState.TrustTier.COMMUNITY) requireNotNull(repo.consent) { "Community repository requires consent" }
        if (observation != null) {
            require(catalog.tier == DaemonState.TrustTier.COMMUNITY) { "Signed catalogs require publisher digests" }
            val entry = catalog.plugins.single { it.internalName == observation.internalName }
            require(entry.fileHash.isNullOrBlank() && entry.url == observation.catalogUrl) { "Observation is not bound to this catalog entry" }
            require(RepositoryService.normalizedHash(observation.artifactHash) == observation.artifactHash) { "Invalid observed digest" }
            RepositoryTransport.requireHttpsUrl(observation.resolvedUrl)
            DaemonRuntime.policy.requireVerification(DaemonState.ArtifactVerification.LOCAL_OBSERVATION)
        }
        val proof = Proof(repo.copy(pluginsJson = null, pluginListsJson = emptyList(), lastError = null, lastAttemptAt = 0),
            anchor.takeIf { catalog.tier == DaemonState.TrustTier.VERIFIED }, System.currentTimeMillis(), catalog.tier,
            formatVersion = 2, observation = observation)
        val bytes = json.encodeToString(proof).toByteArray()
        require(bytes.size <= MAX_BYTES) { "Installation proof exceeds size limit" }
        val hash = ArtifactDigest.sha256(bytes)
        AtomicFiles.write(File(directory, "$hash.json").toPath(), bytes)
        return hash
    }

    /** Evidence for a developer (local file) import: the user's explicit action and the exact bytes. */
    fun putDeveloper(artifactHash: String): String {
        require(RepositoryService.normalizedHash(artifactHash) == artifactHash) { "Invalid artifact digest" }
        val proof = Proof(DaemonState.PersistedRepository(url = DaemonState.DEVELOPER_SOURCE), null, System.currentTimeMillis(),
            DaemonState.TrustTier.DEVELOPER, artifactHash, formatVersion = 2)
        val bytes = json.encodeToString(proof).toByteArray()
        val hash = ArtifactDigest.sha256(bytes)
        AtomicFiles.write(File(directory, "$hash.json").toPath(), bytes)
        return hash
    }

    fun read(hash: String): Proof {
        require(RepositoryService.normalizedHash(hash) == hash) { "Invalid installation proof digest" }
        val path = File(directory, "$hash.json").toPath()
        require(Files.isRegularFile(path, NOFOLLOW_LINKS) && Files.size(path) <= MAX_BYTES) { "Invalid installation proof file" }
        val bytes = Files.readAllBytes(path)
        require(ArtifactDigest.sha256(bytes) == hash) { "Installation proof digest mismatch" }
        return json.decodeFromString(RepositoryDocument(bytes, "").text())
    }

    fun exists(hash: String): Boolean = RepositoryService.normalizedHash(hash) == hash && File(directory, "$hash.json").isFile

    /** Proof digests present on disk (for garbage collection). */
    fun storedHashes(): Set<String> = directory.listFiles { f -> f.isFile && f.name.endsWith(".json") }
        ?.map { it.name.removeSuffix(".json") }?.filter { RepositoryService.normalizedHash(it) == it }?.toSet().orEmpty()

    fun delete(hash: String) {
        if (RepositoryService.normalizedHash(hash) == hash) Files.deleteIfExists(File(directory, "$hash.json").toPath())
    }

    fun verify(record: DaemonState.InstalledExtension, currentAnchor: DaemonState.RepositoryTrustAnchor?): RepositoryService.SitePlugin {
        val proof = read(record.proofHash)
        require(proof.formatVersion in 1..2 && record.proofFormatVersion in 1..2 &&
            (record.proofFormatVersion == 1 || proof.formatVersion == record.proofFormatVersion)) { "Unsupported installation proof format" }
        require(record.repositoryUrl == proof.repository.url && record.id == installationId(record.repositoryUrl, record.internalName)) { "Installation identity mismatch" }
        require(proof.tier == record.tier) { "Installation trust tier mismatch" }
        val plugins = when (proof.tier) {
            DaemonState.TrustTier.VERIFIED -> {
                val signedAnchor = requireNotNull(proof.anchor) { "Verified proof lacks a trust anchor" }
                require(currentAnchor != null && currentAnchor.publicKey == signedAnchor.publicKey &&
                    currentAnchor.catalogVersion >= signedAnchor.catalogVersion) { "Installation signing key is no longer trusted" }
                // Prove that this evidence was accepted while fresh; offline boot does
                // not turn an expired receipt into permission to install new content.
                CatalogTrust.authenticateRoot(requireNotNull(proof.repository.manifestJson), signedAnchor.publicKey, signedAnchor,
                    now = Instant.ofEpochMilli(proof.acceptedAt), requireFresh = true)
                DaemonRuntime.policy.requireTier(DaemonState.TrustTier.VERIFIED, proof.repository.url)
                CatalogTrust.restore(proof.repository, signedAnchor, requireFresh = false)
            }
            DaemonState.TrustTier.DEVELOPER -> {
                require(proof.repository.url == DaemonState.DEVELOPER_SOURCE && proof.artifactHash == record.artifactHash) {
                    "Developer proof does not match this installation"
                }
                DaemonRuntime.policy.requireTier(DaemonState.TrustTier.DEVELOPER)
                if (!DaemonState.snapshot().extensionSettings.developerMode) {
                    throw SecurityException("Developer mode is off; local extensions do not load.")
                }
                listOf(record.metadata)
            }
            DaemonState.TrustTier.COMMUNITY -> {
                require(!proof.repository.signed && proof.repository.consent != null) { "Community proof lacks consent" }
                DaemonRuntime.policy.requireTier(DaemonState.TrustTier.COMMUNITY)
                CatalogTrust.distinctEntries(proof.repository.authenticatedLists.flatMap { list ->
                    CatalogTrust.decodeList(null, list.reference, list.body.toByteArray(Charsets.UTF_8), list.effectiveUrl, proof.repository.url)
                })
            }
        }
        val plugin = plugins.single { it.internalName == record.internalName }
        require(plugin == record.metadata) { "Installation metadata differs from catalog evidence" }
        DaemonRuntime.policy.requireVerification(record.verificationMode)
        val declaredHash = RepositoryService.normalizedHash(plugin.fileHash)
        if (record.verificationMode == DaemonState.ArtifactVerification.LOCAL_OBSERVATION) {
            val observation = requireNotNull(proof.observation) { "Missing local byte observation" }
            require(proof.formatVersion == 2 && record.proofFormatVersion == 2 && record.tier == DaemonState.TrustTier.COMMUNITY &&
                plugin.fileHash.isNullOrBlank() && record.publisherHash == null && observation.artifactHash == record.artifactHash &&
                observation.internalName == record.internalName && observation.catalogUrl == plugin.url &&
                observation.observedAt > 0 && observation.observedAt <= proof.acceptedAt) { "Installation differs from its local byte observation" }
            RepositoryTransport.requireHttpsUrl(observation.resolvedUrl)
        } else {
            require(record.verificationMode == DaemonState.ArtifactVerification.legacy(record.tier) &&
                declaredHash == record.artifactHash && record.publisherHash == declaredHash && proof.observation == null) {
                "Installation digest differs from publisher evidence"
            }
        }
        return plugin
    }

    companion object {
        private const val MAX_BYTES = 16 * 1024 * 1024
        fun installationId(repo: String, name: String): String = ArtifactDigest.sha256("${repo.length}:$repo$name".toByteArray())
    }
}
