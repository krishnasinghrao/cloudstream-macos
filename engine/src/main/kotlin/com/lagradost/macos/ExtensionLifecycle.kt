package com.lagradost.macos

import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** Short publication/state boundaries only. Downloads and plugin preparation
 * run outside this gate, so the current generation stays available. */
internal object ExtensionLifecycle {
    private val lock = ReentrantLock()
    fun <T> locked(block: () -> T): T = lock.withLock(block)
}
