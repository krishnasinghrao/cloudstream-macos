package com.lagradost.macos

import kotlinx.serialization.Serializable
import org.objectweb.asm.ClassReader
import org.objectweb.asm.ClassVisitor
import org.objectweb.asm.Opcodes
import org.objectweb.asm.commons.ClassRemapper
import org.objectweb.asm.commons.Remapper
import java.io.ByteArrayInputStream
import java.util.zip.ZipInputStream

/**
 * The Android/CloudStream API surface this engine provides (plan RT-05). Bump
 * [VERSION] whenever host compatibility types are added or change, so stored
 * assessments are recognizably stale.
 */
object RuntimeProfile {
    const val VERSION = "cloudstream-macos-runtime-5"

    // 2: android.os Handler/Looper/Message/SystemClock/Bundle and android.text.TextUtils (RT-14).
    // 3: Android resources (RT-13), app types (Event, MainActivity, PluginManager, CommonActivity,
    //    AniListApi, ActivityManager, ContextWrapper), the app's bundled libraries (Gson, fuzzywuzzy,
    //    juniversalchardet, kotlinx-collections-immutable); every unresolved reference is assessed.
    // 4: android.webkit types (inert WebView: configuration accepted, evaluateJavascript fails by name).
    // 5: Android's own org.json (AOSP) instead of JSON-java; Intent, Context.startActivity, Toast,
    //    android.preference and androidx.preference PreferenceManager (A1, A2).

    /** The JDK: always present, never assessed. */
    internal val PLATFORM_PACKAGES = listOf("java/", "javax/", "jdk/", "sun/")

    /** Annotation-only packages: the JVM ignores missing annotation types, so they never break an extension. */
    internal val ANNOTATION_PACKAGES = listOf("com/android/tools/r8/annotations/", "android/annotation/", "androidx/annotation/", "dalvik/annotation/")
}

/**
 * Static compatibility evidence for one translated extension: host types it
 * references that this engine does not provide. Evidence, not proof — JVM class
 * loading is lazy, so a missing type in code that never runs (e.g. an Android
 * settings screen) is harmless, while one on a startup path is fatal.
 */
@Serializable
data class CapabilityReport(
    val profile: String = RuntimeProfile.VERSION,
    /** Missing host types, most important first. */
    val missing: List<MissingHostType> = emptyList(),
    /** More missing types exist than are listed. */
    val truncated: Boolean = false,
)

@Serializable
data class MissingHostType(
    /** Internal name, e.g. `android/webkit/WebView`. */
    val type: String,
    /** `startup` (plugin entry class), `provider` (a MainAPI/extractor class) or `other`. */
    val role: String,
    /** A few referencing extension classes. */
    val referencedBy: List<String>,
)

internal object CompatibilityAssessment {
    private const val MAX_CLASSES = 20_000
    private const val MAX_REPORTED = 64
    private val PROVIDER_BASES = setOf("com/lagradost/cloudstream3/MainAPI", "com/lagradost/cloudstream3/utils/ExtractorApi")

