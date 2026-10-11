package com.lagradost.macos

import com.lagradost.cloudstream3.MainAPI
import com.lagradost.macos.models.OperationFailureDto
import com.lagradost.macos.models.OperationHealthDto
import com.lagradost.macos.worker.RemoteProvider

/**
 * Last outcome of each provider operation stage, per installation generation
 * (plan RT-16). Registration is not health: an extension is only shown as
 * working for a stage after that stage succeeded for its current generation.
 * A new generation starts unknown. Entries hold the redacted public failure
 * record only — never URLs, queries or provider data — and are bounded.
 * They are saved (debounced, atomically) so a restart keeps what is known
 * about the installed versions; entries of versions no longer installed are
 * dropped when loading.
 */
internal object OperationHealth {
    private const val MAX_ENTRIES = 4_096

    @kotlinx.serialization.Serializable
    private data class Key(val installationId: String, val generation: String, val providerId: String, val stage: String)

    @kotlinx.serialization.Serializable
    private data class Saved(val key: Key, val outcome: OperationHealthDto)

    private const val SAVE_DELAY_MS = 5_000L
    private const val MAX_FILE_BYTES = 4 * 1024 * 1024
    private val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
    private val file get() = java.io.File(CloudDirs.stateDir, "operation-health.json")
    private val saver = java.util.concurrent.Executors.newSingleThreadScheduledExecutor { action ->
        Thread(action, "operation-health-save").apply { isDaemon = true }
    }
    private val savePending = java.util.concurrent.atomic.AtomicBoolean(false)
    private var scheduledSave: java.util.concurrent.ScheduledFuture<*>? = null
    @Volatile private var loadedFrom: String? = null

    private val outcomes = object : LinkedHashMap<Key, OperationHealthDto>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Key, OperationHealthDto>?) = size > MAX_ENTRIES
    }

    /** Stages reported to the app. */
    object Stage {
        const val SEARCH = "search"
        const val HOME = "home"
        const val DETAILS = "details"
        const val LINKS = "links"
    }

    private val lastAt = java.util.concurrent.atomic.AtomicLong(0)
    private fun nextAt(): Long {
        val now = System.currentTimeMillis()
        return lastAt.updateAndGet { prev -> maxOf(now, prev + 1) }
    }

    fun success(provider: MainAPI, stage: String) = record(provider, stage, null)

    fun failure(provider: MainAPI, stage: String, failure: OperationFailureDto) = record(provider, stage, failure)

    private fun record(provider: MainAPI, stage: String, failure: OperationFailureDto?) {
        val installationId = provider.sourcePlugin ?: return // built-in providers have no installation row
        val generation = (provider as? RemoteProvider)?.handle?.record?.generation
            ?: PluginBridge.loadedInstallation(installationId)?.generation ?: return
        val providerId = PluginBridge.providerId(provider)
        val outcome = OperationHealthDto(
            provider = provider.name.take(200), providerId = providerId, stage = stage, ok = failure == null,
            code = failure?.code, message = failure?.publicMessage, at = nextAt(),
        )
        ensureLoaded()
        synchronized(outcomes) {
            outcomes[Key(installationId, generation, providerId, stage)] = outcome
            if (savePending.compareAndSet(false, true)) {
                scheduledSave?.cancel(false)
                scheduledSave = saver.schedule({ save() }, SAVE_DELAY_MS, java.util.concurrent.TimeUnit.MILLISECONDS)
            }
        }
    }

    /** Loads saved outcomes once per data root, keeping only currently installed generations. */
    private fun ensureLoaded() {
        val path = file.path
        if (loadedFrom == path) return
        synchronized(outcomes) {
            if (loadedFrom == path) return
            loadedFrom = path
            outcomes.clear()
            runCatching {
                val source = file
                if (!source.isFile || source.length() > MAX_FILE_BYTES) return@runCatching
                val installed = DaemonState.snapshot().installations.values.associate { it.id to it.generation }
                json.decodeFromString(kotlinx.serialization.builtins.ListSerializer(Saved.serializer()), source.readText())
                    .filter { installed[it.key.installationId] == it.key.generation }
                    .takeLast(MAX_ENTRIES).forEach { outcomes[it.key] = it.outcome }
            }
        }
    }

    /** Writes the current outcomes now (also called by the debounce timer). */
    internal fun save() {
        val snapshot = synchronized(outcomes) {
            savePending.set(false)
            scheduledSave?.cancel(false)
            scheduledSave = null
            outcomes.entries.map { Saved(it.key, it.value) }
        }
        runCatching {
            AtomicFiles.write(file.toPath(), json.encodeToString(kotlinx.serialization.builtins.ListSerializer(Saved.serializer()), snapshot).toByteArray())
        }.onFailure { DaemonLog.warn("operation_health.save_failed", mapOf("error" to it.javaClass.simpleName)) }
    }

    /** Latest outcome per provider and stage for this generation, newest first. */
    fun forGeneration(installationId: String, generation: String): List<OperationHealthDto> = ensureLoaded().let { synchronized(outcomes) {
        outcomes.entries.filter { it.key.installationId == installationId && it.key.generation == generation }.map { it.value }
    } }.sortedByDescending { it.at }

    /** Tests only. */
    internal fun clearForTest() = synchronized(outcomes) {
        savePending.set(false)
        scheduledSave?.cancel(false)
        scheduledSave = null
        outcomes.clear()
        loadedFrom = null
        lastAt.set(0)
        file.delete()
    }

    /** Tests only: forget in-memory state so the next read loads from disk, as after a restart. */
    internal fun reloadForTest() = synchronized(outcomes) {
        savePending.set(false)
        scheduledSave?.cancel(false)
        scheduledSave = null
        outcomes.clear()
        loadedFrom = null
    }
}
