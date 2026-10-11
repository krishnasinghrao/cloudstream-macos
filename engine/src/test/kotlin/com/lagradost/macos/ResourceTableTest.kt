package com.lagradost.macos

import android.content.res.AssetManager
import org.junit.Assume.assumeTrue
import org.objectweb.asm.ClassReader
import org.objectweb.asm.ClassVisitor
import org.objectweb.asm.Opcodes
import java.io.File
import java.util.zip.ZipFile
import java.util.zip.ZipInputStream
import kotlin.test.*

/** Plan RT-13: the compiled resource table reader is correct on aapt2 output and refuses malformed input. */
class ResourceTableTest {
    private fun entry(name: String): ByteArray = ZipInputStream(ExtensionTestSupport.extension("android-resources").inputStream()).use { zip ->
        generateSequence { zip.nextEntry }.first { it.name == name }.let { zip.readBytes() }
    }

    @Test fun `aapt2 table resolves names, locales, references and arrays`() {
        val table = ResourceTable.parse(entry("resources.arsc"))
        assertEquals(setOf("com.example.resfixture"), table.packageNames())
        val id = table.identifier("provider_name", "string", null)
        assertEquals(0x7f, id ushr 24)
        assertEquals(ResourceTable.Value.Text("ResourceProvider"), table.value(id), "default configuration wins over values-fr")
        assertEquals(Triple("com.example.resfixture", "string", "provider_name"), table.name(id))
        assertEquals(id, table.identifier("@com.example.resfixture:string/provider_name", null, null))
        assertEquals(0, table.identifier("provider_name", "string", "other.package"))
        assertEquals(0, table.identifier("provider_name", null, null), "a bare name needs a type")
        assertNull(table.value(0x7f7f0000))
    }

    @Test fun `malformed tables are rejected whole`() {
        val good = entry("resources.arsc")
        for (bad in listOf(ByteArray(0), good.copyOf(good.size / 2), good.copyOf().also { it[4] = 0x7f }, good.copyOf().also { it[0] = 9 })) {
            assertFailsWith<IllegalArgumentException> { ResourceTable.parse(bad) }
        }
        assertFailsWith<IllegalArgumentException> { ResourceTable.parse(ByteArray(ResourceTable.MAX_TABLE_BYTES + 1)) }
    }

    @Test fun `truncated chunks fail as malformed tables, never as out-of-bounds reads (Q4)`() {
        fun table(vararg chunks: ByteArray): ByteArray {
            val body = chunks.fold(ByteArray(0)) { all, chunk -> all + chunk }
            return java.nio.ByteBuffer.allocate(12 + body.size).order(java.nio.ByteOrder.LITTLE_ENDIAN)
                .putShort(0x0002).putShort(12).putInt(12 + body.size).putInt(1).put(body).array()
        }
        fun chunk(type: Int, headerSize: Int, size: Int) = java.nio.ByteBuffer.allocate(size).order(java.nio.ByteOrder.LITTLE_ENDIAN)
            .putShort(type.toShort()).putShort(headerSize.toShort()).putInt(size).array()
        // The minimal reproduction: an 8-byte string pool chunk.
        assertFailsWith<IllegalArgumentException> { ResourceTable.parse(table(chunk(0x0001, 8, 8))) }
        assertFailsWith<IllegalArgumentException> { ResourceTable.parse(table(chunk(0x0001, 8, 24))) }
        assertFailsWith<IllegalArgumentException> { ResourceTable.parse(table(chunk(0x0001, 40, 28))) }
        // Every single-byte corruption of a real table either parses or is rejected as malformed.
        val good = entry("resources.arsc")
        val random = java.util.Random(7)
        repeat(3_000) {
            val bad = good.copyOf()
            repeat(1 + random.nextInt(3)) { bad[random.nextInt(bad.size)] = random.nextInt(256).toByte() }
            val failure = runCatching { ResourceTable.parse(bad) }.exceptionOrNull()
            assertTrue(failure == null || failure is IllegalArgumentException, "unexpected ${failure?.javaClass?.name}")
        }
        // Truncating each chunk's declared size is likewise contained.
        for (cut in 12 until minOf(good.size, 600) step 4) {
            val failure = runCatching { ResourceTable.parse(good.copyOf(cut).also {
                java.nio.ByteBuffer.wrap(it).order(java.nio.ByteOrder.LITTLE_ENDIAN).putInt(4, cut)
            }) }.exceptionOrNull()
            assertTrue(failure == null || failure is IllegalArgumentException, "cut $cut: ${failure?.javaClass?.name}")
        }
    }

