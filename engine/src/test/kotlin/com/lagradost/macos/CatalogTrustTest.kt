package com.lagradost.macos

import kotlinx.coroutines.runBlocking
import java.time.Instant
import kotlin.test.*

class CatalogTrustTest {
    private val fixture = SignedCatalogFixture()
    @BeforeTest fun before() { ExtensionTestSupport.resetHome() }
    private fun authorized(hash: String) = hash in ExtensionTestSupport.verifiedHashes(fixture.url)

    @Test fun `signed chain authenticates artifact and supports slow status`() = runBlocking<Unit> {
        val outcome = RepositoryService.sync(fixture.url, fixture.fetcher())
        assertTrue(outcome.verified)
        val unconsented = RepositoryService.getRepoPlugins(fixture.url).single()
        assertFalse(unconsented.installationAllowed, "a signature alone does not skip first-time consent (M4)")
        assertTrue(unconsented.requiresConsent)
        fixture.consentIfNeeded()
        assertTrue(RepositoryService.getRepoPlugins(fixture.url).single().installationAllowed)
        assertEquals(2, outcome.plugins.single().status)
        assertTrue(authorized(fixture.hash))
        DaemonState.load()
        assertTrue(authorized(fixture.hash))
    }

    @Test fun `valid root cannot authenticate modified detached list or missing artifact digest`() = runBlocking<Unit> {
        val before = DaemonState.snapshot()
        assertFailsWith<SecurityException> {
            RepositoryService.sync(fixture.url, fixture.fetcher(list = fixture.list.replace(fixture.hash, "a".repeat(64))))
        }
        assertEquals(before.withoutAttempts(), DaemonState.snapshot().withoutAttempts())
        val missingDigest = """[{"internalName":"Fixture","url":"Fixture.cs3"}]"""
        assertFailsWith<SecurityException> {
            RepositoryService.sync(fixture.url, fixture.fetcher(fixture.manifest(body = missingDigest), missingDigest))
        }
        assertEquals(before.withoutAttempts(), DaemonState.snapshot().withoutAttempts())
    }

    @Test fun `missing list binding expired and excessively future catalogs fail without state change`() = runBlocking<Unit> {
        val before = DaemonState.snapshot()
        for (manifest in listOf(fixture.manifest(bindList = false), fixture.manifest(expires = Instant.now().minusSeconds(1)),
            fixture.manifest(expires = Instant.now().plusSeconds(31 * 86400L)))) {
            assertFailsWith<SecurityException> { RepositoryService.sync(fixture.url, fixture.fetcher(manifest)) }
            assertEquals(before.withoutAttempts(), DaemonState.snapshot().withoutAttempts())
        }
    }

    @Test fun `rollback and same revision content replacement fail across restart`() = runBlocking<Unit> {
        RepositoryService.sync(fixture.url, fixture.fetcher(fixture.manifest(revision = 2)))
        DaemonState.load()
        val before = DaemonState.snapshot()
        for (manifest in listOf(fixture.manifest(revision = 1), fixture.manifest(revision = 2, title = "changed"))) {
            assertFailsWith<SecurityException> { RepositoryService.sync(fixture.url, fixture.fetcher(manifest)) }
            assertEquals(before.withoutAttempts(), DaemonState.snapshot().withoutAttempts())
        }
        assertTrue(RepositoryService.sync(fixture.url, fixture.fetcher(fixture.manifest(revision = 2))).verified)
    }

    @Test fun `removing a catalog retains key continuity and revision high water mark`() = runBlocking<Unit> {
        RepositoryService.sync(fixture.url, fixture.fetcher(fixture.manifest(revision = 3)))
        assertTrue(ExtensionTestSupport.removeRepository(fixture.url))
        DaemonState.load()
        assertFailsWith<SecurityException> { RepositoryService.sync(fixture.url, fixture.fetcher(fixture.manifest(revision = 2))) }
        val otherKey = SignedCatalogFixture(fixture.url)
        assertFailsWith<SecurityException> { RepositoryService.sync(fixture.url, otherKey.fetcher(otherKey.manifest(revision = 4))) }
        assertTrue(DaemonState.snapshot().repos.isEmpty())
        assertEquals(3, DaemonState.snapshot().repositoryTrust.getValue(fixture.url).catalogVersion)
    }

    @Test fun `display metadata cannot authorize forged artifact and corrupt stored evidence is rejected`() = runBlocking<Unit> {
        RepositoryService.sync(fixture.url, fixture.fetcher())
        val original = DaemonState.snapshot().repos.single()
        val forged = "f".repeat(64)
        DaemonState.update { it.copy(repos = listOf(original.copy(pluginsJson = original.pluginsJson!!.replace(fixture.hash, forged)))) }
        assertFalse(authorized(forged))
        assertTrue(authorized(fixture.hash))
        val evidence = original.authenticatedLists.single()
        DaemonState.update { it.copy(repos = listOf(original.copy(authenticatedLists = listOf(evidence.copy(body = evidence.body + " "))))) }
        assertFalse(authorized(fixture.hash))
    }

    @Test fun `unsigned catalog is community tier and cannot install without consent`() = runBlocking<Unit> {
        RepositoryService.sync(fixture.url, fixture.fetcher("""{"pluginLists":["list.json"]}"""))
        val entry = RepositoryService.getRepoPlugins(fixture.url).single()
        assertEquals("community", entry.tier)
        assertFalse(entry.installationAllowed)
        assertTrue(entry.requiresConsent)
        assertFalse(authorized(fixture.hash), "community catalogs never count as verified")
        val failure = assertFailsWith<ExtensionException> {
            InstallationManager(BridgeExtensionRuntime, fixture.fetcher()).install(fixture.url, "Fixture", "", fixture.hash)
        }
        assertEquals(ExtensionException.Code.CONSENT_REQUIRED, failure.code)
    }

