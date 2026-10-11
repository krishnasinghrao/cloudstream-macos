package com.lagradost.macos

import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.*

class RepositoryMigrationTest {
    @BeforeTest fun before() = ExtensionTestSupport.resetHome()

    @Test fun `legacy migration is offline idempotent and cannot resurrect a removed repository`() {
        val url = "https://migration.invalid/repo.json"
        RepositoryService.importLegacyRepositories(listOf(url, url))
        assertEquals(listOf(url), DaemonState.snapshot().repos.map { it.url })
        assertEquals(0L, DaemonState.snapshot().repos.single().lastSyncedAt)
        assertTrue(ExtensionTestSupport.removeRepository(url))
        DaemonState.load()
        // Client lost its migration acknowledgement and retries after removal.
        RepositoryService.importLegacyRepositories(listOf(url))
        assertTrue(DaemonState.snapshot().repos.isEmpty())
    }

    @Test fun `invalid migration leaves marker and existing repositories unchanged`() {
        assertFailsWith<IllegalArgumentException> {
            RepositoryService.importLegacyRepositories(listOf("https://valid.invalid/repo.json", "http://insecure.invalid/repo.json"))
        }
        assertTrue(DaemonState.snapshot().repos.isEmpty())
        assertTrue(DaemonState.snapshot().completedMigrations.isEmpty())
        assertFailsWith<IllegalArgumentException> {
            RepositoryService.importLegacyRepositories(listOf("https://invalid host/repo.json"))
        }
    }

    @Test fun `policy filters imported repositories`() {
        DaemonRuntime.resetForTest(LaunchOptions(ExtensionPolicy(blockedRepositories = listOf("https://blocked.invalid/repo.json"))))
        RepositoryService.importLegacyRepositories(listOf("https://blocked.invalid/repo.json", "https://ok.invalid/repo.json"))
        assertEquals(listOf("https://ok.invalid/repo.json"), DaemonState.snapshot().repos.map { it.url })
    }

    @Test fun `ordinary registration is repeatable after the migration and reports each address`() {
        // The one-time migration has already run, as it has after any normal launch.
        RepositoryService.importLegacyRepositories(listOf("https://first.invalid/repo.json"))
        RepositoryService.importLegacyRepositories(listOf("https://ignored.invalid/repo.json"))
        assertTrue(DaemonState.snapshot().repos.none { it.url == "https://ignored.invalid/repo.json" }, "the migration API stays one-time")

        val first = RepositoryService.registerRepositories(listOf(
            "https://first.invalid/repo.json", "https://backup.invalid/repo.json", "https://backup.invalid/repo.json",
            "http://insecure.invalid/repo.json", "https://user:pw@creds.invalid/repo.json", "not a url"))
        assertEquals(listOf("already_present", "applied", "already_present", "rejected", "rejected", "rejected"), first.map { it.status })
        assertTrue(first.filter { it.status == "rejected" }.all { !it.reason.isNullOrBlank() })
        val saved = DaemonState.snapshot().repos.single { it.url == "https://backup.invalid/repo.json" }
        assertEquals(DaemonState.PersistedRepository(url = saved.url), saved, "registration records the address only: no sync, trust or consent")
        assertTrue(DaemonState.snapshot().installations.isEmpty())

        // Repeating the restore, and restoring after the user removed it, both work.
        assertEquals(listOf("already_present"), RepositoryService.registerRepositories(listOf("https://backup.invalid/repo.json")).map { it.status })
        DaemonState.update { state -> state.copy(repos = state.repos.filter { it.url != "https://backup.invalid/repo.json" }) }
        assertEquals(listOf("applied"), RepositoryService.registerRepositories(listOf("https://backup.invalid/repo.json")).map { it.status })
    }

    @Test fun `registration honours managed policy and the route returns per-address outcomes`() {
        DaemonRuntime.resetForTest(LaunchOptions(ExtensionPolicy(allowedRepositories = listOf("https://ok.invalid/repo.json"), managed = true)))
        try {
            RouteHarness().use { http ->
                val response = http.post("/repos/register", """{"urls":["https://blocked.invalid/repo.json","https://ok.invalid/repo.json"]}""")
                assertEquals(200, response.status, response.body)
                val outcomes = response.json.jsonArray.map { it.jsonObject.getValue("status").jsonPrimitive.content }
                assertEquals(listOf("rejected", "applied"), outcomes)
                assertTrue(DaemonState.snapshot().repos.none { it.url == "https://blocked.invalid/repo.json" })
            }
        } finally { DaemonRuntime.resetForTest() }
    }
}
