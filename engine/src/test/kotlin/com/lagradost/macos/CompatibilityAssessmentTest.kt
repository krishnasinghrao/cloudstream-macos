package com.lagradost.macos

import kotlinx.coroutines.runBlocking
import org.objectweb.asm.ClassWriter
import org.objectweb.asm.Opcodes
import java.io.ByteArrayOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.test.*

/** Plan RT-05: static host-compatibility evidence, classified by where the missing type is used. */
class CompatibilityAssessmentTest {
    @BeforeTest fun before() = ExtensionTestSupport.resetHome()
    @AfterTest fun after() = ExtensionTestSupport.resetHome()

    /** A class [name] extending [superName] whose one method type-checks against [uses]. */
    private fun classBytes(name: String, superName: String, vararg uses: String): ByteArray {
        val writer = ClassWriter(0)
        writer.visit(Opcodes.V1_8, Opcodes.ACC_PUBLIC, name, null, superName, null)
        val method = writer.visitMethod(Opcodes.ACC_PUBLIC or Opcodes.ACC_STATIC, "probe", "(Ljava/lang/Object;)V", null, null)
        method.visitCode()
        for (type in uses) {
            method.visitVarInsn(Opcodes.ALOAD, 0)
            method.visitTypeInsn(Opcodes.CHECKCAST, type)
            method.visitInsn(Opcodes.POP)
        }
        method.visitInsn(Opcodes.RETURN)
        method.visitMaxs(1, 1)
        method.visitEnd()
        writer.visitEnd()
        return writer.toByteArray()
    }

    private fun jar(classes: Map<String, ByteArray>): ByteArray = ByteArrayOutputStream().also { out ->
        ZipOutputStream(out).use { zip -> classes.forEach { (name, bytes) -> zip.putNextEntry(ZipEntry("$name.class")); zip.write(bytes); zip.closeEntry() } }
    }.toByteArray()

    @Test fun `missing host types are classified by startup, provider and other use`() {
        val jar = jar(mapOf(
            "ext/Entry" to classBytes("ext/Entry", "java/lang/Object", "android/app/FragmentMissing", "android/content/Context"),
            "ext/Api" to classBytes("ext/Api", "com/lagradost/cloudstream3/MainAPI", "android/webkit/WebViewMissing"),
            "ext/Util" to classBytes("ext/Util", "java/lang/Object", "android/graphics/BitmapMissing", "ext/Api"),
        ))
        val report = CompatibilityAssessment.assess(listOf(jar), "ext.Entry")
        assertEquals(RuntimeProfile.VERSION, report.profile)
        assertEquals(
            listOf("android/app/FragmentMissing" to "startup", "android/webkit/WebViewMissing" to "provider", "android/graphics/BitmapMissing" to "other"),
            report.missing.map { it.type to it.role },
        )
        assertEquals(listOf("ext/Entry"), report.missing.first().referencedBy)
        assertTrue(report.missing.none { it.type == "android/content/Context" }, "host-provided types are not reported")
        assertTrue(report.missing.none { it.type.startsWith("ext/") }, "the extension's own classes are not host types")
    }

    /** A provider class whose one method calls [calls] (owner, name, descriptor, static) and reads [reads]. */
    private fun callerBytes(name: String, calls: List<List<Any>>, reads: List<Triple<String, String, String>> = emptyList()): ByteArray {
        val writer = ClassWriter(ClassWriter.COMPUTE_MAXS)
        writer.visit(Opcodes.V1_8, Opcodes.ACC_PUBLIC, name, null, "com/lagradost/cloudstream3/MainAPI", null)
        val method = writer.visitMethod(Opcodes.ACC_PUBLIC or Opcodes.ACC_STATIC, "probe", "()V", null, null)
        method.visitCode()
        for (call in calls) {
            method.visitMethodInsn(if (call[3] as Boolean) Opcodes.INVOKESTATIC else Opcodes.INVOKEVIRTUAL,
                call[0] as String, call[1] as String, call[2] as String, false)
        }
        for ((owner, field, desc) in reads) { method.visitFieldInsn(Opcodes.GETSTATIC, owner, field, desc); method.visitInsn(Opcodes.POP) }
        method.visitInsn(Opcodes.RETURN)
        method.visitMaxs(0, 0)
        method.visitEnd()
        writer.visitEnd()
        return writer.toByteArray()
    }

    @Test fun `missing members of provided host types are reported, inherited and JDK ones are not`() {
        val jar = jar(mapOf("ext/Api" to callerBytes("ext/Api", listOf(
            listOf("android/content/Context", "getPackageName", "()Ljava/lang/String;", false),       // declared
            listOf("android/app/Activity", "getPackageName", "()Ljava/lang/String;", false),          // inherited from Context
            listOf("android/content/Context", "bindService", "(Landroid/content/Intent;)Z", false),   // not provided
            listOf("java/lang/String", "noSuchJdkCall", "()V", false),                                 // JDK: never assessed
            listOf("android/missing/Gone", "call", "()V", true),                                       // missing type: reported once, as a type
        ), reads = listOf(Triple("android/content/Context", "MODE_PRIVATE", "I"), Triple("android/content/Context", "NO_SUCH", "I")))))
        val report = CompatibilityAssessment.assess(listOf(jar), null)
        assertEquals(setOf(
            "android/content/Context.bindService(Landroid/content/Intent;)Z",
            "android/content/Context.NO_SUCH:I",
            "android/missing/Gone",
        ), report.missing.map { it.type }.toSet())
        assertTrue(report.missing.all { it.role == "provider" })
    }

    @Test fun `assessment is bounded and never executes extension code`() {
        val classes = (1..70).associate { "ext/C$it" to classBytes("ext/C$it", "java/lang/Object", "android/missing/T$it") }
        val report = CompatibilityAssessment.assess(listOf(jar(classes)), null)
        assertEquals(64, report.missing.size)
        assertTrue(report.truncated)
    }

    @Test fun `installs record the assessment and the API exposes it against the current profile`() = runBlocking<Unit> {
        val repo = SignedCatalogFixture("https://compat.invalid/repo.json")
        val fetcher = repo.publish(mapOf("Fixture" to ExtensionTestSupport.extension("fixture")), 1)
        val manager = ExtensionTestSupport.use(InstallationManager(BridgeExtensionRuntime, fetcher))
        val record = manager.install(repo.url, "Fixture")
        val stored = assertNotNull(DaemonState.snapshot().installations.getValue(record.id).compatibility)
        assertEquals(RuntimeProfile.VERSION, stored.profile)
        assertEquals(emptyList(), stored.missing, "the d8 fixture only uses provided host APIs")
        val dto = assertNotNull(RepositoryService.installedPlugin(record.id)?.compatibility)
        assertTrue(dto.current)
        assertEquals(emptyList(), dto.coreCode)
    }
}
