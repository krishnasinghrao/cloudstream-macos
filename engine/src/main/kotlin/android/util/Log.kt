package android.util

/**
 * SEC-08: Pure-Java stub for `android.util.Log`.
 * All daemon and plugin log output remains strictly local (SEC-03).
 */
object Log {
    @JvmStatic
    fun v(tag: String, msg: String): Int = 0.also { println("VERBOSE: [$tag] $msg") }

    @JvmStatic
    fun d(tag: String, msg: String): Int = 0.also { println("DEBUG:   [$tag] $msg") }

    @JvmStatic
    fun i(tag: String, msg: String): Int = 0.also { println("INFO:    [$tag] $msg") }

    @JvmStatic
    fun w(tag: String, msg: String): Int = 0.also { println("WARN:    [$tag] $msg") }

    @JvmStatic
    fun w(tag: String, tr: Throwable): Int = 0.also { println("WARN:    [$tag] ${tr.message}") }

    @JvmStatic
    fun e(tag: String, msg: String): Int = 0.also { System.err.println("ERROR:   [$tag] $msg") }

    @JvmStatic
    fun e(tag: String, msg: String, tr: Throwable?): Int = 0.also {
        System.err.println("ERROR:   [$tag] $msg")
        tr?.printStackTrace()
    }

    @JvmStatic
    fun wtf(tag: String, msg: String): Int = 0.also { System.err.println("FATAL:   [$tag] $msg") }
}
