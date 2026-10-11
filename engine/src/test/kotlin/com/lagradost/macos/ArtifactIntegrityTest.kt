package com.lagradost.macos

import kotlinx.coroutines.runBlocking
import java.io.File
import java.nio.file.Files
import kotlin.test.*

class ArtifactIntegrityTest {
    private val bytes = "synthetic artifact integrity fixture".toByteArray()
    private val hash = ArtifactDigest.sha256(bytes)
    private val artifact get() = File(CloudDirs.cs3StoreDir, "$hash.cs3")
    private var requests = 0

    private val fetcher = RepositoryFetcher { requested, _ ->
        check(requested == "https://artifact-regression.invalid/extension.cs3")
        requests++
        RepositoryDocument(bytes, requested)
    }
    private suspend fun fetch(plugin: RepositoryService.SitePlugin): File = RepositoryService.fetchVerifiedCs3(plugin, fetcher)

    @BeforeTest fun before() {
        ExtensionTestSupport.resetHome()
        CloudDirs.cs3StoreDir.mkdirs()
    }

    private fun plugin(digest: String? = hash) = RepositoryService.SitePlugin(
        url = "https://artifact-regression.invalid/extension.cs3", internalName = "integrity-fixture", fileHash = digest,
    )

    @Test fun `equal length corrupted cache is replaced by exactly the verified bytes`() = runBlocking<Unit> {
        artifact.writeBytes(ByteArray(bytes.size) { 0 })
        val fetched = fetch(plugin())
        assertContentEquals(bytes, fetched.readBytes())
        assertEquals(hash, ArtifactDigest.sha256(fetched))
        assertTrue(DaemonState.snapshot().installations.isEmpty(), "downloaded bytes are not an installed extension")
    }

    @Test fun `missing malformed and mismatched digests cannot publish artifacts`() = runBlocking<Unit> {
        for (digest in listOf(null, "", "../outside", "a".repeat(63), "０".repeat(64))) {
            assertFailsWith<SecurityException> { fetch(plugin(digest)) }
        }
        assertEquals(0, requests)
        assertFailsWith<SecurityException> { fetch(plugin("f".repeat(64))) }
        assertFalse(artifact.exists())
    }

    @Test fun `declared size must match downloaded bytes`() = runBlocking<Unit> {
        assertFailsWith<SecurityException> { fetch(plugin().copy(fileSize = bytes.size + 1L)) }
        assertFalse(artifact.exists())
    }

    @Test fun `symlink publication cannot overwrite its target`() = runBlocking<Unit> {
        val target = File.createTempFile("artifact-target-", ".txt", CloudDirs.home)
        try {
            target.writeText("protected")
            Files.createSymbolicLink(artifact.toPath(), target.toPath())
            assertFailsWith<IllegalArgumentException> { fetch(plugin()) }
            assertEquals("protected", target.readText())
        } finally { target.delete() }
    }

    @Test fun `artifact store paths accept only validated digests`() {
        for (bad in listOf("../outside", "a".repeat(63), "A".repeat(64), "")) {
            assertFailsWith<IllegalArgumentException> { ArtifactStore.source(bad) }
        }
    }

    @Test fun `restore ignores orphan and nonregular cache files without aborting`() = runBlocking<Unit> {
        artifact.mkdir()
        File(CloudDirs.cs3StoreDir, "${"b".repeat(64)}.cs3").writeBytes(bytes)
        val result = InstallationManager(BridgeExtensionRuntime, fetcher).restoreAll()
        assertEquals("ready", result.phase)
        assertEquals(0, result.restored)
        assertTrue(PluginBridge.getAllLoadedDescriptors().isEmpty(), "cached files are never execution authority")
    }

    @Test fun `garbage collection removes only unreferenced blobs past the grace period`() {
        val orphan = File(CloudDirs.cs3StoreDir, "${"c".repeat(64)}.cs3").apply { writeBytes(bytes) }
        val fresh = File(CloudDirs.cs3StoreDir, "${"d".repeat(64)}.cs3").apply { writeBytes(bytes) }
        val staleJar = File(CloudDirs.pluginCacheDir.apply { mkdirs() }, "${"e".repeat(64)}.jar").apply { writeBytes(bytes) }
        val outside = File(CloudDirs.home, "outside.cs3").apply { writeBytes(bytes) }
        val old = System.currentTimeMillis() - 60 * 60 * 1000L
        orphan.setLastModified(old); staleJar.setLastModified(old); outside.setLastModified(old)
        val collected = ArtifactStore.collect(DaemonState.snapshot(), InstallationProofStore())
        assertEquals(1, collected.sources)
        assertEquals(1, collected.translations)
        assertFalse(orphan.exists()); assertFalse(staleJar.exists())
        assertTrue(fresh.exists(), "blobs of in-flight operations survive the grace period")
        assertTrue(outside.exists(), "collection never leaves the managed directories")
    }
}
