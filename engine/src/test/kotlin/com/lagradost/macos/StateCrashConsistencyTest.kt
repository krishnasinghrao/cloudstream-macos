package com.lagradost.macos

import java.io.File
import java.nio.file.Files
import java.util.concurrent.TimeUnit
import kotlin.random.Random
import kotlin.test.*

/** Writer process for [StateCrashConsistencyTest]: commits ever-increasing generations until killed. */
object StateWriterProbe {
    @JvmStatic fun main(args: Array<String>) {
        val repository = StateRepository(File(args[0]))
        repository.load()
        var generation = repository.snapshot().disabledProviders.firstOrNull { it.startsWith("gen-") }?.removePrefix("gen-")?.toInt() ?: 0
        println("ready")
        while (true) {
            generation++
            // Large enough that a write spans several syscalls.
            repository.update { it.copy(disabledProviders = setOf("gen-$generation") + (1..2_000).map { i -> "padding-$generation-$i" }) }
        }
    }
}

/** Plan T9.4: SIGKILL at arbitrary points of the commit never corrupts or rolls back state. */
class StateCrashConsistencyTest {
    @Test fun `killing a writer mid-commit leaves a loadable, monotonic state`() {
        val dir = Files.createTempDirectory("state-crash").toFile()
        try {
            val file = File(dir, "state.json")
            // SIGKILL can legitimately arrive before the first commit. Seed
            // a complete durable generation so every kill point, including
            // the first write, has a known baseline to preserve. "ready"
            // only means the process loaded; it never proved a commit.
            StateRepository(file).also { repository ->
                repository.load()
                repository.update { it.copy(disabledProviders = setOf("gen-0") + (1..2_000).map { i -> "padding-0-$i" }) }
            }
            val java = File(System.getProperty("java.home"), "bin/java").path
            var lastGeneration = 0
            repeat(20) { round ->
                val process = ProcessBuilder(java, "-cp", System.getProperty("java.class.path"),
                    "-Dcs.cloudstream.home=${dir.path}", StateWriterProbe::class.java.name, file.path)
                    .redirectErrorStream(true).start()
                val reader = process.inputStream.bufferedReader()
                assertEquals("ready", reader.readLine(), "writer started")
                Thread.sleep(Random(round).nextLong(20, 250))
                process.destroyForcibly()
                assertTrue(process.waitFor(10, TimeUnit.SECONDS))

                val repository = StateRepository(file)
                repository.load()
                assertNull(repository.recoveryError, "round $round: state must load after SIGKILL")
                val generation = repository.snapshot().disabledProviders.single { it.startsWith("gen-") }.removePrefix("gen-").toInt()
                assertTrue(generation >= lastGeneration, "round $round: generation went backwards ($lastGeneration → $generation)")
                assertEquals(2_001, repository.snapshot().disabledProviders.size, "round $round: partial state")
                lastGeneration = generation
                assertTrue(dir.listFiles()!!.none { it.name.endsWith(".tmp") }, "interrupted temp files are removed on load")
            }
            assertTrue(lastGeneration > 0)
        } finally { dir.deleteRecursively() }
    }
}
