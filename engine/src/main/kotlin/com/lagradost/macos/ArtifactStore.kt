package com.lagradost.macos

import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS

/**
 * Content-addressed storage below the installation model. Presence of a file
 * never authorizes execution; receipts do. Collection only removes blobs no
 * receipt, rollback generation or pending migration references.
 */
internal object ArtifactStore {
    /** Blobs younger than this may belong to an operation that has not committed yet. */
    private const val GRACE_MS = 10 * 60 * 1000L

    fun source(hash: String): File {
        require(RepositoryService.normalizedHash(hash) == hash) { "Invalid artifact digest" }
        return File(CloudDirs.cs3StoreDir, "$hash.cs3")
    }

    fun storedSources(): Map<String, Long> =
        (CloudDirs.cs3StoreDir.listFiles() ?: emptyArray()).mapNotNull { file ->
            val hash = file.name.removeSuffix(".cs3")
            if (!file.name.endsWith(".cs3") || RepositoryService.normalizedHash(hash) != hash) return@mapNotNull null
            if (!Files.isRegularFile(file.toPath(), NOFOLLOW_LINKS)) return@mapNotNull null
            hash to file.length()
        }.toMap()

    fun translationKey(sourceHash: String): String =
        ArtifactDigest.sha256("$sourceHash:${PluginBridge.TRANSLATION_PROFILE}".toByteArray())

    data class Collected(val sources: Int, val translations: Int, val proofs: Int)

    fun collect(state: DaemonState.PersistedState, proofs: InstallationProofStore, now: Long = System.currentTimeMillis()): Collected {
        val records = state.installations.values
        val keepSources = records.flatMap { listOfNotNull(it.artifactHash, it.previous?.artifactHash) }.toSet() +
            state.unmatchedLegacyArtifacts.map { it.artifactHash }
        val keepProofs = records.flatMap { listOfNotNull(it.proofHash, it.previous?.proofHash) }.toSet()
        val keepKeys = keepSources.map(::translationKey).toSet()
        fun old(file: File) = now - file.lastModified() > GRACE_MS

        var sources = 0
        (CloudDirs.cs3StoreDir.listFiles() ?: emptyArray()).forEach { file ->
            if (file.name.startsWith(".")) { if (old(file)) file.delete(); return@forEach }
            val hash = file.name.removeSuffix(".cs3")
            if (hash !in keepSources && old(file) && file.delete()) sources++
        }
        var translations = 0
        (CloudDirs.pluginCacheDir.listFiles() ?: emptyArray()).forEach { file ->
            val key = file.name.removeSuffix(".jar").substringBefore('_')
            // Includes JARs from older translation profiles and legacy <hash>.jar names.
            if (key !in keepKeys && old(file) && file.delete()) translations++
        }
        var removedProofs = 0
        proofs.storedHashes().forEach { hash ->
            val file = File(CloudDirs.stateDir, "installation-proofs/$hash.json")
            if (hash !in keepProofs && old(file)) { proofs.delete(hash); removedProofs++ }
        }
        return Collected(sources, translations, removedProofs)
    }
}

/** A marker exists only while a generation's plugin code is being loaded.
 * A marker left behind at startup means that load crashed or hung the engine. */
internal object LoadingMarkers {
    private fun file(record: DaemonState.InstalledExtension) =
        File(CloudDirs.loadingMarkerDir, "${record.id}.${record.generation.filter { it.isLetterOrDigit() || it == '-' }}")

    fun begin(record: DaemonState.InstalledExtension) {
        AtomicFiles.write(file(record).toPath(), ByteArray(0))
    }

    fun end(record: DaemonState.InstalledExtension) {
        Files.deleteIfExists(file(record).toPath())
    }

    /** (installationId, generation) pairs left by an interrupted load. */
    fun leftovers(): List<Pair<String, String>> =
        (CloudDirs.loadingMarkerDir.listFiles() ?: emptyArray()).mapNotNull { f ->
            val id = f.name.substringBefore('.')
            val generation = f.name.substringAfter('.', "")
            if (RepositoryService.normalizedHash(id) == id && generation.isNotEmpty()) id to generation else null
        }

    fun clearAll() {
        (CloudDirs.loadingMarkerDir.listFiles() ?: emptyArray()).forEach { it.delete() }
    }
}