    @Test fun `assets cannot escape their directory`() {
        val assets = AssetManager(mapOf("config/a.txt" to byteArrayOf(1)))
        assertContentEquals(byteArrayOf(1), assets.open("/config/a.txt").readBytes())
        assertFailsWith<java.io.FileNotFoundException> { assets.open("config/../../state.json") }
        assertFailsWith<java.io.FileNotFoundException> { assets.open("missing") }
        assertContentEquals(arrayOf("config"), assets.list(""))
    }

    /** Extensions link by exact descriptor; the resource members we provide must match Android API 35. */
    @Test fun `resources keep Android's descriptors`() {
        val sdk = File(System.getProperty("user.home"), "Library/Android/sdk/platforms/android-35/android.jar")
        assumeTrue("Android API 35 SDK required", sdk.isFile)
        ZipFile(sdk).use { jar ->
            for (type in listOf("android/content/res/Resources", "android/content/res/AssetManager", "android/content/res/Resources\$NotFoundException")) {
                val android = members(jar.getInputStream(jar.getEntry("$type.class")).readBytes())
                val ours = members(javaClass.classLoader.getResourceAsStream("$type.class")!!.readBytes())
                val wrong = ours.filter { it.substringBefore('(') != "<init>" }.filter { mine ->
                    android.none { it == mine } && android.any { it.substringBefore('(') == mine.substringBefore('(') }
                }
                assertEquals(emptyList(), wrong, "$type members whose descriptor differs from Android's")
                val missing = listOf("getIdentifier", "getString", "getStringArray", "getIntArray", "getInteger", "getBoolean", "getText",
                    "getResourceName", "getResourceEntryName", "getResourceTypeName", "getResourcePackageName", "getAssets", "open", "list")
                    .filter { name -> android.any { it.startsWith("$name(") } && ours.none { it.startsWith("$name(") } }
                assertEquals(emptyList(), missing, "$type")
            }
        }
    }

    private fun members(bytes: ByteArray): Set<String> {
        val out = mutableSetOf<String>()
        ClassReader(bytes).accept(object : ClassVisitor(Opcodes.ASM9) {
            override fun visitMethod(access: Int, name: String, descriptor: String, signature: String?, exceptions: Array<out String>?) = null.also {
                if (access and (Opcodes.ACC_PUBLIC or Opcodes.ACC_PROTECTED) != 0) out += name + descriptor
            }
        }, ClassReader.SKIP_CODE)
        return out
    }
}

/** Translation bounds: an oversized method becomes a named failure, not an out-of-memory worker. */
class TranslationGuardTest {
    @Test fun `oversized methods translate to a throwing stub and the rest still runs`() {
        val dex = ExtensionTestSupport.dexOf("android-resources")
        assertEquals(emptyList(), TranslationGuard.scan(dex), "ordinary fixtures are far below the limits")
        // Force the guard on the fixture plugin's load() with test limits.
        val oversized = TranslationGuard.scan(dex, maxComplexity = 50).filter { it.owner == "Lfixture/ResourcePlugin;" && it.name == "load" }
        assertEquals(1, oversized.size)
        assertEquals("ResourcePlugin.load", oversized.single().label)
        val out = kotlin.io.path.createTempFile(suffix = ".jar")
        try {
            com.googlecode.d2j.dex.Dex2jar.from(TranslationGuard.guard(dex, oversized)).reUseReg(true).topoLogicalSort()
                .optimizeSynchronized().skipDebug().to(out)
            val loader = java.net.URLClassLoader(arrayOf(out.toUri().toURL()), javaClass.classLoader)
            val plugin = loader.loadClass("fixture.ResourcePlugin").getDeclaredConstructor().newInstance()
            val failure = assertFailsWith<java.lang.reflect.InvocationTargetException> {
                plugin.javaClass.getMethod("load", android.content.Context::class.java).invoke(plugin, android.content.Context())
            }.targetException
            assertIs<UnsupportedOperationException>(failure)
            assertEquals("fixture.ResourcePlugin.load is too large to translate for macOS and cannot run.", failure.message)
            // Untouched methods of the same DEX still work.
            val api = loader.loadClass("fixture.ResourceApi").getConstructor(String::class.java, String::class.java).newInstance("n", "https://u.invalid")
            assertEquals("n", api.javaClass.getMethod("getName").invoke(api))
        } finally { java.nio.file.Files.deleteIfExists(out) }
    }
}
