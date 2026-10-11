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
}
