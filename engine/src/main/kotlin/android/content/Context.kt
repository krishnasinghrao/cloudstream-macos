package android.content

import android.content.res.AssetManager
import android.content.res.Resources
import android.os.Looper
import com.lagradost.macos.CloudDirs
import java.io.File

/**
 * Stub for `android.content.Context` with Android method descriptors.
 *
 * Each extension receives a Context rooted at its private data directory, so
 * files and preferences are namespaced per installation and follow the
 * configured data root (`cs.cloudstream.home`), never `user.home` directly.
 */
open class Context(private val root: File) {
    /** Host-level context (no extension); used for engine-internal callers. */
    constructor() : this(File(CloudDirs.extensionDataDir, "_host"))

    companion object {
        const val MODE_PRIVATE: Int = 0x0000
        const val MODE_WORLD_READABLE: Int = 0x0001
        const val MODE_WORLD_WRITEABLE: Int = 0x0002
        const val MODE_APPEND: Int = 0x8000
        const val ACTIVITY_SERVICE: String = "activity"
        private val activityManager by lazy { android.app.ActivityManager() }
        const val CONNECTIVITY_SERVICE: String = "connectivity"
        private val connectivityManager by lazy { android.net.ConnectivityManager() }
        private val reportedServices = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()

        /** Android returns null for a service the device lacks; extensions handle that. Name it once in diagnostics (RT-14). */
        private fun unavailableService(name: String) {
            if (reportedServices.size < 64 && reportedServices.add(name.take(64))) {
                com.lagradost.macos.DaemonLog.info("android.service_unavailable", mapOf("service" to name.take(64)))
            }
        }
    }

    private fun dir(vararg parts: String): File = parts.fold(root) { acc, part -> File(acc, part) }.apply { mkdirs() }

    open fun getPackageName(): String = "com.lagradost.cloudstream3"
    open fun getFilesDir(): File = dir("files")
    open fun getCacheDir(): File = dir("cache")
    open fun getExternalFilesDir(type: String?): File = dir("external", type ?: "files")
    open fun getExternalCacheDir(): File = dir("external", "cache")
    open fun getDir(name: String, mode: Int): File {
        require(name.isNotBlank() && '/' !in name && name != "." && name != "..") { "Invalid directory name" }
        return dir("app_$name")
    }

    open fun getSharedPreferences(name: String?, mode: Int): SharedPreferences {
        val safe = (name ?: "default").replace(Regex("[^A-Za-z0-9._-]"), "_").take(128).ifBlank { "default" }
        return FileSharedPreferences.forFile(File(dir("shared_prefs"), "$safe.json"))
    }

    open fun getString(resId: Int): String = ""
    open fun getString(resId: Int, vararg formatArgs: Any?): String = ""
    open fun getApplicationContext(): Context = this
    open fun getApplicationInfo(): android.content.pm.ApplicationInfo = android.content.pm.ApplicationInfo().also {
        it.packageName = getPackageName()
        it.dataDir = root.apply { mkdirs() }.absolutePath
    }
    /** Services that exist on macOS; others are absent (null), as for an unavailable Android service. */
    open fun getSystemService(name: String): Any? = when (name) {
        ACTIVITY_SERVICE -> activityManager
        CONNECTIVITY_SERVICE -> connectivityManager
        else -> null.also { unavailableService(name) }
    }
    open fun getResources(): Resources? = null
    open fun getAssets(): AssetManager? = null
    open fun getClassLoader(): ClassLoader = Context::class.java.classLoader

    /**
     * macOS never starts Android activities (a browser tab, another app). The
     * request is recorded by action only — never its data, which may be a
     * URL — and nothing opens, as when Android finds no app for an intent
     * the caller treats as optional.
     */
    open fun startActivity(intent: Intent?) = startActivity(intent, null)
    open fun startActivity(intent: Intent?, @Suppress("UNUSED_PARAMETER") options: android.os.Bundle?) {
        com.lagradost.macos.DaemonLog.info("android.start_activity_unavailable", mapOf("action" to intent?.getAction().orEmpty().take(80)))
    }
    open fun getMainLooper(): Looper = Looper.getMainLooper()
}
