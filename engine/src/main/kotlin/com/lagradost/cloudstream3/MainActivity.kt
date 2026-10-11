package com.lagradost.cloudstream3

import com.lagradost.cloudstream3.utils.Event

/**
 * The Android app's main screen. The Mac app has no Android activity; the
 * events extensions observe or raise exist with the app's names and types.
 * Raising them has no effect on the native app (its own refresh is driven by
 * the engine API), which matches an Android app whose screen is not showing.
 */
open class MainActivity : android.app.Activity() {
    companion object {
        /** Android pre-fills the search screen with it once; the Mac app has no such screen. */
        var nextSearchQuery: String? = null

        val afterPluginsLoadedEvent = Event<Boolean>()
        val mainPluginsLoadedEvent = Event<Boolean>()
        val afterRepositoryLoadedEvent = Event<Boolean>()
        val bookmarksUpdatedEvent = Event<Boolean>()
        val reloadHomeEvent = Event<Boolean>()
        val reloadLibraryEvent = Event<Boolean>()
        val reloadAccountEvent = Event<Boolean>()
    }
}
