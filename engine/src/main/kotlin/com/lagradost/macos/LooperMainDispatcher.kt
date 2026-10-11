package com.lagradost.macos

import android.os.Handler
import android.os.Looper
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.InternalCoroutinesApi
import kotlinx.coroutines.MainCoroutineDispatcher
import kotlinx.coroutines.internal.MainDispatcherFactory
import kotlin.coroutines.CoroutineContext

/**
 * `Dispatchers.Main` for extensions, as kotlinx-coroutines-android provides it:
 * coroutines run on the main [Looper]. That looper is the engine's
 * `android-main` thread (plan RT-14), never the Mac app's UI thread. Loaded
 * through the standard `MainDispatcherFactory` service entry.
 */
@OptIn(InternalCoroutinesApi::class)
class LooperMainDispatcherFactory : MainDispatcherFactory {
    /** The priority kotlinx-coroutines-android uses, so test dispatchers still take precedence. */
    override val loadPriority: Int get() = Int.MAX_VALUE / 2

    override fun createDispatcher(allFactories: List<MainDispatcherFactory>): MainCoroutineDispatcher =
        LooperMainDispatcher(Handler(Looper.getMainLooper()), invokeImmediately = false)

    override fun hintOnError(): String = "The engine's Android main looper could not be started."
}

internal class LooperMainDispatcher(private val handler: Handler, private val invokeImmediately: Boolean) : MainCoroutineDispatcher() {
    override val immediate: MainCoroutineDispatcher by lazy {
        if (invokeImmediately) this else LooperMainDispatcher(handler, invokeImmediately = true)
    }

    override fun isDispatchNeeded(context: CoroutineContext): Boolean = !invokeImmediately || Looper.myLooper() !== handler.getLooper()

    override fun dispatch(context: CoroutineContext, block: Runnable) {
        // A looper that has quit refuses work; the coroutine must still complete somewhere.
        if (!handler.post(block)) Dispatchers.IO.dispatch(context, block)
    }

    override fun toString(): String = if (invokeImmediately) "Dispatchers.Main.immediate" else "Dispatchers.Main"
}
