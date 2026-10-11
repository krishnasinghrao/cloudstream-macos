package com.lagradost.macos

import com.lagradost.cloudstream3.USER_AGENT
import com.lagradost.cloudstream3.app
import com.lagradost.cloudstream3.network.DdosGuardKiller
import com.lagradost.cloudstream3.network.buildDefaultClient
import com.lagradost.cloudstream3.network.getHeaders
import com.lagradost.nicehttp.Requests
import okhttp3.Headers
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import java.io.File
import java.nio.file.Files
import kotlin.test.*

/**
 * Extensions are compiled against the Android *app*, not only the shared
 * library. These app-module network helpers must exist in the engine with the
 * JVM names and descriptors the Kotlin compiler emits for the Android sources
 * (including `$default` bridges for default parameters), or extensions fail
 * with NoClassDefFoundError / NoSuchMethodError at run time.
 */
class AndroidNetworkHelpersAbiTest {
    private fun method(owner: String, name: String, vararg parameters: Class<*>) =
        Class.forName(owner).getMethod(name, *parameters)

    @Test fun `RequestsHelper functions keep their Android JVM signatures`() {
        val owner = "com.lagradost.cloudstream3.network.RequestsHelperKt"
        val context = android.content.Context::class.java
        assertEquals(Headers::class.java, method(owner, "getHeaders", Map::class.java, Map::class.java).returnType)
        assertEquals(OkHttpClient::class.java, method(owner, "buildDefaultClient", context).returnType)
        assertEquals(OkHttpClient::class.java, method(owner, "buildDefaultClient", context, Boolean::class.javaPrimitiveType!!).returnType)
        method(owner, "buildDefaultClient\$default", context, Boolean::class.javaPrimitiveType!!, Int::class.javaPrimitiveType!!, Any::class.java)
        method(owner, "initClient", Requests::class.java, context)
        method(owner, "initClient", Requests::class.java, context, Boolean::class.javaPrimitiveType!!)
        method(owner, "initClient\$default", Requests::class.java, context, Boolean::class.javaPrimitiveType!!, Int::class.javaPrimitiveType!!, Any::class.java)
    }

    @Test fun `DoH helpers keep their Android JVM signatures`() {
        val owner = "com.lagradost.cloudstream3.network.DohProvidersKt"
        val builder = OkHttpClient.Builder::class.java
        for (name in listOf("addGoogleDns", "addCloudFlareDns", "addAdGuardDns", "addDNSWatchDns", "addQuad9Dns", "addDnsSbDns", "addCanadianShieldDns")) {
            assertEquals(builder, method(owner, name, builder).returnType, name)
        }
        assertEquals(builder, method(owner, "addGenericDns", builder, String::class.java, List::class.java).returnType)
    }

    @Test fun `DdosGuardKiller is an interceptor constructed like on Android`() {
        val killer = DdosGuardKiller::class.java.getConstructor(Boolean::class.javaPrimitiveType!!).newInstance(false)
        assertIs<Interceptor>(killer)
    }

    @Test fun `helpers behave like Android and reuse the engine's configured client`() {
        val headers = getHeaders(mapOf("Referer" to "https://a.invalid/"), mapOf("cf_clearance" to "x", "session" to "y"))
        assertEquals(USER_AGENT, headers["user-agent"])
        assertEquals("https://a.invalid/", headers["Referer"])
        assertEquals("cf_clearance=x; session=y;", headers["Cookie"])
        assertTrue(getHeaders(emptyMap(), emptyMap())["Cookie"] == null)

        val dir = Files.createTempDirectory("ctx").toFile()
        try {
            // Engine DNS, cache and challenge handling apply to extension requests.
            assertSame(app.baseClient, buildDefaultClient(android.content.Context(File(dir, "ext"))))
        } finally { dir.deleteRecursively() }
    }
}
