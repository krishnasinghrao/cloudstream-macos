package com.lagradost.macos

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import java.io.File
import kotlin.test.*

/** Lifecycle invariants (plan P3/P4) with a runtime double; the real loader is covered by PluginBridgeTest. */
class InstallationLifecycleTest {
    private val repo = SignedCatalogFixture("https://lifecycle.invalid/repo.json")
    private val v1 = "extension version one".toByteArray()
    private val v2 = "extension version two".toByteArray()
    private lateinit var runtime: FakeRuntime

    @BeforeTest fun before() { ExtensionTestSupport.resetHome(); runtime = FakeRuntime() }
    @AfterTest fun after() = ExtensionTestSupport.resetHome()

    private fun server(vararg artifacts: ByteArray) = RepositoryFetcher { url, _ ->
        val bytes = artifacts.firstOrNull { RepositoryService.resolveUrl(repo.url, "Ext.cs3") == url && true }
        requireNotNull(bytes) { "unexpected $url" }
        RepositoryDocument(currentArtifact ?: bytes, url)
    }
    @Volatile private var currentArtifact: ByteArray? = null

    private suspend fun publish(bytes: ByteArray, revision: Long, version: Int = 1, status: Int = 1) {
        currentArtifact = bytes
        repo.publish(mapOf("Ext" to bytes), revision, version, status)
    }

    private fun manager() = ExtensionTestSupport.use(InstallationManager(runtime, server(v1)))
    private val id = InstallationProofStore.installationId(repo.url, "Ext")

    @Test fun `install commits a receipt with provenance then publishes`() = runBlocking<Unit> {
        publish(v1, 1)
        val record = manager().install(repo.url, "Ext")
        assertEquals(id, record.id)
        assertEquals(DaemonState.TrustTier.VERIFIED, record.tier)
        assertEquals(ArtifactDigest.sha256(v1), record.artifactHash)
        assertEquals(record.generation, runtime.generation(id))
        assertEquals(listOf("FakeProvider"), record.providerNames)
        assertTrue(ExtensionTestSupport.sourceFile(record.artifactHash).isFile)
        assertTrue(AuditLog.recent().any { "extension.install" in it })
    }

    @Test fun `update keeps previous generation for rollback and failed publish keeps the old one serving`() = runBlocking<Unit> {
        publish(v1, 1, version = 1)
        val manager = manager()
        val first = manager.install(repo.url, "Ext")
        publish(v2, 2, version = 2)
        assertTrue(RepositoryService.getRepoPlugins(repo.url).single().isUpdateAvailable)
        assertEquals(listOf(id), manager.availableUpdates().map { it.id })

        runtime.failPublish = true
        assertFails { manager.update(id) }
        assertEquals(first, DaemonState.snapshot().installations[id], "state rolled back")
        assertEquals(first.generation, runtime.generation(id), "old generation still serving")

        runtime.failPublish = false
        val second = manager.update(id)
        assertEquals(ArtifactDigest.sha256(v2), second.artifactHash)
        assertEquals(first.artifactHash, second.previous?.artifactHash)
        assertFalse(RepositoryService.getRepoPlugins(repo.url).single().isUpdateAvailable)

        val rolledBack = manager.rollback(id)
        assertEquals(first.artifactHash, rolledBack.artifactHash)
        assertEquals(second.artifactHash, rolledBack.previous?.artifactHash)
        assertEquals(rolledBack.generation, runtime.generation(id))
    }

    @Test fun `beta extensions install like Android and status 0 never does`() = runBlocking<Unit> {
        publish(v1, 1, status = 3)
        val listed = RepositoryService.getRepoPlugins(repo.url).single()
        assertNull(listed.installationBlockedReason, "status 3 (beta) is installable, as on Android")
        assertEquals(ArtifactDigest.sha256(v1), manager().install(repo.url, "Ext").artifactHash)
        publish(v1, 2, status = 0)
        assertNotNull(RepositoryService.getRepoPlugins(repo.url).single().installationBlockedReason)
        assertTrue(RepositoryService.isInstallable(2) && RepositoryService.isInstallable(4) && !RepositoryService.isInstallable(0))
    }

