package com.lagradost.cloudstream3.ui.home

import com.lagradost.cloudstream3.utils.DataStoreHelper

/** The Android home screen model, as extensions call it. The Mac app's watch history is not shared with extensions. */
open class HomeViewModel {
    companion object {
        suspend fun getResumeWatching(): List<DataStoreHelper.ResumeWatchingResult>? = emptyList()
    }
}
