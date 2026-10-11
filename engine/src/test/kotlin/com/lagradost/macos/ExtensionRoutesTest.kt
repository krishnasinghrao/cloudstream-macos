package com.lagradost.macos

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import kotlin.test.*

/** IPC v4 contract through the real HTTP stack (plan T2.1–T2.5). */
class ExtensionRoutesTest {
    private val repo = SignedCatalogFixture("https://routes.invalid/repo.json")
    private val bytes = "route fixture artifact".toByteArray()
    private lateinit var runtime: FakeRuntime

    @BeforeTest fun before() {
        ExtensionTestSupport.resetHome()
        runtime = FakeRuntime()
        runBlocking { ExtensionTestSupport.use(InstallationManager(runtime, repo.publish(mapOf("Ext" to bytes), 1))) }
    }
    @AfterTest fun after() = ExtensionTestSupport.resetHome()

    private val id = InstallationProofStore.installationId(repo.url, "Ext")
    private fun JsonElement.obj() = jsonObject
    private fun JsonObject.str(key: String) = getValue(key).jsonPrimitive.content

    @Test fun `unauthenticated requests are rejected`() = RouteHarness().use { http ->
        assertEquals(401, http.get("/plugins", auth = false).status)
        assertEquals(200, http.get("/health", auth = false).status)
    }

    @Test fun `install then installed list reports receipt metadata without paths`() = RouteHarness().use { http ->
        val installed = http.post("/plugins/install", """{"repoUrl":"${repo.url}","internalName":"Ext"}""")
        assertEquals(200, installed.status, installed.body)
        val list = http.get("/plugins").json.jsonArray
        val dto = list.single().obj()
        assertEquals(id, dto.str("id"))
        assertEquals("Ext", dto.str("internalName"))
        assertEquals("1", dto.str("version"))
        // Signed by the fixture's own key, which no policy pins (M4).
        assertEquals("false", dto.str("verified"))
        assertEquals("signed", dto.str("tier"))
        assertEquals("running", dto.str("state"))
        assertFalse(dto.toString().contains(CloudDirs.home.path), "no local filesystem paths over IPC")
    }

    @Test fun `enable toggle uses installation ids and unknown ids are typed errors`() = RouteHarness().use { http ->
        http.post("/plugins/install", """{"repoUrl":"${repo.url}","internalName":"Ext"}""")
        val disabled = http.post("/plugins/setEnabled", """{"installationId":"$id","enabled":false}""")
        assertEquals(200, disabled.status, disabled.body)
        assertEquals("disabled", disabled.json.obj().str("state"))
        assertFalse(DaemonState.snapshot().installations.getValue(id).enabled)
        assertNull(runtime.generation(id))
        assertTrue(DaemonState.snapshot().disabledProviders.isEmpty(), "no arbitrary strings are written into provider state")
        val unknown = http.post("/plugins/setEnabled", """{"installationId":"${"f".repeat(64)}","enabled":false}""")
        assertEquals(404, unknown.status)
        assertEquals("unknown_extension", unknown.json.obj().str("code"))
    }

    @Test fun `unloaded receipts stay listed with an error and can be retried or uninstalled`() = RouteHarness().use { http ->
        http.post("/plugins/install", """{"repoUrl":"${repo.url}","internalName":"Ext"}""")
        runtime.remove(id)
        runtime.onPrepare = { error("boom") }
        assertEquals(200, http.post("/plugins/retry", """{"installationId":"$id"}""").status)
        val dto = http.get("/plugins").json.jsonArray.single().obj()
        assertEquals("failed", dto.str("state"))
        assertTrue(dto.str("lastError").contains("boom"))
        runtime.onPrepare = {}
        assertEquals("running", http.post("/plugins/retry", """{"installationId":"$id"}""").json.obj().str("state"))
        assertEquals(200, http.post("/plugins/uninstall", """{"installationId":"$id"}""").status)
        assertTrue(http.get("/plugins").json.jsonArray.isEmpty())
        assertEquals(404, http.post("/plugins/uninstall", """{"installationId":"$id"}""").status)
    }

    @Test fun `catalog projection and consent route for community repositories`() = RouteHarness().use { http ->
        val community = SignedCatalogFixture("https://routes-community.invalid/repo.json")
        val body = community.listFor(mapOf("Ext" to bytes))
        runBlocking { RepositoryService.sync(community.url, community.fetcher("""{"pluginLists":["list.json"]}""", body)) }
        val entry = http.get("/repos/plugins?repoUrl=${community.url}").json.jsonArray.single().obj()
        assertEquals("community", entry.str("tier"))
        assertEquals("true", entry.str("requiresConsent"))
        val blocked = http.post("/plugins/install", """{"repoUrl":"${community.url}","internalName":"Ext"}""")
        assertEquals(403, blocked.status)
        assertEquals("consent_required", blocked.json.obj().str("code"))
        val consent = http.post("/repos/consent", """{"repoUrl":"${community.url}","allow":true}""")
        assertEquals("true", consent.json.obj().str("consented"))
        assertEquals("false", http.get("/repos/plugins?repoUrl=${community.url}").json.jsonArray.single().obj().str("requiresConsent"))
    }

