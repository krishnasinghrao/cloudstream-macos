package com.lagradost.macos

import com.lagradost.cloudstream3.syncproviders.AccountManager
import com.lagradost.cloudstream3.syncproviders.SyncRepo
import com.lagradost.cloudstream3.utils.UiText
import kotlinx.coroutines.runBlocking
import kotlin.test.*

/**
 * Extensions such as CineStream bundle providers that reference the Android
 * app's account-sync types and Android UI types in load(). Without these
 * types the whole extension failed to load (NoClassDefFoundError). The engine
 * provides them with Android's JVM names and "no account signed in" behavior.
 */
class AndroidSyncAbiTest {
    @Test fun `sync types keep the JVM names extensions link against`() {
        val repo = Class.forName("com.lagradost.cloudstream3.syncproviders.SyncRepo")
        // Kotlin mangles suspend functions returning Result; the suffix must match Android's.
        repo.getMethod("library-IoAF18A", kotlin.coroutines.Continuation::class.java)
        repo.getMethod("authUser")
        Class.forName("com.lagradost.cloudstream3.syncproviders.AccountManager\$Companion").getMethod("getSimklApi")
        Class.forName("com.lagradost.cloudstream3.syncproviders.SyncAPI\$LibraryMetadata").getMethod("getAllLibraryLists")
        val list = Class.forName("com.lagradost.cloudstream3.syncproviders.SyncAPI\$LibraryList")
        assertEquals(UiText::class.java, list.getMethod("getName").returnType)
        list.getMethod("getItems")
    }

    @Test fun `no sync account is signed in on macOS`() = runBlocking<Unit> {
        val repo = SyncRepo(AccountManager.simklApi)
        assertNull(repo.authUser())
        assertFalse(repo.isAvailable)
        assertNull(repo.library().getOrNull())
    }

    @Test fun `Android UI types referenced by load() exist and are inert`() {
        val activity = Class.forName("android.app.Activity")
        assertTrue(android.content.Context::class.java.isAssignableFrom(activity))
    }
}
