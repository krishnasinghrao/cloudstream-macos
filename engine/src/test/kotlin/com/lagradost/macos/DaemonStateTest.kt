package com.lagradost.macos

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Persisted state round-trips (plan WS-2.1) against the isolated test home. */
class DaemonStateTest {
    @kotlin.test.BeforeTest fun before() = ExtensionTestSupport.resetHome()


    @Test
    fun `provider enable-disable persists`() {
        DaemonState.load()
        DaemonState.setProviderEnabled("TestProvider", enabled = false)
        assertFalse(DaemonState.isProviderEnabled("TestProvider"))

        // Simulated restart: re-load from disk.
        DaemonState.load()
        assertFalse(DaemonState.isProviderEnabled("TestProvider"))

        DaemonState.setProviderEnabled("TestProvider", enabled = true)
        DaemonState.load()
        assertTrue(DaemonState.isProviderEnabled("TestProvider"))
    }

    @Test
    fun `provider override round-trip`() {
        DaemonState.load()
        assertNull(DaemonState.overrideFor("Provider X"))

        DaemonState.setProviderOverride(
            "Provider X",
            DaemonState.ProviderOverride(url = "https://mirror.example", hasCredentials = true),
        )
        DaemonState.load()
        val override = DaemonState.overrideFor("Provider X")
        assertEquals("https://mirror.example", override?.url)
        assertEquals(true, override?.hasCredentials)
        assertFalse(DaemonState.stateFile.readText().contains("credentials\""), "secrets are never persisted")

        DaemonState.setProviderOverride("Provider X", null)
        DaemonState.load()
        assertNull(DaemonState.overrideFor("Provider X"))
    }

    @Test
    fun `schema 1 state migrates forward and drops plaintext credentials`() {
        val v1 = """{"repos":[{"url":"https://legacy.example/repo.json"}],"disabledProviders":["Old"],
            "providerOverrides":{"Old":{"url":"https://mirror.example","credentials":"secret-token"}},
            "removedPluginHashes":["abc123"]}"""
        DaemonState.stateFile.parentFile.mkdirs()
        DaemonState.stateFile.writeText(v1)
        DaemonState.load()
        assertNull(DaemonState.recoveryError)
        assertEquals(DaemonState.SCHEMA_VERSION, DaemonState.snapshot().version)
        assertEquals("https://mirror.example", DaemonState.overrideFor("Old")?.url)
        val onDisk = DaemonState.stateFile.readText()
        assertFalse(onDisk.contains("secret-token"), "migration rewrites the file without credentials")
        assertFalse(java.io.File(DaemonState.stateFile.parentFile, "state.json.previous").readText().contains("secret-token"))
        assertTrue(onDisk.contains("\"version\": ${DaemonState.SCHEMA_VERSION}"))
    }

    @Test
    fun `state file survives repository persistence`() {
        DaemonState.load()
        val url = "https://test-state.example/repo.json"
        DaemonState.update { s ->
            s.copy(
                repos = s.repos.filter { it.url != url } + DaemonState.PersistedRepository(
                    url = url,
                    signed = false,
                    manifestJson = """{"name":"TestRepoName"}""",
                ),
            )
        }
        DaemonState.load()
        val repo = DaemonState.snapshot().repos.firstOrNull { it.url == url }
        assertTrue(repo?.manifestJson?.contains("TestRepoName") == true)
    }
}
