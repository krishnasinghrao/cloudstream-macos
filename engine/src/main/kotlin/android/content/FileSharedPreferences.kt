package android.content

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Durable SharedPreferences with Android editor semantics: removals and clear
 * are applied before puts, commit publishes atomically to a private file, and
 * one instance per file is shared across getSharedPreferences calls.
 */
internal class FileSharedPreferences private constructor(private val file: File) : SharedPreferences {
    private val lock = Any()
    private var values: Map<String, Any> = load()
    private val listeners = CopyOnWriteArrayList<SharedPreferences.OnSharedPreferenceChangeListener>()

    override fun getAll(): MutableMap<String, *> = synchronized(lock) { HashMap(values) }
    override fun getString(key: String?, defValue: String?): String? = get(key) as? String ?: defValue
    @Suppress("UNCHECKED_CAST")
    override fun getStringSet(key: String?, defValues: MutableSet<String>?): MutableSet<String>? =
        (get(key) as? Set<String>)?.toMutableSet() ?: defValues
    override fun getInt(key: String?, defValue: Int): Int = (get(key) as? Number)?.toInt() ?: defValue
    override fun getLong(key: String?, defValue: Long): Long = (get(key) as? Number)?.toLong() ?: defValue
    override fun getFloat(key: String?, defValue: Float): Float = (get(key) as? Number)?.toFloat() ?: defValue
    override fun getBoolean(key: String?, defValue: Boolean): Boolean = get(key) as? Boolean ?: defValue
    override fun contains(key: String?): Boolean = synchronized(lock) { key != null && key in values }
    override fun edit(): SharedPreferences.Editor = EditorImpl()
    override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) {
        listener?.let(listeners::addIfAbsent)
    }
    override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) {
        listeners.remove(listener)
    }

    private fun get(key: String?): Any? = synchronized(lock) {
        // Which keys the extension reads from this file (RT-15): lets native settings store a key where it is read.
        if (key != null && observed.size < MAX_OBSERVED) observed.add(key)
        key?.let { values[it] }
    }

    private val observed = HashSet<String>()

    /** The file's name as passed to getSharedPreferences. */
    val name: String get() = file.nameWithoutExtension

    /** Keys read from this file since the process started. */
    fun observedKeys(): Set<String> = synchronized(lock) { observed.toSet() }

    /** The stored value of [key], without recording a read. */
    fun peek(key: String): Any? = synchronized(lock) { values[key] }

    private inner class EditorImpl : SharedPreferences.Editor {
        private val puts = LinkedHashMap<String, Any?>()
        private var clear = false
        @Synchronized private fun put(key: String?, value: Any?) = apply { if (key != null) puts[key] = value }
        override fun putString(key: String?, value: String?) = put(key, value)
        override fun putStringSet(key: String?, values: MutableSet<String>?) = put(key, values?.toSet())
        override fun putInt(key: String?, value: Int) = put(key, value)
        override fun putLong(key: String?, value: Long) = put(key, value)
        override fun putFloat(key: String?, value: Float) = put(key, value)
        override fun putBoolean(key: String?, value: Boolean) = put(key, value)
        override fun remove(key: String?) = put(key, REMOVED)
        @Synchronized override fun clear() = apply { clear = true }

        override fun commit(): Boolean {
            val changed = mutableListOf<String?>()
            synchronized(lock) {
                val next = if (clear) HashMap() else HashMap(values)
                if (clear && values.isNotEmpty()) changed += null
                synchronized(this) {
                    for ((key, value) in puts) {
                        if (value == null || value === REMOVED) next.remove(key) else next[key] = value
                        changed += key
                    }
                }
                try { persist(next) } catch (_: Exception) { return false }
                values = next
            }
            changed.forEach { key -> listeners.forEach { runCatching { it.onSharedPreferenceChanged(this@FileSharedPreferences, key) } } }
            return true
        }

        override fun apply() { commit() }
    }

    private fun persist(map: Map<String, Any>) {
        val encoded = JsonObject(map.mapValues { (_, value) -> encode(value) }).toString().toByteArray(Charsets.UTF_8)
        require(encoded.size <= MAX_BYTES) { "Preferences exceed size limit" }
        com.lagradost.macos.AtomicFiles.write(file.toPath(), encoded)
    }

    private fun load(): Map<String, Any> = try {
        if (!file.isFile) emptyMap() else {
            val root = kotlinx.serialization.json.Json.parseToJsonElement(file.readText()).jsonObject
            root.mapNotNull { (key, value) -> decode(value)?.let { key to it } }.toMap()
        }
    } catch (_: Exception) { emptyMap() }

    private fun encode(value: Any): JsonElement = when (value) {
        is String -> JsonObject(mapOf("s" to JsonPrimitive(value)))
        is Boolean -> JsonObject(mapOf("b" to JsonPrimitive(value)))
        is Int -> JsonObject(mapOf("i" to JsonPrimitive(value)))
        is Long -> JsonObject(mapOf("l" to JsonPrimitive(value)))
        is Float -> JsonObject(mapOf("f" to JsonPrimitive(value)))
        is Set<*> -> JsonObject(mapOf("set" to JsonArray(value.map { JsonPrimitive(it as String) })))
        else -> error("Unsupported preference type")
    }

    private fun decode(element: JsonElement): Any? {
        val (type, value) = element.jsonObject.entries.singleOrNull() ?: return null
        return when (type) {
            "s" -> value.jsonPrimitive.content
            "b" -> value.jsonPrimitive.booleanOrNull
            "i" -> value.jsonPrimitive.longOrNull?.toInt()
            "l" -> value.jsonPrimitive.longOrNull
            "f" -> value.jsonPrimitive.doubleOrNull?.toFloat()
            "set" -> value.jsonArray.map { it.jsonPrimitive.content }.toSet()
            else -> null
        }
    }

    companion object {
        private val REMOVED = Any()
        private const val MAX_BYTES = 4 * 1024 * 1024
        private const val MAX_OBSERVED = 2_000

        /** Stores opened under [directory] in this process. */
        fun openedUnder(directory: File): List<FileSharedPreferences> {
            val prefix = directory.canonicalPath + File.separator
            return instances.filterKeys { it.startsWith(prefix) }.values.toList()
        }
        private val instances = ConcurrentHashMap<String, FileSharedPreferences>()

        fun forFile(file: File): FileSharedPreferences = instances.computeIfAbsent(file.canonicalPath) { FileSharedPreferences(file) }

        /** Forgets cached stores under [directory] (its files are being deleted), so
         * a later reinstall starts empty instead of resurrecting old values. */
        fun evictUnder(directory: File) {
            val prefix = directory.canonicalPath + File.separator
            instances.keys.removeIf { it.startsWith(prefix) }
        }
    }
}