    @Test fun `update and settings routes honor policy`() = RouteHarness().use { http ->
        http.post("/plugins/install", """{"repoUrl":"${repo.url}","internalName":"Ext"}""")
        val settings = http.post("/extensions/settings", """{"autoUpdate":true}""")
        assertEquals("true", settings.json.obj().str("autoUpdate"))
        DaemonRuntime.resetForTest(LaunchOptions(ExtensionPolicy(autoUpdate = false, managed = true)))
        val managed = http.post("/extensions/settings", """{"autoUpdate":true}""")
        assertEquals(403, managed.status)
        assertEquals("policy_denied", managed.json.obj().str("code"))
        assertEquals("true", http.get("/extensions/settings").json.obj().str("autoUpdateManaged"))
        assertEquals("[]", http.post("/plugins/updateAll", "{}").json.jsonArray.toString())
    }

    @Test fun `health reports background restore and safe mode`() = RouteHarness().use { http ->
        val health = http.get("/health", auth = false).json.obj()
        assertEquals("6", health.str("ipcVersion"))
        assertTrue(health.containsKey("extensions"))
        assertEquals("false", health.str("safeMode"))
    }

    @Test fun `provider configuration keeps credentials out of state`() = RouteHarness().use { http ->
        val api = object : com.lagradost.cloudstream3.MainAPI() { override var name = "Configurable"; override var mainUrl = "https://a.invalid" }
        api.sourcePlugin = id
        com.lagradost.cloudstream3.APIHolder.allProviders.add(api)
        try {
            val response = http.post("/plugins/config", """{"providerId":"$id:Configurable","url":"https://b.invalid","credentials":"s3cret"}""")
            assertEquals(200, response.status, response.body)
            assertEquals("https://b.invalid", api.mainUrl)
            assertEquals("s3cret", api.storedCredentials)
            assertEquals("https://b.invalid", DaemonState.overrideFor("$id:Configurable")?.url)
            assertFalse(DaemonState.stateFile.readText().contains("s3cret"))
            val invalid = http.post("/plugins/config", """{"providerId":"$id:Configurable","url":"file:///etc/passwd"}""")
            assertEquals(400, invalid.status)
            assertEquals("invalid_request", invalid.json.obj().str("code"))
        } finally { com.lagradost.cloudstream3.APIHolder.allProviders.remove(api) }
    }

    @Test fun `provider settings distinguish unchanged set clear and reset`() = RouteHarness().use { http ->
        val api = object : com.lagradost.cloudstream3.MainAPI() { override var name = "Configurable"; override var mainUrl = "https://a.invalid" }
        api.sourcePlugin = id
        com.lagradost.cloudstream3.APIHolder.allProviders.add(api)
        val provider = "$id:Configurable"
        fun config(fields: String) = http.post("/plugins/config", """{"providerId":"$provider"$fields}""")
        try {
            assertEquals(200, config(""","url":"https://b.invalid","credentials":"s3cret"""").status)
            // Unchanged: null fields keep both the address and the live secret.
            val unchanged = config("").json.obj()
            assertEquals("true", unchanged.str("applied"))
            assertEquals("s3cret", api.storedCredentials)
            assertEquals("https://b.invalid", api.mainUrl)

            // An explicit clear removes the live secret; it never falls back to the old one.
            val cleared = config(""","clearCredentials":true""").json.obj()
            assertEquals("true", cleared.str("applied"))
            assertNull(api.storedCredentials)
            assertEquals("https://b.invalid", DaemonState.overrideFor(provider)?.url, "the address is unchanged")
            assertFalse(DaemonState.overrideFor(provider)!!.hasCredentials)

            // Current clients send an empty value; it is the same clear.
            config(""","credentials":"again"""")
            assertEquals("again", api.storedCredentials)
            config(""","credentials":""""")
            assertNull(api.storedCredentials)

            // An empty address is a clear, not a validation error; the default returns at reload.
            val urlCleared = config(""","url":""""")
            assertEquals(200, urlCleared.status, urlCleared.body)
            assertEquals("false", urlCleared.json.obj().str("applied"))
            assertEquals("true", urlCleared.json.obj().str("pending"))
            assertNull(DaemonState.overrideFor(provider))

            config(""","url":"https://c.invalid","credentials":"third"""")
            val reset = config(""","reset":true""").json.obj()
            assertEquals("true", reset.str("pending"))
            assertNull(api.storedCredentials, "reset revokes the live secret at once")
            assertNull(DaemonState.overrideFor(provider))
            assertEquals(400, config(""","url":"file:///etc/passwd"""").status)
        } finally { com.lagradost.cloudstream3.APIHolder.allProviders.remove(api) }
    }

    @Test fun `a worker clears its live credential instead of keeping the previous one`() {
        val api = object : com.lagradost.cloudstream3.MainAPI() { override var name = "Live"; override var mainUrl = "https://a.invalid" }
        val worker = com.lagradost.macos.worker.WorkerMain
        worker.configure(api, com.lagradost.macos.worker.ProviderConfig("https://b.invalid", "s3cret"))
        worker.configure(api, com.lagradost.macos.worker.ProviderConfig(null, null))
        assertEquals("s3cret", api.storedCredentials, "null means unchanged")
        worker.configure(api, com.lagradost.macos.worker.ProviderConfig("https://b.invalid", null), clearCredentials = true)
        assertNull(api.storedCredentials)
        assertEquals("https://b.invalid", api.mainUrl)
    }
}
