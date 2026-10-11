package android.content.res

import com.lagradost.macos.ResourceTable
import java.io.ByteArrayInputStream
import java.io.InputStream

/**
 * An extension's own compiled resources (plan RT-13), read from the verified
 * archive's `resources.arsc`. Values, names and identifiers work as on
 * Android. Layouts and drawables are Android UI, which the Mac engine does not
 * render: those methods are absent, so such code fails where it runs (only
 * Android settings screens use them) instead of receiving fake objects.
 */
open class Resources internal constructor(
    private val table: ResourceTable?,
    private val assets: AssetManager,
) {
    open class NotFoundException : RuntimeException {
        constructor() : super()
        constructor(name: String?) : super(name)
        constructor(name: String?, cause: Exception?) : super(name, cause)
    }

    fun getAssets(): AssetManager = assets

    fun getIdentifier(name: String, defType: String?, defPackage: String?): Int = table?.identifier(name, defType, defPackage) ?: 0

    private fun value(id: Int): ResourceTable.Value =
        table?.value(id) ?: throw NotFoundException("Resource ID #0x${Integer.toHexString(id)}")

    open fun getText(id: Int): CharSequence = getString(id)

    open fun getString(id: Int): String = when (val value = value(id)) {
        is ResourceTable.Value.Text -> value.value
        else -> throw NotFoundException("Resource ID #0x${Integer.toHexString(id)} is not a string")
    }

    open fun getString(id: Int, vararg formatArgs: Any?): String = String.format(java.util.Locale.US, getString(id), *formatArgs)

    open fun getStringArray(id: Int): Array<String> = bag(id).map { (it as? ResourceTable.Value.Text)?.value ?: "" }.toTypedArray()

    open fun getTextArray(id: Int): Array<CharSequence> = getStringArray(id).map { it as CharSequence }.toTypedArray()

    open fun getIntArray(id: Int): IntArray = bag(id).map { (it as? ResourceTable.Value.Data)?.data ?: 0 }.toIntArray()

    open fun getInteger(id: Int): Int = data(id).data

    open fun getBoolean(id: Int): Boolean = data(id).let {
        if (it.type != ResourceTable.TYPE_INT_BOOLEAN) throw NotFoundException("Resource ID #0x${Integer.toHexString(id)} is not a boolean")
        it.data != 0
    }

    @Deprecated("Android deprecated the theme-less overload") open fun getColor(id: Int): Int = data(id).data

    open fun getResourceName(id: Int): String = name(id).let { (pkg, type, entry) -> "$pkg:$type/$entry" }
    open fun getResourcePackageName(id: Int): String = name(id).first
    open fun getResourceTypeName(id: Int): String = name(id).second
    open fun getResourceEntryName(id: Int): String = name(id).third

    private fun name(id: Int) = table?.name(id) ?: throw NotFoundException("Resource ID #0x${Integer.toHexString(id)}")

    private fun data(id: Int): ResourceTable.Value.Data = value(id) as? ResourceTable.Value.Data
        ?: throw NotFoundException("Resource ID #0x${Integer.toHexString(id)} is not a scalar value")

    private fun bag(id: Int): List<ResourceTable.Value> = (value(id) as? ResourceTable.Value.Bag)?.items?.map { item ->
        if (item is ResourceTable.Value.Reference) table?.value(item.id) ?: item else item
    } ?: throw NotFoundException("Resource ID #0x${Integer.toHexString(id)} is not an array")
}

/** Files under the archive's `assets/` directory (read-only, in memory, bounded at load). */
open class AssetManager internal constructor(private val files: Map<String, ByteArray>) {
    companion object {
        const val ACCESS_UNKNOWN = 0
        const val ACCESS_RANDOM = 1
        const val ACCESS_STREAMING = 2
        const val ACCESS_BUFFER = 3
    }

    fun open(fileName: String): InputStream = open(fileName, ACCESS_STREAMING)

    fun open(fileName: String, accessMode: Int): InputStream =
        ByteArrayInputStream(files[normalize(fileName)] ?: throw java.io.FileNotFoundException(fileName))

    /** Names directly inside [path] ("" is the root), like Android. */
    fun list(path: String): Array<String> {
        val prefix = normalize(path).let { if (it.isEmpty()) "" else "$it/" }
        return files.keys.filter { it.startsWith(prefix) }.map { it.removePrefix(prefix).substringBefore('/') }.distinct().sorted().toTypedArray()
    }

    fun close() {}

    private fun normalize(path: String): String = path.trim('/').also {
        if (it.split('/').any { segment -> segment == ".." }) throw java.io.FileNotFoundException(path)
    }
}
