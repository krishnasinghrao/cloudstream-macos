package android.widget

import android.content.Context

/**
 * Android `android.widget.Toast` (A2). There is no Android UI on macOS: a
 * toast is recorded in the engine log, like `CommonActivity.showToast`, with
 * the extension's text length-bounded. Descriptors follow API 35.
 */
open class Toast(@Suppress("UNUSED_PARAMETER") context: Context?) {
    private var text: CharSequence? = null
    private var duration = LENGTH_SHORT

    open fun show() {
        com.lagradost.macos.DaemonLog.info("extension.toast", mapOf("message" to text?.toString().orEmpty().take(200)))
    }
    open fun cancel() {}
    open fun setText(s: CharSequence?) { text = s }
    open fun setText(resId: Int) { text = "resource #$resId" }
    open fun setDuration(duration: Int) { this.duration = duration }
    open fun getDuration(): Int = duration

    companion object {
        const val LENGTH_SHORT = 0
        const val LENGTH_LONG = 1

        @JvmStatic fun makeText(context: Context?, text: CharSequence?, duration: Int): Toast =
            Toast(context).apply { setText(text); setDuration(duration) }

        @JvmStatic fun makeText(context: Context?, resId: Int, duration: Int): Toast =
            Toast(context).apply { setText(resId); setDuration(duration) }
    }
}
