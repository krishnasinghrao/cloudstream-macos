package android.app

/**
 * Android's Application. There is no Android application object on macOS;
 * the type exists so extensions that observe activity lifecycles link, and
 * callbacks registered on it are never called (no activities exist).
 */
open class Application : android.content.ContextWrapper(null) {
    interface ActivityLifecycleCallbacks

    open fun registerActivityLifecycleCallbacks(callback: ActivityLifecycleCallbacks) {}
    open fun unregisterActivityLifecycleCallbacks(callback: ActivityLifecycleCallbacks) {}
}
