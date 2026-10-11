package com.lagradost.macos

import com.lagradost.macos.network.GitHubMirror
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.*

/** N2: the opt-in jsDelivr mirror for GitHub-hosted repositories. */
class GitHubMirrorTest {
    @BeforeTest fun before() { ExtensionTestSupport.resetHome(); NetworkSetup.apply(DaemonState.NetworkSettings()) }
    @AfterTest fun after() { NetworkSetup.apply(DaemonState.NetworkSettings()); ExtensionTestSupport.resetHome() }

    @Test fun `github raw addresses map to jsDelivr and nothing else does`() {
        assertEquals("https://cdn.jsdelivr.net/gh/recloudstream/extensions@builds/plugins.json",
            GitHubMirror.mirrorOf("https://raw.githubusercontent.com/recloudstream/extensions/builds/plugins.json"))
        assertEquals("https://cdn.jsdelivr.net/gh/phisher98/cloudstream-extensions-phisher@builds/CineStream.cs3",
            GitHubMirror.mirrorOf("https://raw.githubusercontent.com/phisher98/cloudstream-extensions-phisher/refs/heads/builds/CineStream.cs3"))
        assertEquals("https://cdn.jsdelivr.net/gh/lawlietbr/lietrepo@main/builds/AnimeFire.cs3",
            GitHubMirror.mirrorOf("https://github.com/lawlietbr/lietrepo/raw/refs/heads/main/builds/AnimeFire.cs3"))
        for (other in listOf("https://gitlab.com/tearrs/vn/-/raw/main/plugins.json", "http://raw.githubusercontent.com/a/b/c/d.json",
            "https://raw.githubusercontent.com/a/b/main", "https://raw.githubusercontent.com/a/b/main/../x.json",
            "https://raw.githubusercontent.com/a/b/main/x.json?token=1", "https://github.com/a/b/blob/main/x.json",
            "https://raw.githubusercontent.com/a b/c/main/x.json")) {
            assertNull(GitHubMirror.mirrorOf(other), other)
        }
    }

    @Test fun `the mirror is off by default and an older client cannot switch it off`() {
        assertFalse(GitHubMirror.enabled)
        RouteHarness().use { routes ->
            assertEquals(200, routes.post("/settings/network", """{"dns":"system","httpCacheMb":50,"retryOnNetworkError":true,"githubMirror":true}""").status)
            assertTrue(GitHubMirror.enabled)
            // A client from before N2 sends no githubMirror: the user's choice stays.
            assertEquals(200, routes.post("/settings/network", """{"dns":"system","httpCacheMb":50,"retryOnNetworkError":false}""").status)
            assertTrue(GitHubMirror.enabled)
            assertTrue(routes.get("/settings/network").json.jsonObject.getValue("githubMirror").jsonPrimitive.boolean)
            assertTrue(DaemonState.networkSettings().githubMirror, "persisted")
        }
    }
}
