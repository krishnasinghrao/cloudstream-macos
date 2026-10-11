package com.lagradost.macos

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardOpenOption.APPEND
import java.nio.file.StandardOpenOption.CREATE
import java.nio.file.StandardOpenOption.WRITE
import java.nio.file.attribute.PosixFilePermissions
import java.time.Instant

/**
 * Append-only, hash-chained record of security-relevant extension events
 * (repository add/remove/sync/consent/trust, install/update/rollback/uninstall,
 * enable/disable, revoke/quarantine). Each line carries the SHA-256 of the
 * previous line, so edits or deletions inside a file are detectable.
 * Values are identifiers and digests only — never credentials or cookies.
 */
object AuditLog {
    private const val MAX_BYTES = 4L * 1024 * 1024
    private val lock = Any()
    private var head: String? = null
    private val file: File get() = File(CloudDirs.stateDir, "audit.log")
    private val rotated: File get() = File(CloudDirs.stateDir, "audit.log.1")

    fun record(event: String, fields: Map<String, Any?> = emptyMap(), actor: String = "user") = synchronized(lock) {
        try {
            AtomicFiles.privateDirectory(file.parentFile.toPath())
            if (file.exists() && file.length() > MAX_BYTES) {
                Files.move(file.toPath(), rotated.toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING)
            }
            val previous = head ?: lastLineHash(file) ?: lastLineHash(rotated) ?: "genesis"
            val entry = JsonObject(buildMap {
                put("at", JsonPrimitive(Instant.now().toString()))
                put("event", JsonPrimitive(event))
                put("actor", JsonPrimitive(actor))
                fields.forEach { (key, value) -> if (value != null) put(key, JsonPrimitive(value.toString())) }
                put("prev", JsonPrimitive(previous))
            })
            val line = RepoSignature.canonicalize(entry) + "\n"
            val path = file.toPath()
            val created = !Files.exists(path)
            Files.write(path, line.toByteArray(Charsets.UTF_8), CREATE, WRITE, APPEND)
            if (created) Files.setPosixFilePermissions(path, PosixFilePermissions.fromString("rw-------"))
            head = ArtifactDigest.sha256(line.trimEnd('\n').toByteArray(Charsets.UTF_8))
        } catch (failure: Exception) {
            DaemonLog.error("audit.write_failed", mapOf("event" to event, "error" to failure.javaClass.simpleName))
        }
    }

    /** Newest entries first, bounded. */
    fun recent(limit: Int = 200): List<String> = synchronized(lock) {
        (readLines(rotated) + readLines(file)).takeLast(limit.coerceIn(1, 5_000)).reversed()
    }

    /** Tests only: forget the cached chain head (the data root was reset). */
    internal fun resetForTest() = synchronized(lock) { head = null }

    /** Verifies the chain across the rotated and current files. */
    fun verify(): Boolean = synchronized(lock) {
        var previous: String? = null
        for (line in readLines(rotated) + readLines(file)) {
            val prev = try { RepositoryJson.parse(line).jsonObject["prev"]?.jsonPrimitive?.content } catch (_: Exception) { return false }
            if (previous != null && prev != previous) return false
            previous = ArtifactDigest.sha256(line.toByteArray(Charsets.UTF_8))
        }
        true
    }

    private fun readLines(target: File): List<String> =
        if (target.isFile) target.readLines(Charsets.UTF_8).filter { it.isNotBlank() } else emptyList()

    private fun lastLineHash(target: File): String? = readLines(target).lastOrNull()?.let { ArtifactDigest.sha256(it.toByteArray(Charsets.UTF_8)) }
}
