package com.lagradost.macos

import com.lagradost.macos.models.HealthDto
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.File

/**
 * Support bundle (plan T8.5): extension and repository state, recent audit
 * entries and recent engine log lines, with credentials, cookies, tokens and
 * URL secrets removed. Everything is local; the user decides where it goes.
 */
internal object DiagnosticsExport {
    private const val MAX_LOG_LINES = 500

    internal val sensitiveKey = Regex("(?i)token|password|passwd|secret|cookie|authorization|credential|api[_-]?key|session")
    private val url = Regex("""(?i)\b([a-z][a-z0-9+.-]*://)([^\s"'<>]+)""")
    private val bearer = Regex("""(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}""")
    /**
     * key=value / key: value / "key": "value" secrets. Prefixed and camel-cased
     * names count (`access_token`, `hashedToken`, `X-Auth-Token`), so there is
     * no leading word boundary; JSON keys may be quoted.
     */
    private val keyValue = Regex("""(?i)(["']?)([A-Za-z0-9_.-]*(?:token|password|passwd|secret|cookie|authorization|credentials?|api[_-]?key|session(?:id)?|cf_clearance|signature|sig))\1(\s*[=:]\s*)("[^"]*"|'[^']*'|[^\s,;&"'}\]]+)""")
    /** A path segment that looks like a credential: long, and mixing letters with digits. */
    private val opaqueSegment = Regex("""^[A-Za-z0-9_~.=-]{24,}$""")

    /** Removes URL userinfo/query/fragment, auth headers and key=value secrets from free text. */
    fun redactText(text: String): String {
        var out = url.replace(text) { match ->
            val rest = match.groupValues[2]
            val authorityEnd = rest.indexOfAny(charArrayOf('/', '?', '#')).let { if (it < 0) rest.length else it }
            val at = rest.lastIndexOf('@', authorityEnd - 1)
            val withoutUser = if (at >= 0) rest.substring(at + 1) else rest
            val hostAndPath = withoutUser.substringBefore('?').substringBefore('#')
            val stripped = rest.length != hostAndPath.length
            match.groupValues[1] + redactPathSegments(hostAndPath) + if (stripped) "?[REDACTED]" else ""
        }
        out = bearer.replace(out) { "${it.groupValues[1]} [REDACTED]" }
        out = keyValue.replace(out) { "${it.groupValues[1]}${it.groupValues[2]}${it.groupValues[1]}${it.groupValues[3]}[REDACTED]" }
        return out
    }

    /** Keeps the host and ordinary path names; replaces token-like segments (`/file/<token>/video.mp4`). */
    private fun redactPathSegments(hostAndPath: String): String {
        val slash = hostAndPath.indexOf('/')
        if (slash < 0) return hostAndPath
        val segments = hostAndPath.substring(slash + 1).split('/').map { segment ->
            if (opaqueSegment.matches(segment) && segment.any(Char::isDigit) && segment.any(Char::isLetter)) "[REDACTED]" else segment
        }
        return hostAndPath.substring(0, slash + 1) + segments.joinToString("/")
    }

    /** Redacts values under sensitive keys and free text everywhere else. */
    fun redact(element: JsonElement, key: String? = null): JsonElement = when {
        key != null && sensitiveKey.containsMatchIn(key) && element !is JsonNull -> JsonPrimitive("[REDACTED]")
        element is JsonObject -> JsonObject(element.mapValues { (k, v) -> redact(v, k) })
        element is JsonArray -> JsonArray(element.map { redact(it) })
        element is JsonPrimitive && element.isString -> JsonPrimitive(redactText(element.content))
        else -> element
    }

    fun build(health: HealthDto): JsonObject {
        val state = DaemonState.snapshot()
        val manager = RepositoryService.installations
        val raw = buildJsonObject {
            put("format", "cloudstream-diagnostics-v1")
            put("generatedAt", java.time.Instant.now().toString())
            put("engine", buildJsonObject {
                put("ipcVersion", HealthDto.IPC_VERSION)
                put("uptimeMs", health.uptimeMs)
                put("providersLoaded", health.providersLoaded)
                put("safeMode", DaemonRuntime.safeMode)
                put("policyManaged", DaemonRuntime.policy.managed)
                put("recoveryError", DaemonState.recoveryError)
                put("restorePhase", manager.restoreState.phase)
                put("java", System.getProperty("java.version"))
                put("os", "${System.getProperty("os.name")} ${System.getProperty("os.version")} ${System.getProperty("os.arch")}")
            })
            put("repositories", buildJsonArray {
                state.repos.forEach { repo ->
                    add(buildJsonObject {
                        put("url", repo.url)
                        put("tier", repo.tier.name.lowercase())
                        put("consented", repo.consent != null)
                        put("keyFingerprint", repo.pinnedKeyFingerprint)
                        put("lastSyncedAt", repo.lastSyncedAt)
                        put("lastAttemptAt", repo.lastAttemptAt)
                        put("lastError", repo.lastError)
                        put("discoveredVia", repo.discoveredVia)
                    })
                }
            })
            put("extensions", buildJsonArray {
                state.installations.values.sortedBy { it.metadata.name.lowercase() }.forEach { record ->
                    add(buildJsonObject {
                        put("installationId", record.id)
                        put("name", record.metadata.name)
                        put("repository", record.repositoryUrl)
                        put("version", record.metadata.version)
                        put("tier", record.tier.name.lowercase())
                        put("sha256", record.artifactHash)
                        put("enabled", record.enabled)
                        put("running", manager.isRunning(record))
                        put("revokedReason", record.revokedReason)
                        put("quarantinedReason", record.quarantinedReason)
                        put("lastError", manager.lastError(record.id))
                        put("providers", JsonArray(record.providerNames.map(::JsonPrimitive)))
                    })
                }
            })
            put("disabledProviders", JsonArray(state.disabledProviders.sorted().map(::JsonPrimitive)))
            put("audit", buildJsonObject {
                put("chainVerified", AuditLog.verify())
                put("entries", JsonArray(AuditLog.recent(200).map(::JsonPrimitive)))
            })
            put("log", JsonArray(recentLogLines().map(::JsonPrimitive)))
        }
        return redact(raw) as JsonObject
    }

    private fun recentLogLines(): List<String> {
        val files = listOf("daemon.log.0", "daemon.log").map { File(CloudDirs.logDir, it) }.filter { it.isFile }
        return files.flatMap { file -> runCatching { file.readLines() }.getOrDefault(emptyList()) }.takeLast(MAX_LOG_LINES)
    }
}
