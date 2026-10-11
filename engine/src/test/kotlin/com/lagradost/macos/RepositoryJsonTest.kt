package com.lagradost.macos

import kotlin.test.*

class RepositoryJsonTest {
    @Test fun `duplicate decoded keys and invalid Unicode are rejected before signature verification`() {
        for (body in listOf("""{"name":"one","name":"two"}""", """{"name":"one","na\u006de":"two"}""",
            """{"nested":{"a":1,"a":2}}""", """{"name":"\ud800"}""")) {
            assertFailsWith<IllegalArgumentException> { RepositoryJson.parse(body) }
            assertEquals(false, RepoSignature.verify(body, null)?.valid)
        }
    }

    @Test fun `depth string and collection budgets precede tree allocation`() {
        for (body in listOf("[".repeat(34) + "0" + "]".repeat(34),
            "\"" + "x".repeat(65_537) + "\"", (0..10_000).joinToString(",", "[", "]"))) {
            assertFailsWith<IllegalArgumentException> { RepositoryJson.parse(body) }
        }
    }

    @Test fun `malformed JSON cannot use lenient decoding`() {
        for (body in listOf("{name:1}", "[1,]", "{\"a\":1,}", "01", "+1", "true false", "\"bad\nstring\"")) {
            assertFailsWith<IllegalArgumentException> { RepositoryJson.parse(body) }
        }
    }

    @Test fun `valid escapes supplementary Unicode and numeric syntax parse unchanged`() {
        val body = """{"a":"quote\" slash\\ 🌍 \u0000","b":[true,false,null,-1,1.5,1e3]}"""
        assertEquals(kotlinx.serialization.json.Json.parseToJsonElement(body), RepositoryJson.parse(body))
    }

    @Test fun `malformed UTF8 is not silently replaced`() {
        assertFailsWith<java.nio.charset.CharacterCodingException> {
            RepositoryDocument(byteArrayOf(0xc3.toByte(), 0x28), "https://fixture.invalid").text()
        }
    }
}
