package android.content

import android.net.Uri

/**
 * Android `android.content.Intent` as a plain value (A2). Extensions build
 * intents to open a browser or another app, usually from a settings button;
 * macOS never starts Android activities, so [Context.startActivity] only
 * records that it was asked to. Descriptors follow API 35.
 */
open class Intent() {
    private var action: String? = null
    private var data: Uri? = null
    private var type: String? = null
    private var flags = 0
    private var packageName: String? = null
    private val categories = linkedSetOf<String>()
    private val extras = LinkedHashMap<String, Any?>()

    constructor(action: String?) : this() { this.action = action }
    constructor(action: String?, uri: Uri?) : this(action) { data = uri }
    constructor(@Suppress("UNUSED_PARAMETER") packageContext: Context?, @Suppress("UNUSED_PARAMETER") cls: Class<*>?) : this()
    constructor(other: Intent?) : this() {
        if (other != null) {
            action = other.action; data = other.data; type = other.type; flags = other.flags
            packageName = other.packageName; categories += other.categories; extras += other.extras
        }
    }

    open fun getAction(): String? = action
    open fun setAction(action: String?): Intent = apply { this.action = action }
    open fun getData(): Uri? = data
    open fun getDataString(): String? = data?.toString()
    open fun setData(data: Uri?): Intent = apply { this.data = data; type = null }
    open fun getType(): String? = type
    open fun setType(type: String?): Intent = apply { this.type = type; data = null }
    open fun setDataAndType(data: Uri?, type: String?): Intent = apply { this.data = data; this.type = type }
    open fun addCategory(category: String?): Intent = apply { category?.let(categories::add) }
    open fun getFlags(): Int = flags
    open fun setFlags(flags: Int): Intent = apply { this.flags = flags }
    open fun addFlags(flags: Int): Intent = apply { this.flags = this.flags or flags }
    open fun getPackage(): String? = packageName
    open fun setPackage(packageName: String?): Intent = apply { this.packageName = packageName }
    open fun setClassName(packageName: String?, @Suppress("UNUSED_PARAMETER") className: String?): Intent =
        apply { this.packageName = packageName }

    open fun putExtra(name: String?, value: Boolean): Intent = put(name, value)
    open fun putExtra(name: String?, value: Int): Intent = put(name, value)
    open fun putExtra(name: String?, value: Long): Intent = put(name, value)
    open fun putExtra(name: String?, value: Float): Intent = put(name, value)
    open fun putExtra(name: String?, value: Double): Intent = put(name, value)
    open fun putExtra(name: String?, value: String?): Intent = put(name, value)
    open fun putExtra(name: String?, value: CharSequence?): Intent = put(name, value)
    open fun putExtra(name: String?, value: Array<String>?): Intent = put(name, value)
    open fun hasExtra(name: String?): Boolean = name != null && extras.containsKey(name)
    open fun getStringExtra(name: String?): String? = extras[name]?.toString()
    open fun getIntExtra(name: String?, defaultValue: Int): Int = extras[name] as? Int ?: defaultValue
    open fun getLongExtra(name: String?, defaultValue: Long): Long = extras[name] as? Long ?: defaultValue
    open fun getBooleanExtra(name: String?, defaultValue: Boolean): Boolean = extras[name] as? Boolean ?: defaultValue

    private fun put(name: String?, value: Any?): Intent = apply { if (name != null) extras[name] = value }

    companion object {
        const val ACTION_VIEW = "android.intent.action.VIEW"
        const val ACTION_SEND = "android.intent.action.SEND"
        const val ACTION_MAIN = "android.intent.action.MAIN"
        const val ACTION_CHOOSER = "android.intent.action.CHOOSER"
        const val CATEGORY_BROWSABLE = "android.intent.category.BROWSABLE"
        const val CATEGORY_DEFAULT = "android.intent.category.DEFAULT"
        const val EXTRA_TEXT = "android.intent.extra.TEXT"
        const val EXTRA_TITLE = "android.intent.extra.TITLE"
        const val EXTRA_INTENT = "android.intent.extra.INTENT"
        const val FLAG_ACTIVITY_NEW_TASK = 0x10000000
        const val FLAG_ACTIVITY_CLEAR_TOP = 0x04000000
        const val FLAG_GRANT_READ_URI_PERMISSION = 0x00000001

        @JvmStatic fun createChooser(target: Intent?, title: CharSequence?): Intent =
            Intent(ACTION_CHOOSER).putExtra(EXTRA_TITLE, title).also { chooser -> target?.let { chooser.extras[EXTRA_INTENT] = it } }
    }
}
