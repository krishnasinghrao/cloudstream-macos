package com.lagradost.macos

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import java.nio.file.Files
import kotlin.test.*

/** Plan D5: local extension files, developer mode only, never enabled automatically, blockable by policy. */
class DeveloperExtensionTest {
    private lateinit var runtime: FakeRuntime
    private lateinit var manager: InstallationManager
    private lateinit var dir: File

    @BeforeTest fun before() {
        ExtensionTestSupport.resetHome()
        runtime = FakeRuntime()
        manager = ExtensionTestSupport.use(InstallationManager(runtime, RepositoryFetcher { _, _ -> error("no network in developer tests") }))
        dir = Files.createTempDirectory("developer-ext").toFile()
    }

    @AfterTest fun after() {
        dir.deleteRecursively()
        DaemonRuntime.resetForTest()
        ExtensionTestSupport.resetHome()
    }

    private fun file(name: String, content: String) = File(dir, name).apply { writeText(content) }
    private fun install(http: RouteHarness, file: File) =
        http.post("/extensions/developer/install", """{"path":"${file.canonicalPath}"}""")
    private val id = InstallationProofStore.installationId(DaemonState.DEVELOPER_SOURCE, "MyExt")

    @Test fun `developer mode is off by default and imports are refused`() = RouteHarness().use { http ->
        val response = install(http, file("MyExt.cs3", "v1"))
        assertEquals(403, response.status, response.body)
        assertEquals("policy_denied", response.json.jsonObject["code"]!!.jsonPrimitive.content)
        assertTrue(DaemonState.snapshot().installations.isEmpty())
    }

    @Test fun `an import is committed disabled and only runs while developer mode is on`() = RouteHarness().use { http ->
        assertEquals(200, http.post("/extensions/settings", """{"developerMode":true}""").status)
        val installed = install(http, file("MyExt.cs3", "v1"))
        assertEquals(200, installed.status, installed.body)
        assertEquals("developer", installed.json.jsonObject["tier"]!!.jsonPrimitive.content)
        assertEquals("disabled", installed.json.jsonObject["state"]!!.jsonPrimitive.content, "never enabled automatically")
        assertEquals("true", installed.json.jsonObject["repositoryPresent"]!!.jsonPrimitive.content, "no misleading 'repository removed' notice")
        assertNull(runtime.generation(id))

        assertEquals(200, http.post("/plugins/setEnabled", """{"installationId":"$id","enabled":true}""").status)
        assertNotNull(runtime.generation(id))

        // Turning developer mode off stops it at once and keeps it from loading at the next start.
        assertEquals(200, http.post("/extensions/settings", """{"developerMode":false}""").status)
        assertNull(runtime.generation(id))
        runBlocking { manager.restoreAll() }
        assertNull(runtime.generation(id))

        // Back on: the enabled import loads again; re-importing keeps its state and a rollback version.
        assertEquals(200, http.post("/extensions/settings", """{"developerMode":true}""").status)
        assertNotNull(runtime.generation(id))
        val first = DaemonState.snapshot().installations.getValue(id)
        assertEquals(200, install(http, file("MyExt.cs3", "v2")).status)
        val second = DaemonState.snapshot().installations.getValue(id)
        assertTrue(second.enabled)
        assertEquals(first.artifactHash, second.previous?.artifactHash)
        assertTrue(AuditLog.recent().any { "extension.developer_install" in it })
    }

    @Test fun `policy and allow-lists block developer extensions`() = RouteHarness().use { http ->
        DaemonRuntime.resetForTest(LaunchOptions(ExtensionPolicy(allowDeveloperExtensions = false, managed = true)))
        assertEquals(403, http.post("/extensions/settings", """{"developerMode":true}""").status)

        DaemonRuntime.resetForTest(LaunchOptions(ExtensionPolicy(allowedRepositories = listOf("https://only.invalid/repo.json"), managed = true)))
        assertEquals(200, http.post("/extensions/settings", """{"developerMode":true}""").status)
        assertEquals(403, install(http, file("MyExt.cs3", "v1")).status, "an allow-list excludes local files")
    }

    @Test fun `only regular cs3 files are accepted`() = RouteHarness().use { http ->
        assertEquals(200, http.post("/extensions/settings", """{"developerMode":true}""").status)
        assertEquals(400, install(http, file("notes.txt", "x")).status)
        val target = file("Real.cs3", "v1")
        val link = File(dir, "Link.cs3").toPath().also { Files.createSymbolicLink(it, target.toPath()) }
        assertEquals(400, http.post("/extensions/developer/install", """{"path":"$link"}""").status, "symbolic links are refused")
        assertEquals(400, http.post("/extensions/developer/install", """{"path":"relative/My.cs3"}""").status)
    }
}
