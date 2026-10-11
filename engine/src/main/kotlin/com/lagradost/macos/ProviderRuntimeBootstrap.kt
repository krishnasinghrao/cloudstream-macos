package com.lagradost.macos

import android.content.Context
import com.lagradost.api.setContext
import com.lagradost.cloudstream3.CloudStreamApp
import org.schabi.newpipe.extractor.NewPipe

/** Process-local provider dependencies. A parent JVM cannot initialize a worker's singletons. */
internal object ProviderRuntimeBootstrap {
    private var initialized = false

    @Synchronized
    fun initialize(context: Context = Context()) {
        CloudStreamApp.context = context
        setContext(context)
        if (!initialized) {
            // The downloader reads the current immutable provider client on every request,
            // so subsequent network-settings changes also apply to NewPipe.
            NewPipe.init(NewPipeBridge())
            initialized = true
        }
    }
}
