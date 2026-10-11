package com.lagradost.macos

import org.junit.Assume.assumeTrue
import org.objectweb.asm.ClassReader
import org.objectweb.asm.ClassVisitor
import org.objectweb.asm.FieldVisitor
import org.objectweb.asm.MethodVisitor
import org.objectweb.asm.Opcodes
import java.io.File
import java.util.zip.ZipFile
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Extensions link against Android by exact JVM descriptor. For every engine
 * class under `android/` that Android API 35 also defines, each public member
 * whose name Android also declares must exist with Android's exact descriptor
 * and static-ness. Kotlin-generated helpers and extra constructor overloads
 * (engine-internal construction) are ignored.
 */
class AndroidDescriptorConformanceTest {
    private data class Member(val name: String, val descriptor: String, val static: Boolean)

    private fun members(bytes: ByteArray): Pair<Set<Member>, Set<Member>> {
        val methods = mutableSetOf<Member>()
        val fields = mutableSetOf<Member>()
        ClassReader(bytes).accept(object : ClassVisitor(Opcodes.ASM9) {
            override fun visitMethod(access: Int, name: String, descriptor: String, signature: String?, exceptions: Array<out String>?): MethodVisitor? {
                if (access and (Opcodes.ACC_PUBLIC or Opcodes.ACC_PROTECTED) != 0 && access and Opcodes.ACC_SYNTHETIC == 0)
                    methods += Member(name, descriptor, access and Opcodes.ACC_STATIC != 0)
                return null
            }
            override fun visitField(access: Int, name: String, descriptor: String, signature: String?, value: Any?): FieldVisitor? {
                if (access and (Opcodes.ACC_PUBLIC or Opcodes.ACC_PROTECTED) != 0 && access and Opcodes.ACC_SYNTHETIC == 0)
                    fields += Member(name, descriptor, access and Opcodes.ACC_STATIC != 0)
                return null
            }
        }, ClassReader.SKIP_CODE)
        return methods to fields
    }

    private fun kotlinGenerated(name: String) = '$' in name || name.matches(Regex("component\\d+")) || name in setOf("copy", "INSTANCE", "Companion")

    @Test fun `engine android classes keep Android's exact descriptors`() {
        val sdk = File(System.getProperty("user.home"), "Library/Android/sdk/platforms/android-35/android.jar")
        assumeTrue("Android API 35 SDK required", sdk.isFile)
        val root = File(android.content.Context::class.java.protectionDomain.codeSource.location.toURI())
        assumeTrue("engine classes are a directory in this build", root.isDirectory)
        val ours = File(root, "android").walkTopDown().filter { it.extension == "class" }.toList()
        assertTrue(ours.size > 20, "engine android classes found")
        val problems = mutableListOf<String>()
        var compared = 0
        ZipFile(sdk).use { jar ->
            for (file in ours) {
                val type = file.relativeTo(root).path.removeSuffix(".class")
                val entry = jar.getEntry("$type.class") ?: continue
                compared++
                val (androidMethods, androidFields) = members(jar.getInputStream(entry).readBytes())
                val (myMethods, myFields) = members(file.readBytes())
                for (m in myMethods) {
                    // Engine-internal constructor overloads (e.g. Context(File)) add to Android's set; they cannot break linking.
                    if (kotlinGenerated(m.name) || m.name == "<clinit>" || m.name == "<init>") continue
                    val sameName = androidMethods.filter { it.name == m.name }
                    if (sameName.isNotEmpty() && m !in sameName) problems += "$type.${m.name}${m.descriptor}${if (m.static) " static" else ""}"
                }
                for (f in myFields) {
                    if (kotlinGenerated(f.name)) continue
                    val android = androidFields.firstOrNull { it.name == f.name } ?: continue
                    if (android != f) problems += "$type.${f.name}:${f.descriptor}${if (f.static) " static" else ""}"
                }
            }
        }
        assertTrue(compared > 20, "classes compared against android.jar: $compared")
        assertEquals(emptyList(), problems, "members whose descriptor differs from Android API 35")
    }
}
