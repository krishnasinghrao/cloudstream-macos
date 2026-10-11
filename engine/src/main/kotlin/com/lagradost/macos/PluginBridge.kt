package com.lagradost.macos

import com.googlecode.d2j.dex.Dex2jar
import com.lagradost.cloudstream3.APIHolder
import com.lagradost.cloudstream3.MainAPI
import com.lagradost.cloudstream3.plugins.BasePlugin
import com.lagradost.cloudstream3.plugins.PluginRegistrationTarget
import com.lagradost.cloudstream3.utils.ExtractorApi
import com.lagradost.cloudstream3.utils.extractorApis
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.ByteArrayInputStream
import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.StandardCopyOption.ATOMIC_MOVE
import java.nio.file.StandardCopyOption.REPLACE_EXISTING
import java.util.Collections
import java.util.IdentityHashMap
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import java.util.zip.ZipInputStream

/** Plugin callbacks may report features the macOS host does not implement. */
interface UnsupportedFeatureSink {
    fun unsupported(feature: String)
}

/**
 * Extension runtime (Architecture.md §3.2):
 *
 * committed receipt → verified source bytes → dex2jar (cache keyed by source
 * digest + translation profile, reused only when its digest matches the
 * receipt) → [VerifiedClassLoader] over in-memory verified bytes → staged
 * registration → atomic publication of a generation.
 *
 * Exception barriers contain ordinary failures; hard resource and privilege
 * isolation belongs to the worker boundary (docs/adr).
 */
object PluginBridge {
    /** Bump whenever dex2jar options, the translator or the android.* stub ABI change. */
    const val TRANSLATION_PROFILE = "d2j-2.4/reuse-topo-sync-nodebug/stubs-5/host-abi-1/repro-1/guard-1"
    private const val RETIRE_DRAIN_MS = 30_000L

    private val json = Json { ignoreUnknownKeys = true }
    private val translationLocks = ConcurrentHashMap<String, Any>()

    class LoadedPlugin internal constructor(
        val installationId: String,
        val generation: String,
        val sourceHash: String,
        val manifestName: String?,
        val plugin: BasePlugin,
        val providers: List<MainAPI>,
        val extractors: List<ExtractorApi>,
        val jarHashes: List<String>,
        val unsupportedFeatures: List<String>,
        /** Static host-compatibility evidence (RT-05); null for worker-hosted stubs. */
        val compatibility: CapabilityReport? = null,
        /** The extension's own preferences (RT-15); null for worker-hosted stubs, whose worker holds it. */
        internal val preferences: ExtensionPreferenceStore? = null,
    ) {
        internal val activeCalls = AtomicInteger(0)
        /** Set before draining; leases taken after it are refused (T3.19). */
        @Volatile internal var retired = false
        val extractorCount: Int get() = extractors.size
    }

    class UnsupportedExtensionException(message: String) : IllegalStateException(message)

    /** installation ID → published generation. */
    private val loaded = ConcurrentHashMap<String, LoadedPlugin>()
    private val owners: MutableMap<Any, LoadedPlugin> = Collections.synchronizedMap(IdentityHashMap())
    /** Providers/extractors of retired generations (weak: lets them be collected). Stale references are refused. */
    private val retiredApis: MutableSet<Any> = Collections.synchronizedSet(Collections.newSetFromMap(java.util.WeakHashMap()))

