package com.lagradost.macos

import com.lagradost.cloudstream3.APIHolder
import com.lagradost.cloudstream3.LoadResponse
import com.lagradost.cloudstream3.MainAPI
import com.lagradost.cloudstream3.network.WebViewResolver
import kotlinx.coroutines.runBlocking
import okhttp3.Request
import kotlin.test.*

/** Characterization: a pass confirms the adverse behavior, not a repaired app. */
class RuntimeAuditProbe {
    @BeforeTest fun before() {
        ExtensionTestSupport.resetHome()
        APIHolder.allProviders.clear()
    }

    @AfterTest fun after() {
        APIHolder.allProviders.clear()
        ExtensionTestSupport.resetHome()
    }

    @Test fun `Android CloudflareKiller is absent from the JVM host`() {
        assertFailsWith<ClassNotFoundException> {
            Class.forName("com.lagradost.cloudstream3.network.CloudflareKiller", false, javaClass.classLoader)
        }
    }

    @Test fun `JVM Result does not expose the DEX underscore method name`() {
        val names = Class.forName("kotlin.Result").declaredMethods.map { it.name }
        assertTrue("constructor-impl" in names)
        assertFalse("constructor_impl" in names)
    }

    @Test fun `JVM webview resolution throws before any HTTP request`() = runBlocking<Unit> {
        assertFailsWith<NotImplementedError> {
            WebViewResolver(Regex("m3u8")).resolveUsingWebView(Request.Builder().url("https://audit.invalid/embed").build())
        }
    }

    @Test fun `unprefixed unknown shortcode incorrectly resolves through py md`() = runBlocking {
        val fetched = mutableListOf<String>()
        val target = "https://audit.invalid/repo.json"
        val parsed = RepositoryService.parseRepoUrl("CustomAuditCode", RepositoryFetcher { url, _ ->
            fetched += url
            RepositoryDocument(byteArrayOf(), target)
        })
        assertEquals(target, parsed)
        assertEquals(listOf("https://py.md/CustomAuditCode"), fetched)
    }

    @Test fun `known explicit shortlink ignores the server redirect`() = runBlocking {
        var fetched = false
        val parsed = RepositoryService.parseRepoUrl("https://cutt.ly/hexated", RepositoryFetcher { _, _ ->
            fetched = true
            RepositoryDocument(byteArrayOf(), "https://audit.invalid/user-target.json")
        })
        assertFalse(fetched)
        assertEquals("https://codeberg.org/cloudstream/cloudstream-extensions-hexated/raw/branch/builds/repo.json", parsed)
    }

    @Test fun `community consent cannot make a hashless extension installable`() = runBlocking {
        val repo = "https://audit.invalid/repo.json"
        RepositoryService.sync(repo, RepositoryFetcher { url, _ ->
            RepositoryDocument((if (url.endsWith("repo.json"))
                """{"name":"Audit","manifestVersion":1,"pluginLists":["plugins.json"]}"""
            else """[{"name":"Hashless","internalName":"Hashless","url":"Hashless.cs3","status":1,"version":1}]""").toByteArray(), url)
        })
        RepositoryService.setConsent(repo, true)
        val plugin = RepositoryService.getRepoPlugins(repo).single()
        assertFalse(plugin.installationAllowed == true)
        assertTrue(plugin.installationBlockedReason.orEmpty().contains("SHA-256"))
    }

    @Test fun `details ABI failure becomes a local HTTP 502`() {
        APIHolder.allProviders.add(object : MainAPI() {
            override var name = "AuditBroken"
            override suspend fun load(url: String): LoadResponse? = throw NoSuchMethodError("kotlin.Result.constructor_impl")
        })
        RouteHarness().use { routes ->
            val response = routes.get("/details?plugin=AuditBroken&url=https%3A%2F%2Faudit.invalid%2Ftitle")
            assertEquals(502, response.status)
            assertTrue(response.body.contains("provider failure"))
            assertFalse(response.body.contains("NoSuchMethodError"))
        }
    }

    @Test fun `links ABI failure becomes HTTP 200 with an empty successful-looking stream`() {
        APIHolder.allProviders.add(object : MainAPI() {
            override var name = "AuditBrokenLinks"
            override suspend fun loadLinks(data: String, isCasting: Boolean,
                subtitleCallback: (com.lagradost.cloudstream3.SubtitleFile) -> Unit,
                callback: (com.lagradost.cloudstream3.utils.ExtractorLink) -> Unit): Boolean {
                throw NoSuchMethodError("kotlin.Result.constructor_impl")
            }
        })
        RouteHarness().use { routes ->
            val response = routes.post("/links/stream", """{"plugin":"AuditBrokenLinks","data":"audit"}""")
            assertEquals(200, response.status)
            assertTrue(response.body.contains("\"type\":\"done\""))
            assertFalse(response.body.contains("\"type\":\"error\""))
            assertFalse(response.body.contains("NoSuchMethodError"))
        }
    }
}
