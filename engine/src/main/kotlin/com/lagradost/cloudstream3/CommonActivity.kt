package com.lagradost.cloudstream3

import android.app.Activity
import com.lagradost.cloudstream3.utils.UiText

/**
 * The Android app's activity helpers, as extensions call them. There is no
 * Android activity on macOS: [activity] is always null (extensions already
 * handle that, as on Android before the UI exists), and toasts are logged
 * instead of shown, with the extension's message length-bounded.
 */
object CommonActivity {
    var activity: Activity?
        get() = null
        set(@Suppress("UNUSED_PARAMETER") value) {}

    fun showToast(message: Int, duration: Int? = null) = log("resource #$message")
    fun showToast(message: String?, duration: Int? = null) = log(message)
    fun showToast(message: UiText?, duration: Int? = null) = log(message?.toString())
    fun showToast(act: Activity?, text: UiText, duration: Int) = log(text.toString())
    fun showToast(act: Activity?, message: Int, duration: Int? = null) = log("resource #$message")
    fun showToast(act: Activity?, message: String?, duration: Int? = null) = log(message)

    private fun log(message: String?) {
        com.lagradost.macos.DaemonLog.info("extension.toast", mapOf("message" to message.orEmpty().take(200)))
    }
}
