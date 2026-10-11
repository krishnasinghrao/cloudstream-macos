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
 */
internal object HostAbiAdapter {
    private const val MAX_BYTES = 64 * 1024 * 1024
    private data class Method(val name: String, val descriptor: String, val static: Boolean)
    private data class Symbols(val methods: List<Method>, val parents: List<String>)
    private val symbols = ConcurrentHashMap<String, Symbols>()
    private val hostLoader = HostAbiAdapter::class.java.classLoader

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

    private fun methods(owner: String, visited: MutableSet<String>): List<Method> {
        if (!visited.add(owner)) return emptyList()
        val info = symbols.computeIfAbsent(owner) {
            val methods = mutableListOf<Method>()
            val parents = mutableListOf<String>()
            hostLoader.getResourceAsStream("$owner.class")?.use { stream ->
                ClassReader(stream).accept(object : ClassVisitor(Opcodes.ASM9) {
                    override fun visit(version: Int, access: Int, name: String, signature: String?, superName: String?, interfaces: Array<out String>?) {
                        superName?.let(parents::add)
                        interfaces?.let(parents::addAll)
                    }
                    override fun visitMethod(access: Int, name: String, descriptor: String, signature: String?, exceptions: Array<out String>?): MethodVisitor? {
                        if (access and (Opcodes.ACC_PUBLIC or Opcodes.ACC_PROTECTED) != 0) {
                            methods.add(Method(name, descriptor, access and Opcodes.ACC_STATIC != 0))
                        }
                        return null
                    }
                }, ClassReader.SKIP_CODE or ClassReader.SKIP_DEBUG or ClassReader.SKIP_FRAMES)
            }
            Symbols(methods, parents)
        }
        return info.methods + info.parents.flatMap { methods(it, visited) }
    }
}
