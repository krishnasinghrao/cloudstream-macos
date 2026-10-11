package com.lagradost.macos

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.security.KeyPairGenerator
import java.security.Signature
import java.util.Base64
import kotlin.test.*

/** Synthetic transport only: no live repositories or community executable code. */
class RepositoryTrustTest {
    private val url = "https://trust-regression.invalid/repo.json"
    private lateinit var saved: DaemonState.PersistedState
    private var body = ""
    private var revision = 0
    private var duringFetch: () -> Unit = {}

    private val fetcher = RepositoryFetcher { requested, _ ->
        check(requested == url)
        duringFetch()
        RepositoryDocument(body.toByteArray(), requested)
    }

    @BeforeTest fun before() {
        DaemonState.load()
        saved = DaemonState.snapshot()
        DaemonState.update { it.copy(repos = emptyList(), repositoryTrust = emptyMap()) }

    }

    @AfterTest fun after() {
        DaemonState.update { saved }
    }

    private fun signed(): String {
        val keys = KeyPairGenerator.getInstance("Ed25519").generateKeyPair()
        val payload = buildJsonObject {
            put("name", "fixture")
            put("pluginLists", kotlinx.serialization.json.JsonArray(emptyList()))
            put("catalogVersion", ++revision)
            put("expiresAt", java.time.Instant.now().plusSeconds(86400).toString())
            put("pluginListHashes", buildJsonObject {})
        }
        val signer = Signature.getInstance("Ed25519")
        signer.initSign(keys.private)
        signer.update(RepoSignature.canonicalize(payload).toByteArray())
        val encoder = Base64.getEncoder()
        return buildJsonObject {
            payload.forEach { (key, value) -> put(key, value) }
            put("signature", buildJsonObject {
                put("algorithm", "ed25519")
                put("publicKey", encoder.encodeToString(keys.public.encoded.takeLast(32).toByteArray()))
                put("value", encoder.encodeToString(signer.sign()))
            })
        }.toString()
    }

    @Test fun `unsigned and HTML downgrade preserve existing pin and catalog`() = runBlocking {
        body = signed()
        RepositoryService.sync(url, fetcher)
        val trusted = DaemonState.snapshot()
        for (downgrade in listOf("""{"name":"unsigned","pluginLists":[]}""", "<html><body>catalog</body></html>")) {
            body = downgrade
            assertFailsWith<SecurityException> { RepositoryService.sync(url, fetcher) }
            assertEquals(trusted.withoutAttempts(), DaemonState.snapshot().withoutAttempts())
        }
    }

    @Test fun `failed rotation preserves trust and successful rotation commits atomically`() = runBlocking {
        body = signed()
        RepositoryService.sync(url, fetcher)
        val trusted = DaemonState.snapshot()
        for (invalid in listOf("invalid JSON", """{"pluginLists":[]}""", "<html></html>")) {
            body = invalid
            assertFailsWith<SecurityException> { RepositoryService.sync(url, fetcher, rotateKey = true).repository }
            assertEquals(trusted.withoutAttempts(), DaemonState.snapshot().withoutAttempts())
        }
        body = signed()
        assertFailsWith<SecurityException> { RepositoryService.sync(url, fetcher) }
        assertTrue(RepositoryService.sync(url, fetcher, rotateKey = true).repository.verified)
        assertNotEquals(trusted.repos.single().pinnedPublicKey, DaemonState.snapshot().repos.single().pinnedPublicKey)
    }

    @Test fun `sync cannot resurrect a repository removed while fetching`() = runBlocking {
        body = signed()
        RepositoryService.sync(url, fetcher)
        duringFetch = { ExtensionTestSupport.removeRepository(url) }
        assertFailsWith<IllegalStateException> { RepositoryService.sync(url, fetcher) }
        assertTrue(DaemonState.snapshot().repos.isEmpty())
        assertNull(DaemonState.recoveryError)
    }
}
