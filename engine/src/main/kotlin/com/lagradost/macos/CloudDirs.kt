package com.lagradost.macos

import java.io.File

/**
 * Filesystem layout (SEC-06): everything the daemon writes lives under one
 * root — `~/.cloudstream-macos/` in production, an isolated temp dir in tests
 * (override with the `cs.cloudstream.home` system property).
 */
object CloudDirs {
    private val customRoot = System.getProperty("cs.cloudstream.home")

    val home: File = customRoot?.let { File(it) }
        ?: File(System.getProperty("user.home"), ".cloudstream-macos")

    val pluginCacheDir: File get() = File(home, "cache/plugins")
    val cs3StoreDir: File get() = File(home, "cache/sources")
    val stateDir: File get() = File(home, "state")
    val logDir: File get() = File(home, "logs")
    /** Private per-installation storage exposed to extensions via Context. */
    val extensionDataDir: File get() = File(home, "extension-data")
    /** Markers for generations being loaded; a leftover marker means a crash during load. */
    val loadingMarkerDir: File get() = File(stateDir, "loading")

    init {
        home.mkdirs()
        OwnerOnly.directory(home)
    }
}

/**
 * Owner-only permissions for what the engine creates (0700 folders, 0600
 * files). The app already creates the data root 0700; this keeps each folder
 * and log private even when the engine runs on its own (tests, development).
 * Best effort: a filesystem without POSIX permissions is left as it is.
 */
internal object OwnerOnly {
    private val directoryMode = java.nio.file.attribute.PosixFilePermissions.fromString("rwx------")
    private val fileMode = java.nio.file.attribute.PosixFilePermissions.fromString("rw-------")

    fun directory(dir: File): File = dir.also {
        runCatching { if (it.isDirectory) java.nio.file.Files.setPosixFilePermissions(it.toPath(), directoryMode) }
    }

    fun file(file: File): File = file.also {
        runCatching { if (it.isFile) java.nio.file.Files.setPosixFilePermissions(it.toPath(), fileMode) }
    }

    /** Creates [dir] and any missing parents below [CloudDirs.home], all owner-only. */
    fun mkdirs(dir: File): File {
        val created = generateSequence(dir.absoluteFile) { it.parentFile }.takeWhile { !it.exists() }.toList()
        dir.mkdirs()
        created.forEach(::directory)
        return directory(dir)
    }
}
