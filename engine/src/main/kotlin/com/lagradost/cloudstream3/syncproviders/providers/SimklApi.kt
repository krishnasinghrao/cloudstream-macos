package com.lagradost.cloudstream3.syncproviders.providers

import com.lagradost.cloudstream3.syncproviders.SyncAPI

/** Android: syncproviders/providers/SimklApi.kt. No Simkl sign-in on macOS: never authenticated. */
class SimklApi : SyncAPI() {
    override val name = "Simkl"
    override val idPrefix = "simkl"
}
