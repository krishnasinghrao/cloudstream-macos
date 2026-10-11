package com.lagradost.macos

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Background `MainAPI.extractorVerifierJob` runs (Android download/player
 * parity): some hosts expire a link unless the provider keeps polling while
 * the link is in use. The client starts a job when an attempt begins and
 * stops it when the attempt ends.
 *
 * Bounded by design: at most [MAX_JOBS] concurrent jobs and a hard lifetime
 * of [MAX_LIFETIME_MS], so a client that crashes without calling stop can't
 * leak work forever. Provider failures are contained (Rules.md §4.2).
 */
object VerifierJobs {
    private const val MAX_JOBS = 16
    private const val MAX_LIFETIME_MS = 6 * 60 * 60 * 1000L

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private data class Owned(val job: Job, val installationId: String?, val generation: String?)
    private val jobs = ConcurrentHashMap<String, Owned>()

    /** Returns a job ID, or null when no provider/verifier applies. */
    fun start(source: String, extractorData: String): String? {
        if (extractorData.isEmpty()) return null
        val provider = ProviderExecutor.findProvider(source) ?: return null
        val owner = PluginBridge.ownerOf(provider)
        synchronized(jobs) {
            if (jobs.size >= MAX_JOBS) return null
            val id = UUID.randomUUID().toString()
            // LAZY: registered before it can run, so a verifier that ends
            // instantly (the NotImplementedError default) can't leave a stale
            // map entry behind.
            val job = scope.launch(start = CoroutineStart.LAZY) {
                try {
                    withTimeoutOrNull(MAX_LIFETIME_MS) {
                        PluginBridge.withLease(provider) { provider.extractorVerifierJob(extractorData) }
                    }
                } catch (_: NotImplementedError) {
                    // The default: provider has no verifier.
                } catch (t: Throwable) {
                    if (t !is kotlinx.coroutines.CancellationException) {
                        DaemonLog.warn(
                            "verifier.failed",
                            mapOf("provider" to provider.name, "error" to (t.javaClass.simpleName)),
                        )
                    }
                } finally {
                    jobs.remove(id)
                }
            }
            jobs[id] = Owned(job, owner?.installationId, owner?.generation)
            job.start()
            return id
        }
    }

    fun stop(id: String) {
        jobs.remove(id)?.job?.cancel()
    }

    /** Host-owned work never outlives the generation it was started for. */
    fun cancelFor(installationId: String, generation: String) {
        jobs.entries.filter { it.value.installationId == installationId && it.value.generation == generation }
            .forEach { (id, owned) -> jobs.remove(id); owned.job.cancel() }
    }

    val activeCount: Int get() = jobs.size
}