    @Test fun `older catalog versions require explicit downgrade`() = runBlocking<Unit> {
        publish(v2, 1, version = 5)
        val manager = manager()
        manager.install(repo.url, "Ext")
        publish(v1, 2, version = 4)
        assertEquals("older_in_catalog", RepositoryService.getRepoPlugins(repo.url).single().updateState)
        assertEquals(ExtensionException.Code.DOWNGRADE, assertFailsWith<ExtensionException> { manager.update(id) }.code)
        assertEquals(ArtifactDigest.sha256(v1), manager.install(repo.url, "Ext", allowDowngrade = true).artifactHash)
    }

    @Test fun `publisher revocation unloads, survives restart and is lifted when re-enabled remotely`() = runBlocking<Unit> {
        publish(v1, 1)
        val manager = manager()
        manager.install(repo.url, "Ext")
        publish(v1, 2, status = 0)
        manager.reconcile(repo.url)
        val revoked = DaemonState.snapshot().installations.getValue(id)
        assertEquals(InstallationManager.REVOKED_BY_PUBLISHER, revoked.revokedReason)
        assertNull(runtime.generation(id))
        DaemonState.load()
        assertFalse(manager.restore(id), "revoked receipts never load at startup")
        publish(v1, 3, status = 1)
        manager.reconcile(repo.url)
        assertNull(DaemonState.snapshot().installations.getValue(id).revokedReason)
        assertNotNull(runtime.generation(id))
    }

    @Test fun `key rotation re-issues evidence for unchanged artifacts and revokes others`() = runBlocking<Unit> {
        publish(v1, 1)
        val manager = manager()
        val record = manager.install(repo.url, "Ext")
        val rotated = SignedCatalogFixture(repo.url)
        val body = rotated.listFor(mapOf("Ext" to v1))
        RepositoryService.sync(repo.url, rotated.fetcher(rotated.manifest(body, revision = 2), body), rotateKey = true)
        manager.reconcile(repo.url)
        val reproved = DaemonState.snapshot().installations.getValue(id)
        assertNotEquals(record.proofHash, reproved.proofHash)
        assertNull(reproved.revokedReason)
        assertTrue(runCatching { InstallationProofStore().verify(reproved, DaemonState.snapshot().repositoryTrust[repo.url]) }.isSuccess)

        val other = rotated.listFor(mapOf("Ext" to v2), version = 2)
        currentArtifact = v2
        RepositoryService.sync(repo.url, rotated.fetcher(rotated.manifest(other, revision = 3), other))
        manager.reconcile(repo.url)
        assertNull(DaemonState.snapshot().installations.getValue(id).revokedReason, "evidence re-issued under the new key stays valid")
    }

    @Test fun `community repositories need consent and receipts keep the community tier`() = runBlocking<Unit> {
        val community = SignedCatalogFixture("https://community.invalid/repo.json")
        val body = community.listFor(mapOf("Ext" to v1))
        val fetcher = community.fetcher("""{"name":"c","pluginLists":["list.json"]}""", body, mapOf("Ext" to v1))
        RepositoryService.sync(community.url, fetcher)
        val manager = ExtensionTestSupport.use(InstallationManager(runtime, fetcher))
        assertEquals(ExtensionException.Code.CONSENT_REQUIRED, assertFailsWith<ExtensionException> { manager.install(community.url, "Ext") }.code)
        RepositoryService.setConsent(community.url, true)
        val record = manager.install(community.url, "Ext")
        assertEquals(DaemonState.TrustTier.COMMUNITY, record.tier)
        assertFalse(RepositoryService.installedPlugins().single().verified)
        DaemonRuntime.resetForTest(LaunchOptions(ExtensionPolicy(allowCommunityTier = false)))
        runtime.remove(record.id)
        assertFalse(manager.restore(record.id), "policy blocks community receipts at load time")
        assertTrue(manager.lastError(record.id)!!.contains("organization"))
    }

