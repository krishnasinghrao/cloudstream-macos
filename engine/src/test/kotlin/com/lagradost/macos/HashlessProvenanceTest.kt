package com.lagradost.macos

import kotlinx.coroutines.runBlocking
import kotlin.test.*

/**
 * Plan RT-08: a hashless install is backed by the bytes this Mac observed, and
 * that evidence can be neither dropped nor relabeled as a publisher digest.
 */
class HashlessProvenanceTest {
    private val community = SignedCatalogFixture("https://hashless-provenance.invalid/repo.json")
    private val manifest = """{"name":"c","pluginLists":["list.json"]}"""
    private val list = """[{"name":"Fixture","internalName":"Fixture","url":"Fixture.cs3","status":1,"version":1}]"""
    private val bytes = ExtensionTestSupport.extension("fixture")
    private var downloads = 0
    private val fetcher = RepositoryFetcher { url, max ->
        if (url.endsWith(".cs3")) downloads++
        community.fetcher(manifest, list, mapOf("Fixture" to bytes)).fetch(url, max)
    }

    @BeforeTest fun before() = ExtensionTestSupport.resetHome()
    @AfterTest fun after() = ExtensionTestSupport.resetHome()

    private suspend fun install(): Pair<InstallationManager, DaemonState.InstalledExtension> {
        RepositoryService.sync(community.url, fetcher)
        RepositoryService.setConsent(community.url, true)
        val manager = ExtensionTestSupport.use(InstallationManager(BridgeExtensionRuntime, fetcher))
        return manager to manager.install(community.url, "Fixture")
    }

    private fun replace(record: DaemonState.InstalledExtension) =
        DaemonState.update { it.copy(installations = it.installations + (record.id to record)) }

    @Test fun `a hashless extension really loads and its cached bytes are checked against the observation`() = runBlocking<Unit> {
        val (manager, record) = install()
        assertNotNull(PluginBridge.loadedInstallation(record.id), "the extension runs")
        assertEquals(DaemonState.ArtifactVerification.LOCAL_OBSERVATION, record.verificationMode)

        BridgeExtensionRuntime.remove(record.id)?.close()
        val source = ArtifactStore.source(record.artifactHash)
        source.writeBytes(ByteArray(source.length().toInt()))
        val fetched = downloads
        assertFalse(manager.restore(record.id), "corrupted bytes never load")
        assertEquals(fetched, downloads, "restore never re-downloads in place of the observed bytes")
        assertNull(PluginBridge.loadedInstallation(record.id))
    }

    @Test fun `observation evidence cannot be dropped or relabeled as a publisher digest`() = runBlocking<Unit> {
        val (manager, record) = install()
        val proofs = InstallationProofStore()
        val state = DaemonState.snapshot()

        // A valid community proof for the same catalog, but without the observation.
        val bare = proofs.put(state.repos.single { it.url == community.url }, state.repositoryTrust[community.url])
        replace(record.copy(proofHash = bare))
        assertFailsWith<IllegalArgumentException> { proofs.verify(DaemonState.snapshot().installations.getValue(record.id), null) }

        // The local digest presented as if the publisher had declared it.
        replace(record.copy(verificationMode = DaemonState.ArtifactVerification.PUBLISHER_DIGEST, publisherHash = record.artifactHash))
        assertFailsWith<IllegalArgumentException> { proofs.verify(DaemonState.snapshot().installations.getValue(record.id), null) }

        replace(record)
        BridgeExtensionRuntime.remove(record.id)?.close()
        assertTrue(manager.restore(record.id), "the untouched receipt still restores")
    }
}
