package android.content

import android.content.res.AssetManager
import android.content.res.Resources
import java.io.File

/**
 * Android's ContextWrapper (Context → ContextWrapper → Activity). Extensions
 * unwrap a context with [getBaseContext] to find their Activity in settings
 * code; storage and resource calls delegate directly to the wrapped context.
 */
open class ContextWrapper(private val base: Context?) : Context() {
    open fun getBaseContext(): Context? = base
    override fun getFilesDir(): File = base?.getFilesDir() ?: super.getFilesDir()
    override fun getCacheDir(): File = base?.getCacheDir() ?: super.getCacheDir()
    override fun getDataDir(): File = base?.getDataDir() ?: super.getDataDir()
    override fun getSharedPreferences(name: String?, mode: Int): SharedPreferences =
        base?.getSharedPreferences(name, mode) ?: super.getSharedPreferences(name, mode)
    override fun getResources(): Resources = base?.getResources() ?: super.getResources()
    override fun getAssets(): AssetManager = base?.getAssets() ?: super.getAssets()
    override fun getPackageName(): String = base?.getPackageName() ?: super.getPackageName()
    override fun getApplicationContext(): Context = base?.getApplicationContext() ?: super.getApplicationContext()
}