    @Test fun `hashless community entries install with consent and truthful local observation`() = runBlocking<Unit> {
        val community = SignedCatalogFixture("https://hashless.invalid/repo.json")
        val body = """[{"name":"Ext","internalName":"Ext","url":"Ext.cs3","status":1}]"""
        val fetcher = community.fetcher("""{"name":"c","pluginLists":["list.json"]}""", body, mapOf("Ext" to v1))
        RepositoryService.sync(community.url, fetcher)
        val manager = ExtensionTestSupport.use(InstallationManager(runtime, fetcher))
        assertEquals(ExtensionException.Code.CONSENT_REQUIRED, assertFailsWith<ExtensionException> { manager.install(community.url, "Ext") }.code)
        RepositoryService.setConsent(community.url, true)
        assertTrue(RepositoryService.getRepoPlugins(community.url).single().installationAllowed)
        val record = manager.install(community.url, "Ext")
        assertEquals(DaemonState.ArtifactVerification.LOCAL_OBSERVATION, record.verificationMode)
        assertNull(record.metadata.fileHash)
        assertNull(record.publisherHash)
        assertEquals(ArtifactDigest.sha256(v1), record.artifactHash)
        val proof = InstallationProofStore().read(record.proofHash)
        assertEquals(record.artifactHash, proof.observation?.artifactHash)
        assertEquals(2, proof.formatVersion)
        runtime.remove(record.id)
        assertTrue(manager.restore(record.id))
        DaemonRuntime.resetForTest(LaunchOptions(ExtensionPolicy(allowLocalObservation = false)))
        runtime.remove(record.id)
        assertFalse(manager.restore(record.id))
        assertTrue(manager.lastError(record.id)!!.contains("organization"))
    }

    /** RT-08: the catalog cannot show a republished hashless file, so updates download and compare. */
    @Test fun `hashless rechecks compare bytes and automatic updates stay conservative`() = runBlocking<Unit> {
        val community = SignedCatalogFixture("https://hashless-update.invalid/repo.json")
        val manifest = """{"name":"c","pluginLists":["list.json"]}"""
        fun list(version: Int) = """[{"name":"Ext","internalName":"Ext","url":"Ext.cs3","status":1,"version":$version}]"""
        var artifact = v1
        var catalog = list(1)
        val fetcher = RepositoryFetcher { url, max -> community.fetcher(manifest, catalog, mapOf("Ext" to artifact)).fetch(url, max) }
        RepositoryService.sync(community.url, fetcher)
        RepositoryService.setConsent(community.url, true)
        val manager = ExtensionTestSupport.use(InstallationManager(runtime, fetcher))
        val record = manager.install(community.url, "Ext")

        // Recheck with unchanged bytes keeps the committed generation.
        val prepares = runtime.prepares
        val same = manager.update(record.id)
        assertEquals(record.generation, same.generation)
        assertEquals(prepares, runtime.prepares, "unchanged bytes are not prepared again")
        assertTrue(AuditLog.recent().any { "extension.recheck" in it })

        // Same URL and version, different bytes: a new generation that can be rolled back.
        artifact = v2
        val changed = manager.update(record.id)
        assertNotEquals(record.generation, changed.generation)
        assertEquals(ArtifactDigest.sha256(v2), changed.artifactHash)
        assertEquals(ArtifactDigest.sha256(v1), changed.previous?.artifactHash)
        assertEquals(DaemonState.ArtifactVerification.LOCAL_OBSERVATION, changed.verificationMode)
        assertNull(changed.publisherHash, "a local observation is never presented as a publisher digest")

        // Always-update (-1) hashless entries are offered to the user, never applied automatically.
        catalog = list(-1)
        RepositoryService.sync(community.url, fetcher)
        assertTrue(manager.availableUpdates().any { it.id == record.id })
        assertEquals(emptyList(), manager.updateAll(actor = InstallationManager.AUTO_UPDATE_ACTOR))
        assertEquals(changed.generation, DaemonState.snapshot().installations.getValue(record.id).generation)

        // A higher catalog version is applied automatically.
        catalog = list(2)
        RepositoryService.sync(community.url, fetcher)
        val results = manager.updateAll(actor = InstallationManager.AUTO_UPDATE_ACTOR)
        assertEquals(listOf(record.id to null), results.map { it.installationId to it.error })
        assertEquals(2, DaemonState.snapshot().installations.getValue(record.id).metadata.version)
    }