    @Test fun `policy can forbid the community tier entirely`() = runBlocking<Unit> {
        DaemonRuntime.resetForTest(LaunchOptions(ExtensionPolicy(allowCommunityTier = false)))
        assertFailsWith<PolicyException> { RepositoryService.sync(fixture.url, fixture.fetcher("""{"pluginLists":["list.json"]}""")) }
        assertTrue(DaemonState.snapshot().repos.isEmpty())
        assertTrue(RepositoryService.sync(fixture.url, fixture.fetcher()).verified, "verified repositories remain allowed")
    }

    @Test fun `policy pinned key rejects unsigned and differently signed catalogs`() = runBlocking<Unit> {
        val otherKey = SignedCatalogFixture(fixture.url)
        val pinned = CatalogTrust.authenticateRoot(fixture.manifest(), null, null).publicKey
        DaemonRuntime.resetForTest(LaunchOptions(ExtensionPolicy(pinnedRepositoryKeys = mapOf(fixture.url to pinned))))
        assertFails { RepositoryService.sync(fixture.url, fixture.fetcher("""{"pluginLists":["list.json"]}""")) }
        assertFailsWith<SecurityException> { RepositoryService.sync(fixture.url, otherKey.fetcher(otherKey.manifest())) }
        assertTrue(RepositoryService.sync(fixture.url, fixture.fetcher()).verified)
    }

    @Test fun `only a policy-pinned key is verified and skips consent (M4)`() = runBlocking<Unit> {
        val pinned = CatalogTrust.authenticateRoot(fixture.manifest(), null, null).publicKey
        DaemonRuntime.resetForTest(LaunchOptions(ExtensionPolicy(pinnedRepositoryKeys = mapOf(fixture.url to pinned))))
        RepositoryService.sync(fixture.url, fixture.fetcher())
        val repo = RepositoryService.listRepositories().single { it.url == fixture.url }
        assertEquals("verified", repo.tier)
        assertTrue(repo.verified)
        assertFalse(repo.consentRequired)
        val entry = RepositoryService.getRepoPlugins(fixture.url).single()
        assertEquals("verified", entry.tier)
        assertTrue(entry.installationAllowed, "the organization vouched for this key")
        assertFailsWith<ExtensionException> { RepositoryService.setConsent(fixture.url, true) }
    }

    @Test fun `signed-only policy accepts pinned or allow-listed repositories, not any signature (M4)`() = runBlocking<Unit> {
        DaemonRuntime.resetForTest(LaunchOptions(ExtensionPolicy(allowCommunityTier = false)))
        RepositoryService.sync(fixture.url, fixture.fetcher())
        val repo = RepositoryService.listRepositories().single { it.url == fixture.url }
        assertEquals("signed", repo.tier)
        assertFalse(repo.allowedByPolicy, "a self-generated key does not satisfy a signed-only policy")
        assertFalse(RepositoryService.getRepoPlugins(fixture.url).single().installationAllowed)
        assertFailsWith<PolicyException> { RepositoryService.setConsent(fixture.url, true) }

        ExtensionTestSupport.resetHome()
        DaemonRuntime.resetForTest(LaunchOptions(ExtensionPolicy(allowCommunityTier = false, allowedRepositories = listOf(fixture.url))))
        RepositoryService.sync(fixture.url, fixture.fetcher())
        assertTrue(RepositoryService.listRepositories().single { it.url == fixture.url }.allowedByPolicy, "an allow-listed repository qualifies")
        fixture.consentIfNeeded()
        assertTrue(RepositoryService.getRepoPlugins(fixture.url).single().installationAllowed)
    }

    @Test fun `consent to a signed repository does not survive a change of signing key (M4)`() = runBlocking<Unit> {
        RepositoryService.sync(fixture.url, fixture.fetcher())
        fixture.consentIfNeeded()
        assertTrue(RepositoryService.listRepositories().single { it.url == fixture.url }.consented)
        RepositoryService.sync(fixture.url, fixture.fetcher(fixture.manifest(revision = 2)))
        assertTrue(RepositoryService.listRepositories().single { it.url == fixture.url }.consented, "an ordinary sync keeps consent")
        val rotated = SignedCatalogFixture(fixture.url)
        RepositoryService.sync(fixture.url, rotated.fetcher(rotated.manifest(revision = 3)), rotateKey = true)
        assertFalse(RepositoryService.listRepositories().single { it.url == fixture.url }.consented, "a new key needs new consent")
    }

    @Test fun `offline evidence can retain authenticity after expiry while new installation requires freshness`() {
        val expired = fixture.manifest(expires = Instant.now().minusSeconds(1))
        val root = CatalogTrust.authenticateRoot(expired, null, null, requireFresh = false)
        val anchor = DaemonState.RepositoryTrustAnchor(root.publicKey, root.fingerprint, root.version, root.digest)
        val repo = DaemonState.PersistedRepository(url = fixture.url, signed = true, manifestJson = expired,
            authenticatedLists = listOf(DaemonState.AuthenticatedCatalogList("list.json", RepositoryService.resolveUrl(fixture.url, "list.json"), fixture.list)))
        assertEquals(1, CatalogTrust.restore(repo, anchor, requireFresh = false).size)
        assertFailsWith<SecurityException> { CatalogTrust.restore(repo, anchor, requireFresh = true) }
    }
}
