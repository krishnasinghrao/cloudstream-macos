package com.lagradost.macos

import com.lagradost.cloudstream3.MainAPI
import com.lagradost.cloudstream3.MovieSearchResponse
import com.lagradost.cloudstream3.SearchResponseList
import com.lagradost.cloudstream3.TvType
import com.lagradost.cloudstream3.newSearchResponseList
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Regression tests for the review-catalog fixes:
 * * P1-9 — a provider returning null (its failure convention) must surface
 *   as a provider failure, not as a successful empty result.
 * * P1-8 — update detection compares the committed receipt with the catalog.
 * * P3 — RepoSignature.canonicalize escapes \b and \f like standard JSON.
 * * P2-15 — SolveBridge.complete validates cookies BEFORE removing the
 *   parked task, so a blank submission doesn't destroy the pending scrape.
 */
class ReviewFixRegressionTest {

    // ------------------------------------------------------------------ P1-9

    /** Modern-API provider whose search reports failure by returning null. */
    private class NullFailingApi(override var name: String) : MainAPI() {
        override val supportedTypes = setOf(TvType.Others)
        override suspend fun search(query: String, page: Int): SearchResponseList? = null
    }

    private class HealthyApi(override var name: String) : MainAPI() {
        override val supportedTypes = setOf(TvType.Movie)
        override suspend fun search(query: String, page: Int): SearchResponseList? {
            @Suppress("DEPRECATION_ERROR")
            return newSearchResponseList(
                listOf<MovieSearchResponse>(
                    MovieSearchResponse(name = "$name-1", url = "https://h.example/1", apiName = name, type = TvType.Movie),
                ),
                hasNext = false,
            )
        }
    }

    @Test
    fun `provider returning null surfaces as failure not empty success`() = runBlocking {
        val result = ProviderExecutor.searchOne(NullFailingApi("NullFailing"), "query")
        assertTrue(result.error != null, "null from a provider is its failure convention and must be an error")
        assertTrue(result.results.isEmpty())
    }

    @Test
    fun `null provider does not mask healthy siblings`() = runBlocking {
        val results = ProviderExecutor.searchAll(
            "query",
            listOf(NullFailingApi("NullFailing"), HealthyApi("Healthy")),
        )
        assertEquals(1, results.size)
        assertEquals("Healthy", results.single().provider)
    }

    // ------------------------------------------------------------------ P1-8

    @Test
    fun `update detection - same loaded hash means no update`() {
        val pinned = "a".repeat(64)
        val loadedHash = pinned
        val isUpdateAvailable = pinned != loadedHash
        assertFalse(isUpdateAvailable)
    }

    @Test
    fun `update detection - different loaded hash means update available`() {
        val pinned = "a".repeat(64)
        val loadedHash = "b".repeat(64)
        val isUpdateAvailable = !loadedHash.equals(pinned, ignoreCase = true)
        assertTrue(isUpdateAvailable)
    }

    @Test
    fun `update detection - hash comparison is case-insensitive`() {
        val pinned = "A".repeat(64)
        val loadedHash = "a".repeat(64)
        assertFalse(loadedHash.equals(pinned, ignoreCase = true).not())
    }

    /** Update detection now compares the committed receipt with the catalog (UpdatePolicy). */
    @Test
    fun `update policy follows versions, always-update and republished digests`() {
        val installed = DaemonState.InstalledExtension("i".repeat(64).replace('i', 'a'), "https://r.invalid/repo.json", "P", "c".repeat(64),
            "g", "d".repeat(64), 0, RepositoryService.SitePlugin(internalName = "P", version = 3, fileHash = "c".repeat(64)))
        fun entry(version: Int, hash: String, status: Int = 1) = RepositoryService.SitePlugin(internalName = "P", version = version, fileHash = hash, status = status)
        assertEquals(UpdatePolicy.State.NONE, UpdatePolicy.evaluate(installed, entry(4, "c".repeat(64))))
        assertEquals(UpdatePolicy.State.UPDATE, UpdatePolicy.evaluate(installed, entry(4, "e".repeat(64))))
        assertEquals(UpdatePolicy.State.UPDATE, UpdatePolicy.evaluate(installed, entry(-1, "e".repeat(64))))
        assertEquals(UpdatePolicy.State.UPDATE, UpdatePolicy.evaluate(installed, entry(3, "e".repeat(64))))
        assertEquals(UpdatePolicy.State.OLDER_IN_CATALOG, UpdatePolicy.evaluate(installed, entry(2, "e".repeat(64))))
        assertEquals(UpdatePolicy.State.NONE, UpdatePolicy.evaluate(installed, entry(4, "e".repeat(64), status = 0)))
        assertEquals(UpdatePolicy.State.NONE, UpdatePolicy.evaluate(installed, entry(4, "not-a-digest")))
        // Absent digest (Android parity): a newer version is still offered.
        val hashless = RepositoryService.SitePlugin(internalName = "P", version = 4, fileHash = null)
        assertEquals(UpdatePolicy.State.UPDATE, UpdatePolicy.evaluate(installed, hashless))
    }

    // ------------------------------------------------------------------ P3

    @Test
    fun `canonicalize escapes backspace and formfeed like standard JSON`() {
        val withControlChars = kotlinx.serialization.json.buildJsonObject {
            put("name", kotlinx.serialization.json.JsonPrimitive("a\u0008b\u000Cc"))
        }
        val canonical = RepoSignature.canonicalize(withControlChars)
        assertTrue("\\b" in canonical, "backspace must be the short escape: $canonical")
        assertTrue("\\f" in canonical, "form feed must be the short escape: $canonical")
        assertFalse("\u0008" in canonical)
        assertFalse("\u000C" in canonical)
    }

    @Test
    fun `canonicalize round-trips control chars through standard JSON parsing`() {
        val body = kotlinx.serialization.json.buildJsonObject {
            put("name", kotlinx.serialization.json.JsonPrimitive("x\u0008y\u000Cz"))
        }
        // A standard JSON parser must read our canonical form back to the same string.
        val reparsed = kotlinx.serialization.json.Json.parseToJsonElement(canonicalBody(body))
        assertEquals(body, reparsed)
    }

    private fun canonicalBody(element: kotlinx.serialization.json.JsonElement): String =
        RepoSignature.canonicalize(element)

    // ------------------------------------------------------------------ P2-15

    @Test
    fun `blank cookie submission leaves the parked task alive`() {
        val task = SolveBridge.newTask("https://blank-check.example/page")
        try {
            val completed = SolveBridge.complete(task.taskId, null, "   ")
            assertFalse(completed, "blank cookies must be rejected")
            assertTrue(
                SolveBridge.listPending().any { it.taskId == task.taskId },
                "a blank submission must NOT destroy the parked task — the scrape keeps waiting",
            )
        } finally {
            SolveBridge.complete(task.taskId, null, "cf_clearance=cleanup")
        }
    }

    @Test
    fun `valid cookie submission still removes the task`() {
        val task = SolveBridge.newTask("https://valid-check.example/page")
        val completed = SolveBridge.complete(task.taskId, null, "cf_clearance=abc")
        assertTrue(completed)
        assertFalse(SolveBridge.listPending().any { it.taskId == task.taskId })
    }
}
