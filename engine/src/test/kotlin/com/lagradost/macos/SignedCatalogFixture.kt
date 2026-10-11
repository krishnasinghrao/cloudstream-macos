package com.lagradost.macos

import kotlinx.serialization.json.*
import java.security.KeyPairGenerator
import java.security.Signature
import java.time.Instant
import java.util.Base64

/** Every fixture uses a real ephemeral Ed25519 key; no verifier bypass. */
internal class SignedCatalogFixture(val url: String = "https://signed-fixture.invalid/repo.json") {
    private val keys = KeyPairGenerator.getInstance("Ed25519").generateKeyPair()
    val expiry: Instant = Instant.now().plusSeconds(86400)
    val hash = ArtifactDigest.sha256("signed fixture source".toByteArray())
    val list = """[{"name":"Fixture","internalName":"Fixture","url":"Fixture.cs3","status":2,"fileHash":"$hash"}]"""

    fun manifest(body: String = list, revision: Long = 1, expires: Instant = expiry, title: String = "fixture", bindList: Boolean = true): String =
        sign(buildJsonObject {
            put("name", title); put("manifestVersion", 1); put("catalogVersion", revision); put("expiresAt", expires.toString())
            put("pluginLists", buildJsonArray { add("list.json") })
            put("pluginListHashes", buildJsonObject { if (bindList) put("list.json", ArtifactDigest.sha256(body.toByteArray())) })
        })

    fun sign(payload: JsonObject): String {
        val signer = Signature.getInstance("Ed25519")
        signer.initSign(keys.private)
        signer.update(RepoSignature.canonicalize(payload).toByteArray())
        val encoder = Base64.getEncoder()
        return JsonObject(payload + ("signature" to buildJsonObject {
            put("algorithm", "ed25519")
            put("publicKey", encoder.encodeToString(keys.public.encoded.takeLast(32).toByteArray()))
            put("value", encoder.encodeToString(signer.sign()))
        })).toString()
    }

    /** Catalog list with one entry per artifact (name → bytes), served next to the manifest. */
    fun listFor(artifacts: Map<String, ByteArray>, version: Int = 1, status: Int = 1): String =
        buildJsonArray {
            artifacts.forEach { (name, bytes) -> add(buildJsonObject {
                put("name", name); put("internalName", name); put("url", "$name.cs3"); put("status", status)
                put("version", version); put("fileHash", ArtifactDigest.sha256(bytes)); put("fileSize", bytes.size)
            }) }
        }.toString()

    fun fetcher(manifest: String = manifest(), list: String = this.list, artifacts: Map<String, ByteArray> = emptyMap()): RepositoryFetcher =
        RepositoryFetcher { requested, max ->
            val body = when (requested) {
                url -> manifest.toByteArray()
                RepositoryService.resolveUrl(url, "list.json") -> list.toByteArray()
                else -> artifacts.entries.firstOrNull { RepositoryService.resolveUrl(url, "${it.key}.cs3") == requested }?.value
                    ?: error("Unexpected fixture fetch: $requested")
            }
            check(body.size <= max)
            RepositoryDocument(body, requested)
        }

    /**
     * Signed catalog + artifact server for [artifacts]; returns the fetcher used.
     * [consent]: the user allows installs from this repository after its first
     * sync, as the app asks for every repository whose key policy has not pinned (M4).
     */
    suspend fun publish(artifacts: Map<String, ByteArray>, revision: Long, version: Int = 1, status: Int = 1,
        consent: Boolean = true): RepositoryFetcher {
        val body = listFor(artifacts, version, status)
        val fetcher = fetcher(manifest(body, revision = revision), body, artifacts)
        RepositoryService.sync(url, fetcher)
        if (consent) consentIfNeeded()
        return fetcher
    }

    /** Records the user's first-time consent unless it exists or policy pins this repository's key. */
    fun consentIfNeeded() {
        val repo = DaemonState.snapshot().repos.singleOrNull { it.url == url } ?: return
        if (repo.consent == null && DaemonRuntime.policy.needsConsent(DaemonState.TrustTier.VERIFIED, url)) {
            RepositoryService.setConsent(url, true, actor = "test")
        }
    }
}
