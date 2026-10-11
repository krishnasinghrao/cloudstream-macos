package com.lagradost.macos

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlin.test.*

/**
 * Plan RT-17: an offline engine restart with every kind of installation
 * present — signed, community with a publisher digest, hashless (locally
 * observed), disabled and quarantined — and with a state file written before
 * this runtime's newer receipt fields existed. Real translation and loading.
 */
class RestartMatrixTest {
    @BeforeTest fun before() = ExtensionTestSupport.resetHome()
    @AfterTest fun after() = ExtensionTestSupport.resetHome()

    private val bytes = ExtensionTestSupport.extension("fixture")
    private val signed = SignedCatalogFixture("https://matrix-signed.invalid/repo.json")
    private val digest = SignedCatalogFixture("https://matrix-digest.invalid/repo.json")
    private val hashless = SignedCatalogFixture("https://matrix-hashless.invalid/repo.json")
    private val manifest = """{"name":"c","pluginLists":["list.json"]}"""
    private fun entry(name: String, hash: String?) =
        """{"name":"$name","internalName":"$name","url":"$name.cs3","status":1,"version":1${hash?.let { ""","fileHash":"$it"""" } ?: ""}}"""

    @Test fun `offline restart restores each provenance mode and respects disabled and quarantined`() = runBlocking<Unit> {
        val signedFetcher = signed.publish(mapOf("Signed" to bytes, "Disabled" to bytes, "Quarantined" to bytes), revision = 1)
        val digestFetcher = digest.fetcher(manifest, "[${entry("Digest", ArtifactDigest.sha256(bytes))}]", mapOf("Digest" to bytes))
        val hashlessFetcher = hashless.fetcher(manifest, "[${entry("Hashless", null)}]", mapOf("Hashless" to bytes))
        val online = RepositoryFetcher { url, max ->
            when {
                url.startsWith("https://matrix-signed.invalid/") -> signedFetcher.fetch(url, max)
                url.startsWith("https://matrix-digest.invalid/") -> digestFetcher.fetch(url, max)
                else -> hashlessFetcher.fetch(url, max)
            }
        }
        RepositoryService.sync(digest.url, online); RepositoryService.setConsent(digest.url, true)
        RepositoryService.sync(hashless.url, online); RepositoryService.setConsent(hashless.url, true)
        val manager = ExtensionTestSupport.use(InstallationManager(BridgeExtensionRuntime, online))
        val ids = mapOf(
            "Signed" to manager.install(signed.url, "Signed").id, "Digest" to manager.install(digest.url, "Digest").id,
            "Hashless" to manager.install(hashless.url, "Hashless").id, "Disabled" to manager.install(signed.url, "Disabled").id,
            "Quarantined" to manager.install(signed.url, "Quarantined").id,
        )
        manager.setEnabled(ids.getValue("Disabled"), false)
        manager.quarantineSync(ids.getValue("Quarantined"), "crashed repeatedly")
        assertEquals(setOf("signed_catalog", "publisher_digest", "local_observation"),
            RepositoryService.installedPlugins().mapNotNull { it.verificationMode }.toSet())

        // Receipts as an engine before this runtime wrote them: drop the newer optional fields.
        val state = DaemonState.stateFile
        val root = Json.parseToJsonElement(state.readText()).jsonObject
        val installations = JsonObject(root.getValue("installations").jsonObject.mapValues { (_, value) ->
            JsonObject(value.jsonObject - setOf("extractorDescriptors", "compatibility"))
        })
        state.writeText(JsonObject(root + ("installations" to installations)).toString())

        // Restart: nothing loaded, state re-read from disk, and the network is unreachable.
        PluginBridge.getAllLoadedDescriptors().forEach { PluginBridge.detach(it.installationId) }
        DaemonState.load()
        assertNull(DaemonState.recoveryError, "the older state file loads")
        var fetches = 0
        val offline = RepositoryFetcher { _, _ -> fetches++; throw java.net.UnknownHostException("offline") }
        val restarted = ExtensionTestSupport.use(InstallationManager(BridgeExtensionRuntime, offline))
        val result = restarted.restoreAll()

        assertEquals(3, result.restored, "signed, publisher-digest and hashless installations restore from verified local bytes")
        assertEquals(0, result.failed)
        assertEquals(0, fetches, "restoring never needs the network")
        val states = RepositoryService.installedPlugins().associate { it.internalName to it.state }
        assertEquals(mapOf("Signed" to "running", "Digest" to "running", "Hashless" to "running",
            "Disabled" to "disabled", "Quarantined" to "quarantined"), states)
        assertNull(PluginBridge.loadedInstallation(ids.getValue("Disabled")))
        assertNull(PluginBridge.loadedInstallation(ids.getValue("Quarantined")))
        val hashlessRow = RepositoryService.installedPlugin(ids.getValue("Hashless"))!!
        assertEquals("local_observation", hashlessRow.verificationMode)
        assertNull(hashlessRow.publisherHash, "a restart never turns a local observation into a publisher digest")
        // Fields the older receipts lacked are learned again at load.
        assertNotNull(DaemonState.snapshot().installations.getValue(ids.getValue("Signed")).compatibility)

        // The user can bring the quarantined one back; it loads from the same verified bytes, still offline.
        assertTrue(restarted.retry(ids.getValue("Quarantined")))
        assertEquals("running", RepositoryService.installedPlugin(ids.getValue("Quarantined"))!!.state)
        assertEquals(0, fetches)
    }
}
