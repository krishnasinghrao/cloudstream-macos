package com.lagradost.macos

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.util.Base64
import kotlin.test.*

class RepositoryFetchIntegrationTest {
    private lateinit var saved: DaemonState.PersistedState
    @BeforeTest fun before() { DaemonState.load(); saved = DaemonState.snapshot(); DaemonState.update { it.copy(repos = emptyList()) } }
    @AfterTest fun after() { DaemonState.update { saved } }

    @Test fun `redirected root and list use their final directories for relative links`() = runBlocking {
        val root = "https://redirect.invalid/original/repo.json"
        val fetcher = RepositoryFetcher { url, max ->
            when (url) {
                root -> {
                    assertEquals(RepositoryTransport.MAX_MANIFEST_BYTES, max)
                    RepositoryDocument("""{"pluginLists":["list.json"]}""".toByteArray(), "https://redirect.invalid/moved/repo.json")
                }
                "https://redirect.invalid/moved/list.json" -> {
                    assertEquals(RepositoryTransport.MAX_LIST_BYTES, max)
                    RepositoryDocument("""[{"internalName":"Case","url":"Case.cs3","iconUrl":"icon.png","repositoryUrl":"https://forged.invalid/"}]""".toByteArray(), "https://cdn.invalid/build/list.json")
                }
                else -> error("unexpected fetch: $url")
            }
        }
        val plugin = RepositoryService.sync(root, fetcher).plugins.single()
        assertEquals("https://cdn.invalid/build/Case.cs3", plugin.url)
        assertEquals("https://cdn.invalid/build/icon.png", plugin.iconUrl)
        assertEquals(root, plugin.repositoryUrl)
    }

    @Test fun `URL parsing preserves identity and rewrites only explicit wrappers`() = runBlocking {
        val fetcher = RepositoryFetcher { url, _ ->
            assertEquals("https://bit.ly/CaseSensitive", url)
            RepositoryDocument(byteArrayOf(), "https://target.invalid/Case/Repo.json?Token=ABC")
        }
        assertEquals("https://target.invalid/Case/Repo.json?Token=ABC", RepositoryService.parseRepoUrl("https://bit.ly/CaseSensitive", fetcher))
        for (url in listOf("https://localhost/", "https://safe.invalid/likdev2583/repo.json", "https://safe.invalid/?next=cs.repo&url=value",
            "https://safe.invalid/Rowdy-Avocado/Rowdycado-Extensions/repo.json")) {
            assertEquals(url, RepositoryService.parseRepoUrl(url, fetcher))
        }
        assertEquals("https://target.invalid/Repo.json?a=b", RepositoryService.parseRepoUrl("https://cs.repo/?url=https%3A%2F%2Ftarget.invalid%2FRepo.json%3Fa%3Db", fetcher))
        // A plain-HTTP address names its HTTPS form; it is never fetched over HTTP.
        assertEquals("https://insecure.invalid/repo.json", RepositoryService.parseRepoUrl("http://insecure.invalid/repo.json", fetcher))
        assertFailsWith<IllegalArgumentException> { RepositoryService.parseRepoUrl("https://user:pass@safe.invalid/repo.json", fetcher) }
        Unit
    }

    @Test fun `unknown shortcode case survives resolution and cancellation is not swallowed`() = runBlocking {
        var seen = ""
        val fetcher = RepositoryFetcher { url, _ -> seen = url; throw CancellationException("cancelled") }
        assertFailsWith<CancellationException> { RepositoryService.parseRepoUrl("MixedCaseCode", fetcher) }
        assertEquals("https://cutt.ly/MixedCaseCode", seen)
    }

    @Test fun `cyclic HTML discovery terminates without recursive refetch`() = runBlocking {
        var count = 0
        val root = "https://cycle.invalid/repo.json"
        val fetcher = RepositoryFetcher { url, _ -> count++; RepositoryDocument("""<html><a href="$root">cycle</a></html>""".toByteArray(), url) }
        assertFailsWith<IllegalArgumentException> { RepositoryService.sync(root, fetcher) }
        assertEquals(1, count)
        assertTrue(DaemonState.snapshot().repos.isEmpty())
    }

    @Test fun `Codeberg API bytes retain raw resource base and enforce decoded size`() = runBlocking {
        val root = "https://codeberg.org/Owner/Repo/raw/branch/Builds/folder/repo.json"
        val expectedApi = "https://codeberg.org/api/v1/repos/Owner/Repo/contents/folder/repo.json?ref=Builds"
        val fetcher = RepositoryContentFetcher(RepositoryFetcher { url, _ ->
            assertEquals(expectedApi, url)
            RepositoryDocument(buildJsonObject {
                put("encoding", "base64"); put("content", Base64.getEncoder().encodeToString("payload".toByteArray()))
            }.toString().toByteArray(), url)
        })
        val document = fetcher.fetch(root, 100)
        assertEquals(root, document.effectiveUrl)
        assertEquals("payload", document.bytes.toString(Charsets.UTF_8))
        var oversizedCalls = 0
        val oversized = RepositoryContentFetcher(RepositoryFetcher { url, _ ->
            oversizedCalls++
            if (url == root) throw java.io.IOException("bounded raw fallback unavailable")
            RepositoryDocument(buildJsonObject {
                put("encoding", "base64"); put("content", "QUJDREVGRw==")
            }.toString().toByteArray(), url)
        })
        assertFailsWith<java.io.IOException> { oversized.fetch(root, 3) }
        assertEquals(2, oversizedCalls)
        var calls = 0
        val cancellation = RepositoryContentFetcher(RepositoryFetcher { _, _ -> calls++; throw CancellationException("cancelled") })
        assertFailsWith<CancellationException> { cancellation.fetch(root, 100) }
        assertEquals(1, calls)
    }
}
