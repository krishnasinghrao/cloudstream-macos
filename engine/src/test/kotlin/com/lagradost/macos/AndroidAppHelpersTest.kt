@file:OptIn(com.lagradost.cloudstream3.InternalAPI::class)

package com.lagradost.macos

import android.content.Context
import com.lagradost.cloudstream3.CloudStreamApp
import com.lagradost.cloudstream3.network.CloudflareKiller
import com.lagradost.cloudstream3.utils.DataStore
import com.lagradost.cloudstream3.utils.DataStore.containsKey
import com.lagradost.cloudstream3.utils.DataStore.getKey
import com.lagradost.cloudstream3.utils.DataStore.getKeys
import com.lagradost.cloudstream3.utils.DataStore.getSharedPrefs
import com.lagradost.cloudstream3.utils.DataStore.removeKeys
import com.lagradost.cloudstream3.utils.DataStore.setKey
import java.io.File
import kotlin.test.*

class AndroidAppHelpersTest {
    @BeforeTest fun before() { ExtensionTestSupport.resetHome() }
    @AfterTest fun after() { ProviderRuntimeBootstrap.initialize(); ExtensionTestSupport.resetHome() }

    @Test fun `Android DataStore and app delegates persist within one installation`() {
        val root = File(CloudDirs.extensionDataDir, "helper-fixture")
        val first = Context(root)
        ProviderRuntimeBootstrap.initialize(first)
        first.setKey("seen", "providers", listOf("one", "two"))
        first.setKey("seenElsewhere", "providers", "untouched")
        CloudStreamApp.setKeyClass("setting", "persisted")
        assertEquals("persisted", CloudStreamApp.getKeyClass("setting", String::class.java))
        DataStore.editor(first).apply { setKeyRaw("enabled", true); setKeyRaw("names", setOf("a", "b")); apply() }

        val restored = Context(root)
        ProviderRuntimeBootstrap.initialize(restored)
        assertEquals(listOf("one", "two"), restored.getKey<List<String>>("seen", "providers"))
        assertEquals("persisted", CloudStreamApp.getKeyClass("setting", String::class.java))
        assertTrue(restored.getSharedPrefs().getBoolean("enabled", false))
        assertEquals(setOf("a", "b"), restored.getSharedPrefs().getStringSet("names", null)?.toSet())
        assertEquals(listOf("seen/providers"), restored.getKeys("seen"))
        assertEquals(1, restored.removeKeys("seen"))
        assertFalse(restored.containsKey("seen/providers"))
        assertTrue(restored.containsKey("seenElsewhere/providers"))

        ProviderRuntimeBootstrap.initialize(Context(File(CloudDirs.extensionDataDir, "other-fixture")))
        assertNull(CloudStreamApp.getKeyClass("setting", String::class.java))
    }

    @Test fun `helper exposes the Android binary descriptors used by extensions`() {
        assertEquals(android.content.SharedPreferences::class.java,
            DataStore::class.java.getMethod("getSharedPrefs", Context::class.java).returnType)
        assertEquals(Map::class.java, CloudflareKiller::class.java.getMethod("getSavedCookies").returnType)
        assertEquals(okhttp3.Headers::class.java, CloudflareKiller::class.java.getMethod("getCookieHeaders", String::class.java).returnType)
        assertEquals(Int::class.javaObjectType, CloudStreamApp.Companion::class.java.getMethod("removeKeys", String::class.java).returnType)
        assertEquals(mapOf("cf_clearance" to "a=b", "session" to "value"), CloudflareKiller.parseCookieMap("cf_clearance=a=b; invalid; session=value"))
    }
}
