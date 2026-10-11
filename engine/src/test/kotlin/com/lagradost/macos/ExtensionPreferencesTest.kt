package com.lagradost.macos

import com.lagradost.macos.worker.RemoteProvider
import com.lagradost.macos.worker.WorkerExtensionRuntime
import com.lagradost.macos.worker.WorkerLauncher
import com.lagradost.macos.worker.WorkerPool
import kotlinx.coroutines.runBlocking
import java.io.File
import kotlin.test.*

/**
 * Plan RT-15: an extension's settings are discovered from its own code and
 * edited natively. The fixture cannot operate until its server is configured.
 */
class ExtensionPreferencesTest {
    private val repo = SignedCatalogFixture("https://prefs.invalid/repo.json")

    @BeforeTest fun before() { ExtensionTestSupport.resetHome(); WorkerPool.resetForTest(); OperationHealth.clearForTest(); ExtensionTestSupport.allowUnsandboxedWorkers() }
    @AfterTest fun after() { WorkerPool.resetForTest(); ExtensionTestSupport.resetHome() }

    private suspend fun install(runtime: ExtensionRuntime): DaemonState.InstalledExtension {
        val fetcher = repo.publish(mapOf("Configurable" to ExtensionTestSupport.extension("configurable")), revision = 1)
        return ExtensionTestSupport.use(InstallationManager(runtime, fetcher)).install(repo.url, "Configurable")
    }

    private fun provider(id: String) = PluginBridge.loadedInstallation(id)!!.providers.single()

    @Test fun `settings come from the extension's own keys, types and defaults`() = runBlocking<Unit> {
        val record = install(BridgeExtensionRuntime)
        val fields = ExtensionPreferences.describe(record.id).fields.associateBy { it.key }
        // The fixture DEX is shared by every Java fixture, so other fixtures' keys appear too (as for any class in an extension).
        assertTrue(fields.keys.containsAll(setOf("server", "page_size", "show_adult", "mirrors")), fields.keys.toString())
        assertEquals("string" to null, fields.getValue("server").let { it.type to it.default })
        assertEquals("int" to "10", fields.getValue("page_size").let { it.type to it.default })
        assertEquals("boolean" to "false", fields.getValue("show_adult").let { it.type to it.default })
        assertEquals("string_set", fields.getValue("mirrors").type)
        assertTrue(fields.values.none { it.isSet }, "nothing is stored yet")
    }

    @Test fun `a worker-hosted extension operates only after it is configured natively`() = runBlocking<Unit> {
        val record = install(WorkerExtensionRuntime(WorkerLauncher(sandboxed = false)))
        val before = ProviderExecutor.loadHome(assertIs<RemoteProvider>(provider(record.id)), 1)
        assertEquals("failure", before.outcome, "unconfigured: the provider cannot operate")

        val saved = ExtensionPreferences.update(record.id, listOf(
            ExtensionPreferenceUpdateDto("server", value = "https://media.invalid"),
            ExtensionPreferenceUpdateDto("page_size", value = "25"),
            ExtensionPreferenceUpdateDto("show_adult", value = "true"),
            ExtensionPreferenceUpdateDto("mirrors", values = listOf("a", "b")),
        )).fields.associateBy { it.key }
        assertEquals("https://media.invalid", saved.getValue("server").value)
        assertEquals(listOf("a", "b"), saved.getValue("mirrors").values)
        assertFalse(assertIs<RemoteProvider>(provider(record.id)).handle.running, "the worker restarts so load() sees the new settings")

        val after = ProviderExecutor.loadHome(provider(record.id), 1)
        assertEquals(setOf("25|true|2"), after.lists.map { it.name }.toSet(), "the extension loaded with the saved settings")
        // Stored where the extension reads it: its own private data directory in the worker home.
        assertTrue(File(com.lagradost.macos.worker.WorkerHandle.homeFor(record.id), "extension-data/${record.id}/shared_prefs/configurable.json").isFile)
        // The audit record names keys, never values.
        val audit = AuditLog.recent().last { "extension.preferences" in it }
        assertTrue("server" in audit && "media.invalid" !in audit)

        // Removing a value restores the extension's default.
        ExtensionPreferences.update(record.id, listOf(ExtensionPreferenceUpdateDto("page_size", remove = true)))
        assertEquals(setOf("10|true|2"), ProviderExecutor.loadHome(provider(record.id), 1).lists.map { it.name }.toSet())
    }

    @Test fun `only the extension's own keys and types are accepted`() = runBlocking<Unit> {
        val record = install(BridgeExtensionRuntime)
        suspend fun rejected(update: ExtensionPreferenceUpdateDto) =
            assertFailsWith<IllegalArgumentException> { ExtensionPreferences.update(record.id, listOf(update)) }.message.orEmpty()
        assertTrue("no setting named" in rejected(ExtensionPreferenceUpdateDto("not_a_key", value = "x")))
        assertTrue("whole number" in rejected(ExtensionPreferenceUpdateDto("page_size", value = "many")))
        assertTrue("true or false" in rejected(ExtensionPreferenceUpdateDto("show_adult", value = "yes")))
        assertTrue("too long" in rejected(ExtensionPreferenceUpdateDto("server", value = "x".repeat(20_000))))
        assertTrue(ExtensionPreferences.describe(record.id).fields.none { it.isSet }, "a rejected change stores nothing")
    }

    @Test fun `keys built at runtime are never reported`() {
        // The scanner only accepts a constant key pushed immediately before the call.
        val schema = PreferenceSchemaScanner.scan(listOf(java.io.ByteArrayOutputStream().also { out ->
            java.util.zip.ZipOutputStream(out).use { zip ->
                val writer = org.objectweb.asm.ClassWriter(0)
                writer.visit(org.objectweb.asm.Opcodes.V1_8, org.objectweb.asm.Opcodes.ACC_PUBLIC, "x/Dynamic", null, "java/lang/Object", null)
                val m = writer.visitMethod(org.objectweb.asm.Opcodes.ACC_STATIC, "read", "(Landroid/content/SharedPreferences;Ljava/lang/String;)Ljava/lang/String;", null, null)
                m.visitCode()
                m.visitVarInsn(org.objectweb.asm.Opcodes.ALOAD, 0)
                m.visitLdcInsn("looks_like_a_key")
                m.visitVarInsn(org.objectweb.asm.Opcodes.ALOAD, 1) // the real key is a runtime value
                m.visitInsn(org.objectweb.asm.Opcodes.SWAP)
                m.visitMethodInsn(org.objectweb.asm.Opcodes.INVOKEINTERFACE, "android/content/SharedPreferences", "getString",
                    "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;", true)
                m.visitInsn(org.objectweb.asm.Opcodes.ARETURN)
                m.visitMaxs(3, 2); m.visitEnd(); writer.visitEnd()
                zip.putNextEntry(java.util.zip.ZipEntry("x/Dynamic.class")); zip.write(writer.toByteArray()); zip.closeEntry()
            }
        }.toByteArray()))
        assertEquals(emptyList(), schema.fields)
    }
}
