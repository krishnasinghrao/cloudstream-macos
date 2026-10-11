package com.lagradost.macos

import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.channels.FileLock
import java.nio.channels.OverlappingFileLockException
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.Path
import java.nio.file.StandardCopyOption.ATOMIC_MOVE
import java.nio.file.StandardCopyOption.REPLACE_EXISTING
import java.nio.file.StandardOpenOption.*
import java.nio.file.attribute.PosixFilePermissions

/** Publication on the destination filesystem; readers never see a partial file. */
internal object AtomicFiles {
    fun privateDirectory(path: Path) {
        Files.createDirectories(path)
        require(Files.isDirectory(path, NOFOLLOW_LINKS)) { "Expected a real directory: $path" }
        Files.setPosixFilePermissions(path, PosixFilePermissions.fromString("rwx------"))
    }

    fun write(path: Path, bytes: ByteArray) {
        privateDirectory(path.parent)
        require(!Files.isSymbolicLink(path)) { "Refusing symbolic-link destination: $path" }
        val temp = Files.createTempFile(path.parent, ".${path.fileName}-", ".tmp",
            PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------")))
        try {
            FileChannel.open(temp, WRITE).use { channel ->
                val buffer = ByteBuffer.wrap(bytes)
                while (buffer.hasRemaining()) channel.write(buffer)
                channel.force(true)
            }
            // No non-atomic fallback: inability to publish safely is a failed operation.
            Files.move(temp, path, ATOMIC_MOVE, REPLACE_EXISTING)
            FileChannel.open(path.parent, READ).use { it.force(true) }
            // fsync leaves the commit in the drive's cache on macOS; flush it to the medium.
            fullSync(path)
        } finally {
            Files.deleteIfExists(temp)
        }
    }

    @Volatile private var fullSyncUnavailableLogged = false

    /** F_FULLFSYNC after the rename is durable in the file system; logged once if it cannot be issued. */
    fun fullSync(path: Path): Boolean {
        if (FullFsync.flush(path.toString())) return true
        if (!fullSyncUnavailableLogged) {
            fullSyncUnavailableLogged = true
            DaemonLog.warn("storage.fullfsync_unavailable", mapOf("reason" to (FullFsync.unavailableReason() ?: "the call failed")))
        }
        return false
    }
}

/** OS lock lives as long as the process's channel, including abnormal termination. */
internal class DataRootLock private constructor(
    private val channel: FileChannel,
    private val lock: FileLock,
) : AutoCloseable {
    override fun close() { try { lock.release() } finally { channel.close() } }

    companion object {
        /** EX_TEMPFAIL; mirrored by DaemonSupervisor.dataRootInUseStatus. */
        const val IN_USE_EXIT_STATUS = 75

        fun acquire(root: Path): DataRootLock {
            AtomicFiles.privateDirectory(root)
            val path = root.resolve("daemon.lock")
            require(!Files.isSymbolicLink(path)) { "Refusing symbolic-link lock file" }
            val channel = FileChannel.open(path, CREATE, WRITE, NOFOLLOW_LINKS)
            try {
                Files.setPosixFilePermissions(path, PosixFilePermissions.fromString("rw-------"))
                val lock = try { channel.tryLock() } catch (_: OverlappingFileLockException) { null }
                checkNotNull(lock) { "Another daemon owns this data root" }
                // The owner's pid, so the app can identify an orphaned engine
                // that still holds the lock after its app went away (Remediation 1.4).
                channel.truncate(0)
                channel.write(ByteBuffer.wrap("${ProcessHandle.current().pid()}\n".toByteArray()), 0)
                channel.force(false)
                return DataRootLock(channel, lock)
            } catch (failure: Throwable) {
                channel.close()
                throw failure
            }
        }
    }
}
