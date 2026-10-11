package com.lagradost.macos

import okhttp3.HttpUrl.Companion.toHttpUrl
import kotlin.test.*

/** One bad catalog entry never costs the rest of the repository (85-repository survey, 2026-10-08). */
class CatalogEntriesTest {
    private val list = "https://repo.invalid/builds/plugins.json"

    private fun decode(json: String) = CatalogTrust.decodeList(null, "plugins.json", json.toByteArray(), list, "https://repo.invalid/repo.json")

    @Test fun `unusable icons are dropped, plain HTTP is read as HTTPS, private-network icons are dropped`() {
        val plugins = decode("""[
            {"internalName":"A","url":"A.cs3","iconUrl":"hhttps://bad.invalid/a.png"},
            {"internalName":"B","url":"B.cs3","iconUrl":"http://cdn.invalid/b.png"},
            {"internalName":"C","url":"C.cs3","iconUrl":"http://10.16.100.244/c.svg"},
            {"internalName":"D","url":"D.cs3","iconUrl":"https://cdn.invalid/d.png#x"}
        ]""")
        assertEquals(listOf("A", "B", "C", "D"), plugins.map { it.internalName })
        assertEquals(listOf(null, "https://cdn.invalid/b.png", null, null), plugins.map { it.iconUrl })
        assertEquals("https://repo.invalid/builds/A.cs3", plugins[0].url)
    }

    @Test fun `numeric hosts that are not IPv4 literals drop the icon without resolving or failing the list`() {
        // OkHttp keeps these as ordinary (non-literal) host names, so a DNS lookup would be the only way to "check" them.
        assertEquals("999.999.999.999", "https://999.999.999.999/i.png".toHttpUrl().host)
        assertEquals("1.2.3.4.5", "https://1.2.3.4.5/i.png".toHttpUrl().host)
        val plugins = decode("""[
            {"internalName":"A","url":"A.cs3","iconUrl":"https://999.999.999.999/i.png"},
            {"internalName":"B","url":"B.cs3","iconUrl":"https://1.2.3.4.5/i.png"},
            {"internalName":"C","url":"C.cs3","iconUrl":"https://8.8.8.8/i.png"},
            {"internalName":"D","url":"D.cs3","iconUrl":"https://[::1]/i.png"},
            {"internalName":"E","url":"E.cs3","iconUrl":"https://[2606:4700::1111]/i.png"}
        ]""")
        assertEquals(listOf("A", "B", "C", "D", "E"), plugins.map { it.internalName })
        assertEquals(listOf(null, null, "https://8.8.8.8/i.png", null, "https://[2606:4700::1111]/i.png"), plugins.map { it.iconUrl })
    }

    @Test fun `icon checks never touch DNS for host names`() {
        val started = System.nanoTime()
        assertEquals("https://does-not-exist.invalid/i.png", CatalogTrust.iconUrl(list, "https://does-not-exist.invalid/i.png"))
        assertTrue((System.nanoTime() - started) / 1_000_000 < 500, "A host name is passed through without a lookup")
    }

    @Test fun `an unusable download address keeps the entry listed but empty`() {
        val plugins = decode("""[
            {"internalName":"Plain","url":"http://dl.invalid/Plain.cs3"},
            {"internalName":"Odd","url":"ftp://dl.invalid/Odd.cs3"},
            {"internalName":"Creds","url":"https://u:p@dl.invalid/Creds.cs3"}
        ]""")
        assertEquals(listOf("https://dl.invalid/Plain.cs3", "", ""), plugins.map { it.url })
    }

    @Test fun `malformed entries are skipped and lenient values read as on Android`() {
        val plugins = decode("""[
            {"internalName":"Good","url":"Good.cs3","version":"7","status":null,"authors":null},
            {"internalName":"Broken","url":"Broken.cs3","authors":"not a list"},
            42,
            {"internalName":"","url":""}
        ]""")
        assertEquals(listOf("Good"), plugins.map { it.internalName })
        assertEquals(7, plugins[0].version)
        assertEquals(1, plugins[0].status)
        assertEquals(emptyList(), plugins[0].authors)
    }

    @Test fun `duplicate identities keep the first entry`() {
        val plugins = CatalogTrust.distinctEntries(decode("""[
            {"internalName":"Same","url":"first.cs3"},
            {"internalName":"Same","url":"second.cs3"}
        ]"""))
        assertEquals(listOf("https://repo.invalid/builds/first.cs3"), plugins.map { it.url })
    }

    @Test fun `a list that is not an array is still refused`() {
        assertFailsWith<IllegalArgumentException> { decode("""{"internalName":"A"}""") }
    }

    @Test fun `a missing plugin list names the file instead of a generic network failure`() {
        val failure = ExtensionException.from(RemoteHttpException(404, "https://cdn.invalid/plugins.json"))
        assertEquals(ExtensionException.Code.DOWNLOAD_FAILED, failure.code)
        assertTrue(failure.message!!.contains("no longer exists") && failure.message!!.contains("https://cdn.invalid/plugins.json"))
    }
}
