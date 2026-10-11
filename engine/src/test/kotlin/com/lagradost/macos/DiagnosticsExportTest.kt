package com.lagradost.macos

import com.lagradost.macos.models.HealthDto
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.coroutines.runBlocking
import java.io.File
import kotlin.test.*

/** T8.5: the support bundle never carries credentials, cookies, tokens or URL secrets. */
class DiagnosticsExportTest {
    @BeforeTest fun before() = ExtensionTestSupport.resetHome()
    @AfterTest fun after() = ExtensionTestSupport.resetHome()

    @Test fun `free text loses url secrets, auth headers and key-value credentials`() {
        val redacted = DiagnosticsExport.redactText(
            "GET https://user:pa55@cdn.invalid/v/1.m3u8?token=abc&exp=1#frag failed; Authorization: Bearer abcdefghijklmnop " +
                "cookie=cf_clearance_value password: hunter2 see https://example.invalid/@channel/page")
        assertFalse("pa55" in redacted)
        assertFalse("token=abc" in redacted)
        assertFalse("frag" in redacted)
        assertFalse("abcdefghijklmnop" in redacted)
        assertFalse("cf_clearance_value" in redacted)
        assertFalse("hunter2" in redacted)
        assertTrue("https://cdn.invalid/v/1.m3u8?[REDACTED]" in redacted)
        assertTrue("https://example.invalid/@channel/page" in redacted, "an @ in the path is not userinfo")
    }

    @Test fun `prefixed, camel-cased and JSON-quoted secret names are redacted (L1)`() {
        val samples = mapOf(
            "hashedToken: 9f8e7d6c5b4a" to "9f8e7d6c5b4a",
            "{\"access_token\":\"ya29.secretvalue\"}" to "ya29.secretvalue",
            "access_token=abc123def" to "abc123def",
            "auth_token: zzz999yyy" to "zzz999yyy",
            "X-Auth-Token: header-secret" to "header-secret",
            "'refreshToken': 'quoted-secret'" to "quoted-secret",
            "token: plain-token" to "plain-token",
        )
        for ((line, secret) in samples) {
            val redacted = DiagnosticsExport.redactText(line)
            assertFalse(secret in redacted, "'$line' leaked as '$redacted'")
            assertTrue("[REDACTED]" in redacted)
        }
    }

    @Test fun `token-like path segments are redacted while ordinary paths stay readable (L1)`() {
        val redacted = DiagnosticsExport.redactText("fetch https://files.invalid/d/Xk29fLq8Zp3Rt7Wm1Nv5Bc0Yh/video.mp4 then https://cdn.invalid/series/season-1/episode-12.m3u8")
        assertFalse("Xk29fLq8Zp3Rt7Wm1Nv5Bc0Yh" in redacted)
        assertTrue("https://files.invalid/d/[REDACTED]/video.mp4" in redacted)
        assertTrue("https://cdn.invalid/series/season-1/episode-12.m3u8" in redacted)
    }

    @Test fun `the engine log redacts every value at write time and is owner-only (L1)`() {
        val dir = java.nio.file.Files.createTempDirectory("daemon-log-").toFile()
        try {
            DaemonLog.init(dir)
            DaemonLog.debug("worker.stderr", mapOf("line" to "hashedToken: leaked-1 at https://h.invalid/a?sig=leaked-2", "accessToken" to "leaked-3"))
            val text = File(dir, "daemon.log").readText()
            assertFalse("leaked-1" in text || "leaked-2" in text || "leaked-3" in text, text)
            assertEquals("rw-------", java.nio.file.attribute.PosixFilePermissions.toString(
                java.nio.file.Files.getPosixFilePermissions(File(dir, "daemon.log").toPath())))
            assertEquals("rwx------", java.nio.file.attribute.PosixFilePermissions.toString(
                java.nio.file.Files.getPosixFilePermissions(dir.toPath())))
        } finally {
            DaemonLog.init()
            dir.deleteRecursively()
        }
    }

    @Test fun `values under sensitive keys are replaced wherever they appear`() {
        val input = buildJsonObject {
            put("name", "ok")
            put("credentials", "s3cret")
            put("nested", buildJsonObject { put("sessionId", "abc"); put("url", "https://a.invalid/x?sig=1") })
        }
        val out = DiagnosticsExport.redact(input).jsonObject
        assertEquals("ok", out["name"]!!.jsonPrimitive.content)
        assertEquals("[REDACTED]", out["credentials"]!!.jsonPrimitive.content)
        assertEquals("[REDACTED]", out["nested"]!!.jsonObject["sessionId"]!!.jsonPrimitive.content)
        assertEquals("https://a.invalid/x?[REDACTED]", out["nested"]!!.jsonObject["url"]!!.jsonPrimitive.content)
    }

    @Test fun `bundle lists installed extensions and redacts log lines`() = runBlocking<Unit> {
        val repo = SignedCatalogFixture("https://diagnostics.invalid/repo.json")
        val bytes = "diagnostics extension".toByteArray()
        repo.publish(mapOf("Ext" to bytes), revision = 1)
        val record = ExtensionTestSupport.use(InstallationManager(FakeRuntime(),
            RepositoryFetcher { url, _ -> RepositoryDocument(bytes, url) })).install(repo.url, "Ext")
        DaemonLog.init()
        DaemonLog.warn("provider.failed", mapOf("error" to "https://cdn.invalid/a?token=leak", "cookie" to "c=1"))

        val bundle = DiagnosticsExport.build(HealthDto(uptimeMs = 1, providersLoaded = 0))
        val text = bundle.toString()
        assertEquals(record.id, bundle["extensions"]!!.jsonArray.single().jsonObject["installationId"]!!.jsonPrimitive.content)
        assertEquals(JsonPrimitive(true), bundle["audit"]!!.jsonObject["chainVerified"])
        assertFalse("token=leak" in text)
        assertFalse("c=1" in text)
    }
}
