package com.lagradost.macos.worker

import com.lagradost.cloudstream3.MainAPI
import com.lagradost.cloudstream3.TvType
import com.lagradost.cloudstream3.VPNStatus
import com.lagradost.cloudstream3.plugins.BasePlugin
import com.lagradost.macos.ArtifactStore
import com.lagradost.macos.CloudDirs
import com.lagradost.macos.DaemonLog
import com.lagradost.macos.DaemonState
import com.lagradost.macos.ExtensionRuntime
import com.lagradost.macos.NetworkSetup
import com.lagradost.macos.PluginBridge
import com.lagradost.macos.PreparedExtension
import com.lagradost.macos.ProviderOverrides
import com.lagradost.macos.SolveBridge
import com.lagradost.macos.URLSanitizer
import com.lagradost.macos.models.DetailsDto
import com.lagradost.macos.models.HomePageDto
import com.lagradost.macos.models.LinksResponseDto
import com.lagradost.macos.models.SearchResultDto
import com.lagradost.macos.models.StreamLinkDto
import com.lagradost.macos.models.SubtitleDto
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.KSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.JsonElement
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.concurrent.ConcurrentHashMap

/**
 * One installation generation hosted by a worker process. The worker starts on
 * first use (or immediately when metadata must be learned) and can be stopped
 * and restarted transparently until the generation is retired.
 */