    @Test fun `operations on one extension are serialized and uninstall is never lost`() = runBlocking<Unit> {
        publish(v1, 1)
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        runtime.onPrepare = { entered.complete(Unit); runBlocking { release.await() } }
        val manager = manager()
        val installing = async(Dispatchers.IO) { manager.install(repo.url, "Ext") }
        withTimeout(5000) { entered.await() }
        val uninstalling = async(Dispatchers.IO) { manager.uninstall(id) }
        delay(100)
        assertFalse(uninstalling.isCompleted, "uninstall waits for the in-flight install")
        release.complete(Unit)
        installing.await()
        assertTrue(uninstalling.await())
        assertNull(DaemonState.snapshot().installations[id])
        assertNull(runtime.generation(id))
    }

    @Test fun `enable is idempotent and a toggle never cancels an update`() = runBlocking<Unit> {
        publish(v1, 1)
        val manager = manager()
        manager.install(repo.url, "Ext")
        val prepares = runtime.prepares
        assertTrue(manager.setEnabled(id, true))
        assertEquals(prepares, runtime.prepares, "enabling a running extension does not reload it")
        assertTrue(manager.setEnabled(id, false))
        assertNull(runtime.generation(id))
        assertFalse(DaemonState.snapshot().installations.getValue(id).enabled)
        assertTrue(manager.setEnabled(id, true))
        assertNotNull(runtime.generation(id))

        publish(v2, 2, version = 2)
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        runtime.onPrepare = { entered.complete(Unit); runBlocking { release.await() } }
        val updating = async(Dispatchers.IO) { manager.update(id) }
        withTimeout(5000) { entered.await() }
        val toggling = async(Dispatchers.IO) { runtime.onPrepare = {}; manager.setEnabled(id, false) }
        release.complete(Unit)
        assertEquals(ArtifactDigest.sha256(v2), updating.await().artifactHash)
        assertTrue(toggling.await())
        assertFalse(DaemonState.snapshot().installations.getValue(id).enabled)
    }

    @Test fun `committed but unloaded receipt is loaded by reinstall instead of returned dead`() = runBlocking<Unit> {
        publish(v1, 1)
        val manager = manager()
        manager.install(repo.url, "Ext")
        runtime.remove(id)
        manager.install(repo.url, "Ext")
        assertNotNull(runtime.generation(id))
    }

    @Test fun `restore rechecks trust at publication`() = runBlocking<Unit> {
        publish(v1, 1)
        val manager = manager()
        manager.install(repo.url, "Ext")
        runtime.remove(id)
        runtime.onPrepare = { DaemonState.update { it.copy(repositoryTrust = emptyMap()) } }
        assertFalse(manager.restore(id))
        assertNull(runtime.generation(id))
    }

    @Test fun `a load interrupted by a crash quarantines that generation at next start`() = runBlocking<Unit> {
        publish(v1, 1)
        val manager = manager()
        val record = manager.install(repo.url, "Ext")
        runtime.remove(id)
        LoadingMarkers.begin(record) // simulate the engine dying while loading
        val result = manager.restoreAll()
        assertEquals(1, result.quarantined)
        assertNotNull(DaemonState.snapshot().installations.getValue(id).quarantinedReason)
        assertNull(runtime.generation(id))
        assertEquals("quarantined", RepositoryService.installedPlugins().single().state)
        assertTrue(manager.retry(id))
        assertNull(DaemonState.snapshot().installations.getValue(id).quarantinedReason)
        assertNotNull(runtime.generation(id))
    }