    internal fun prepare(record: DaemonState.InstalledExtension, cs3File: File, reuseTranslation: Boolean): LoadedPlugin {
        DaemonState.requireHealthy()
        val path = cs3File.toPath()
        require(Files.isRegularFile(path, NOFOLLOW_LINKS)) { "Extension source is missing" }
        require(Files.size(path) <= RepositoryTransport.MAX_ARTIFACT_BYTES) { "Extension source exceeds size limit" }
        val source = Files.readAllBytes(path)
        require(ArtifactDigest.sha256(source) == record.artifactHash) { "Artifact differs from installation receipt" }

        var pluginClassName: String? = null
        var manifestName: String? = null
        var requiresResources = false
        val dexEntries = sortedMapOf<Int, ByteArray>()
        var resourceTable: ByteArray? = null
        val assets = HashMap<String, ByteArray>()
        var hasAndroidUi = false
        var expanded = 0L
        ZipInputStream(ByteArrayInputStream(source)).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: break
                val name = entry.name
                val dexIndex = DEX_NAME.matchEntire(name)?.groupValues?.get(1)?.let { if (it.isEmpty()) 1 else it.toInt() }
                if (name.startsWith("res/layout") || name.startsWith("res/drawable")) hasAndroidUi = true
                val asset = name.removePrefix("assets/").takeIf { name.startsWith("assets/") && !entry.isDirectory && it.isNotEmpty() }
                if (name != "manifest.json" && name != "resources.arsc" && asset == null && dexIndex == null) continue
                val bytes = zip.readNBytes(MAX_ENTRY_BYTES + 1)
                require(bytes.size <= MAX_ENTRY_BYTES) { "Archive entry exceeds size limit" }
                expanded += bytes.size
                require(expanded <= MAX_EXPANDED_BYTES) { "Archive expands beyond size limit" }
                if (name == "manifest.json") {
                    val manifest = json.parseToJsonElement(bytes.toString(Charsets.UTF_8)).jsonObject
                    pluginClassName = manifest["pluginClassName"]?.jsonPrimitive?.content
                    manifestName = manifest["name"]?.jsonPrimitive?.content
                    requiresResources = manifest["requiresResources"]?.jsonPrimitive?.booleanOrNull == true
                } else if (name == "resources.arsc") {
                    resourceTable = bytes
                } else if (asset != null) {
                    require(asset.split('/').none { it == ".." || it.isEmpty() } && assets.size < MAX_ASSETS) { "Invalid or too many assets" }
                    assets[asset] = bytes
                } else if (dexIndex != null) {
                    require(dexEntries.put(dexIndex, bytes) == null) { "Duplicate DEX entry" }
                }
            }
        }
        require(!pluginClassName.isNullOrBlank()) { "Missing plugin class in manifest" }
        // Android builds an AssetManager over the artifact and sets plugin.resources before load (RT-13).
        val resources = if (requiresResources || resourceTable != null || assets.isNotEmpty()) {
            val table = resourceTable?.let { bytes ->
                try { ResourceTable.parse(bytes) } catch (failure: IllegalArgumentException) {
                    throw UnsupportedExtensionException("This extension's Android resources are malformed: ${failure.message}")
                }
            }
            android.content.res.Resources(table, android.content.res.AssetManager(assets))
        } else null
        require(dexEntries.isNotEmpty() && dexEntries.keys.toList() == (1..dexEntries.size).toList()) { "Incomplete DEX set" }

        val expected = record.jarHashes.takeIf { reuseTranslation && it.size == dexEntries.size }
        // Methods too large to translate within a worker's memory become throwing stubs (TranslationGuard).
        val oversized = dexEntries.values.map(TranslationGuard::scan)
        val jars = dexEntries.values.mapIndexed { index, dex ->
            translate(record.artifactHash, index, dex, expected?.get(index), oversized[index])
        }
        val jarHashes = jars.map(ArtifactDigest::sha256)
        // Before any extension code runs: record host types it references that this engine lacks.
        val compatibility = runCatching { CompatibilityAssessment.assess(jars, pluginClassName) }.getOrNull()
        compatibility?.let(CompatibilityAssessment::impossibleReason)?.let { throw UnsupportedExtensionException(it) }
        val loader = VerifiedClassLoader(jars, PluginBridge::class.java.classLoader, record.id)

        val context = android.content.Context(ExtensionStorage.directory(record.id))
        ProviderRuntimeBootstrap.initialize(context)

        val instance = loader.loadClass(pluginClassName).getDeclaredConstructor().newInstance()
        require(instance is BasePlugin) { "Plugin entry class does not implement BasePlugin" }
        instance.filename = cs3File.absolutePath
        if (instance is com.lagradost.cloudstream3.plugins.Plugin) instance.resources = resources
        val registration = StagedRegistration(record.id)
        instance.registrationTarget = registration
        try {
            if (instance is com.lagradost.cloudstream3.plugins.Plugin) instance.load(context)
            else {
                val withContext = instance.javaClass.methods.firstOrNull {
                    it.name == "load" && it.parameterCount == 1 && it.parameterTypes[0].name == "android.content.Context"
                }
                if (withContext != null) withContext.invoke(instance, context) else instance.load()
            }
        } finally { registration.seal() }
        ProviderOverrides.apply(registration.providers)
        return LoadedPlugin(record.id, record.generation, record.artifactHash, manifestName, instance,
            registration.providers.toList(), registration.extractors.toList(), jarHashes,
            registration.unsupported.toList() + oversized.flatten().take(16).map { "${it.label} (too large to translate)" } +
                listOfNotNull("Android settings screens".takeIf { hasAndroidUi },
                    // Workers serve WebViews through the app's WebKit (RT-14); an
                    // engine without that host (in-process development) cannot.
                    "Sources that run JavaScript in an Android WebView".takeIf {
                        WebViewSessions.transport == null &&
                            runCatching { CompatibilityAssessment.constructs(jars, "android/webkit/WebView") }.getOrDefault(false)
                    }), compatibility,
            // Settings the extension keeps in SharedPreferences, read from its code without running it.
            ExtensionPreferenceStore(context, ExtensionStorage.directory(record.id),
                runCatching { PreferenceSchemaScanner.scan(jars) }.getOrDefault(PreferenceSchema())))
    }

    /** Returns JAR bytes. A cached file is reused only when its digest equals the
     * receipt's; otherwise it is rebuilt from the verified DEX bytes. */
    private fun translate(sourceHash: String, index: Int, dex: ByteArray, expectedHash: String?,
        oversized: List<TranslationGuard.Oversized>): ByteArray {
        val key = ArtifactDigest.sha256("$sourceHash:$TRANSLATION_PROFILE".toByteArray())
        val target = File(CloudDirs.pluginCacheDir, if (index == 0) "$key.jar" else "${key}_${index + 1}.jar").toPath()
        val lock = translationLocks.computeIfAbsent(target.toString()) { Any() }
        synchronized(lock) {
            if (expectedHash != null && Files.isRegularFile(target, NOFOLLOW_LINKS) && Files.size(target) <= MAX_EXPANDED_BYTES) {
                val cached = Files.readAllBytes(target)
                if (ArtifactDigest.sha256(cached) == expectedHash) return cached
                DaemonLog.warn("plugin.jar_rebuilt", mapOf("artifact" to sourceHash, "index" to index))
            }
            AtomicFiles.privateDirectory(target.parent)
            val temp = Files.createTempFile(target.parent, ".translate-", ".jar")
            try {
                Dex2jar.from(TranslationGuard.guard(dex, oversized)).reUseReg(true).topoLogicalSort().optimizeSynchronized().skipDebug().to(temp)
                val bytes = reproducibleJar(HostAbiAdapter.adaptJar(Files.readAllBytes(temp)))
                require(bytes.isNotEmpty()) { "DEX translation produced no output" }
                Files.write(temp, bytes)
                Files.move(temp, target, ATOMIC_MOVE, REPLACE_EXISTING)
                return bytes
            } finally {
                Files.deleteIfExists(temp)
            }
        }
    }

    /** Normalizes container noise (entry order, timestamps) in dex2jar output. The
     * class bytes themselves are not always reproducible (dex2jar is
     * nondeterministic for some methods), so integrity never relies on
     * reproducibility: the source is verified on every load and a cached JAR is
     * reused only when it matches the digest recorded for this receipt. */
    internal fun reproducibleJar(jar: ByteArray): ByteArray {
        val entries = sortedMapOf<String, ByteArray>()
        ZipInputStream(ByteArrayInputStream(jar)).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: break
                if (entry.isDirectory) continue
                val body = zip.readNBytes(MAX_EXPANDED_BYTES.toInt() + 1)
                require(body.size <= MAX_EXPANDED_BYTES) { "Translated class exceeds size limit" }
                require(entries.put(entry.name, body) == null) { "Duplicate translated entry" }
            }
        }
        val out = java.io.ByteArrayOutputStream(jar.size)
        java.util.zip.ZipOutputStream(out).use { zip ->
            for ((name, body) in entries) {
                zip.putNextEntry(java.util.zip.ZipEntry(name).apply { time = FIXED_ENTRY_TIME })
                zip.write(body)
                zip.closeEntry()
            }
        }
        return out.toByteArray()
    }

    private class StagedRegistration(val owner: String) : PluginRegistrationTarget, UnsupportedFeatureSink {
        val providers = mutableListOf<MainAPI>()
        val extractors = mutableListOf<ExtractorApi>()
        val unsupported = linkedSetOf<String>()
        private var sealed = false
        @Synchronized fun seal() { sealed = true }
        @Synchronized override fun registerMainAPI(element: MainAPI) {
            check(!sealed && providers.size < 128) { "Registration is closed or exceeds provider limit" }
            element.sourcePlugin = owner
            providers.add(element)
        }
        @Synchronized override fun registerExtractorAPI(element: ExtractorApi) {
            check(!sealed && extractors.size < 256) { "Registration is closed or exceeds extractor limit" }
            element.sourcePlugin = owner
            extractors.add(element)
        }
        @Synchronized override fun unsupported(feature: String) {
            unsupported.add(feature)
        }
    }

    /** Publishes only host registry state; no plugin callback runs here.
     * Restores every registry if legacy mapping code throws. */
    internal fun publish(candidate: LoadedPlugin): LoadedPlugin? = ExtensionLifecycle.locked {
        APIHolder.allProviders.withLock {
            extractorApis.withLock {
                val old = loaded[candidate.installationId]
                val providersBefore = APIHolder.allProviders.toList()
                val extractorsBefore = extractorApis.toList()
                val mappingsBefore = APIHolder.apis
                val mapBefore = APIHolder.apiMap
                try {
                    candidate.providers.forEach { APIHolder.allProviders.add(it); APIHolder.addPluginMapping(it) }
                    candidate.extractors.forEach { extractorApis.add(it) }
                    old?.providers?.forEach { APIHolder.allProviders.remove(it); APIHolder.removePluginMapping(it) }
                    old?.extractors?.forEach { extractorApis.remove(it) }
                    loaded[candidate.installationId] = candidate
                    (candidate.providers + candidate.extractors).forEach { owners[it] = candidate }
                    old?.let { previous -> (previous.providers + previous.extractors).forEach { owners.remove(it) } }
                    ProviderExecutor.invalidateCaches(candidate.installationId)
                    old
                } catch (failure: Throwable) {
                    APIHolder.allProviders.clear(); APIHolder.allProviders.addAll(providersBefore)
                    extractorApis.clear(); extractorApis.addAll(extractorsBefore)
                    APIHolder.apis = mappingsBefore; APIHolder.apiMap = mapBefore
                    if (old != null) loaded[candidate.installationId] = old else loaded.remove(candidate.installationId)
                    (candidate.providers + candidate.extractors).forEach { owners.remove(it) }
                    old?.let { previous -> (previous.providers + previous.extractors).forEach { owners[it] = previous } }
                    throw failure
                }
            }
        }
    }

    /** Removes a generation from every registry. The caller retires it outside the lock. */
    internal fun detach(installationId: String): LoadedPlugin? = ExtensionLifecycle.locked {
        val descriptor = loaded.remove(installationId) ?: return@locked null
        APIHolder.allProviders.withLock {
            descriptor.providers.forEach { APIHolder.allProviders.remove(it); APIHolder.removePluginMapping(it) }
        }
        extractorApis.withLock { descriptor.extractors.forEach { extractorApis.remove(it) } }
        ProviderExecutor.invalidateCaches(installationId)
        descriptor
    }

    /** Drains in-flight calls (bounded), cancels host-owned jobs, then runs the
     * plugin's unload callback. Never blocks the caller. */
    internal fun retire(descriptor: LoadedPlugin) {
        descriptor.retired = true
        (descriptor.providers + descriptor.extractors).forEach { retiredApis.add(it) }
        VerifierJobs.cancelFor(descriptor.installationId, descriptor.generation)
        val thread = Thread({
            val deadline = System.currentTimeMillis() + RETIRE_DRAIN_MS
            while (descriptor.activeCalls.get() > 0 && System.currentTimeMillis() < deadline) Thread.sleep(50)
            if (descriptor.activeCalls.get() > 0) {
                DaemonLog.warn("plugin.retire_drain_timeout", mapOf("installation" to descriptor.installationId, "calls" to descriptor.activeCalls.get()))
            }
            try { descriptor.plugin.beforeUnload() } catch (failure: Throwable) {
                DaemonLog.warn("plugin.beforeUnload_failed", mapOf("installation" to descriptor.installationId, "error" to failure.javaClass.simpleName))
            }
            // Android callbacks the retired generation queued must not run its code later (RT-14).
            runCatching { android.os.Looper.removeCallbacksFrom(descriptor.plugin.javaClass.classLoader) }
            (descriptor.providers + descriptor.extractors).forEach { owners.remove(it) }
        }, "retire-${descriptor.installationId.take(8)}")
        thread.isDaemon = true
        thread.start()
    }

    /** Discards a prepared generation that was never published. */
    internal fun discard(descriptor: LoadedPlugin) {
        try { descriptor.plugin.beforeUnload() } catch (_: Throwable) { }
    }

    /** Runs [block] holding a lease on the generation that owns [api], so its
     * retirement waits for the call to finish. */
    inline fun <T> withLease(api: Any?, block: () -> T): T {
        val owner = api?.let { ownerOf(it) }
        if (owner == null && api != null && isRetired(api)) throw IllegalStateException("This extension was just updated or removed; try again.")
        owner?.let { leaseAcquire(it) }
        try { return block() } finally { owner?.let { leaseRelease(it) } }
    }

    fun ownerOf(api: Any): LoadedPlugin? = owners[api]
    fun isRetired(api: Any): Boolean = api in retiredApis
    /** Counted before the retired check: either the drain waits for this call, or the call is refused. */
    fun leaseAcquire(owner: LoadedPlugin) {
        owner.activeCalls.incrementAndGet()
        if (owner.retired) {
            owner.activeCalls.decrementAndGet()
            throw IllegalStateException("This extension was just updated or removed; try again.")
        }
    }
    fun leaseRelease(owner: LoadedPlugin) { owner.activeCalls.decrementAndGet() }

    internal fun loadedInstallation(id: String): LoadedPlugin? = loaded[id]

    fun getAllLoadedDescriptors(): List<LoadedPlugin> = loaded.values.toList()

    /** Stable provider identity: `<installationId>:<name>`; built-ins use their name. */
    fun providerId(api: MainAPI): String = api.sourcePlugin?.let { "$it:${api.name}" } ?: api.name

    /** Resolves an exact provider ID, else a provider name only when unambiguous. */
    fun findProvider(idOrName: String): MainAPI? {
        val needle = idOrName.trim()
        if (needle.isEmpty()) return null
        val all = allProviders()
        return all.firstOrNull { providerId(it) == needle } ?: all.singleOrNull { it.name == needle }
    }

    fun allProviders(): List<MainAPI> = APIHolder.allProviders.withLock { APIHolder.allProviders.toList() }

    /**
     * Packaging gate (`java -jar daemon.jar --self-test`): translates the
     * embedded Android-compiled multi-DEX extension on *this* runtime and
     * defines its classes, without running extension code. Catches runtimes
     * missing modules the translator needs (e.g. jdk.zipfs).
     */
    fun selfTest(): String {
        // Exercise the actual APIs on the reduced image, not only a full JDK.
        val memory = android.app.ActivityManager.MemoryInfo()
        android.app.ActivityManager().getMemoryInfo(memory)
        require(memory.totalMem > 0 && memory.availMem >= 0) { "Management memory APIs unavailable" }
        android.os.SystemClock.currentThreadTimeMillis()
        val archive = requireNotNull(PluginBridge::class.java.getResourceAsStream("/self-test/extension.cs3")) { "Missing self-test extension" }.readBytes()
        val dex = sortedMapOf<Int, ByteArray>()
        var pluginClass: String? = null
        ZipInputStream(ByteArrayInputStream(archive)).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: break
                val bytes = zip.readBytes()
                if (entry.name == "manifest.json") pluginClass = json.parseToJsonElement(bytes.toString(Charsets.UTF_8)).jsonObject["pluginClassName"]?.jsonPrimitive?.content
                DEX_NAME.matchEntire(entry.name)?.groupValues?.get(1)?.let { dex[if (it.isEmpty()) 1 else it.toInt()] = bytes }
            }
        }
        val work = Files.createTempDirectory("cs-self-test")
        try {
            val jars = dex.values.mapIndexed { index, bytes ->
                val out = work.resolve("$index.jar")
                Dex2jar.from(bytes).reUseReg(true).topoLogicalSort().optimizeSynchronized().skipDebug().to(out)
                Files.readAllBytes(out)
            }
            val loader = VerifiedClassLoader(jars, PluginBridge::class.java.classLoader, "self-test")
            val type = Class.forName(requireNotNull(pluginClass), false, loader)
            require(BasePlugin::class.java.isAssignableFrom(type)) { "Self-test class is not a plugin" }
            // Android facilities backed by optional JDK modules must be real on the shipped runtime: StreamPlay
            // sizes its concurrency from ActivityManager, and a trimmed runtime without the management modules
            // broke its load. The code falls back without them; the shipped runtime must not need the fallback.
            for (type in listOf("java.lang.management.ManagementFactory", "com.sun.management.OperatingSystemMXBean")) {
                require(runCatching { Class.forName(type) }.isSuccess) { "This runtime lacks $type (java.management / jdk.management)" }
            }
            val memory = android.app.ActivityManager.MemoryInfo().also {
                (android.content.Context().getSystemService(android.content.Context.ACTIVITY_SERVICE) as android.app.ActivityManager).getMemoryInfo(it)
            }
            require(memory.totalMem > 0 && memory.availMem > 0) { "ActivityManager reported no memory" }
            // Dispatchers.Main must resolve to the Android main looper (extensions launch on it during load).
            val onMain = kotlinx.coroutines.runBlocking {
                kotlinx.coroutines.withTimeout(5_000) { kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) { android.os.Looper.myLooper() } }
            }
            require(onMain === android.os.Looper.getMainLooper()) { "Dispatchers.Main is not the Android main looper" }
            val worker = workerSelfTest(work)
            return "ok: translated ${jars.size} DEX file(s) and defined ${type.name}; $worker"
        } finally {
            work.toFile().deleteRecursively()
        }
    }

    /**
     * Runs a real Android-compiled Kotlin extension (`self-test/runtime.cs3`)
     * in a real worker on this runtime — sandboxed when available — through
     * the actual protocol: INIT, search → details → links, then shutdown
     * (plan RT-17). Fully offline: the fixture fabricates its results.
     */
    private fun workerSelfTest(work: java.nio.file.Path): String {
        val bytes = requireNotNull(PluginBridge::class.java.getResourceAsStream("/self-test/runtime.cs3")) { "Missing runtime self-test extension" }.readBytes()
        val artifact = work.resolve("runtime.cs3").toFile().apply { writeBytes(bytes) }
        val home = Files.createDirectories(work.resolve("worker-home")).toFile()
        val launcher = com.lagradost.macos.worker.WorkerLauncher()
        val id = ArtifactDigest.sha256("cloudstream-self-test".toByteArray())
        val record = DaemonState.InstalledExtension(id, "https://self-test.invalid/repo.json", "SelfTest",
            ArtifactDigest.sha256(bytes), java.util.UUID.randomUUID().toString(), "0".repeat(64), System.currentTimeMillis(),
            RepositoryService.SitePlugin(internalName = "SelfTest", url = "https://self-test.invalid/SelfTest.cs3", version = 1))
        val exited = java.util.concurrent.CompletableFuture<String>()
        val client = com.lagradost.macos.worker.WorkerClient(id, launcher.command(home, artifact), launcher.workingDirectory(home),
            launcher.environment(home),
            solve = { null }, onExit = { _, expected, reason -> exited.complete(if (expected) "" else reason) })
        try {
            return kotlinx.coroutines.runBlocking {
                with(com.lagradost.macos.worker.FrameCodec) {
                    val init = json.decodeFromJsonElement(com.lagradost.macos.worker.InitResult.serializer(), client.call(
                        com.lagradost.macos.worker.Op.INIT, json.encodeToJsonElement(com.lagradost.macos.worker.InitRequest.serializer(),
                            com.lagradost.macos.worker.InitRequest(record, artifact.canonicalPath, false, DaemonState.NetworkSettings(),
                                egress = com.lagradost.macos.worker.WorkerEgressProxy.active.settings)), 60_000))
                    val provider = requireNotNull(init.providers.singleOrNull()?.name) { "Self-test extension registered ${init.providers.size} providers" }
                    require(init.compatibility?.missing.orEmpty().isEmpty()) { "Self-test extension needs missing host APIs: ${init.compatibility?.missing?.map { it.type }}" }
                    val search = json.decodeFromJsonElement(com.lagradost.macos.worker.SearchResponsePayload.serializer(), client.call(
                        com.lagradost.macos.worker.Op.SEARCH, json.encodeToJsonElement(com.lagradost.macos.worker.SearchRequest.serializer(),
                            com.lagradost.macos.worker.SearchRequest(provider, "self-test")), 30_000))
                    val result = requireNotNull(search.results?.firstOrNull()) { "Search failed: ${search.failure?.code ?: search.error}" }
                    val details = json.decodeFromJsonElement(com.lagradost.macos.worker.DetailsResponsePayload.serializer(), client.call(
                        com.lagradost.macos.worker.Op.DETAILS, json.encodeToJsonElement(com.lagradost.macos.worker.DetailsRequest.serializer(),
                            com.lagradost.macos.worker.DetailsRequest(provider, result.url)), 30_000)).details
                    val data = requireNotNull(details?.movieData) { "Details returned no playable data" }
                    val links = json.decodeFromJsonElement(com.lagradost.macos.models.LinksResponseDto.serializer(), client.call(
                        com.lagradost.macos.worker.Op.LINKS, json.encodeToJsonElement(com.lagradost.macos.worker.LinksRequest.serializer(),
                            com.lagradost.macos.worker.LinksRequest(provider, data)), 30_000))
                    require(links.links.any { it.type == "M3U8" && it.url.endsWith("/video.m3u8") }) { "Links failed: ${links.failures.map { it.code }}" }
                }
                client.stop()
                val reason = exited.get(30, java.util.concurrent.TimeUnit.SECONDS)
                require(reason.isEmpty()) { "Worker did not shut down cleanly: $reason" }
                "worker ok: search, details and links through the protocol (sandboxed=${launcher.sandboxed})"
            }
        } finally { client.kill("self-test finished") }
    }

    private val DEX_NAME = Regex("classes(\\d*)\\.dex")
    private const val MAX_ENTRY_BYTES = 32 * 1024 * 1024
    private const val MAX_ASSETS = 4_096
    private const val MAX_EXPANDED_BYTES = 64L * 1024 * 1024
    /** 2000-01-01T00:00:00Z: any constant within the ZIP DOS date range. */
    private const val FIXED_ENTRY_TIME = 946_684_800_000L
}

/** Per-installation private storage handed to the plugin's Context. */
object ExtensionStorage {
    fun directory(installationId: String): File {
        require(RepositoryService.normalizedHash(installationId) == installationId) { "Invalid installation identity" }
        val dir = File(CloudDirs.extensionDataDir, installationId)
        AtomicFiles.privateDirectory(dir.toPath())
        return dir
    }

    fun delete(installationId: String) {
        if (RepositoryService.normalizedHash(installationId) != installationId) return
        val dir = File(CloudDirs.extensionDataDir, installationId)
        android.content.FileSharedPreferences.evictUnder(dir)
        dir.deleteRecursively()
        // Worker home: its Context storage, translation cache and temp (ADR-0016).
        File(CloudDirs.home, "workers/$installationId").deleteRecursively()
    }
}
