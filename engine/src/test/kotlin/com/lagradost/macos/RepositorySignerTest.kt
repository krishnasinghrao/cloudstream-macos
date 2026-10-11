package com.lagradost.macos

import com.lagradost.macos.tools.RepositorySigner
import kotlinx.coroutines.runBlocking
import java.io.File
import java.nio.file.Files
import kotlin.test.*

/** Publisher tooling produces catalogs the production verifier accepts (T8.3). */
class RepositorySignerTest {
    @BeforeTest fun before() = ExtensionTestSupport.resetHome()

    @Test fun `signed output syncs as a verified catalog and tampering is rejected`() = runBlocking<Unit> {
        val dir = Files.createTempDirectory("signer").toFile()
        try {
            val key = File(dir, "repo.key")
            val publicKey = RepositorySigner.keygen(key)
            assertEquals(publicKey, File(dir, "repo.key.pub").readText().trim())
            val artifact = "signed by tool".toByteArray()
            val list = """[{"name":"Tool","internalName":"Tool","url":"Tool.cs3","status":1,"version":1,"fileHash":"${ArtifactDigest.sha256(artifact)}"}]"""
            File(dir, "plugins.json").writeText(list)
            val manifest = RepositorySigner.sign("""{"name":"Tool Repo","manifestVersion":1,"pluginLists":["plugins.json"]}""",
                dir, key.readText().trim(), publicKey, catalogVersion = 1, validDays = 7)
            val url = "https://signer.invalid/repo.json"
            val fetcher = RepositoryFetcher { requested, _ ->
                when (requested) {
                    url -> RepositoryDocument(manifest.toByteArray(), requested)
                    RepositoryService.resolveUrl(url, "plugins.json") -> RepositoryDocument(list.toByteArray(), requested)
                    else -> error("unexpected $requested")
                }
            }
            val outcome = RepositoryService.sync(url, fetcher)
            assertTrue(outcome.verified)
            // Signed by a key nobody vouched for: shown as signed, and installs need consent (M4).
            assertEquals("signed", RepositoryService.getRepoPlugins(url).single().tier)
            assertTrue(RepositoryService.getRepoPlugins(url).single().requiresConsent)
            RepositoryService.setConsent(url, true)
            assertTrue(RepositoryService.getRepoPlugins(url).single().installationAllowed)

            val tampered = RepositoryFetcher { requested, max ->
                if (requested == url) fetcher.fetch(requested, max) else RepositoryDocument(list.replace("Tool.cs3", "Evil.cs3").toByteArray(), requested)
            }
            assertFailsWith<SecurityException> { RepositoryService.sync(url, tampered) }
        } finally { dir.deleteRecursively() }
    }

    @Test fun `signer refuses entries without digests, absolute lists and long validity`() {
        val dir = Files.createTempDirectory("signer").toFile()
        try {
            val key = File(dir, "k")
            val pub = RepositorySigner.keygen(key)
            File(dir, "l.json").writeText("""[{"internalName":"X","url":"X.cs3"}]""")
            val manifest = """{"name":"r","pluginLists":["l.json"]}"""
            assertFailsWith<IllegalArgumentException> { RepositorySigner.sign(manifest, dir, key.readText().trim(), pub, 1, 7) }
            assertFailsWith<IllegalArgumentException> { RepositorySigner.sign("""{"pluginLists":["https://x.invalid/l.json"]}""", dir, key.readText().trim(), pub, 1, 7) }
            assertFailsWith<IllegalArgumentException> { RepositorySigner.sign(manifest, dir, key.readText().trim(), pub, 1, 31) }
            assertFailsWith<IllegalArgumentException> { RepositorySigner.keygen(key) }
            val other = RepositorySigner.keygen(File(dir, "other"))
            File(dir, "l.json").writeText("""[{"internalName":"X","url":"X.cs3","fileHash":"${"a".repeat(64)}"}]""")
            assertFails { RepositorySigner.sign(manifest, dir, key.readText().trim(), other, 1, 7) }
        } finally { dir.deleteRecursively() }
    }
}