internal class WorkerHandle(
    val record: DaemonState.InstalledExtension,
    private val artifact: File,
    private val launcher: WorkerLauncher,
    private val reuseTranslation: Boolean,
    private val startupTimeoutMs: Long = INIT_TIMEOUT_MS,
    private val homePreparation: (() -> File)? = null,
    private val workerCommand: (File, File) -> List<String> = { home, file ->
        WorkerPool.heapFor(record.id)?.let { launcher.command(home, file, it) } ?: launcher.command(home, file)
    },
) {
    private val lifecycleLock = Any()
    private val callers = java.util.concurrent.atomic.AtomicInteger()
    val awaitingOrActiveCalls: Int get() = callers.get()
    @Volatile private var client: WorkerClient? = null
    @Volatile var retired = false
        private set
    @Volatile var initResult: InitResult? = null
        private set

    val installationId: String get() = record.id
    val running: Boolean get() = client?.alive == true
    val activeCalls: Int get() = client?.activeCalls ?: 0
    val lastUsed: Long get() = client?.lastUsed ?: 0L
    val pid: Long? get() = client?.takeIf { it.alive }?.pid

    /** Starts are shared and run outside any caller's scope, so a caller's own
     * deadline never cancels (and kills) a worker that is still loading. */
    @Volatile private var starting: kotlinx.coroutines.Deferred<WorkerClient>? = null

    /**
     * The running worker, starting it if needed. [waitForCapacity] false refuses
     * at once when the pool is full instead of waiting [WorkerPool.capacityWaitMs].
     * One in-flight start is shared by every caller, so the wait policy of the
     * caller that began it applies to all of them; a nested caller that joins a
     * waiting start may wait, which is never worse than its own fast refusal.
     */
    suspend fun ensure(waitForCapacity: Boolean = true): WorkerClient {
        val start = synchronized(lifecycleLock) {
            check(!retired) { "This extension version was replaced or removed." }
            client?.takeIf { it.acceptingCalls }?.let { return it }
            starting?.takeIf { !it.isCompleted } ?: WorkerPool.scope.async {
                withTimeout(startupTimeoutMs) { start(waitForCapacity) }
            }.also { starting = it }
        }
        return start.await()
    }

    private suspend fun start(waitForCapacity: Boolean): WorkerClient {
        if (!launcher.sandboxed && com.lagradost.macos.DaemonRuntime.policy.requireSandbox) {
            throw com.lagradost.macos.PolicyException("Your organization requires extensions to run in the macOS sandbox, which is not available on this Mac.")
        }
        var reservation: WorkerPool.Reservation? = null
        var started: WorkerClient? = null
        var published = false
        try {
            currentCoroutineContext().ensureActive()
            val slot = WorkerPool.admit(this, if (waitForCapacity) WorkerPool.capacityWaitMs else 0L).also { reservation = it }
            val home = homePreparation?.invoke() ?: prepareHome()
            currentCoroutineContext().ensureActive()
            check(!retired) { "This extension version was replaced or removed." }
            val worker = WorkerClient(record.id, workerCommand(home, artifact), launcher.workingDirectory(home), launcher.environment(home),
                solve = { request -> SolveBridge.solveForWorker(request.targetUrl, request.userAgent) },
                extract = { request -> com.lagradost.macos.ExtractorRouter.answer(record.id, request) },
                resolveMedia = { spec -> com.lagradost.macos.MediaResolveBridge.resolve(spec) },
                webView = { request -> com.lagradost.macos.WebViewSessionBridge.handle(record.id, request) },
                onExit = { exited, expected, reason ->
                    // Its WebViews end with the process that drove them.
                    com.lagradost.macos.WebViewSessionBridge.release(record.id)
                    synchronized(lifecycleLock) { if (client === exited) client = null }
                    WorkerPool.release(slot)
                    if (exited.outOfMemory) WorkerPool.raiseHeap(record.id)
                    if (!expected && !retired) WorkerPool.recordCrash(record.id, reason)
                }).also { started = it }
            check(WorkerPool.attach(slot, worker)) { "The extension startup was stopped." }
            val request = InitRequest(record, artifact.canonicalPath, reuseTranslation || record.jarHashes.isNotEmpty(),
                NetworkSetup.current, ProviderOverrides.workerConfig(record.id), egress = WorkerEgressProxy.active.settings)
            val result = FrameCodec.json.decodeFromJsonElement(InitResult.serializer(),
                worker.call(Op.INIT, FrameCodec.json.encodeToJsonElement(InitRequest.serializer(), request), INIT_TIMEOUT_MS))
            validate(result)
            currentCoroutineContext().ensureActive()
            if (result.jarHashes != record.jarHashes) WorkerPool.onTranslation(record.id, record.generation, result.jarHashes)
            result.compatibility?.takeIf { it != record.compatibility }?.let { WorkerPool.onAssessment(record.id, record.generation, it) }
            synchronized(lifecycleLock) {
                check(!retired && WorkerPool.publish(slot, worker)) { "The extension startup was stopped." }
                initResult = result
                client = worker
                published = true
            }
            DaemonLog.info("worker.started", mapOf("installation" to record.id, "pid" to worker.pid, "sandboxed" to launcher.sandboxed))
            return worker
        } finally {
            if (!published) {
                val worker = started
                if (worker == null) reservation?.let(WorkerPool::release)
                else {
                    reservation?.let(WorkerPool::markStopping)
                    worker.stop() // The process-exit callback owns release.
                }
            }
        }
    }

    private fun validate(result: InitResult) {
        val names = result.providers.map { it.name }
        require(names.size <= 128 && names.distinct().size == names.size && names.all { it.isNotBlank() && it.length <= 200 }) {
            "The extension registered invalid providers."
        }
        require(result.extractors.size <= 256 && result.extractors.all { it.name.length <= 200 && it.mainUrl.length <= 2_000 }) {
            "The extension registered invalid extractors."
        }
        require(result.jarHashes.all { com.lagradost.macos.RepositoryService.normalizedHash(it) == it }) { "Invalid translation digest" }
        val expected = record.providerDescriptors.map { it.name }
        require(expected.isEmpty() || expected == names) { "The extension registered different providers than when it was installed." }
    }

    /** Worker home: translation cache, Context storage and temp; migrates pre-worker data once. */
    private fun prepareHome(): File {
        val home = homeFor(record.id)
        val data = File(home, "extension-data/${record.id}")
        val legacy = File(CloudDirs.extensionDataDir, record.id)
        com.lagradost.macos.OwnerOnly.mkdirs(File(home, "tmp"))
        if (!data.exists() && legacy.isDirectory) {
            com.lagradost.macos.OwnerOnly.mkdirs(data.parentFile)
            runCatching { Files.move(legacy.toPath(), data.toPath(), StandardCopyOption.ATOMIC_MOVE) }
        }
        // Keep only this generation's (and the rollback generation's) translations.
        val keep = listOfNotNull(record.artifactHash, record.previous?.artifactHash).map { ArtifactStore.translationKey(it) }
        File(home, "cache/plugins").listFiles()?.filter { file -> keep.none { file.name.startsWith(it) } }?.forEach { it.delete() }
        return home
    }

    suspend fun <T> call(type: String, request: JsonElement, serializer: KSerializer<T>, timeoutMs: Long,
        waitForCapacity: Boolean = true, onEvent: ((JsonElement) -> Unit)? = null): T {
        callers.incrementAndGet()
        try {
            while (true) {
                currentCoroutineContext().ensureActive()
                val worker = ensure(waitForCapacity)
                val slot = WorkerPool.acquireCall(this, worker)
                // Eviction won the admission race; back off briefly, then restart safely.
                if (slot == null) { delay(ADMISSION_RETRY_MS); continue }
                try {
                    val result = worker.call(type, request, timeoutMs, onEvent)
                    return FrameCodec.json.decodeFromJsonElement(serializer, result)
                } finally { WorkerPool.releaseCall(slot) }
            }
        } finally { callers.decrementAndGet() }
    }

    fun stop() {
        val worker = synchronized(lifecycleLock) {
            // A published startup may still be returning to its awaiters.
            // Eviction must let them obtain the worker and retry call admission,
            // rather than cancelling their request with that startup's Job.
            if (client == null) starting?.cancel()
            starting = null
            client = null
            WorkerPool.stop(this)
        }
        worker?.stop()
    }

    /** The generation is being replaced or removed: stop for good. */
    fun retire() {
        synchronized(lifecycleLock) { retired = true }
        stop()
    }

    companion object {
        const val INIT_TIMEOUT_MS = 60_000L
        /** Pause before retrying call admission after losing a race with eviction. */
        const val ADMISSION_RETRY_MS = 20L
        fun homeFor(installationId: String): File {
            require(com.lagradost.macos.RepositoryService.normalizedHash(installationId) == installationId) { "Invalid installation identity" }
            return com.lagradost.macos.OwnerOnly.mkdirs(File(CloudDirs.home, "workers/$installationId"))
        }
    }
}