    /**
     * Scans translated JARs. [pluginClass] is the manifest entry class (dotted
     * name). [hostHas] answers whether the host provides an internal type name.
     */
    fun assess(jars: List<ByteArray>, pluginClass: String?, hostHas: (String) -> Boolean = ::hostProvides,
        hostMember: (owner: String, name: String, descriptor: String, field: Boolean) -> Boolean = ::hostMemberExists): CapabilityReport {
        val defined = HashSet<String>()
        val supers = HashMap<String, String?>()
        val references = HashMap<String, MutableSet<String>>() // host type -> referencing classes
        // Members of host types the extension calls or reads (A3): owner.name+descriptor -> referencing classes.
        val members = HashMap<MemberRef, MutableSet<String>>()
        var scanned = 0
        for (jar in jars) {
            ZipInputStream(ByteArrayInputStream(jar)).use { zip ->
                while (true) {
                    val entry = zip.nextEntry ?: break
                    if (!entry.name.endsWith(".class")) continue
                    require(++scanned <= MAX_CLASSES) { "Extension has too many classes to assess" }
                    val reader = ClassReader(zip.readBytes())
                    val owner = reader.className
                    defined += owner
                    supers[owner] = reader.superName
                    val recorder = object : Remapper(Opcodes.ASM9) {
                        override fun map(internalName: String): String {
                            // Anything not from the JDK must come from the extension or the host;
                            // checking every package catches host libraries the Android app ships.
                            if ((RuntimeProfile.PLATFORM_PACKAGES + RuntimeProfile.ANNOTATION_PACKAGES).none { internalName.startsWith(it) } &&
                                !internalName.startsWith("[")) {
                                references.getOrPut(internalName) { linkedSetOf() }.add(owner)
                            }
                            return internalName
                        }
                    }
                    // One pass: the remapper records every referenced type and hands the
                    // (unchanged) instructions on to the member collector.
                    reader.accept(ClassRemapper(memberCollector(owner, members), recorder), ClassReader.SKIP_FRAMES)
                }
            }
        }
        val entry = pluginClass?.replace('.', '/')
        fun isProvider(name: String): Boolean {
            var current: String? = name
            var hops = 0
            while (current != null && hops++ < 32) {
                if (current in PROVIDER_BASES) return true
                current = supers[current]
            }
            return false
        }
        fun role(referrers: Set<String>): String = when {
            entry != null && referrers.any { it == entry || it.startsWith("$entry$") } -> "startup"
            referrers.any { isProvider(it.substringBefore('$')) || isProvider(it) } -> "provider"
            else -> "other"
        }
        val rank = mapOf("startup" to 0, "provider" to 1, "other" to 2)
        val missingTypes = references.filterKeys { it !in defined && !hostHas(it) }
        val missingMembers = members.filterKeys { ref ->
            // Only members of types the host provides: a missing type is already reported above.
            ref.owner !in defined && ref.owner !in missingTypes && hostHas(ref.owner) &&
                !hostMember(ref.owner, ref.name, ref.descriptor, ref.isField)
        }.entries.take(MAX_MEMBER_CHECKS).associate { (ref, referrers) -> ref.label to referrers }
        val missing = (missingTypes + missingMembers)
            .map { (type, referrers) -> MissingHostType(type, role(referrers), referrers.sorted().take(3)) }
            .sortedWith(compareBy({ rank[it.role] }, { it.type }))
        return CapabilityReport(missing = missing.take(MAX_REPORTED), truncated = missing.size > MAX_REPORTED)
    }

    /**
     * Host types whose use from start-up or provider code means the extension
     * cannot work on a Mac at all (X3). Said at install, before any of its
     * code runs, instead of failing later with a missing-class error.
     */
    private val IMPOSSIBLE = listOf(
        "dalvik/system/" to "This extension loads Android app packages (APK files) while it runs, which can't work on a Mac.",
        "com/lagradost/cloudstream3/plugins/RepositoryManager" to
            "This extension manages CloudStream's repositories itself, which the Mac app doesn't allow. Add the repositories you want in Settings ▸ Extensions instead.",
    )

    fun impossibleReason(report: CapabilityReport): String? = report.missing.asSequence()
        .filter { it.role != "other" }
        .firstNotNullOfOrNull { missing -> IMPOSSIBLE.firstOrNull { missing.type.startsWith(it.first) }?.second }

    /** True when the translated code constructs [internalName] somewhere (e.g. an embedded Android WebView). */
    fun constructs(jars: List<ByteArray>, internalName: String): Boolean {
        var found = false
        for (jar in jars) {
            ZipInputStream(ByteArrayInputStream(jar)).use { zip ->
                while (!found) {
                    val entry = zip.nextEntry ?: break
                    if (!entry.name.endsWith(".class")) continue
                    ClassReader(zip.readBytes()).accept(object : ClassVisitor(Opcodes.ASM9) {
                        override fun visitMethod(access: Int, name: String?, descriptor: String?, signature: String?, exceptions: Array<out String>?) =
                            object : org.objectweb.asm.MethodVisitor(Opcodes.ASM9) {
                                override fun visitTypeInsn(opcode: Int, type: String?) {
                                    if (opcode == Opcodes.NEW && type == internalName) found = true
                                }
                            }
                    }, ClassReader.SKIP_DEBUG or ClassReader.SKIP_FRAMES)
                }
            }
        }
        return found
    }

