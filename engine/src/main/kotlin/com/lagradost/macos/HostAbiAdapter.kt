package com.lagradost.macos

import org.objectweb.asm.ClassReader
import org.objectweb.asm.ClassVisitor
import org.objectweb.asm.ClassWriter
import org.objectweb.asm.ConstantDynamic
import org.objectweb.asm.Handle
import org.objectweb.asm.MethodVisitor
import org.objectweb.asm.Opcodes
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

/**
 * Android DEX/dex2jar sanitizes Kotlin JVM member names such as constructor-impl.
 * Resolve against trusted host definitions without initializing either host or
 * extension classes. Only an exact, unambiguous descriptor/kind match is adapted.
 *
 * Extensions built with the Compose compiler read the `$stable` stability mask
 * of every host superclass (`Plugin.$stable`, `MainAPI.$stable`) in their own
 * static initializer. Upstream's library is compiled with Compose and declares
 * those fields; this host is not, so the read failed with NoSuchFieldError and
 * the extension could not load. A read of a `$stable` the host class lacks is
 * replaced by 0, the mask Compose itself assigns a stable class: only the
 * extension's own Compose recomposition hints depend on it.
 */
internal object HostAbiAdapter {
    private const val MAX_BYTES = 64 * 1024 * 1024
    private data class Method(val name: String, val descriptor: String, val static: Boolean)
    private data class Symbols(val methods: List<Method>, val parents: List<String>, val fields: Set<String>, val host: Boolean)
    private val symbols = ConcurrentHashMap<String, Symbols>()
    private val hostLoader = HostAbiAdapter::class.java.classLoader
    private const val COMPOSE_STABILITY = "\$stable"

