package com.lagradost.macos

import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.boolean
import kotlin.test.*

class DaemonLockTest {
    @BeforeTest
    fun before() {
        DaemonLock.resetForTest()
    }

    @AfterTest
    fun after() {
        DaemonLock.resetForTest()
    }

    @Test
    fun `lock transition purges solve cookies and keeps download relay sessions`() {
        // Seed solve cookie
        SolveBridge.applySolvedCookies("https://example.com/stream", "cf_clearance=secret123")
        assertNotNull(SolveBridge.cookieHeaderFor("https://example.com/stream"))

        // Seed media relay session
        val reg = MediaRelay.register(listOf(MediaRelay.Resource("https://example.com/video.mp4", emptyMap())))
        assertNotNull(reg)
        assertTrue(MediaRelay.activeSessions > 0)

        // Lock
        DaemonLock.setLocked(true)
        assertTrue(DaemonLock.isLocked)

        // Solved cookies are purged; relay sessions stay, since downloads continue behind the lock
        assertNull(SolveBridge.cookieHeaderFor("https://example.com/stream"))
        assertEquals(1, MediaRelay.activeSessions)
        MediaRelay.revoke(reg.sessionId)

        // Unlock
        DaemonLock.setLocked(false)
        assertFalse(DaemonLock.isLocked)
    }

    @Test
    fun `daemon rejects operations when locked and permits health and lock routes`() = RouteHarness().use { http ->
        // Initially unlocked
        val initialLock = http.get("/lock")
        assertEquals(200, initialLock.status)
        assertFalse(initialLock.json.jsonObject["locked"]!!.jsonPrimitive.boolean)

        // Lock daemon via POST /lock
        val lockResp = http.post("/lock", """{"locked": true}""")
        assertEquals(200, lockResp.status)
        assertTrue(lockResp.json.jsonObject["locked"]!!.jsonPrimitive.boolean)
        assertTrue(DaemonLock.isLocked)

        // /health remains accessible when locked
        val health = http.get("/health", auth = false)
        assertEquals(200, health.status)

        // /plugins is rejected with 423 Locked
        val plugins = http.get("/plugins")
        assertEquals(423, plugins.status)
        assertEquals("locked", plugins.json.jsonObject["error"]?.jsonPrimitive?.content)

        // Relay reads stay open for downloads (an unknown id is simply not found)
        val relayResp = http.raw("/media/relay/test-id")
        assertEquals(404, relayResp.status)

        // /lock remains accessible when locked
        val statusWhileLocked = http.get("/lock")
        assertEquals(200, statusWhileLocked.status)
        assertTrue(statusWhileLocked.json.jsonObject["locked"]!!.jsonPrimitive.boolean)

        // Unlock daemon via POST /lock
        val unlockResp = http.post("/lock", """{"locked": false}""")
        assertEquals(200, unlockResp.status)
        assertFalse(unlockResp.json.jsonObject["locked"]!!.jsonPrimitive.boolean)
        assertFalse(DaemonLock.isLocked)

        // /plugins is now accessible
        val pluginsAfterUnlock = http.get("/plugins")
        assertEquals(200, pluginsAfterUnlock.status)
    }

    @Test
    fun `state recovery blocks persistent mutations but not the lock or download routes (Q2)`() {
        ExtensionTestSupport.resetHome()
        DaemonState.stateFile.parentFile.mkdirs()
        DaemonState.stateFile.writeText("{ not json")
        DaemonState.load()
        assertNotNull(DaemonState.recoveryError)
        try {
            RouteHarness().use { http ->
                assertEquals(200, http.post("/lock", """{"locked": true}""").status, "/lock changes only memory")
                assertEquals(200, http.post("/lock", """{"locked": false}""").status)
                val install = http.post("/plugins/install", """{"repositoryUrl":"https://r.invalid/repo.json","internalName":"X"}""")
                assertEquals(503, install.status, "persistent mutations stay blocked")
                val revoke = http.post("/media/relay/revoke", """{"sessionId":"absent"}""")
                assertNotEquals(503, revoke.status, "download routes are not behind the recovery gate")
            }
        } finally {
            ExtensionTestSupport.resetHome()
            DaemonState.load()
        }
    }
}