/** Running-worker cap, idle stop and crash budget (ADR-0016). */
internal object WorkerPool {
    @Volatile var maxRunning = 8
    /** With the class archive loaded a worker restarts quickly, so idle ones stop sooner. */
    @Volatile var idleStopMs = 5 * 60_000L
    /**
     * An idle worker whose resident memory has grown past this is restarted
     * (Remediation 5.2): long sessions with many loaded classes and caches
     * otherwise keep it. Never while a call is running or waiting.
     */
    @Volatile var maxIdleResidentBytes = DEFAULT_MAX_IDLE_RESIDENT_BYTES
    const val DEFAULT_MAX_IDLE_RESIDENT_BYTES = 256L * 1024 * 1024
    /** Resident bytes of a process, or null when unknown (tests replace it). */
    @Volatile internal var residentBytes: (Long) -> Long? = ::processResidentBytes
    const val OVERFLOW = 4
    /**
     * How long a start may wait for a busy worker to finish before capacity is
     * refused. Kept near the shortest normal operation budget, so search and
     * home requests don't spend their whole budget queued.
     */
    @Volatile var capacityWaitMs = DEFAULT_CAPACITY_WAIT_MS
    const val DEFAULT_CAPACITY_WAIT_MS = 10_000L
    /** Bumped whenever a slot or a call is released, so waiting starts re-check. */
    private val capacityChanged = MutableStateFlow(0L)
    const val CRASH_BUDGET = 3
    const val CRASH_WINDOW_MS = 60 * 60_000L

    /** Called when a worker retranslated (dex2jar output is not byte-reproducible) so the receipt can reuse it next time. */
    @Volatile var onTranslation: (installationId: String, generation: String, jarHashes: List<String>) -> Unit = { _, _, _ -> }

    /** Called when a worker start produced a different compatibility assessment than the receipt holds. */
    @Volatile var onAssessment: (installationId: String, generation: String, report: com.lagradost.macos.CapabilityReport) -> Unit = { _, _, _ -> }

    /** Called when an extension exceeds its crash budget. */
    @Volatile var onQuarantine: (installationId: String, reason: String) -> Unit = { _, _ -> }

