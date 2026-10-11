package com.lagradost.cloudstream3.plugins

/** The Android app's record of an installed plugin (same JVM shape). */
data class PluginData(
    val internalName: String,
    val url: String?,
    val isOnline: Boolean,
    val filePath: String,
    val version: Int,
)

/**
 * The Android app's plugin manager, as far as extensions call it. On macOS the
 * engine owns installation, isolation and reloading, so an extension cannot
 * enumerate or unload extensions: the list is empty and unloading is refused
 * (logged), which turns an extension's self-reload into a no-op.
 */
object PluginManager {
    fun getPluginsOnline(): Array<PluginData> = emptyArray()
    fun getPluginsLocal(): Array<PluginData> = emptyArray()

    fun unloadPlugin(absolutePath: String) {
        com.lagradost.macos.DaemonLog.info("plugin.self_unload_ignored", mapOf("reason" to "the engine manages extension lifecycles"))
    }
}