    @Test fun `safe mode loads nothing but keeps receipts manageable`() = runBlocking<Unit> {
        publish(v1, 1)
        val manager = manager()
        manager.install(repo.url, "Ext")
        runtime.remove(id)
        DaemonRuntime.resetForTest(LaunchOptions(safeMode = true))
        assertEquals("safe_mode", manager.restoreAll().phase)
        assertNull(runtime.generation(id))
        assertEquals("safe_mode", RepositoryService.installedPlugins().single().state)
        assertTrue(manager.uninstall(id))
    }

    @Test fun `repository removal can keep or remove its installations`() = runBlocking<Unit> {
        publish(v1, 1)
        val manager = manager()
        manager.install(repo.url, "Ext")
        assertTrue(manager.removeRepository(repo.url, removeInstallations = false))
        val kept = RepositoryService.installedPlugins().single()
        assertFalse(kept.repositoryPresent)
        assertNotNull(runtime.generation(id))
        publish(v1, 2)
        assertTrue(manager.removeRepository(repo.url, removeInstallations = true))
        assertTrue(DaemonState.snapshot().installations.isEmpty())
        assertNull(runtime.generation(id))
    }

    @Test fun `uninstall removes private data and unreferenced blobs are collected`() = runBlocking<Unit> {
        publish(v1, 1)
        val manager = manager()
        val record = manager.install(repo.url, "Ext")
        val data = ExtensionStorage.directory(id)
        File(data, "marker").writeText("x")
        val source = ExtensionTestSupport.sourceFile(record.artifactHash)
        source.setLastModified(System.currentTimeMillis() - 3600_000)
        assertTrue(manager.uninstall(id))
        assertFalse(data.exists())
        assertFalse(source.exists())
    }

    @Test fun `legacy cached artifacts are adopted once a catalog lists them`() = runBlocking<Unit> {
        CloudDirs.cs3StoreDir.mkdirs()
        ExtensionTestSupport.sourceFile(ArtifactDigest.sha256(v1)).writeBytes(v1)
        val manager = manager()
        manager.migrateLegacyArtifacts()
        assertEquals(1, DaemonState.snapshot().unmatchedLegacyArtifacts.size)
        publish(v1, 1)
        manager.migrateLegacyArtifacts()
        val adopted = DaemonState.snapshot().installations.getValue(id)
        assertEquals(ArtifactDigest.sha256(v1), adopted.artifactHash)
        assertTrue(DaemonState.snapshot().unmatchedLegacyArtifacts.isEmpty())
        assertNotNull(runtime.generation(id))
        assertTrue(AuditLog.recent().any { "extension.migrate" in it })
    }

    @Test fun `failed syncs are recorded for the repository without changing trust`() = runBlocking<Unit> {
        publish(v1, 1)
        val before = DaemonState.snapshot()
        assertFails { RepositoryService.sync(repo.url, RepositoryFetcher { _, _ -> throw java.io.IOException("offline") }) }
        val dto = RepositoryService.listRepositories().single()
        assertEquals("error", dto.status)
        assertEquals("offline", dto.error)
        assertEquals(before.withoutAttempts(), DaemonState.snapshot().withoutAttempts())
    }

    @Test fun `audit log is hash chained and detects edits`() = runBlocking<Unit> {
        publish(v1, 1)
        manager().install(repo.url, "Ext")
        assertTrue(AuditLog.verify())
        val file = File(CloudDirs.stateDir, "audit.log")
        val lines = file.readLines()
        assertTrue(lines.size >= 2)
        file.writeText((listOf(lines.first().replace("\"actor\":\"", "\"actor\":\"forged-")) + lines.drop(1)).joinToString("\n") + "\n")
        assertFalse(AuditLog.verify())
    }
}