    internal enum class State { STARTING, RUNNING, STOPPING, RELEASED }
    internal class Reservation(val handle: WorkerHandle) {
        @Volatile var state = State.STARTING
        @Volatile var client: WorkerClient? = null
        var calls = 0
        val released = CompletableDeferred<Unit>()
    }
    private val poolLock = Any()
    private val reservations = linkedMapOf<WorkerHandle, Reservation>()
    private val crashes = ConcurrentHashMap<String, MutableList<Long>>()
    /** Set once the engine begins to exit; worker exits after it are not crashes. */
    @Volatile var shuttingDown = false
        private set
    internal val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    init {
        scope.launch {
            while (true) {
                delay(60_000)
                reapIdle()
            }
        }
    }

    /**
     * Admits a starting worker. Past [maxRunning] the least recently used idle
     * worker is stopped; when all are busy (e.g. a provider waiting on a routed
     * extractor, RT-12) up to [OVERFLOW] more may run. Beyond that the start
     * waits up to [maxWaitMs] for a worker to become idle or exit, and only
     * then is refused with a retryable capacity failure. A [maxWaitMs] of 0
     * refuses immediately (nested extraction: the caller is the busy capacity).
     */
    suspend fun admit(handle: WorkerHandle, maxWaitMs: Long = capacityWaitMs): Reservation {
        var deadline = 0L
        while (true) {
            currentCoroutineContext().ensureActive()
            // Read before the check, so a release after it is never missed.
            val seen = capacityChanged.value
            var victim: Reservation? = null
            val waitFor = synchronized(poolLock) {
                check(!handle.retired) { "This extension version was replaced or removed." }
                val previous = reservations[handle]
                if (previous != null) previous
                else {
                    if (reservations.size < maxRunning.coerceAtLeast(1)) {
                        return Reservation(handle).also { reservations[handle] = it }
                    }
                    victim = reservations.values.filter {
                        it.state == State.RUNNING && it.calls == 0 && it.handle.awaitingOrActiveCalls == 0 && it.client?.activeCalls == 0
                    }.minByOrNull { it.client?.lastUsed ?: 0L }
                    if (victim != null) {
                        victim.state = State.STOPPING
                        victim
                    } else {
                        if (reservations.size >= maxRunning.coerceAtLeast(1) + OVERFLOW) {
                            val now = System.nanoTime()
                            if (deadline == 0L) deadline = now + maxWaitMs.coerceAtLeast(0) * 1_000_000
                            if (now - deadline >= 0) {
                                DaemonLog.warn("worker.capacity_refused", mapOf("reserved" to reservations.size))
                                throw com.lagradost.macos.WorkerCapacityException()
                            }
                            null
                        } else {
                            DaemonLog.warn("worker.cap_exceeded", mapOf("reserved" to reservations.size))
                            return Reservation(handle).also { reservations[handle] = it }
                        }
                    }
                }
            }
            if (waitFor == null) {
                // Every worker is busy: wait for a release, re-checking periodically
                // because call counts inside workers change without a pool event.
                withTimeoutOrNull(CAPACITY_RECHECK_MS) { capacityChanged.first { it != seen } }
                continue
            }
            victim?.let {
                DaemonLog.info("worker.evicted", mapOf("installation" to it.handle.installationId))
                it.handle.stop()
            }
            // Stopping processes still consume capacity. A caller's cancellation
            // cancels only this wait, never the process-exit-owned reservation.
            waitFor.released.await()
        }
    }

    private const val CAPACITY_RECHECK_MS = 500L

    fun attach(slot: Reservation, worker: WorkerClient): Boolean = synchronized(poolLock) {
        if (reservations[slot.handle] !== slot || slot.state != State.STARTING) false
        else { slot.client = worker; true }
    }

    fun publish(slot: Reservation, worker: WorkerClient): Boolean = synchronized(poolLock) {
        if (reservations[slot.handle] !== slot || slot.state != State.STARTING || !worker.acceptingCalls) false
        else { slot.state = State.RUNNING; true }
    }

    fun markStopping(slot: Reservation) = synchronized(poolLock) {
        if (reservations[slot.handle] === slot) slot.state = State.STOPPING
    }

    fun stop(handle: WorkerHandle): WorkerClient? = synchronized(poolLock) {
        reservations[handle]?.let { it.state = State.STOPPING; it.client }
    }

    fun release(slot: Reservation) {
        synchronized(poolLock) {
            if (reservations[slot.handle] === slot) reservations.remove(slot.handle)
            slot.state = State.RELEASED
        }
        slot.released.complete(Unit)
        capacityChanged.update { it + 1 }
    }

