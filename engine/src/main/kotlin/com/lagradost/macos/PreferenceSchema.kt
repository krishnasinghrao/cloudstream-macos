package com.lagradost.macos

import kotlinx.serialization.Serializable
import org.objectweb.asm.ClassReader
import org.objectweb.asm.ClassVisitor
import org.objectweb.asm.Handle
import org.objectweb.asm.Label
import org.objectweb.asm.MethodVisitor
import org.objectweb.asm.Opcodes
import java.io.ByteArrayInputStream
import java.util.zip.ZipInputStream

/** One preference an extension reads or writes: its own key, the type of the API it uses, and its constant default. */
@Serializable
data class PreferenceField(
    val key: String,
    /** `string`, `boolean`, `int`, `long`, `float` or `string_set`. */
    val type: String,
    /** The default the extension passes when reading, when it is a constant. */
    val default: String? = null,
)

/**
 * The settings an extension keeps in Android SharedPreferences (plan RT-15),
 * derived from its translated bytecode without running it: every call to a
 * typed `SharedPreferences`/`Editor` method with a constant key. Keys and
 * types are the extension's own — nothing is guessed — so the Mac app can
 * offer a native, typed editor where the extension only ships Android UI.
 */
@Serializable
data class PreferenceSchema(
    /** Preferences files the extension opens by constant name (which key lives in which file is learned when it runs). */
    val files: List<String> = emptyList(),
    val fields: List<PreferenceField> = emptyList(),
    /** More fields exist than are listed. */
    val truncated: Boolean = false,
)

internal object PreferenceSchemaScanner {
    const val MAX_FIELDS = 200
    const val MAX_FILES = 8
    private const val MAX_KEY = 128
    private const val MAX_DEFAULT = 512
    private const val PREFS = "android/content/SharedPreferences"
    private const val EDITOR = "android/content/SharedPreferences\$Editor"

    private val getters = mapOf("getString" to "string", "getBoolean" to "boolean", "getInt" to "int", "getLong" to "long",
        "getFloat" to "float", "getStringSet" to "string_set")
    private val putters = mapOf("putString" to "string", "putBoolean" to "boolean", "putInt" to "int", "putLong" to "long",
        "putFloat" to "float", "putStringSet" to "string_set")

    /** Scans translated JARs. Never loads or runs extension classes. */
    fun scan(jars: List<ByteArray>): PreferenceSchema {
        val fields = LinkedHashMap<String, PreferenceField>()
        val files = LinkedHashSet<String>()
        var classes = 0
        for (jar in jars) {
            ZipInputStream(ByteArrayInputStream(jar)).use { zip ->
                while (true) {
                    val entry = zip.nextEntry ?: break
                    if (!entry.name.endsWith(".class") || ++classes > 20_000) continue
                    ClassReader(zip.readBytes()).accept(object : ClassVisitor(Opcodes.ASM9) {
                        override fun visitMethod(access: Int, name: String?, descriptor: String?, signature: String?, exceptions: Array<out String>?) =
                            Recorder(fields, files)
                    }, ClassReader.SKIP_DEBUG or ClassReader.SKIP_FRAMES)
                }
            }
        }
        val listed = fields.values.sortedBy { it.key }
        return PreferenceSchema(files.take(MAX_FILES), listed.take(MAX_FIELDS), listed.size > MAX_FIELDS)
    }

    /**
     * Tracks the constants pushed immediately before a call. Any other
     * instruction clears them, so only `…, LDC key[, constant default], INVOKE`
     * sequences are recognised — a key computed at runtime is never reported.
     */
    private class Recorder(private val fields: MutableMap<String, PreferenceField>, private val files: MutableSet<String>) : MethodVisitor(Opcodes.ASM9) {
        private val constants = ArrayList<Any?>()

        private fun push(value: Any?) { constants += value; if (constants.size > 4) constants.removeAt(0) }

        override fun visitLdcInsn(value: Any?) = push(value)
        override fun visitIntInsn(opcode: Int, operand: Int) = if (opcode == Opcodes.BIPUSH || opcode == Opcodes.SIPUSH) push(operand) else constants.clear()
        override fun visitInsn(opcode: Int) = when (opcode) {
            in Opcodes.ICONST_M1..Opcodes.ICONST_5 -> push(opcode - Opcodes.ICONST_0)
            Opcodes.LCONST_0, Opcodes.LCONST_1 -> push((opcode - Opcodes.LCONST_0).toLong())
            Opcodes.FCONST_0, Opcodes.FCONST_1, Opcodes.FCONST_2 -> push((opcode - Opcodes.FCONST_0).toFloat())
            Opcodes.ACONST_NULL -> push(null)
            else -> constants.clear()
        }

