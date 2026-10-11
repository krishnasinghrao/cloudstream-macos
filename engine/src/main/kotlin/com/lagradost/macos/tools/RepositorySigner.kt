package com.lagradost.macos.tools

import com.lagradost.macos.ArtifactDigest
import com.lagradost.macos.RepoSignature
import com.lagradost.macos.RepositoryJson
import com.lagradost.macos.RepositoryService
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.Signature
import java.security.spec.PKCS8EncodedKeySpec
import java.time.Instant
import java.util.Base64

/**
 * Publisher tooling for verified repositories (docs/repository-signing.md).
 *
 *   keygen <private-key-out>
 *       Writes a PKCS#8 Ed25519 private key (base64, 0600) and <out>.pub with the
 *       raw public key clients pin; prints the public key.
 *   sign <manifest.json> <private-key> <catalogVersion> <validDays> [out]
 *       (reads <private-key>.pub)
 *       Binds every plugin list listed in the manifest (resolved relative to the
 *       manifest's directory) by SHA-256, sets catalogVersion/expiresAt, and
 *       signs the canonical root. Every list entry must carry a valid fileHash.
 *
 * Run: java -cp daemon.jar com.lagradost.macos.tools.RepositorySigner …
 */
object RepositorySigner {
    @JvmStatic
    fun main(args: Array<String>) {
        try {
            when (args.firstOrNull()) {
                "keygen" -> println(keygen(File(args.getOrElse(1) { usage() })))
                "sign" -> {
                    if (args.size < 5) usage()
                    val manifest = File(args[1])
                    val signed = sign(manifest.readText(), manifest.absoluteFile.parentFile, File(args[2]).readText().trim(),
                        File(args[2] + ".pub").readText().trim(), args[3].toLong(), args[4].toLong())
                    val out = File(args.getOrElse(5) { args[1] })
                    out.writeText(signed)
                    println("signed ${out.path}")
                }
                else -> usage()
            }
        } catch (failure: Exception) {
            System.err.println("error: ${failure.message}")
            kotlin.system.exitProcess(1)
        }
    }

    private fun usage(): Nothing {
        System.err.println("usage: RepositorySigner keygen <key-out> | sign <manifest.json> <key> <catalogVersion> <validDays> [out]")
        kotlin.system.exitProcess(2)
    }

    /** Returns the base64 raw public key; writes the private key with 0600 permissions. */
    fun keygen(privateKeyOut: File): String {
        require(!privateKeyOut.exists()) { "Refusing to overwrite ${privateKeyOut.path}" }
        val pair = KeyPairGenerator.getInstance("Ed25519").generateKeyPair()
        privateKeyOut.writeText(Base64.getEncoder().encodeToString(pair.private.encoded) + "\n")
        privateKeyOut.setReadable(false, false); privateKeyOut.setReadable(true, true)
        privateKeyOut.setWritable(false, false); privateKeyOut.setWritable(true, true)
        val publicKey = Base64.getEncoder().encodeToString(pair.public.encoded.takeLast(32).toByteArray())
        File(privateKeyOut.path + ".pub").writeText(publicKey + "\n")
        return publicKey
    }

    /** Produces the signed manifest text. [listDirectory] resolves relative list references. */
    fun sign(manifestText: String, listDirectory: File, privateKeyBase64: String, publicKey: String, catalogVersion: Long, validDays: Long,
             now: Instant = Instant.now(), listBytes: (String) -> ByteArray = { File(listDirectory, it).readBytes() }): String {
        require(catalogVersion in 1..9_007_199_254_740_991L) { "catalogVersion must be a positive integer" }
        require(validDays in 1..30) { "validity must be between 1 and 30 days" }
        val root = RepositoryJson.parse(manifestText).jsonObject - "signature"
        val lists = root["pluginLists"]?.jsonArray?.map { it.jsonPrimitive.content }.orEmpty()
        require(lists.isNotEmpty() && lists.distinct().size == lists.size) { "manifest must list each plugin list once" }
        val hashes = lists.associateWith { reference ->
            require("://" !in reference) { "sign lists by relative path so the signed bytes are the published bytes: $reference" }
            val bytes = listBytes(reference)
            RepositoryJson.parse(bytes.toString(Charsets.UTF_8)).jsonArray.forEachIndexed { index, entry ->
                val hash = entry.jsonObject["fileHash"]?.jsonPrimitive?.content
                require(RepositoryService.normalizedHash(hash) != null) { "$reference entry $index lacks a valid fileHash" }
            }
            ArtifactDigest.sha256(bytes)
        }
        val payload = JsonObject(root + mapOf(
            "catalogVersion" to JsonPrimitive(catalogVersion),
            "expiresAt" to JsonPrimitive(now.plusSeconds(validDays * 86_400).toString()),
            "pluginListHashes" to JsonObject(hashes.mapValues { JsonPrimitive(it.value) }),
        ))
        val key: PrivateKey = KeyFactory.getInstance("Ed25519").generatePrivate(PKCS8EncodedKeySpec(Base64.getDecoder().decode(privateKeyBase64)))
        val signer = Signature.getInstance("Ed25519")
        signer.initSign(key)
        signer.update(RepoSignature.canonicalize(payload).toByteArray(Charsets.UTF_8))
        val signed = JsonObject(payload + ("signature" to JsonObject(mapOf(
            "algorithm" to JsonPrimitive("ed25519"),
            "format" to JsonPrimitive("cloudstream-json-v1"),
            "publicKey" to JsonPrimitive(publicKey),
            "value" to JsonPrimitive(Base64.getEncoder().encodeToString(signer.sign())),
        ))))
        // Self-check with the production verifier before anything is published.
        val verification = requireNotNull(RepoSignature.verify(signed.toString(), publicKey))
        check(verification.valid) { "signature self-check failed: ${verification.reason}" }
        return signed.toString()
    }
}