    /** A member reference; [label] is how it is reported (`owner.name descriptor`). */
    private data class MemberRef(val owner: String, val name: String, val descriptor: String, val isField: Boolean) {
        val label: String get() = "$owner.$name${if (isField) ":" else ""}$descriptor"
    }

    private const val MAX_MEMBER_CHECKS = 4_096

    /**
     * Records member references for [assess]. Returning visitors for every
     * method and field is also what makes the [ClassRemapper] in front of it
     * walk their bodies and attributes, where the remaining type references are.
     */
    private fun memberCollector(owner: String, into: HashMap<MemberRef, MutableSet<String>>) = object : ClassVisitor(Opcodes.ASM9) {
        override fun visitField(access: Int, name: String?, descriptor: String?, signature: String?, value: Any?) =
            object : org.objectweb.asm.FieldVisitor(Opcodes.ASM9) {}
        override fun visitMethod(access: Int, name: String?, descriptor: String?, signature: String?, exceptions: Array<out String>?) =
            object : org.objectweb.asm.MethodVisitor(Opcodes.ASM9) {
                private fun record(type: String, member: String, desc: String, field: Boolean) {
                    // JDK members are always present; arrays have no declared members.
                    if (type.startsWith("[") || RuntimeProfile.PLATFORM_PACKAGES.any { type.startsWith(it) }) return
                    if (into.size >= MAX_MEMBER_CHECKS) return
                    into.getOrPut(MemberRef(type, member, desc, field)) { linkedSetOf() }.add(owner)
                }
                override fun visitMethodInsn(opcode: Int, type: String, member: String, desc: String, isInterface: Boolean) =
                    record(type, member, desc, false)
                override fun visitFieldInsn(opcode: Int, type: String, member: String, desc: String) = record(type, member, desc, true)
            }
    }

    private val hostMembers = java.util.concurrent.ConcurrentHashMap<String, Pair<Set<String>, List<String>>?>()

    /** Declared members of a host class and its direct supertypes, read from class bytes (never initialized). */
    private fun hostDeclarations(type: String): Pair<Set<String>, List<String>>? = hostMembers.computeIfAbsent(type) {
        val bytes = hostLoader.getResourceAsStream("$type.class")?.use { it.readBytes() } ?: return@computeIfAbsent null
        val declared = HashSet<String>()
        val parents = ArrayList<String>()
        ClassReader(bytes).accept(object : ClassVisitor(Opcodes.ASM9) {
            override fun visit(version: Int, access: Int, name: String?, signature: String?, superName: String?, interfaces: Array<out String>?) {
                superName?.let(parents::add); interfaces?.let { parents += it }
            }
            override fun visitMethod(access: Int, name: String, descriptor: String, signature: String?, exceptions: Array<out String>?): org.objectweb.asm.MethodVisitor? {
                declared += "m$name$descriptor"; return null
            }
            override fun visitField(access: Int, name: String, descriptor: String, signature: String?, value: Any?): org.objectweb.asm.FieldVisitor? {
                declared += "f$name$descriptor"; return null
            }
        }, ClassReader.SKIP_CODE)
        declared to parents
    }

    /**
     * Whether [owner] (or a supertype, as the JVM resolves it) declares the
     * member. Signature-polymorphic and unreadable cases count as present:
     * this is evidence for the user, so it must not invent gaps.
     */
    fun hostMemberExists(owner: String, name: String, descriptor: String, field: Boolean): Boolean {
        val key = (if (field) "f" else "m") + name + descriptor
        val seen = HashSet<String>()
        val queue = ArrayDeque(listOf(owner))
        while (queue.isNotEmpty() && seen.size < 64) {
            val type = queue.removeFirst()
            if (!seen.add(type)) continue
            val (declared, parents) = hostDeclarations(type) ?: return true
            if (key in declared) return true
            queue += parents
        }
        return false
    }

    private val hostLoader = CompatibilityAssessment::class.java.classLoader

    /** Resource lookup: never initializes (or runs) any class. */
    fun hostProvides(internalName: String): Boolean = hostLoader.getResource("$internalName.class") != null
}
