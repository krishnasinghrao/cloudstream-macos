package com.lagradost.api

@Volatile private var platformContext: Any? = null

/**
 * Helper function for Android specific context.
 * Do not use this unless absolutely necessary.
 * setContext() must be called before this is called.
 * @return the context set by the host, null if none.
 */
fun getContext(): Any? = platformContext

/**
 * Set context for Android-specific code such as webview.
 */
fun setContext(context: Any?) { platformContext = context }
