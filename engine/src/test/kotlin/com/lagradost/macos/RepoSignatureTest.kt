package com.lagradost.macos

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.Signature
import java.util.Base64
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * SEC-07 authenticity upgrade tests (plan WS-4.2): Ed25519 manifest
 * signatures with canonical-JSON bodies and TOFU pinning.
 */
class RepoSignatureTest {

    private fun keyPair(): KeyPair = KeyPairGenerator.getInstance("Ed25519").generateKeyPair()

    /** Raw 32-byte public key, as the manifest carries it. */
    private fun rawPublicKey(kp: KeyPair): String {
        val x509 = kp.public.encoded
        return Base64.getEncoder().encodeToString(x509.copyOfRange(x509.size - 32, x509.size))
    }

    private fun sign(kp: KeyPair, canonicalBody: String): String {
        val signer = Signature.getInstance("Ed25519")
        signer.initSign(kp.private)
        signer.update(canonicalBody.toByteArray(Charsets.UTF_8))
        return Base64.getEncoder().encodeToString(signer.sign())
    }

    private fun manifestJson(kp: KeyPair, body: JsonObject): String {
        val canonical = RepoSignature.canonicalize(body)
        val signed = buildJsonObject {
            body.forEach { (k, v) -> put(k, v) }
            put(
                "signature",
                buildJsonObject {
                    put("algorithm", "ed25519")
                    put("publicKey", rawPublicKey(kp))
                    put("value", sign(kp, canonical))
                },
            )
        }
        return signed.toString()
    }

    @Test
    fun `canonicalization is key-sorted and compact`() {
        val a = buildJsonObject {
            put("b", 1)
            put("a", "x")
        }
        val b = buildJsonObject {
            put("a", "x")
            put("b", 1)
        }
        assertEquals(RepoSignature.canonicalize(a), RepoSignature.canonicalize(b))
        assertEquals("""{"a":"x","b":1}""", RepoSignature.canonicalize(a))
    }

    @Test
    fun `valid signature verifies and exposes fingerprint`() {
        val kp = keyPair()
        val body = buildJsonObject {
            put("name", "Test Repo")
            put("manifestVersion", 1)
            put("pluginLists", kotlinx.serialization.json.JsonArray(emptyList()))
        }
        val document = manifestJson(kp, body)

        val verification = RepoSignature.verify(document, pinnedPublicKey = null)
        assertNotNull(verification)
        assertTrue(verification.valid, "expected valid: ${verification.reason}")
        assertNotNull(verification.keyFingerprint)
        assertTrue(":" in verification.keyFingerprint)
    }

    @Test
    fun `tampered body is rejected`() {
        val kp = keyPair()
        val document = manifestJson(
            kp,
            buildJsonObject { put("name", "Test Repo"); put("manifestVersion", 1) },
        )

        val tampered = document.replace("Test Repo", "Evil Repo")
        val verification = RepoSignature.verify(tampered, pinnedPublicKey = null)
        assertNotNull(verification)
        assertTrue(!verification.valid)
    }

    @Test
    fun `key change is refused when pinned`() {
        val kp1 = keyPair()
        val kp2 = keyPair()
        val document = manifestJson(
            kp2,
            buildJsonObject { put("name", "Test Repo"); put("manifestVersion", 1) },
        )
        val pinnedKey = rawPublicKey(kp1)

        val verification = RepoSignature.verify(document, pinnedPublicKey = pinnedKey)
        assertNotNull(verification)
        assertTrue(!verification.valid)
        assertTrue("key changed" in verification.reason.orEmpty())
    }

    @Test
    fun `same pinned key verifies`() {
        val kp = keyPair()
        val document = manifestJson(
            kp,
            buildJsonObject { put("name", "Test Repo"); put("manifestVersion", 1) },
        )
        val verification = RepoSignature.verify(document, pinnedPublicKey = rawPublicKey(kp))
        assertNotNull(verification)
        assertTrue(verification.valid, verification.reason ?: "")
    }

    @Test
    fun `unsigned manifest returns null (allowed, unverified)`() {
        val verification = RepoSignature.verify("""{"name":"Plain","manifestVersion":1}""", null)
        assertNull(verification)
    }

    @Test
    fun `malformed signature members are rejected`() {
        val verification = RepoSignature.verify(
            """{"name":"X","signature":{"algorithm":"md5","publicKey":"AA==","value":"BB=="}}""",
            null,
        )
        assertNotNull(verification)
        assertTrue(!verification.valid)
        assertTrue("algorithm" in verification.reason.orEmpty())
    }
    @Test fun `pinned repository cannot strip its signature`() {
        val result = RepoSignature.verify("""{"name":"unsigned"}""", rawPublicKey(keyPair()))
        assertNotNull(result)
        assertTrue(!result.valid)
    }

    @Test fun `all JSON controls and Unicode have unambiguous canonical bytes`() {
        val controls = (0..31).map { it.toChar() }.joinToString("")
        val value = kotlinx.serialization.json.JsonPrimitive(controls + "\"\\é🌍")
        val encoded = RepoSignature.canonicalize(value)
        assertTrue(encoded.none { it.code < 32 })
        assertEquals(value, kotlinx.serialization.json.Json.parseToJsonElement(encoded))
        assertTrue("\\u0000" in encoded && "\\u001f" in encoded)
        val body = buildJsonObject { put("controls", value) }
        assertTrue(RepoSignature.verify(manifestJson(keyPair(), body), null)!!.valid)
    }

    @Test fun `unsupported numbers and invalid Unicode fail closed`() {
        for (raw in listOf("1.5", "1e3", "9007199254740992", "-9007199254740992")) {
            kotlin.test.assertFailsWith<IllegalArgumentException> {
                RepoSignature.canonicalize(kotlinx.serialization.json.Json.parseToJsonElement(raw))
            }
        }
        kotlin.test.assertFailsWith<IllegalArgumentException> {
            RepoSignature.canonicalize(kotlinx.serialization.json.JsonPrimitive(0xd800.toChar().toString()))
        }
        assertEquals("0", RepoSignature.canonicalize(kotlinx.serialization.json.Json.parseToJsonElement("-0")))
    }

    @Test fun `explicit unsupported signing format is rejected`() {
        val kp = keyPair()
        val document = manifestJson(kp, buildJsonObject { put("name", "fixture") })
        val root = kotlinx.serialization.json.Json.parseToJsonElement(document) as JsonObject
        for (format in listOf(kotlinx.serialization.json.JsonPrimitive("other"), kotlinx.serialization.json.JsonNull)) {
            val signature = root["signature"] as JsonObject
            val altered = JsonObject(root + ("signature" to JsonObject(signature + ("format" to format))))
            assertTrue(RepoSignature.verify(altered.toString(), null)?.valid == false)
        }
    }

}
