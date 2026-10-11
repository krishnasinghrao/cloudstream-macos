package com.lagradost.macos

import java.io.ByteArrayInputStream
import java.io.InputStream
import java.net.URL
import java.net.URLConnection
import java.net.URLStreamHandler
import java.util.Collections
import java.util.Enumeration
import java.util.jar.JarInputStream

/**
 * Defines classes only from JAR bytes whose SHA-256 was verified in memory.
 * Unlike URLClassLoader nothing is re-read from disk after verification, so a
 * cache file replaced later cannot inject code, and retiring a generation
 * cannot break a class load that an in-flight call still needs.
 */
internal class VerifiedClassLoader(
    jars: List<ByteArray>,
    parent: ClassLoader,
    private val label: String,
) : ClassLoader(parent) {
    private val entries: Map<String, ByteArray>

    init {
        val map = HashMap<String, ByteArray>()
        var total = 0L
        for (jar in jars) {
            JarInputStream(ByteArrayInputStream(jar)).use { input ->
                while (true) {
                    val entry = input.nextJarEntry ?: break
                    if (entry.isDirectory) continue
                    val name = entry.name
                    require(!name.startsWith("/") && ".." !in name.split('/')) { "Invalid archive entry" }
                    val bytes = input.readNBytes(MAX_ENTRY_BYTES + 1)
                    require(bytes.size <= MAX_ENTRY_BYTES) { "Class entry exceeds size limit" }
                    total += bytes.size
                    require(total <= MAX_TOTAL_BYTES) { "Translated extension exceeds size limit" }
                    // First occurrence wins, matching classpath order.
                    map.putIfAbsent(name, bytes)
                }
            }
        }
        entries = map
    }

    override fun findClass(name: String): Class<*> {
        val bytes = entries[name.replace('.', '/') + ".class"] ?: throw ClassNotFoundException(name)
        return defineClass(name, bytes, 0, bytes.size)
    }

    override fun findResource(name: String): URL? {
        val bytes = entries[name.removePrefix("/")] ?: return null
        return URL("verified", label, -1, "/" + name.removePrefix("/"), object : URLStreamHandler() {
            override fun openConnection(u: URL): URLConnection = object : URLConnection(u) {
                override fun connect() {}
                override fun getInputStream(): InputStream = ByteArrayInputStream(bytes)
                override fun getContentLengthLong(): Long = bytes.size.toLong()
            }
        })
    }

    override fun findResources(name: String): Enumeration<URL> =
        Collections.enumeration(listOfNotNull(findResource(name)))

    override fun getResourceAsStream(name: String): InputStream? =
        parent?.getResourceAsStream(name) ?: entries[name.removePrefix("/")]?.let(::ByteArrayInputStream)

    companion object {
        private const val MAX_ENTRY_BYTES = 16 * 1024 * 1024
        private const val MAX_TOTAL_BYTES = 32L * 1024 * 1024
    }
}
