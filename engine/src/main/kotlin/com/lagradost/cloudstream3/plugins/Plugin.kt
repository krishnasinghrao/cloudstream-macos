package com.lagradost.cloudstream3.plugins

import android.content.Context
import android.content.res.Resources
import com.lagradost.cloudstream3.actions.VideoClickAction
import com.lagradost.macos.UnsupportedFeatureSink

abstract class Plugin : BasePlugin() {
    /**
     * Called when your Plugin is loaded
     * @param context Context
     */
    @Throws(Throwable::class)
    open fun load(context: Context) {
        // If not overridden by an extension then try the cross-platform load()
        load()
    }

    /**
     * Video click actions launch Android apps; the macOS engine does not offer
     * them. The registration is accepted (so the extension keeps working) and
     * reported as an unsupported feature on the installed extension.
     */
    fun registerVideoClickAction(element: VideoClickAction) {
        element.sourcePlugin = this.filename
        (registrationTarget as? UnsupportedFeatureSink)?.unsupported("Video click actions")
    }

    /**
     * The extension's own compiled resources and assets, set before load as on
     * Android (RT-13); null when the archive has none.
     */
    var resources: Resources? = null

    /** Settings screens are Android UI; not presented on macOS. */
    var openSettings: ((context: Context) -> Unit)? = null
}
