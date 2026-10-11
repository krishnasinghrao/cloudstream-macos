package com.lagradost.macos

import com.lagradost.macos.worker.FrameCodec
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.ByteArrayInputStream
import java.io.DataInputStream
import kotlin.random.Random
import kotlin.test.*

/**
 * Plan T9.5: mutation fuzzing of the parsers that see untrusted bytes —
 * repository JSON, signed manifests, catalog lists and worker frames. Seeds are
 * fixed so any failure reproduces. Only contained failures are acceptable.
 */
class ParserFuzzTest {
    private val signed = SignedCatalogFixture("https://fuzz.invalid/repo.json")

    /** Rejections the parsers are designed to raise (kotlinx SerializationException is an IllegalArgumentException). */
    private fun contained(failure: Throwable) = failure is IllegalArgumentException || failure is IllegalStateException ||
        failure is SecurityException || failure is java.io.EOFException || failure is java.nio.charset.CharacterCodingException

    private fun mutate(input: String, random: Random): String {
        val chars = StringBuilder(input)
        repeat(random.nextInt(1, 6)) {
            if (chars.isEmpty()) return@repeat
            val at = random.nextInt(chars.length)
            when (random.nextInt(6)) {
                0 -> chars.deleteCharAt(at)
                1 -> chars.insert(at, "{}[]\",:\\u0000\uD800\n0-e".random(random))
                2 -> chars.setCharAt(at, (random.nextInt(0x20, 0x7f)).toChar())
                3 -> chars.insert(at, chars.substring(at, minOf(chars.length, at + random.nextInt(1, 40))))
                4 -> chars.setLength(at)
                else -> chars.insert(at, "\\u" + random.nextInt(0, 0xffff).toString(16).padStart(4, '0'))
            }
        }
        return chars.toString()
    }

    private inline fun fuzz(seed: Int, iterations: Int, block: (Random) -> Unit) {
        val random = Random(seed)
        repeat(iterations) { index ->
            try { block(random) } catch (failure: Throwable) {
                if (!contained(failure)) throw AssertionError("seed $seed iteration $index: uncontained ${failure.javaClass.name}: ${failure.message}", failure)
            }
        }
    }

    @Test fun `repository json rejects malformed and hostile documents without crashing`() {
        val samples = listOf(signed.manifest(), signed.list, """{"a":[1,2.5e3,-0,true,null,"é"]}""")
        fuzz(seed = 1, iterations = 3_000) { random -> RepositoryJson.parse(mutate(samples.random(random), random)) }
        // Deep nesting and huge collections are rejected, not recursed into.
        assertFailsWith<IllegalArgumentException> { RepositoryJson.parse("[".repeat(200_000) + "]".repeat(200_000)) }
        assertFailsWith<IllegalArgumentException> { RepositoryJson.parse("{\"a\":1,\"a\":2}") }
    }

    @Test fun `a mutated signed manifest never verifies`() {
        val manifest = signed.manifest()
        val original = RepoSignature.canonicalize(kotlinx.serialization.json.JsonObject(RepositoryJson.parse(manifest).jsonObject - "signature"))
        val key = RepositoryJson.parse(manifest).jsonObject["signature"]!!.jsonObject["publicKey"]!!.jsonPrimitive.content
        var checked = 0
        fuzz(seed = 2, iterations = 3_000) { random ->
            val candidate = mutate(manifest, random)
            val parsed = runCatching { RepositoryJson.parse(candidate).jsonObject }.getOrNull() ?: return@fuzz
            val signature = parsed["signature"]
            val sameBody = runCatching { RepoSignature.canonicalize(kotlinx.serialization.json.JsonObject(parsed - "signature")) == original }.getOrDefault(false)
            val sameSignature = signature == RepositoryJson.parse(manifest).jsonObject["signature"]
            val verification = RepoSignature.verify(candidate, key)
            if (!(sameBody && sameSignature)) {
                checked++
                assertTrue(verification == null || !verification.valid, "tampered manifest verified: $candidate")
            }
        }
        assertTrue(checked > 500, "fuzzer produced enough distinct parseable manifests ($checked)")
    }

    @Test fun `catalog lists reject hostile entries`() {
        val root = CatalogTrust.authenticateRoot(signed.manifest(), null, null)
        fuzz(seed = 3, iterations = 3_000) { random ->
            val body = mutate(signed.list, random).toByteArray()
            // Signed: any change must fail the list digest; unsigned: decoding must stay contained.
            if (!body.contentEquals(signed.list.toByteArray())) {
                assertFailsWith<SecurityException> { CatalogTrust.decodeList(root, "list.json", body, "https://fuzz.invalid/list.json", signed.url) }
            }
            CatalogTrust.decodeList(null, "list.json", body, "https://fuzz.invalid/list.json", signed.url)
        }
    }

    @Test fun `worker frames reject garbage without allocating attacker-sized buffers`() {
        fuzz(seed = 4, iterations = 5_000) { random ->
            val bytes = random.nextBytes(random.nextInt(0, 64))
            FrameCodec.read(DataInputStream(ByteArrayInputStream(bytes)))
        }
        // A length prefix beyond the limit is refused before reading.
        val huge = java.nio.ByteBuffer.allocate(4).putInt(Int.MAX_VALUE).array()
        assertFailsWith<IllegalArgumentException> { FrameCodec.read(DataInputStream(ByteArrayInputStream(huge))) }
        fuzz(seed = 5, iterations = 2_000) { random ->
            val json = mutate("""{"id":1,"type":"result","payload":{"results":[]}}""", random).toByteArray()
            val framed = java.nio.ByteBuffer.allocate(4 + json.size).putInt(json.size).put(json).array()
            FrameCodec.read(DataInputStream(ByteArrayInputStream(framed)))
        }
    }
}