    fun acquireCall(handle: WorkerHandle, worker: WorkerClient): Reservation? = synchronized(poolLock) {
        reservations[handle]?.takeIf { it.state == State.RUNNING && it.client === worker && worker.acceptingCalls }
            ?.also { it.calls++ }
    }

    fun releaseCall(slot: Reservation) {
        synchronized(poolLock) { slot.calls-- }
        capacityChanged.update { it + 1 }
    }

    private fun snapshot(): List<Reservation> = synchronized(poolLock) { reservations.values.toList() }
    internal fun reservedCount(): Int = synchronized(poolLock) { reservations.size }

    /** Pushes changed network settings; a stopped generation reads them on restart. */
    fun broadcastNetwork(settings: DaemonState.NetworkSettings) {
        snapshot().filter { it.state == State.RUNNING }.forEach { slot ->
            scope.launch {
                runCatching {
                    slot.handle.call(Op.NETWORK, FrameCodec.json.encodeToJsonElement(DaemonState.NetworkSettings.serializer(), settings),
                        Boolean.serializer(), 10_000)
                }.onFailure { slot.handle.stop() }
            }
        }
    }

    fun runningCount(): Int = snapshot().count { it.client?.alive == true }

    internal fun reapIdle(now: Long = System.currentTimeMillis()) {
        fun idle(it: Reservation) =
            it.state == State.RUNNING && it.calls == 0 && it.handle.awaitingOrActiveCalls == 0 && it.client?.activeCalls == 0
        // Measured outside the pool lock: a process probe may take a moment.
        val candidates = synchronized(poolLock) { reservations.values.filter(::idle).map { it to it.client?.pid } }
        val oversized = candidates.mapNotNull { (slot, pid) ->
            val bytes = pid?.let(residentBytes) ?: return@mapNotNull null
            if (bytes > maxIdleResidentBytes) slot to bytes else null
        }.toMap()
        val victims = synchronized(poolLock) {
            reservations.values.filter { idle(it) && (now - (it.client?.lastUsed ?: now) > idleStopMs || it in oversized) }
                .onEach { it.state = State.STOPPING }
        }
        victims.forEach {
            val bytes = oversized[it]
            if (bytes != null) DaemonLog.info("worker.recycled", mapOf("installation" to it.handle.installationId, "residentMb" to bytes / (1024 * 1024)))
            else DaemonLog.info("worker.idle_stop", mapOf("installation" to it.handle.installationId))
            it.handle.stop()
        }
    }

    /** `ps` reports resident size in KiB; the engine itself is not sandboxed. */
    private fun processResidentBytes(pid: Long): Long? = runCatching {
        val process = ProcessBuilder("/bin/ps", "-o", "rss=", "-p", pid.toString()).redirectErrorStream(true).start()
        val text = process.inputStream.bufferedReader().use { it.readText() }.trim()
        if (!process.waitFor(5, java.util.concurrent.TimeUnit.SECONDS)) { process.destroyForcibly(); return@runCatching null }
        text.toLongOrNull()?.times(1024)
    }.getOrNull()

    /**
     * Engine shutdown: recorded before workers are stopped, so their exits —
     * however they end — never count towards quarantine.
     */
    fun beginShutdown() {
        shuttingDown = true
        val owned = synchronized(poolLock) { reservations.values.onEach { it.state = State.STOPPING }.toList() }
        owned.forEach { it.client?.stop() }
    }

    /** Installations whose worker ran out of memory this session: they restart with [WorkerLauncher.RAISED_HEAP_MB] (W2). */
    private val raisedHeap = ConcurrentHashMap.newKeySet<String>()

    /** The heap cap for [installationId]'s next start, or null for the launcher's default. */
    fun heapFor(installationId: String): Int? = WorkerLauncher.RAISED_HEAP_MB.takeIf { installationId in raisedHeap }

    fun raiseHeap(installationId: String) {
        if (raisedHeap.add(installationId)) {
            DaemonLog.warn("worker.heap_raised", mapOf("installation" to installationId, "heapMb" to WorkerLauncher.RAISED_HEAP_MB))
        }
    }

