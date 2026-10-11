package com.lagradost.macos

import java.nio.file.Files
import org.junit.Assume.assumeTrue
import kotlin.test.*

/** Commits reach the medium, not only the drive's cache (Audit-Fix deferred item #22). */
class FullFsyncTest {
    @Test fun `F_FULLFSYNC is issued for a committed file`() {
        // F_FULLFSYNC exists only on macOS; there, being unavailable is a real failure.
        assumeTrue("F_FULLFSYNC is a macOS call", System.getProperty("os.name").startsWith("Mac"))
        assertTrue(FullFsync.available(), "the engine runs with the foreign-function module: ${FullFsync.unavailableReason()}")
        val dir = Files.createTempDirectory("fullfsync-")
        try {
            val file = dir.resolve("state.json")
            AtomicFiles.write(file, "{}".toByteArray())
            assertTrue(FullFsync.flush(file.toString()))
            assertTrue(AtomicFiles.fullSync(file))
            assertFalse(FullFsync.flush(dir.resolve("absent.json").toString()), "a missing file reports failure")
        } finally { dir.toFile().deleteRecursively() }
    }
}
