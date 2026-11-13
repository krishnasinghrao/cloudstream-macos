package com.lagradost.macos

import com.lagradost.macos.worker.RemoteProvider
import com.lagradost.macos.worker.WorkerExtensionRuntime
import com.lagradost.macos.worker.WorkerLauncher
import com.lagradost.macos.worker.WorkerPool
import kotlinx.coroutines.runBlocking
import org.objectweb.asm.*
import kotlin.test.*

class HostAbiAdapterTest {
    @BeforeTest fun before() { WorkerPool.resetForTest(); ExtensionTestSupport.resetHome(); ExtensionTestSupport.allowUnsandboxedWorkers() }
    @AfterTest fun after() { WorkerPool.resetForTest(); ExtensionTestSupport.resetHome() }

    @Test fun `Android Kotlin Result and worker bootstrap run through provider stages`() = runBlocking<Unit> {
        val fixture = SignedCatalogFixture("https://kotlin-abi.invalid/repo.json")
        val fetcher = fixture.publish(mapOf("KotlinAbi" to ExtensionTestSupport.extension("kotlin-abi")), revision = 1)
        val manager = ExtensionTestSupport.use(InstallationManager(WorkerExtensionRuntime(WorkerLauncher(sandboxed = false)), fetcher))
        val record = manager.install(fixture.url, "KotlinAbi")
        val provider = assertIs<RemoteProvider>(PluginBridge.loadedInstallation(record.id)!!.providers.single())
        val search = ProviderExecutor.searchOne(provider, "query")
        assertNull(search.error)
        assertEquals("Kotlin:query", search.results.single().name)
        val details = assertNotNull(ProviderExecutor.loadDetails(provider, "https://fixture.invalid/title"))
        assertEquals("Kotlin title", details.name)
        val links = ProviderExecutor.loadLinks(provider, "fixture")
        assertEquals("https://fixture.invalid/video.m3u8", links.links.single().url)
    }

    @Test fun `mapping requires exact descriptor and static kind and preserves ordinary underscores`() {
        val writer = ClassWriter(0)
        writer.visit(Opcodes.V11, Opcodes.ACC_PUBLIC, "fixture/ReferenceOnly", null, "java/lang/Object", null)
        writer.visitMethod(Opcodes.ACC_PUBLIC or Opcodes.ACC_STATIC, "references", "()V", null, null).apply {
            visitMethodInsn(Opcodes.INVOKESTATIC, "kotlin/Result", "constructor_impl", "(Ljava/lang/Object;)Ljava/lang/Object;", false)
            visitMethodInsn(Opcodes.INVOKESTATIC, "kotlin/Result", "constructor_impl", "(I)I", false)
            visitMethodInsn(Opcodes.INVOKEVIRTUAL, "kotlin/Result", "constructor_impl", "(Ljava/lang/Object;)Ljava/lang/Object;", false)
            visitMethodInsn(Opcodes.INVOKESTATIC, "fixture/Custom", "ordinary_underscore", "()V", false)
            visitEnd()
        }
        writer.visitEnd()
        val names = mutableListOf<String>()
        ClassReader(HostAbiAdapter.adaptClass(writer.toByteArray())).accept(object : ClassVisitor(Opcodes.ASM9) {
            override fun visitMethod(a: Int, n: String, d: String, s: String?, e: Array<out String>?): MethodVisitor =
                object : MethodVisitor(Opcodes.ASM9) {
                    override fun visitMethodInsn(op: Int, o: String, n: String, d: String, iface: Boolean) { names.add(n) }
                }
        }, 0)
        assertEquals(listOf("constructor-impl", "constructor_impl", "constructor_impl", "ordinary_underscore"), names)
    }

    /** An extension compiled with the Compose compiler reads its host superclass's stability mask. */
    @Test fun `a Compose stability read of a host class without one becomes zero`() {
        val plugin = "com/lagradost/cloudstream3/plugins/Plugin"
        val writer = ClassWriter(ClassWriter.COMPUTE_MAXS)
        writer.visit(Opcodes.V11, Opcodes.ACC_PUBLIC, "fixture/ComposePlugin", null, plugin, null)
        writer.visitField(Opcodes.ACC_PUBLIC or Opcodes.ACC_STATIC or Opcodes.ACC_FINAL, "\$stable", "I", null, null).visitEnd()
        writer.visitMethod(Opcodes.ACC_PUBLIC, "<init>", "()V", null, null).apply {
            visitVarInsn(Opcodes.ALOAD, 0)
            visitMethodInsn(Opcodes.INVOKESPECIAL, plugin, "<init>", "()V", false)
            visitInsn(Opcodes.RETURN); visitMaxs(0, 0); visitEnd()
        }
        // What the Compose compiler emits: this class's mask folds in its superclass's.
        writer.visitMethod(Opcodes.ACC_STATIC, "<clinit>", "()V", null, null).apply {
            visitFieldInsn(Opcodes.GETSTATIC, plugin, "\$stable", "I")
            visitFieldInsn(Opcodes.PUTSTATIC, "fixture/ComposePlugin", "\$stable", "I")
            visitInsn(Opcodes.RETURN); visitMaxs(0, 0); visitEnd()
        }
        writer.visitMethod(Opcodes.ACC_PUBLIC or Opcodes.ACC_STATIC, "others", "()I", null, null).apply {
            // Not a host class, and not the stability field: both left alone.
            visitFieldInsn(Opcodes.GETSTATIC, "fixture/ComposePlugin", "\$stable", "I")
            visitFieldInsn(Opcodes.GETSTATIC, "java/lang/Integer", "MAX_VALUE", "I")
            visitInsn(Opcodes.IADD)
            visitInsn(Opcodes.IRETURN); visitMaxs(0, 0); visitEnd()
        }
        writer.visitEnd()
        val original = writer.toByteArray()
        val loader = object : ClassLoader(javaClass.classLoader) {
            fun define(bytes: ByteArray): Class<*> = defineClass("fixture.ComposePlugin", bytes, 0, bytes.size)
        }
        val unadapted = assertFailsWith<NoSuchFieldError> {
            Class.forName("fixture.ComposePlugin", true, object : ClassLoader(javaClass.classLoader) {
                override fun findClass(name: String): Class<*> = defineClass(name, original, 0, original.size)
            })
        }
        assertTrue("\$stable" in unadapted.message.orEmpty())
        val adapted = HostAbiAdapter.adaptClass(original)
        val reads = mutableListOf<String>()
        ClassReader(adapted).accept(object : ClassVisitor(Opcodes.ASM9) {
            override fun visitMethod(a: Int, n: String, d: String, s: String?, e: Array<out String>?): MethodVisitor =
                object : MethodVisitor(Opcodes.ASM9) {
                    override fun visitFieldInsn(op: Int, o: String, n: String, d: String) { if (op == Opcodes.GETSTATIC) reads.add("$o.$n") }
                }
        }, 0)
        assertEquals(listOf("fixture/ComposePlugin.\$stable", "java/lang/Integer.MAX_VALUE"), reads)
        val type = loader.define(adapted)
        assertEquals(0, type.getField("\$stable").getInt(null))
        assertIs<com.lagradost.cloudstream3.plugins.Plugin>(type.getDeclaredConstructor().newInstance())
    }
}
