package android.content

/**
 * Android's ContextWrapper (Context → ContextWrapper → Activity). Extensions
 * unwrap a context with [getBaseContext] to find their Activity in settings
 * code; storage calls behave like the wrapped context's on Android only in
 * the Android app, here the wrapper keeps the engine's host context.
 */
open class ContextWrapper(private val base: Context?) : Context() {
    open fun getBaseContext(): Context? = base
}
