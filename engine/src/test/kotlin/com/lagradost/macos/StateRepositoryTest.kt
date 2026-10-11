package com.lagradost.macos

import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermissions
import kotlin.test.*

class StateRepositoryTest {
    private fun withStore(block: (StateRepository, File) -> Unit) {
        val root = Files.createTempDirectory("cloudstream-state-test-").toFile()
        try { block(StateRepository(File(root, "state/state.json")), root) }
        finally { root.deleteRecursively() }
    }

    @Test fun `failed disk commit preserves memory and previous disk generation`() = withStore { store, root ->
        store.load()
        store.update { it.copy(disabledProviders = setOf("disabled")) }
        val savedDir = File(root, "saved")
        assertTrue(store.file.parentFile.renameTo(savedDir))
        store.file.parentFile.writeText("not a directory")
        assertFailsWith<IOException> { store.update { it.copy(disabledProviders = emptySet()) } }
        assertEquals(setOf("disabled"), store.snapshot().disabledProviders)
        assertNotNull(store.recoveryError)
        assertFailsWith<IllegalStateException> { store.update { it } }
        assertTrue(store.file.parentFile.delete())
        assertTrue(savedDir.renameTo(store.file.parentFile))
        store.load()
        assertNull(store.recoveryError)
        assertEquals(setOf("disabled"), store.snapshot().disabledProviders)
    }

    @Test fun `corrupt state cannot silently restore older security policy`() = withStore { store, _ ->
        store.load()
        store.update { it.copy(disabledProviders = setOf("old")) }
        store.update { it.copy(disabledProviders = setOf("old", "new")) }
        assertTrue(store.backupFile.isFile)
        store.file.writeText("{broken")
        store.load()
        assertNotNull(store.recoveryError)
        assertEquals(setOf("old", "new"), store.snapshot().disabledProviders)
        assertEquals("{broken", store.file.readText())
        assertFailsWith<IllegalStateException> { store.update { it.copy(repos = emptyList()) } }
        val restarted = StateRepository(store.file)
        restarted.load()
        assertNotNull(restarted.recoveryError)
        assertFailsWith<IllegalStateException> { restarted.requireHealthy() }
    }

    @Test fun `missing primary with backup requires explicit recovery`() = withStore { store, _ ->
        store.load()
        store.update { it }
        store.update { it.copy(disabledProviders = setOf("removed")) }
        assertTrue(store.file.delete())
        val restarted = StateRepository(store.file)
        restarted.load()
        assertNotNull(restarted.recoveryError)
    }

    @Test fun `future schema is preserved and cannot be overwritten`() = withStore { store, _ ->
        store.file.parentFile.mkdirs()
        store.file.writeText("""{"version":999}""")
        store.load()
        assertNotNull(store.recoveryError)
        assertFailsWith<IllegalStateException> { store.update { it } }
        assertEquals("""{"version":999}""", store.file.readText())
    }

    @Test fun `state and backup are private and round trip after commit`() = withStore { store, _ ->
        store.load()
        store.update { it.copy(disabledProviders = setOf("first")) }
        store.update { it.copy(disabledProviders = setOf("second")) }
        for (file in listOf(store.file, store.backupFile)) {
            assertEquals("rw-------", PosixFilePermissions.toString(Files.getPosixFilePermissions(file.toPath())))
        }
        assertEquals("rwx------", PosixFilePermissions.toString(Files.getPosixFilePermissions(store.file.parentFile.toPath())))
        val restarted = StateRepository(store.file)
        restarted.load()
        assertNull(restarted.recoveryError)
        assertEquals(setOf("second"), restarted.snapshot().disabledProviders)
        assertFalse(store.file.parentFile.listFiles()!!.any { it.name.endsWith(".tmp") })
    }

    @Test fun `symbolic state file is rejected without changing its target`() = withStore { store, root ->
        store.file.parentFile.mkdirs()
        val target = File(root, "outside.json").apply { writeText("{}") }
        Files.createSymbolicLink(store.file.toPath(), target.toPath())
        store.load()
        assertNotNull(store.recoveryError)
        assertEquals("{}", target.readText())
    }

    @Test fun `only one daemon can own a data root and lock can be reacquired`() = withStore { _, root ->
        DataRootLock.acquire(root.toPath()).use {
            assertFailsWith<IllegalStateException> { DataRootLock.acquire(root.toPath()) }
            assertEquals("${ProcessHandle.current().pid()}", File(root, "daemon.lock").readText().trim(),
                "the owner's pid identifies an orphaned engine to the app")
        }
        DataRootLock.acquire(root.toPath()).use { }
    }
}
