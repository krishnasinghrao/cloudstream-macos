package com.lagradost.macos

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.File
import java.time.Instant
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * Structured local logger (SEC-03: nothing leaves the machine).
 *
 * Writes JSON lines to `~/.cloudstream-macos/logs/daemon.log` with size-based
 * rotation (5 MB, 3 rotated files). Secrets are redacted before serialization:
 * values under sensitive keys entirely, and every other value through the
 * diagnostics redactor (URL secrets, auth headers, key=value tokens), so
 * nothing written here needs a second pass (L1). Files are owner-only.
 * The native client tees raw process stdout into the same directory.
 */
object DaemonLog {
    private const val MAX_FILE_BYTES = 5L * 1024 * 1024
    private const val MAX_ROTATED_FILES = 3

    enum class Level { DEBUG, INFO, WARN, ERROR }

    private val lock = ReentrantLock()
    private var logFile: File? = null
    private var json = Json

    fun init(logDir: File = CloudDirs.logDir) {
        lock.withLock {
            OwnerOnly.mkdirs(logDir)
            logFile = File(logDir, "daemon.log").also(OwnerOnly::file)
        }
    }

    /** The value as written: sensitive keys are dropped, other text is redacted. */
    internal fun redactedValue(key: String, value: Any?): String? = when {
        value == null -> null
        DiagnosticsExport.sensitiveKey.containsMatchIn(key) -> "[REDACTED]"
        else -> DiagnosticsExport.redactText(value.toString())
    }

    fun debug(event: String, fields: Map<String, Any?> = emptyMap()) = log(Level.DEBUG, event, fields)
    fun info(event: String, fields: Map<String, Any?> = emptyMap()) = log(Level.INFO, event, fields)
    fun warn(event: String, fields: Map<String, Any?> = emptyMap()) = log(Level.WARN, event, fields)
    fun error(event: String, fields: Map<String, Any?> = emptyMap(), throwable: Throwable? = null) =
        log(Level.ERROR, event, fields + buildMap {
            if (throwable != null) {
                put("exception", throwable.javaClass.simpleName)
                put("message", throwable.message)
            }
        })

    private fun log(level: Level, event: String, fields: Map<String, Any?>) {
        val entry: JsonObject = buildJsonObject {
            put("ts", Instant.now().toString())
            put("level", level.name)
            put("event", event)
            if (fields.isNotEmpty()) {
                put("fields", JsonObject(
                    fields.mapValues { (k, v) -> kotlinx.serialization.json.JsonPrimitive(redactedValue(k, v)) },
                ))
            }
        }
        val line = json.encodeToString(JsonObject.serializer(), entry)

        lock.withLock {
            val file = logFile ?: return
            rotateIfNeeded(file)
            try {
                val created = !file.exists()
                file.appendText(line + "\n")
                if (created) OwnerOnly.file(file)
            } catch (_: Exception) {
                // Logging must never take the daemon down.
            }
        }
        // Mirror to stdout — the supervisor tees this into process.log and
        // developers see it in the console.
        println(line)
    }

    private fun rotateIfNeeded(file: File) {
        if (file.length() < MAX_FILE_BYTES) return
        // daemon.log.2 -> delete, .1 -> .2, .0 -> .1, log -> .0
        for (i in MAX_ROTATED_FILES - 1 downTo 0) {
            val source = if (i == 0) file else File(file.parentFile, "${file.name}.$i")
            val target = File(file.parentFile, "${file.name}.${i + 1}")
            if (source.exists()) {
                if (i == MAX_ROTATED_FILES - 1) source.delete() else source.renameTo(target)
            }
        }
    }
}
