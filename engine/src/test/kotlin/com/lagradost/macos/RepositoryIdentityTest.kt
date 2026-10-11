package com.lagradost.macos

import kotlinx.coroutines.runBlocking
import kotlin.test.*

class RepositoryIdentityTest {
    private val upper = SignedCatalogFixture("https://identity.invalid/Upper/repo.json")
    private val lower = SignedCatalogFixture("https://identity.invalid/upper/repo.json")
    private val bytesA = "artifact from repository A".toByteArray()
    private val bytesB = "artifact from repository B".toByteArray()

    @BeforeTest fun before() = ExtensionTestSupport.resetHome()

    private suspend fun publishBoth() {
        upper.publish(mapOf("Same" to bytesA), revision = 1)
        lower.publish(mapOf("Same" to bytesB), revision = 1)
    }

    @Test fun `catalog lookup preserves path case and never matches substrings`() = runBlocking<Unit> {
        publishBoth()
        assertEquals(ArtifactDigest.sha256(bytesA), RepositoryService.getRepoPlugins(upper.url).single().fileHash)
        assertEquals(ArtifactDigest.sha256(bytesB), RepositoryService.getRepoPlugins(lower.url).single().fileHash)
        assertTrue(RepositoryService.getRepoPlugins("https://identity.invalid/").isEmpty())
        assertTrue(RepositoryService.getRepoPlugins(upper.url + "/extra").isEmpty())
    }

    @Test fun `same internal name in two repositories installs independently with each repository's artifact`() = runBlocking<Unit> {
        publishBoth()
        val runtime = FakeRuntime()
        val serveBoth = RepositoryFetcher { url, _ ->
            when (url) {
                RepositoryService.resolveUrl(upper.url, "Same.cs3") -> RepositoryDocument(bytesA, url)
                RepositoryService.resolveUrl(lower.url, "Same.cs3") -> RepositoryDocument(bytesB, url)
                else -> error("unexpected $url")
            }
        }
        val manager = InstallationManager(runtime, serveBoth)
        val fromB = manager.install(lower.url, "Same")
        val fromA = manager.install(upper.url, "Same")
        assertNotEquals(fromA.id, fromB.id)
        assertEquals(ArtifactDigest.sha256(bytesB), fromB.artifactHash)
        assertEquals(ArtifactDigest.sha256(bytesA), fromA.artifactHash)
        assertTrue(manager.uninstall(fromB.id))
        assertNotNull(DaemonState.snapshot().installations[fromA.id], "uninstall never targets another repository's extension")
    }

    @Test fun `install request cannot override catalog URL or digest and names are case sensitive`() = runBlocking<Unit> {
        publishBoth()
        val manager = InstallationManager(FakeRuntime(), RepositoryFetcher { _, _ -> error("no download expected") })
        for ((url, hash) in listOf("https://evil.invalid/Same.cs3" to null, "" to ArtifactDigest.sha256(bytesA))) {
            assertEquals(ExtensionException.Code.STALE_CATALOG, assertFailsWith<ExtensionException> { manager.install(lower.url, "Same", url, hash) }.code)
        }
        assertEquals(ExtensionException.Code.UNKNOWN_EXTENSION, assertFailsWith<ExtensionException> { manager.install(lower.url, "same") }.code)
        assertEquals(ExtensionException.Code.UNKNOWN_REPOSITORY, assertFailsWith<ExtensionException> { manager.install("https://unknown.invalid/", "Same") }.code)
        assertTrue(DaemonState.snapshot().installations.isEmpty())
    }
}
