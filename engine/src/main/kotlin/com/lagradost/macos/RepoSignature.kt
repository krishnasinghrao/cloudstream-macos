package com.lagradost.macos

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import java.security.KeyFactory
import java.security.Signature
import java.security.spec.X509EncodedKeySpec
import java.util.Base64

/**
 * Repository manifest authenticity (SEC-07 upgrade, plan WS-4.2).
 *
 * A repository may sign its `repo.json` with Ed25519. The manifest carries:
 *
 * ```json
 * "signature": { "algorithm": "ed25519", "publicKey": "<b64 32B>",
 *                "value": "<b64 signature over canonical body>" }
 * ```
 *
 * The canonical body is the document with the `signature` member removed and
 * all object keys sorted recursively, serialized with compact separators —
 * deterministic on both signer and verifier.
 *
 * Trust model (TOFU): the first sync pins the public key per repository URL
 * (fingerprint shown to the user in Settings). Later syncs must present the
 * same key and a valid signature. Key change => hard refusal until the user
 * explicitly re-trusts the repository. Unsigned repos are allowed but marked
 * unverified.
 */
object RepoSignature {
    private val ALLOWED_SIGNATURE_MEMBERS = setOf("algorithm", "format", "publicKey", "value")
    const val ALGORITHM_ED25519 = "ed25519"

    /** Standard X.509 prefix for raw 32-byte Ed25519 public keys. */
    private val ED25519_X509_PREFIX = byteArrayOf(
        0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
    )

    data class Verification(
        val valid: Boolean,
        val reason: String? = null,
        val keyFingerprint: String? = null,
        val publicKey: String? = null,
    )

    /**
     * Verifies a manifest document (raw JSON string).
     * Returns null when the manifest carries no signature (unsigned repo).
     */
    fun verify(manifestJson: String, pinnedPublicKey: String?): Verification? {
        val root = try {
            RepositoryJson.parse(manifestJson).jsonObject
        } catch (_: Exception) {
            return Verification(valid = false, reason = "manifest is not valid JSON")
        }

        val signatureElement = root["signature"] ?: return if (pinnedPublicKey == null) null else
            Verification(valid = false, reason = "pinned repository must remain signed")
        val signatureObj = try {
            signatureElement.jsonObject
        } catch (_: Exception) {
            return Verification(valid = false, reason = "signature member is malformed")
        }

        // Strict profile: the signature object carries exactly these members (repository-signing.md).
        if (!ALLOWED_SIGNATURE_MEMBERS.containsAll(signatureObj.keys)) {
            return Verification(valid = false, reason = "signature object has unknown members")
        }
        fun stringMember(name: String) = (signatureObj[name] as? JsonPrimitive)?.takeIf { it.isString }?.content
        val algorithm = stringMember("algorithm")
        val publicKeyB64 = stringMember("publicKey")
        val valueB64 = stringMember("value")

        if (algorithm != ALGORITHM_ED25519) {
            return Verification(valid = false, reason = "unsupported signature algorithm '$algorithm'")
        }
        if (publicKeyB64 == null || valueB64 == null) {
            return Verification(valid = false, reason = "signature is missing publicKey or value")
        }

        // TOFU enforcement
        if (pinnedPublicKey != null && pinnedPublicKey != publicKeyB64) {
            return Verification(
                valid = false,
                reason = "repository key changed since it was first trusted; re-trust required",
                publicKey = publicKeyB64,
            )
        }

        val format = if ("format" in signatureObj) stringMember("format") else "cloudstream-json-v1"
        if (format != "cloudstream-json-v1") return Verification(valid = false, reason = "unsupported signing format")
        val body = try { canonicalize(JsonObject(root - "signature")) } catch (failure: IllegalArgumentException) {
            return Verification(valid = false, reason = "unsupported canonical JSON value: ${failure.message}")
        }
        val signatureBytes = try {
            Base64.getDecoder().decode(valueB64)
        } catch (_: Exception) {
            return Verification(valid = false, reason = "signature value is not valid base64")
        }
        val keyBytes = try {
            Base64.getDecoder().decode(publicKeyB64)
        } catch (_: Exception) {
            return Verification(valid = false, reason = "publicKey is not valid base64")
        }
        if (keyBytes.size != 32 || signatureBytes.size != 64) {
            return Verification(valid = false, reason = "Ed25519 requires a 32-byte key and 64-byte signature")
        }

        return try {
            val keyFactory = KeyFactory.getInstance("Ed25519")
            val publicKey = keyFactory.generatePublic(
                X509EncodedKeySpec(ED25519_X509_PREFIX + keyBytes),
            )
            val verifier = Signature.getInstance("Ed25519")
            verifier.initVerify(publicKey)
            verifier.update(body.toByteArray(Charsets.UTF_8))
            val valid = verifier.verify(signatureBytes)
            Verification(
                valid = valid,
                reason = if (valid) null else "signature does not match manifest body",
                keyFingerprint = keyFingerprint(keyBytes),
                publicKey = publicKeyB64,
            )
        } catch (t: Exception) {
            Verification(valid = false, reason = "signature verification failed: ${t.message}")
        }
    }

    /** cloudstream-json-v1: UTF-16 sorted keys, valid Unicode strings, compact
     * JSON, integer numbers in the interoperable ±(2^53-1) range. No implicit
     * Unicode normalization, fractional numbers or exponent notation. */
    fun canonicalize(element: JsonElement): String = when (element) {
        is JsonPrimitive -> if (element.isString) {
            quote(element.content)
        } else {
            val value = element.content
            if (value in setOf("null", "true", "false")) value else {
                require(value.matches(Regex("-?(0|[1-9][0-9]*)"))) { "only integer numbers are supported" }
                val integer = value.toLongOrNull()
                require(integer != null && integer in -9_007_199_254_740_991L..9_007_199_254_740_991L) {
                    "integer outside interoperable range"
                }
                integer.toString()
            }
        }
        is JsonArray -> element.joinToString(",", "[", "]") { canonicalize(it) }
        is JsonObject -> element.entries
            .sortedBy { it.key }
            .joinToString(",", "{", "}") { (k, v) -> canonicalize(JsonPrimitive(k)) + ":" + canonicalize(v) }
    }

    private fun quote(value: String): String = buildString {
        append('"')
        value.forEachIndexed { index, c ->
            when {
                c.isHighSurrogate() -> {
                    require(index + 1 < value.length && value[index + 1].isLowSurrogate()) { "unpaired surrogate" }
                    append(c)
                }
                c.isLowSurrogate() -> {
                    require(index > 0 && value[index - 1].isHighSurrogate()) { "unpaired surrogate" }
                    append(c)
                }
                c == '"' -> append("\\\"")
                c == '\\' -> append("\\\\")
                c == '\b' -> append("\\b")
                c == '\u000c' -> append("\\f")
                c == '\n' -> append("\\n")
                c == '\r' -> append("\\r")
                c == '\t' -> append("\\t")
                c.code < 32 -> append("\\u" + c.code.toString(16).padStart(4, '0'))
                else -> append(c)
            }
        }
        append('"')
    }

    fun keyFingerprint(keyBytes: ByteArray): String =
        ArtifactDigest.sha256(keyBytes)
            .chunked(8)
            .joinToString(":")

    fun keyFingerprintFromB64(publicKeyB64: String): String? = try {
        keyFingerprint(Base64.getDecoder().decode(publicKeyB64))
    } catch (_: Exception) {
        null
    }
}
