package com.lagradost.macos

import android.content.Context
import android.content.res.AssetManager
import android.content.res.Resources
import com.lagradost.api.getContext
import com.lagradost.api.setContext
import kotlinx.coroutines.runBlocking
import java.io.File
import kotlin.test.*

/** Characterization only: a passing probe confirms an unsupported capability. */
class AndroidCompatibilityAuditProbe {
    @BeforeTest fun before() = ExtensionTestSupport.resetHome()
    @AfterTest fun after() = ExtensionTestSupport.resetHome()

    @Test fun `resource requirement is rejected before class loading with unsupported 422 over IPC`() = runBlocking<Unit> {
        val fixture = SignedCatalogFixture("https://android-audit.invalid/repo.json")
        val fetcher = fixture.publish(mapOf("Resources" to ExtensionTestSupport.extension("resources")), revision = 1)
        ExtensionTestSupport.use(InstallationManager(BridgeExtensionRuntime, fetcher))
        RouteHarness().use { routes ->
            val response = routes.post("/plugins/install", """{"repoUrl":"${fixture.url}","internalName":"Resources"}""")
            assertEquals(422, response.status)
            assertTrue(response.body.contains("unsupported"))
            assertTrue(response.body.contains("Android resources"))
        }
        assertTrue(PluginBridge.getAllLoadedDescriptors().isEmpty())
        assertTrue(DaemonState.snapshot().installations.isEmpty())
    }

    @Test fun `context exposes null Android resources assets and system services`() {
        val context = Context(File(CloudDirs.extensionDataDir, "android-null-probe"))
        assertNull(context.getResources())
        assertNull(context.getAssets())
        assertNull(context.getSystemService("clipboard"))
        assertEquals("", context.getString(1))
        assertEquals("", context.getString(1, "value"))
    }

    @Test fun `resource classes exist without their Android functionality`() {
        assertFalse(Resources::class.java.methods.any { it.name == "getDisplayMetrics" })
        assertFalse(AssetManager::class.java.methods.any { it.name == "open" })
    }

    @Test fun `worker host lacks Android scheduling WebView and app datastore classes`() {
        for (name in listOf("android.os.Handler", "android.os.Message", "android.os.Build\$VERSION",
            "android.webkit.WebView", "android.webkit.CookieManager", "android.text.TextUtils",
            "com.lagradost.cloudstream3.utils.DataStore", "com.lagradost.cloudstream3.MainActivity")) {
            assertFailsWith<ClassNotFoundException>(name) {
                Class.forName(name, false, javaClass.classLoader)
            }
        }
    }

    @Test fun `JVM context bridge discards a supplied context`() {
        setContext(Context(File(CloudDirs.extensionDataDir, "android-bridge-probe")))
        assertNull(getContext())
    }
}