        override fun visitMethodInsn(opcode: Int, owner: String, name: String, descriptor: String, isInterface: Boolean) {
            when {
                owner == PREFS && name in getters && constants.size >= 2 ->
                    record(constants[constants.size - 2], getters.getValue(name), constants.last())
                owner == EDITOR && name in putters && constants.size >= 2 && constants[constants.size - 2] is String ->
                    record(constants[constants.size - 2], putters.getValue(name), null) // the value written is not a default
                owner == EDITOR && name in putters && constants.isNotEmpty() -> record(constants.last(), putters.getValue(name), null)
                name == "getSharedPreferences" && descriptor == "(Ljava/lang/String;I)Landroid/content/SharedPreferences;" && constants.size >= 2 ->
                    (constants[constants.size - 2] as? String)?.takeIf { it.matches(FILE) }?.let(files::add)
            }
            constants.clear()
        }

        private fun record(key: Any?, type: String, default: Any?) {
            val name = (key as? String)?.takeIf { it.isNotEmpty() && it.length <= MAX_KEY && it.none { c -> c < ' ' } } ?: return
            val constant = when {
                default == null || type == "string_set" -> null
                type == "boolean" -> ((default as? Int) == 1).toString()
                else -> default.toString().take(MAX_DEFAULT)
            }
            val existing = fields[name]
            // A read tells the type and default; keep the first reader and fill a missing default later.
            if (existing == null) fields[name] = PreferenceField(name, type, constant)
            else if (existing.default == null && constant != null && existing.type == type) fields[name] = existing.copy(default = constant)
        }

        override fun visitVarInsn(opcode: Int, varIndex: Int) = constants.clear()
        override fun visitTypeInsn(opcode: Int, type: String?) = constants.clear()
        override fun visitFieldInsn(opcode: Int, owner: String?, name: String?, descriptor: String?) = constants.clear()
        override fun visitInvokeDynamicInsn(name: String?, descriptor: String?, handle: Handle?, vararg args: Any?) = constants.clear()
        override fun visitJumpInsn(opcode: Int, label: Label?) = constants.clear()
        override fun visitLabel(label: Label?) = constants.clear()
        override fun visitIincInsn(varIndex: Int, increment: Int) = constants.clear()
        override fun visitTableSwitchInsn(min: Int, max: Int, dflt: Label?, vararg labels: Label?) = constants.clear()
        override fun visitLookupSwitchInsn(dflt: Label?, keys: IntArray?, labels: Array<out Label>?) = constants.clear()
        override fun visitMultiANewArrayInsn(descriptor: String?, numDimensions: Int) = constants.clear()

        private companion object { val FILE = Regex("[A-Za-z0-9._-]{1,64}") }
    }
}

/** One setting as shown to the user: the extension's key and type, its default, and what is stored now. */
@Serializable
data class ExtensionPreferenceDto(
    val key: String,
    val type: String,
    val default: String? = null,
    /** Stored scalar value as text; null when unset. */
    val value: String? = null,
    /** Stored value of a `string_set`. */
    val values: List<String>? = null,
    val isSet: Boolean = false,
)

@Serializable
data class ExtensionPreferencesDto(
    val fields: List<ExtensionPreferenceDto> = emptyList(),
    val truncated: Boolean = false,
)

@Serializable
data class ExtensionPreferenceUpdateDto(
    val key: String,
    /** New scalar value as text; ignored for `string_set`. */
    val value: String? = null,
    val values: List<String>? = null,
    /** Remove the stored value so the extension's default applies. */
    val remove: Boolean = false,
)

/**
 * Reads and edits an extension's own preferences (plan RT-15) inside the
 * process that hosts it. Only keys in the extension's [schema] can be
 * touched, each with the type the extension uses for it. A key is stored in
 * the file the extension was seen reading it from; before that, in the files
 * the extension names in its code — all inside its private data directory.
 */
