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
        for (code in listOf("samplecode", "abc1", "MixedCaseCode", "!MixedCaseCode")) {
            assertEquals("https://chosen.invalid/repo.json", RepositoryService.parseRepoUrl(code, fetcher))
        }
        assertEquals(listOf("https://cutt.ly/samplecode", "https://cutt.ly/abc1", "https://cutt.ly/MixedCaseCode", "https://py.md/MixedCaseCode"), seen)
    }

    @Test
    fun `explicit addresses and former migrated or blocked sources retain their identity`() = runBlocking {
        val noFetch = RepositoryFetcher { _, _ -> error("An explicit repository URL must not be substituted") }
        for (url in listOf(
            "https://samplecode/",
            "https://codeberg.org/example-owner/example-extensions/raw/branch/builds/repo.json",
            "https://raw.githubusercontent.com/example-owner/example-extensions/builds/repo.json",
            "https://raw.githubusercontent.com/another-owner/extensions/builds/repo.json"
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
     * Live network sync and install (P2-16), gated behind CS_LIVE_REPO_TESTS=1
     * so CI and ordinary dev runs stay deterministic. The project names no
     * third-party repository: the target comes from the environment.
     * CS_LIVE_REPO_URL is a repository address or shortcode, CS_LIVE_EXTENSION
     * the internal name of one of its extensions, and CS_LIVE_QUERY (optional)
     * a search that must return results. Community tier: explicit consent, then
     * a digest-verified install through the real translation pipeline.
     */
    @Test
    fun `live sync and install an extension from a configured repository`() {
        org.junit.Assume.assumeTrue(System.getenv("CS_LIVE_REPO_TESTS") == "1")
        val repository = System.getenv("CS_LIVE_REPO_URL")
        val extension = System.getenv("CS_LIVE_EXTENSION")
        org.junit.Assume.assumeFalse("CS_LIVE_REPO_URL and CS_LIVE_EXTENSION name the target", repository.isNullOrBlank() || extension.isNullOrBlank())
        runBlocking {
            val outcome = RepositoryService.sync(repository!!)
            assertTrue(outcome.plugins.isNotEmpty(), "the repository lists extensions")
            val entry = RepositoryService.getRepoPlugins(outcome.repository.url).firstOrNull { it.internalName == extension }
            assertNotNull(entry, "the repository lists $extension")
            assertEquals("community", entry.tier)
            assertTrue(entry.requiresConsent)
            RepositoryService.setConsent(outcome.repository.url, allow = true)
            val installed = RepositoryService.installations.install(entry.repositoryUrl, entry.internalName, entry.url, entry.fileHash)
            val loaded = assertNotNull(PluginBridge.loadedInstallation(installed.id), "not loaded: ${RepositoryService.installations.lastError(installed.id)}")
            assertTrue(loaded.providers.isNotEmpty(), "the extension registers its providers")
            println("live extension providers=${loaded.providers.map { it.name }} unsupported=${loaded.unsupportedFeatures}")
            System.getenv("CS_LIVE_QUERY")?.takeIf { it.isNotBlank() }?.let { query ->
                val search = ProviderExecutor.searchOne(loaded.providers.first(), query)
                assertTrue(search.results.isNotEmpty(), "search failed: ${search.failure}")
            }
        }
    }

    @Test
    fun `parseRepoUrl handles markdown links and custom schemes`() = runBlocking {
        val markdownLink = "[Sample Repository](cloudstreamrepo://cutt.ly/samplecode)"
        val parsed = RepositoryService.parseRepoUrl(markdownLink, RepositoryFetcher { url, _ ->
            assertEquals("https://cutt.ly/samplecode", url)
            RepositoryDocument(byteArrayOf(), "https://chosen.invalid/repo.json")
        })
        assertTrue(parsed.startsWith("https://"), "Must resolve to https URL, got: $parsed")
        assertTrue(parsed.endsWith(".json"), "Must resolve to json endpoint, got: $parsed")
    }

    @Test
    fun `parseRepoUrl handles cloudstreamrepo scheme without inner https`() = runBlocking {
        val repoUrl = "cloudstreamrepo://raw.githubusercontent.com/example-owner/example-extensions/builds/repo.json"
        val parsed = RepositoryService.parseRepoUrl(repoUrl)
        assertEquals("https://raw.githubusercontent.com/example-owner/example-extensions/builds/repo.json", parsed)
    }

    @Test
    fun `extractRepositoriesFromHtml finds all repositories from web markup`() {
        val sampleHtml = """
            <html>
                <body>
                    <table>
                        <tr>
                            <td>Sample</td>
                            <td><a href="cloudstreamrepo://cutt.ly/samplecode">Add Repo</a></td>
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
        assertTrue(extracted.contains("https://cutt.ly/samplecode"))
        assertTrue(extracted.contains("https://raw.githubusercontent.com/user/anime/builds/repo.json"))
    }

    @Test
    fun `links back to the catalog page's own site are not repositories`() {
        val html = """
            <a href="https://www.catalog.invalid/builds/index.json">Site index</a>
            <a href="cloudstreamrepo://catalog.invalid/raw/list.json">Self</a>
            <a href="https://cdn.catalog.invalid/builds/repo.json">Site CDN</a>
            <a href="https://other.invalid/builds/repo.json">Repo</a>
        """.trimIndent()
        assertEquals(listOf("https://other.invalid/builds/repo.json"),
            RepositoryService.extractRepositoriesFromHtml(html, "https://catalog.invalid/repositories/"))
        // Without a page address nothing is treated as the page's own site.
        assertEquals(4, RepositoryService.extractRepositoriesFromHtml(html).size)
    }

    /** Live sync of a web page listing repositories (CS_LIVE_REPO_TESTS=1, page from CS_LIVE_CATALOG_URL; P2-16). */
    @Test
    fun `live sync from a website catalog aggregates repositories`() = runBlocking {
        org.junit.Assume.assumeTrue(System.getenv("CS_LIVE_REPO_TESTS") == "1")
        val page = System.getenv("CS_LIVE_CATALOG_URL")
        org.junit.Assume.assumeFalse("CS_LIVE_CATALOG_URL names the page", page.isNullOrBlank())
        val outcome = RepositoryService.sync(page!!)
        assertTrue(outcome.plugins.isNotEmpty(), "Synthesized catalog must contain plugins from the listed repositories")
    }
}