    fun recordCrash(installationId: String, reason: String) {
        if (shuttingDown) {
            DaemonLog.info("worker.exited_at_shutdown", mapOf("installation" to installationId, "reason" to reason))
            return
        }
        val now = System.currentTimeMillis()
        val recent = crashes.compute(installationId) { _, list ->
            (list ?: mutableListOf()).apply { add(now); removeAll { now - it > CRASH_WINDOW_MS } }
        }!!
        DaemonLog.warn("worker.crashed", mapOf("installation" to installationId, "reason" to reason, "recent" to recent.size))
        if (recent.size >= CRASH_BUDGET) {
            crashes.remove(installationId)
            onQuarantine(installationId, "The extension stopped responding or crashed repeatedly ($reason). Retry to load it again.")
        }
    }

    /** Tests only. */
    internal fun resetForTest() {
        val owned = snapshot()
        owned.forEach { it.handle.retire() }
        runBlocking { withTimeout(10_000) { owned.forEach { it.released.await() } } }
        crashes.clear()
        raisedHeap.clear()
        shuttingDown = false
        maxRunning = 8
        idleStopMs = 5 * 60_000L
        capacityWaitMs = DEFAULT_CAPACITY_WAIT_MS
        maxIdleResidentBytes = DEFAULT_MAX_IDLE_RESIDENT_BYTES
        residentBytes = ::processResidentBytes
    }
}

/**
 * Control-plane stand-in for a provider hosted by a worker. Carries the
 * metadata the engine lists and routes by; calls go to the worker, and every
 * response is treated as untrusted input.
 */
internal class RemoteProvider(val handle: WorkerHandle, private val descriptor: ProviderDescriptor) : MainAPI() {
    override var name = descriptor.name
    override var mainUrl = descriptor.mainUrl
    override var lang = descriptor.lang
    override val supportedTypes: Set<TvType> = descriptor.supportedTypes.mapNotNull { runCatching { TvType.valueOf(it) }.getOrNull() }.toSet()
    override val hasMainPage = descriptor.hasMainPage
    override val hasQuickSearch = descriptor.hasQuickSearch
    override val vpnStatus: VPNStatus = runCatching { VPNStatus.valueOf(descriptor.vpnStatus) }.getOrDefault(VPNStatus.None)
    override var canBeOverridden = descriptor.canBeOverridden
    override val searchTimeoutMs = descriptor.searchTimeoutMs
    override val loadTimeoutMs = descriptor.loadTimeoutMs
    override val loadLinksTimeoutMs = descriptor.loadLinksTimeoutMs
    override val getMainPageTimeoutMs = descriptor.mainPageTimeoutMs

    init { sourcePlugin = handle.installationId }

    private val providerId: String get() = "${handle.installationId}:$name"
    private fun ownId(id: String?): String = id?.takeIf { it.startsWith("${handle.installationId}:") && it.length <= 400 } ?: providerId

    private fun json(value: Any): JsonElement = when (value) {
        is SearchRequest -> FrameCodec.json.encodeToJsonElement(SearchRequest.serializer(), value)
        is HomeRequest -> FrameCodec.json.encodeToJsonElement(HomeRequest.serializer(), value)
        is DetailsRequest -> FrameCodec.json.encodeToJsonElement(DetailsRequest.serializer(), value)
        is LinksRequest -> FrameCodec.json.encodeToJsonElement(LinksRequest.serializer(), value)
        is VerifyRequest -> FrameCodec.json.encodeToJsonElement(VerifyRequest.serializer(), value)
        is ConfigureRequest -> FrameCodec.json.encodeToJsonElement(ConfigureRequest.serializer(), value)
        else -> error("Unsupported request")
    }

    /** Null when the provider reported a failure (mirrors the in-process result). */
    suspend fun remoteSearch(query: String, timeoutMs: Long): List<SearchResultDto>? {
        val payload = handle.call(Op.SEARCH, json(SearchRequest(name, query)), SearchResponsePayload.serializer(), timeoutMs)
        payload.failure?.let { throw com.lagradost.macos.OperationException(it) }
        if (payload.error != null) throw com.lagradost.macos.OperationFailures.capture(this, "search", IllegalStateException())
        return payload.results?.take(MAX_RESULTS)?.map(::clean)
    }

