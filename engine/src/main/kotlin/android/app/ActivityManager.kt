package android.app

/**
 * Android's ActivityManager, for the device facts scrapers read (RT-14):
 * memory figures come from this Mac. Activity/task management has no meaning
 * in the engine and is not provided.
 */
open class ActivityManager internal constructor() {
    /** Android's public mutable fields, filled by [getMemoryInfo]. */
    open class MemoryInfo {
        @JvmField var availMem: Long = 0
        @JvmField var totalMem: Long = 0
        @JvmField var threshold: Long = 0
        @JvmField var lowMemory: Boolean = false
    }

    open fun getMemoryInfo(outInfo: MemoryInfo) {
        val (total, free) = physicalMemory() ?: (Runtime.getRuntime().maxMemory() to Runtime.getRuntime().freeMemory())
        outInfo.totalMem = total
        outInfo.availMem = free
        outInfo.threshold = outInfo.totalMem / 20
        outInfo.lowMemory = outInfo.availMem < outInfo.threshold
    }

    /**
     * This Mac's physical memory. The JDK management modules are optional in a
     * trimmed runtime: without them (a linkage error, not an exception) the
     * caller falls back to the JVM's own figures instead of failing the
     * extension that asked.
     */
    private fun physicalMemory(): Pair<Long, Long>? = try {
        (java.lang.management.ManagementFactory.getOperatingSystemMXBean() as? com.sun.management.OperatingSystemMXBean)
            ?.let { it.totalMemorySize to it.freeMemorySize }
    } catch (_: LinkageError) { null }

    open fun isLowRamDevice(): Boolean = false
    open fun getMemoryClass(): Int = (Runtime.getRuntime().maxMemory() / (1024 * 1024)).toInt()
    open fun getLargeMemoryClass(): Int = getMemoryClass()
}
