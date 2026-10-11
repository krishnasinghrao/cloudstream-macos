package com.lagradost.macos

import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class RepositoryServiceTest {

    @Test
    fun `ordinary and bang shortcodes resolve generically without compiled sources`() = runBlocking {
        val seen = mutableListOf<String>()
        val fetcher = RepositoryFetcher { url, _ ->
            seen += url
            RepositoryDocument(byteArrayOf(), "https://chosen.invalid/repo.json")
        }
        for (code in listOf("hexated", "cncv", "MixedCaseCode", "!MixedCaseCode")) {
            assertEquals("https://chosen.invalid/repo.json", RepositoryService.parseRepoUrl(code, fetcher))
        }
        assertEquals(listOf("https://cutt.ly/hexated", "https://cutt.ly/cncv", "https://cutt.ly/MixedCaseCode", "https://py.md/MixedCaseCode"), seen)
    }

    @Test
    fun `explicit addresses and former migrated or blocked sources retain their identity`() = runBlocking {
        val noFetch = RepositoryFetcher { _, _ -> error("An explicit repository URL must not be substituted") }
        for (url in listOf(
            "https://hexated/",
            "https://codeberg.org/likdev2583/likdev2583-cloudstream-extensions/raw/branch/builds/repo.json",
            "https://raw.githubusercontent.com/Rowdy-Avocado/Rowdycado-Extensions/builds/repo.json",
            "https://raw.githubusercontent.com/DarkDemonst/cloudstream-extensions/builds/repo.json"
        )) assertEquals(url, RepositoryService.parseRepoUrl(url, noFetch))
    }

    @Test
    fun `shortener home pages and unresolved codes are rejected`() = runBlocking {
        for (finalUrl in listOf("https://cutt.ly/", "https://py.md/404code", "https://cutt.ly/code")) {
            assertFailsWith<IllegalArgumentException> {
                RepositoryService.parseRepoUrl("code", RepositoryFetcher { _, _ -> RepositoryDocument(byteArrayOf(), finalUrl) })
            }
        }
    }

    /**
     * Live network sync (P2-16): gated behind CS_LIVE_REPO_TESTS=1 so CI and
     * ordinary dev runs stay deterministic.
     */
    @Test
    fun `live sync Hexated repository via Codeberg bridge`() {
        org.junit.Assume.assumeTrue(System.getenv("CS_LIVE_REPO_TESTS") == "1")
        runBlocking {
            val outcome = RepositoryService.sync("hexated")
            assertNotNull(outcome)
            assertEquals("Hexated providers repository", outcome.repository.name)
            assertTrue(outcome.plugins.isNotEmpty(), "Hexated must have plugins")
            assertTrue(outcome.plugins.any { it.name == "SoraStream" }, "SoraStream must be present")

            val repoPlugins = RepositoryService.getRepoPlugins(outcome.repository.url)
            assertTrue(repoPlugins.isNotEmpty())
            val sora = repoPlugins.firstOrNull { it.name == "SoraStream" }
            assertNotNull(sora)
            assertTrue(sora.url.contains("SoraStream.cs3"))

            // Community tier: explicit consent, then a digest-verified install through
            // the real translation pipeline (T0.3 nightly compatibility check).
            assertEquals("community", sora.tier)
            assertTrue(sora.requiresConsent)
            RepositoryService.setConsent(outcome.repository.url, allow = true)
            val installed = RepositoryService.installations.install(sora.repositoryUrl, sora.internalName, sora.url, sora.fileHash)
            assertTrue(installed.providerNames.contains("SoraStream"))
            assertTrue(PluginBridge.allProviders().any { it.name == "SoraStream" })
        }
    }

    /**
     * Live (CS_LIVE_REPO_TESTS=1): StreamPlay ships compiled Android resources
     * for its settings screens and one method too large to translate. Both used
     * to block it (rejected at install; translation out of memory).
     */
    @Test
    fun `live install StreamPlay with Android resources and an oversized method`() {
        org.junit.Assume.assumeTrue(System.getenv("CS_LIVE_REPO_TESTS") == "1")
        runBlocking {
            val outcome = RepositoryService.sync("https://raw.githubusercontent.com/phisher98/cloudstream-extensions-phisher/builds/repo.json")
            val entry = RepositoryService.getRepoPlugins(outcome.repository.url).first { it.internalName == "StreamPlay" }
            RepositoryService.setConsent(outcome.repository.url, allow = true)
            val installed = RepositoryService.installations.install(entry.repositoryUrl, entry.internalName, entry.url, entry.fileHash)
            val loaded = assertNotNull(PluginBridge.loadedInstallation(installed.id), "not loaded: ${RepositoryService.installations.lastError(installed.id)}")
            assertTrue(loaded.providers.isNotEmpty(), "StreamPlay registers its providers")
            assertTrue(loaded.unsupportedFeatures.any { "invokeMovieBox" in it }, loaded.unsupportedFeatures.toString())
            assertTrue("Android settings screens" in loaded.unsupportedFeatures)
            val search = ProviderExecutor.searchOne(loaded.providers.first(), "Inception")
            println("StreamPlay providers=${loaded.providers.map { it.name }} search=${search.results.size} error=${search.failure?.code}")
            assertTrue(search.results.isNotEmpty(), "search failed: ${search.failure}")
        }
    }

    @Test
    fun `parseRepoUrl handles markdown links and custom schemes`() = runBlocking {
        val markdownLink = "[Hexated Repository](cloudstreamrepo://cutt.ly/cloudx)"
        val parsed = RepositoryService.parseRepoUrl(markdownLink, RepositoryFetcher { url, _ ->
            assertEquals("https://cutt.ly/cloudx", url)
            RepositoryDocument(byteArrayOf(), "https://chosen.invalid/repo.json")
        })
        assertTrue(parsed.startsWith("https://"), "Must resolve to https URL, got: $parsed")
        assertTrue(parsed.endsWith(".json"), "Must resolve to json endpoint, got: $parsed")
    }

    @Test
    fun `parseRepoUrl handles cloudstreamrepo scheme without inner https`() = runBlocking {
        val repoUrl = "cloudstreamrepo://raw.githubusercontent.com/SaurabhKaperwan/CSX/builds/CS.json"
        val parsed = RepositoryService.parseRepoUrl(repoUrl)
        assertEquals("https://raw.githubusercontent.com/SaurabhKaperwan/CSX/builds/CS.json", parsed)
    }

    @Test
    fun `extractRepositoriesFromHtml finds all repositories from web markup`() {
        val sampleHtml = """
            <html>
                <body>
                    <table>
                        <tr>
                            <td>Hexated</td>
                            <td><a href="cloudstreamrepo://cutt.ly/cloudx">Add Repo</a></td>
                        </tr>
                        <tr>
                            <td>Anime</td>
                            <td><a href="https://raw.githubusercontent.com/user/anime/builds/repo.json">Repo JSON</a></td>
                        </tr>
                    </table>
                </body>
            </html>
        """.trimIndent()

        val extracted = RepositoryService.extractRepositoriesFromHtml(sampleHtml)
        assertEquals(2, extracted.size)
        // The app-link form is normalized to the address it names, so both forms dedupe.
        assertTrue(extracted.contains("https://cutt.ly/cloudx"))
        assertTrue(extracted.contains("https://raw.githubusercontent.com/user/anime/builds/repo.json"))
    }

    /** Live network sync — gated behind CS_LIVE_REPO_TESTS=1 (P2-16). */
    @Test
    fun `live sync from cloudstream-apk website catalog aggregates repositories`() = runBlocking {
        org.junit.Assume.assumeTrue(System.getenv("CS_LIVE_REPO_TESTS") == "1")
        val outcome = RepositoryService.sync("https://cloudstream-apk.com/cloudstream-repositories-extensions/#list-of-repos-&-extensions")
        assertNotNull(outcome)
        assertTrue(outcome.repository.name.contains("CloudStream") || outcome.repository.name.contains("Repositories"))
        assertTrue(outcome.plugins.isNotEmpty(), "Synthesized catalog must contain plugins from community repos")
    }
}
