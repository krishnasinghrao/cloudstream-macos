package com.lagradost.macos

import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.runBlocking
import kotlin.test.*

/** T3.13 / F33: an HTML discovery page aggregates child catalogs with per-entry provenance and the direct path's status rules. */
class AggregateCatalogTest {
    @BeforeTest fun before() = ExtensionTestSupport.resetHome()
    @AfterTest fun after() = ExtensionTestSupport.resetHome()

    private val page = "https://aggregate.invalid/list.html"
    private val childA = "https://a.invalid/repo.json"
    private val childB = "https://b.invalid/repo.json"

    private fun list(vararg entries: Pair<String, Int>) = entries.joinToString(",", "[", "]") { (name, status) ->
        """{"name":"$name","internalName":"$name","url":"$name.cs3","status":$status,"version":1,"fileHash":"${"a".repeat(64)}"}"""
    }

    @Test fun `aggregate keeps statuses 1 and 2, drops 0 and keeps provenance per child`() = runBlocking<Unit> {
        val fetcher = RepositoryFetcher { url, _ ->
            val body = when (url) {
                page -> """<html><body><a href="$childA">A</a><a href="$childB">B</a></body></html>"""
                childA, childB -> """{"name":"child","manifestVersion":1,"pluginLists":["list.json"]}"""
                RepositoryService.resolveUrl(childA, "list.json") -> list("Shared" to 1, "Slow" to 2, "Down" to 0)
                RepositoryService.resolveUrl(childB, "list.json") -> list("Shared" to 1)
                else -> error("unexpected $url")
            }
            RepositoryDocument(body.toByteArray(), url)
        }
        val outcome = RepositoryService.sync(page, fetcher)
        val entries = outcome.plugins.map { it.repositoryUrl to it.internalName }.toSet()
        assertEquals(setOf(childA to "Shared", childA to "Slow", childB to "Shared"), entries)
        assertTrue(outcome.plugins.none { it.status == 0 })
        assertEquals(setOf(page, childA, childB), DaemonState.snapshot().repos.map { it.url }.toSet())
        assertEquals(page, DaemonState.snapshot().repos.single { it.url == childA }.discoveredVia)
        // Installation is offered from the child repository that owns the entry.
        val shared = RepositoryService.getRepoPlugins(page).filter { it.internalName == "Shared" }
        assertEquals(setOf(childA, childB), shared.map { it.repositoryUrl }.toSet())
    }

    @Test fun `a page linking a repository twice syncs it once and both link forms are one repository`() = runBlocking<Unit> {
        val fetcher = RepositoryFetcher { url, _ ->
            val body = when (url) {
                page -> """<html><body><a href="cloudstreamrepo://a.invalid/repo.json">A</a><a href="$childA">A again</a></body></html>"""
                childA -> """{"name":"child","manifestVersion":1,"pluginLists":["list.json"]}"""
                RepositoryService.resolveUrl(childA, "list.json") -> list("Only" to 1)
                else -> error("unexpected $url")
            }
            RepositoryDocument(body.toByteArray(), url)
        }
        assertEquals(listOf(childA), RepositoryService.extractRepositoriesFromHtml(
            """<a href="cloudstreamrepo://a.invalid/repo.json">A</a><a href="$childA">A again</a>"""))
        val outcome = RepositoryService.sync(page, fetcher)
        assertEquals(listOf(childA to "Only"), outcome.plugins.map { it.repositoryUrl to it.internalName })
        assertEquals(emptyList(), outcome.repository.skippedRepositories)
    }

    @Test fun `pages listing more repositories than the cap load the first ones and report the rest`() = runBlocking<Unit> {
        val children = (1..RepositoryService.MAX_DISCOVERED_REPOSITORIES + 3).map { "https://c$it.invalid/repo.json" }
        val fetcher = RepositoryFetcher { url, _ ->
            val body = when {
                url == page -> children.joinToString("", "<html><body>", "</body></html>") { """<a href="$it">x</a>""" }
                url in children -> """{"name":"child","manifestVersion":1,"pluginLists":["list.json"]}"""
                url.endsWith("/list.json") -> list("E" to 1)
                else -> error("unexpected $url")
            }
            RepositoryDocument(body.toByteArray(), url)
        }
        val outcome = RepositoryService.sync(page, fetcher)
        assertEquals(RepositoryService.MAX_DISCOVERED_REPOSITORIES, outcome.plugins.map { it.repositoryUrl }.distinct().size)
        assertEquals(children.takeLast(3), outcome.repository.skippedRepositories.map { it.url })
    }

    /** RT-10: a slow page keeps what loaded; failed, timed-out and never-admitted children are reported, not dropped silently. */
    @Test fun `discovery commits loaded children and reports the rest within one deadline`() = runBlocking<Unit> {
        // More hanging children than transport lanes, so some are never admitted.
        val hanging = (1..RepositoryTransport.LANES + 2).map { "https://hang$it.invalid/repo.json" }
        val broken = "https://broken.invalid/repo.json"
        val fetcher = RepositoryFetcher { url, _ ->
            val body = when {
                url == page -> (listOf(childA, broken) + hanging).joinToString("", "<html><body>", "</body></html>") { """<a href="$it">x</a>""" }
                url == childA -> """{"name":"child","manifestVersion":1,"pluginLists":["list.json"]}"""
                url == RepositoryService.resolveUrl(childA, "list.json") -> list("Loaded" to 1)
                url == broken -> "not json"
                url in hanging -> awaitCancellation()
                else -> error("unexpected $url")
            }
            RepositoryDocument(body.toByteArray(), url)
        }
        val started = System.nanoTime()
        val outcome = RepositoryService.sync(page, fetcher, timeoutMs = 8_000)
        assertTrue((System.nanoTime() - started) / 1_000_000 < 8_000, "the outer sync deadline is never reached")
        assertEquals(listOf(childA to "Loaded"), outcome.plugins.map { it.repositoryUrl to it.internalName })
        val skipped = outcome.repository.skippedRepositories.associate { it.url to it.reason }
        assertEquals((listOf(broken) + hanging).toSet(), skipped.keys)
        assertTrue(skipped.getValue(broken).isNotBlank())
        assertEquals(setOf("Timed out", "Not reached before the discovery deadline"),
            hanging.map { skipped.getValue(it) }.toSet(), "admitted children time out; queued ones are never started")
        assertTrue("${hanging.size + 1} could not be loaded" in outcome.repository.description.orEmpty())
        assertEquals(setOf(page, childA), DaemonState.snapshot().repos.map { it.url }.toSet())
    }
}
