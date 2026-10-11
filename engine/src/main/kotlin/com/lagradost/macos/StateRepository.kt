package com.lagradost.macos

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS

/**
 * Publishes memory only after durable disk commit. A damaged/unknown policy is
 * read-only until explicitly repaired; an old backup is never silently adopted
 * because it may restore a revoked key or removed installation.
 */
internal class StateRepository(val file: File) {
    private val json = Json { prettyPrint = true; ignoreUnknownKeys = true; encodeDefaults = true }
    private val mutex = Any()
    @Volatile private var current = DaemonState.PersistedState()
    @Volatile var recoveryError: String? = null
        private set

    val backupFile: File get() = File(file.parentFile, "${file.name}.previous")

    fun snapshot(): DaemonState.PersistedState = current

    fun load() = synchronized(mutex) {
        try {
            removeInterruptedWrites()
            val path = file.toPath()
            val candidate = if (!Files.exists(path, NOFOLLOW_LINKS)) {
                check(!backupFile.exists()) { "State file is missing but a previous policy exists" }
                DaemonState.PersistedState()
            } else {
                check(Files.isRegularFile(path, NOFOLLOW_LINKS)) { "State is not a regular file" }
                check(Files.size(path) <= MAX_BYTES) { "State exceeds the supported size" }
                val text = file.readText()
                // Files written before schema versioning omitted defaults, so an
                // absent version means schema 1, never "current".
                val version = json.parseToJsonElement(text).jsonObject["version"]?.jsonPrimitive?.int ?: 1
                json.decodeFromString<DaemonState.PersistedState>(text).copy(version = version)
            }
            val migrated = migrate(candidate)
            validate(migrated)
            current = migrated
            recoveryError = null
            if (migrated.version != candidate.version) {
                // Persist the upgrade now: credentials and retired fields from
                // older schemas must not linger on disk.
                val encoded = json.encodeToString(migrated).toByteArray(Charsets.UTF_8)
                AtomicFiles.write(file.toPath(), encoded)
                AtomicFiles.write(backupFile.toPath(), encoded)
                DaemonLog.info("state.migrated", mapOf("from" to candidate.version, "to" to migrated.version))
            }
        } catch (failure: Exception) {
            recoveryError = "Saved extension policy needs recovery. Plugin execution and mutations are disabled."
            DaemonLog.error("state.recovery_required", mapOf("error" to failure.message))
        }
    }

    fun requireHealthy() {
        check(recoveryError == null) { recoveryError.orEmpty() }
    }

    fun update(transform: (DaemonState.PersistedState) -> DaemonState.PersistedState) = synchronized(mutex) {
        requireHealthy()
        val candidate = transform(current)
        validate(candidate)
        val encoded = json.encodeToString(candidate).toByteArray(Charsets.UTF_8)
        require(encoded.size <= MAX_BYTES) { "Extension state exceeds the supported size" }
        try {
            if (file.exists()) {
                AtomicFiles.write(backupFile.toPath(), json.encodeToString(current).toByteArray(Charsets.UTF_8))
            }
            AtomicFiles.write(file.toPath(), encoded)
            current = candidate
        } catch (failure: Exception) {
            // A failed fsync after rename may have published the candidate on
            // disk. Refuse further work rather than assume either generation.
            recoveryError = "Extension state could not be committed. Reload or repair storage before continuing."
            DaemonLog.error("state.write_failed", mapOf("error" to failure.message))
            throw IOException(recoveryError, failure)
        }
    }

    /** A process killed mid-commit leaves AtomicFiles' temp file behind (its `finally` never ran). */
    private fun removeInterruptedWrites() {
        val prefixes = listOf(".${file.name}-", ".${backupFile.name}-")
        file.parentFile?.listFiles()?.filter { candidate ->
            candidate.isFile && candidate.name.endsWith(".tmp") && prefixes.any { candidate.name.startsWith(it) }
        }?.forEach { it.delete() }
    }

    /** Forward-only schema upgrades. Unknown (newer) schemas stay read-only. */
    private fun migrate(state: DaemonState.PersistedState): DaemonState.PersistedState {
        require(state.version in 1..DaemonState.SCHEMA_VERSION) { "Unsupported extension state schema ${state.version}" }
        var migrated = state
        // v1 → v2: trust tiers, consent, rollback generations. Every v1 receipt
        // was signed-only; retired removed-hash tombstones and plaintext
        // credentials are dropped by decoding with the v2 model.
        if (migrated.version == 1) migrated = migrated.copy(version = 2)
        // v2 receipts retain their old catalog proofs and decode with their
        // original authority mode. Hashless observations are created only by
        // a new consented download; migration never invents that evidence.
        if (migrated.version == 2) migrated = migrated.copy(version = 3)
        return migrated
    }

    private fun validate(state: DaemonState.PersistedState) {
        require(state.version == DaemonState.SCHEMA_VERSION) { "Unsupported extension state schema ${state.version}" }
        require(state.repos.map { it.url }.distinct().size == state.repos.size) { "Duplicate repository identities" }
    }

    companion object { private const val MAX_BYTES = 16 * 1024 * 1024 }
}
