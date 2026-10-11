package android.content.pm

/**
 * Android's ApplicationInfo, as extensions read it. [dataDir] is the
 * extension's own private data directory — never the engine's — so code that
 * scans "the app's" data finds only what the extension itself stored.
 */
open class ApplicationInfo {
    @JvmField var packageName: String? = null
    @JvmField var dataDir: String? = null
    @JvmField var flags: Int = 0
}