    fun adaptJar(input: ByteArray): ByteArray {
        require(input.size <= MAX_BYTES) { "Translated archive exceeds byte limit" }
        val entries = linkedMapOf<String, ByteArray>()
        var expanded = 0
        ZipInputStream(ByteArrayInputStream(input)).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: break
                if (entry.isDirectory) continue
                val body = zip.readNBytes(MAX_BYTES + 1)
                require(body.size <= MAX_BYTES - expanded) { "Translated archive expands beyond byte limit" }
                expanded += body.size
                require(entries.put(entry.name, body) == null) { "Duplicate translated entry" }
            }
        }
        // Resolve only symbols present in the trusted parent loader. A plugin's
        // duplicate host class cannot override parent-first resolution; purely
        // plugin-owned value classes have no host symbols and stay consistent.
        val output = ByteArrayOutputStream(input.size)
        ZipOutputStream(output).use { zip ->
            entries.forEach { (name, body) ->
                zip.putNextEntry(ZipEntry(name))
                zip.write(if (name.endsWith(".class")) adaptClass(body) else body)
                zip.closeEntry()
            }
        }
        return output.toByteArray()
    }

    internal fun adaptClass(input: ByteArray): ByteArray {
        val reader = ClassReader(input)
        val writer = ClassWriter(reader, 0)
        fun member(owner: String, name: String, descriptor: String, static: Boolean): String {
            if ('_' !in name) return name
            val methods = methods(owner, hashSetOf())
            if (methods.any { it.name == name && it.descriptor == descriptor && it.static == static }) return name
            val candidates = methods.filter {
                '-' in it.name && it.name.replace('-', '_') == name && it.descriptor == descriptor && it.static == static
            }.map { it.name }.distinct()
            check(candidates.size <= 1) { "Ambiguous host ABI: $owner.$name$descriptor" }
            return candidates.singleOrNull() ?: name
        }
        fun handle(value: Handle): Handle {
            if (value.tag !in Opcodes.H_INVOKEVIRTUAL..Opcodes.H_INVOKEINTERFACE) return value
            val name = member(value.owner, value.name, value.desc, value.tag == Opcodes.H_INVOKESTATIC)
            return if (name == value.name) value else Handle(value.tag, value.owner, name, value.desc, value.isInterface)
        }
        fun constant(value: Any?): Any? = when (value) {
            is Handle -> handle(value)
            is ConstantDynamic -> ConstantDynamic(value.name, value.descriptor, handle(value.bootstrapMethod),
                *Array(value.bootstrapMethodArgumentCount) { constant(value.getBootstrapMethodArgument(it)) })
            else -> value
        }
        reader.accept(object : ClassVisitor(Opcodes.ASM9, writer) {
            override fun visitMethod(access: Int, name: String, descriptor: String, signature: String?, exceptions: Array<out String>?): MethodVisitor {
                val delegate = super.visitMethod(access, name, descriptor, signature, exceptions)
                return object : MethodVisitor(Opcodes.ASM9, delegate) {
                    override fun visitFieldInsn(opcode: Int, owner: String, name: String, descriptor: String) {
                        // Same stack effect (pushes one int): maxs and frames stay valid.
                        if (opcode == Opcodes.GETSTATIC && name == COMPOSE_STABILITY && descriptor == "I" && missingHostField(owner, name)) {
                            super.visitInsn(Opcodes.ICONST_0)
                        } else super.visitFieldInsn(opcode, owner, name, descriptor)
                    }
                    override fun visitMethodInsn(opcode: Int, owner: String, name: String, descriptor: String, isInterface: Boolean) {
                        super.visitMethodInsn(opcode, owner, member(owner, name, descriptor, opcode == Opcodes.INVOKESTATIC), descriptor, isInterface)
                    }
                    override fun visitLdcInsn(value: Any?) { super.visitLdcInsn(constant(value)) }
                    override fun visitInvokeDynamicInsn(name: String, descriptor: String, bootstrapMethodHandle: Handle, vararg bootstrapMethodArguments: Any) {
                        super.visitInvokeDynamicInsn(name, descriptor, handle(bootstrapMethodHandle), *bootstrapMethodArguments.map(::constant).toTypedArray())
                    }
                }
            }
        }, 0)
        return writer.toByteArray()
    }

    /** True when [owner] is a host class and neither it nor a host supertype declares field [name]. */
    private fun missingHostField(owner: String, name: String): Boolean {
        if (!symbols(owner).host) return false
        fun declares(type: String, visited: MutableSet<String>): Boolean {
            if (!visited.add(type)) return false
            val info = symbols(type)
            return name in info.fields || info.parents.any { declares(it, visited) }
        }
        return !declares(owner, hashSetOf())
    }

    private fun methods(owner: String, visited: MutableSet<String>): List<Method> {
        if (!visited.add(owner)) return emptyList()
        val info = symbols(owner)
        return info.methods + info.parents.flatMap { methods(it, visited) }
    }

    private fun symbols(owner: String): Symbols = symbols.computeIfAbsent(owner) {
        val methods = mutableListOf<Method>()
        val parents = mutableListOf<String>()
        val fields = hashSetOf<String>()
        val stream = hostLoader.getResourceAsStream("$owner.class")
        stream?.use { input ->
            ClassReader(input).accept(object : ClassVisitor(Opcodes.ASM9) {
                override fun visit(version: Int, access: Int, name: String, signature: String?, superName: String?, interfaces: Array<out String>?) {
                    superName?.let(parents::add)
                    interfaces?.let(parents::addAll)
                }
                override fun visitField(access: Int, name: String, descriptor: String, signature: String?, value: Any?): org.objectweb.asm.FieldVisitor? {
                    fields.add(name)
                    return null
                }
                override fun visitMethod(access: Int, name: String, descriptor: String, signature: String?, exceptions: Array<out String>?): MethodVisitor? {
                    if (access and (Opcodes.ACC_PUBLIC or Opcodes.ACC_PROTECTED) != 0) {
                        methods.add(Method(name, descriptor, access and Opcodes.ACC_STATIC != 0))
                    }
                    return null
                }
            }, ClassReader.SKIP_CODE or ClassReader.SKIP_DEBUG or ClassReader.SKIP_FRAMES)
        }
        Symbols(methods, parents, fields, host = stream != null)
    }
}