internal class ExtensionPreferenceStore(private val context: android.content.Context, private val directory: java.io.File,
    private val schema: PreferenceSchema) {

    private fun opened(): List<android.content.FileSharedPreferences> = android.content.FileSharedPreferences.openedUnder(directory)

    /** Files to read or write [key] in: where it was read, else where it is stored, else the extension's named files. */
    private fun filesFor(key: String): List<android.content.FileSharedPreferences> {
        val all = opened()
        all.filter { key in it.observedKeys() }.takeIf { it.isNotEmpty() }?.let { return it }
        all.filter { it.peek(key) != null }.takeIf { it.isNotEmpty() }?.let { return it }
        return schema.files.map { context.getSharedPreferences(it, android.content.Context.MODE_PRIVATE) as android.content.FileSharedPreferences }
    }

    fun describe(): ExtensionPreferencesDto {
        // Named files may hold values from an earlier run that this process has not opened yet.
        schema.files.forEach { context.getSharedPreferences(it, android.content.Context.MODE_PRIVATE) }
        return ExtensionPreferencesDto(schema.fields.map { field ->
            val stored = filesFor(field.key).firstNotNullOfOrNull { it.peek(field.key) }
            ExtensionPreferenceDto(field.key, field.type, field.default,
                value = stored?.takeIf { it !is Set<*> }?.toString(),
                values = (stored as? Set<*>)?.map { it.toString() }?.sorted(),
                isSet = stored != null)
        }, schema.truncated)
    }

    /** Applies [updates] atomically per file. Throws [IllegalArgumentException] on an unknown key or a value of the wrong type. */
    fun apply(updates: List<ExtensionPreferenceUpdateDto>) {
        require(updates.size <= PreferenceSchemaScanner.MAX_FIELDS) { "Too many settings in one change" }
        val byKey = schema.fields.associateBy { it.key }
        val edits = LinkedHashMap<android.content.FileSharedPreferences, android.content.SharedPreferences.Editor>()
        for (update in updates) {
            val field = requireNotNull(byKey[update.key]) { "This extension has no setting named '${update.key.take(64)}'" }
            val targets = filesFor(field.key)
            require(targets.isNotEmpty()) { "Use this extension once (search or open its home page) so its settings location is known." }
            for (file in targets) {
                val editor = edits.getOrPut(file) { file.edit() }
                if (update.remove) { editor.remove(field.key); continue }
                when (field.type) {
                    "string" -> editor.putString(field.key, requireNotNull(update.value) { "Missing value" }.also { require(it.length <= MAX_VALUE) { "Value is too long" } })
                    "boolean" -> editor.putBoolean(field.key, when (update.value) { "true" -> true; "false" -> false; else -> throw IllegalArgumentException("'${field.key}' must be true or false") })
                    "int" -> editor.putInt(field.key, update.value?.trim()?.toIntOrNull() ?: throw IllegalArgumentException("'${field.key}' must be a whole number"))
                    "long" -> editor.putLong(field.key, update.value?.trim()?.toLongOrNull() ?: throw IllegalArgumentException("'${field.key}' must be a whole number"))
                    "float" -> editor.putFloat(field.key, update.value?.trim()?.toFloatOrNull()?.takeIf { it.isFinite() } ?: throw IllegalArgumentException("'${field.key}' must be a number"))
                    "string_set" -> editor.putStringSet(field.key, requireNotNull(update.values) { "Missing values" }
                        .also { require(it.size <= 1_000 && it.all { v -> v.length <= MAX_VALUE }) { "Too many or too long values" } }.toMutableSet())
                    else -> throw IllegalArgumentException("Unsupported setting type")
                }
            }
        }
        edits.values.forEach { check(it.commit()) { "Could not save settings" } }
    }

    private companion object { const val MAX_VALUE = 16_384 }
}

/** Control plane: an installed extension's settings, wherever it is hosted. */
internal object ExtensionPreferences {
    private const val TIMEOUT_MS = 60_000L

    private fun loaded(installationId: String) = PluginBridge.loadedInstallation(installationId)
        ?: throw ExtensionException(ExtensionException.Code.UNKNOWN_EXTENSION, "Enable this extension to change its settings.")

    suspend fun describe(installationId: String): ExtensionPreferencesDto {
        val loaded = loaded(installationId)
        val handle = (loaded.plugin as? com.lagradost.macos.worker.WorkerPlugin)?.handle
            ?: return requireNotNull(loaded.preferences).describe()
        return handle.call(com.lagradost.macos.worker.Op.PREFS_GET, kotlinx.serialization.json.JsonNull,
            ExtensionPreferencesDto.serializer(), TIMEOUT_MS)
    }

    /**
     * Saves [updates] and makes them take effect: cached results are dropped and
     * a worker-hosted extension restarts on its next use, since extensions read
     * many settings once at load. Values are never logged; the audit record
     * names the keys only.
     */
    suspend fun update(installationId: String, updates: List<ExtensionPreferenceUpdateDto>, actor: String = "user"): ExtensionPreferencesDto {
        val loaded = loaded(installationId)
        val handle = (loaded.plugin as? com.lagradost.macos.worker.WorkerPlugin)?.handle
        val result = try {
            if (handle == null) requireNotNull(loaded.preferences).let { it.apply(updates); it.describe() }
            else handle.call(com.lagradost.macos.worker.Op.PREFS_SET,
                com.lagradost.macos.worker.FrameCodec.json.encodeToJsonElement(
                    kotlinx.serialization.builtins.ListSerializer(ExtensionPreferenceUpdateDto.serializer()), updates),
                ExtensionPreferencesDto.serializer(), TIMEOUT_MS)
        } catch (failure: com.lagradost.macos.worker.WorkerFailure) {
            // The worker reports rejected values as an error; surface its bounded public message.
            throw IllegalArgumentException(failure.message ?: "Settings were rejected")
        }
        ProviderExecutor.invalidateCaches(installationId)
        handle?.stop()
        AuditLog.record("extension.preferences", mapOf("installation" to installationId, "keys" to updates.map { it.key.take(64) }.sorted()), actor)
        return result
    }
}