    suspend fun remoteHome(page: Int, timeoutMs: Long): HomePageDto {
        val home = handle.call(Op.HOME, json(HomeRequest(name, page)), HomePageDto.serializer(), timeoutMs)
        return home.copy(provider = name, providerId = providerId, page = page,
            lists = home.lists.take(MAX_SHELVES).map { list -> list.copy(items = list.items.take(MAX_SHELF_ITEMS).map(::clean)) })
    }

    suspend fun remoteDetails(url: String, timeoutMs: Long): DetailsDto? {
        val details = handle.call(Op.DETAILS, json(DetailsRequest(name, url)), DetailsResponsePayload.serializer(), timeoutMs).details
            ?: return null
        return details.copy(provider = name, providerId = providerId,
            episodes = details.episodes.take(MAX_EPISODES),
            recommendations = details.recommendations?.take(MAX_RESULTS)?.map(::clean))
    }

    suspend fun remoteLinks(data: String, timeoutMs: Long, onLink: (StreamLinkDto) -> Unit, onSubtitle: (SubtitleDto) -> Unit): LinksResponseDto {
        var links = 0
        var subtitles = 0
        val response = handle.call(Op.LINKS, json(LinksRequest(name, data)), LinksResponseDto.serializer(), timeoutMs) { element ->
            val event = FrameCodec.json.decodeFromJsonElement(LinkEvent.serializer(), element)
            event.link?.let { if (++links <= MAX_LINKS) onLink(clean(it)) }
            event.subtitle?.let { if (++subtitles <= MAX_SUBTITLES) onSubtitle(clean(it)) }
        }
        return response.copy(provider = name, providerId = providerId,
            links = response.links.take(MAX_LINKS).map(::clean), subtitles = response.subtitles.take(MAX_SUBTITLES).map(::clean),
            skipped = response.skipped.take(LinksResponseDto.MAX_SKIPPED).map {
                it.copy(source = it.source.take(200), name = it.name.take(200),
                    reason = it.reason.takeIf { reason -> reason in setOf("torrent", "drm", "invalid") } ?: "invalid")
            })
    }

    override suspend fun extractorVerifierJob(extractorData: String?) {
        handle.call(Op.VERIFY, json(VerifyRequest(name, extractorData.orEmpty())), Boolean.serializer(), VERIFY_TIMEOUT_MS)
    }

    /** Forwards clone-site URL / credentials after the control plane applied them to this stub. */
    suspend fun configureRemote(url: String?, credentials: String?, clearCredentials: Boolean = false) {
        if (!handle.running) return // applied from the control plane's configuration at the next start
        handle.call(Op.CONFIGURE, json(ConfigureRequest(name, url, credentials, clearCredentials)), Boolean.serializer(), 10_000)
    }

    private fun clean(result: SearchResultDto) = result.copy(providerId = ownId(result.providerId),
        provider = result.provider.take(200))

    private fun clean(link: StreamLinkDto) = cleanLink(link)

    private fun clean(subtitle: SubtitleDto) = cleanSubtitle(subtitle)

    companion object {
        /** Reject before cleanup: trimming cannot grant a malformed URL authority. */
        fun cleanLink(raw: StreamLinkDto): StreamLinkDto {
            val link = raw.copy(headers = com.lagradost.macos.MediaResourcePolicy.normalizedHeaders(raw.headers),
                audioTracks = raw.audioTracks.map { it.copy(headers = com.lagradost.macos.MediaResourcePolicy.normalizedHeaders(it.headers)) })
            com.lagradost.macos.MediaResourcePolicy.link(link)
            return link.copy(
                url = URLSanitizer.sanitizeStream(link.url),
                playlist = link.playlist.map(URLSanitizer::sanitizeStream),
                audioTracks = link.audioTracks.map { it.copy(url = URLSanitizer.sanitizeStream(it.url)) },
            )
        }

        fun cleanSubtitle(subtitle: SubtitleDto): SubtitleDto {
            com.lagradost.macos.MediaResourcePolicy.remoteURL(subtitle.url, "subtitle.url")
            return subtitle.copy(url = URLSanitizer.sanitizeStream(subtitle.url))
        }

        const val MAX_RESULTS = 500
        const val MAX_SHELVES = 64
        const val MAX_SHELF_ITEMS = 200
        const val MAX_EPISODES = 20_000
        const val MAX_LINKS = 500
        const val MAX_SUBTITLES = 200
        const val VERIFY_TIMEOUT_MS = 6 * 60 * 60 * 1000L
    }
}

/** The worker-hosted generation's unload hook: stops the worker for good. */
internal class WorkerPlugin(val handle: WorkerHandle) : BasePlugin() {
    override fun beforeUnload() = handle.retire()
}

/**
 * [ExtensionRuntime] that hosts each installation in its own sandboxed worker
 * (ADR-0016). Registration publishes [RemoteProvider] stubs through the same
 * staged-publication path as the in-process runtime.
 */
internal class WorkerExtensionRuntime(private val launcher: WorkerLauncher = WorkerLauncher()) : ExtensionRuntime {
    private class Prepared(
        val handle: WorkerHandle,
        override val providerNames: List<String>,
        override val extractorCount: Int,
        override val jarHashes: List<String>,
        override val unsupportedFeatures: List<String>,
        override val providerDescriptors: List<ProviderDescriptor>,
        override val compatibility: com.lagradost.macos.CapabilityReport? = null,
        override val extractorDescriptors: List<ExtractorDescriptor> = emptyList(),
    ) : PreparedExtension

    val sandboxed: Boolean get() = launcher.sandboxed

    override fun prepare(record: DaemonState.InstalledExtension, artifact: File, reuseTranslation: Boolean): PreparedExtension {
        val handle = WorkerHandle(record, artifact, launcher, reuseTranslation)
        // Known metadata: register now, start the worker on first use.
        // Receipts written before RT-12 lack extractor descriptors: learn them once.
        val extractorsKnown = record.extractorCount == 0 || record.extractorDescriptors.isNotEmpty()
        if (reuseTranslation && (record.providerDescriptors.isNotEmpty() || record.extractorDescriptors.isNotEmpty()) &&
            extractorsKnown && record.jarHashes.isNotEmpty()) {
            return Prepared(handle, record.providerDescriptors.map { it.name }, record.extractorCount, record.jarHashes,
                emptyList(), record.providerDescriptors, record.compatibility, record.extractorDescriptors)
        }
        val result = try { runBlocking { handle.ensure(); requireNotNull(handle.initResult) } } catch (failure: WorkerFailure) {
            handle.retire()
            // The worker's typed record names the stage and, for linkage errors, the missing class or member
            // (never URLs or data). Keep it: "failed to start" alone tells neither the user nor support why.
            val cause = failure.failure?.redactedCause?.take(240)
            DaemonLog.warn("worker.init_failed", mapOf("installation" to record.id, "code" to (failure.failure?.code ?: failure.code),
                "cause" to cause))
            if (failure.code in setOf("unsupported", "unsupported_capability")) throw PluginBridge.UnsupportedExtensionException(failure.message.orEmpty())
            val incompatible = failure.failure?.code in com.lagradost.macos.OperationFailures.INCOMPATIBLE
            throw IllegalStateException(failure.message + (cause?.takeIf { incompatible }?.let { " ($it)" } ?: ""), failure)
        } catch (failure: Throwable) {
            handle.retire()
            throw failure
        }
        return Prepared(handle, result.providers.map { it.name }, result.extractorCount, result.jarHashes,
            result.unsupportedFeatures, result.providers, result.compatibility, result.extractors)
    }

    override fun publish(record: DaemonState.InstalledExtension, prepared: PreparedExtension): AutoCloseable? {
        prepared as Prepared
        val stubs = prepared.providerDescriptors.map { RemoteProvider(prepared.handle, it) }
        ProviderOverrides.apply(stubs)
        val generation = PluginBridge.LoadedPlugin(record.id, record.generation, record.artifactHash, null,
            WorkerPlugin(prepared.handle), stubs, emptyList(), prepared.jarHashes, prepared.unsupportedFeatures)
        return PluginBridge.publish(generation)?.let { AutoCloseable { PluginBridge.retire(it) } }
    }

    override fun discard(prepared: PreparedExtension) { (prepared as Prepared).handle.retire() }

    override fun remove(id: String): AutoCloseable? = PluginBridge.detach(id)?.let { AutoCloseable { PluginBridge.retire(it) } }

    override fun isCurrent(record: DaemonState.InstalledExtension): Boolean =
        PluginBridge.loadedInstallation(record.id)?.generation == record.generation
}
