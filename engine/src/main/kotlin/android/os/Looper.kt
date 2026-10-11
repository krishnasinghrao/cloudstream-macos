package android.os

import java.util.PriorityQueue
import java.util.concurrent.atomic.AtomicLong

/**
 * Android's per-thread message loop (plan RT-14). The engine has no UI
 * thread: the "main" looper is a worker-owned daemon thread that runs posted
 * callbacks in time order, never Swift UI. Other threads get a looper only
 * through [prepare] and [loop], as on Android. Callbacks never outlive their
 * process; [quit] drops pending ones and refuses new ones.
 */
class Looper private constructor(internal val queue: MessageQueue) {
    @Volatile private var owner: Thread? = null

    fun getThread(): Thread = owner ?: Thread.currentThread()
    fun isCurrentThread(): Boolean = owner === Thread.currentThread()
    fun getQueue(): MessageQueue = queue
    fun quit() = queue.quit(safely = false)
    fun quitSafely() = queue.quit(safely = true)

    private fun run() {
        owner = Thread.currentThread()
        while (true) {
            val message = queue.next() ?: return
            try {
                message.target?.dispatchMessage(message)
            } catch (failure: Throwable) {
                if (failure is VirtualMachineError && failure !is StackOverflowError) throw failure
                // Android would crash the app; one extension's callback must not stop the loop.
                System.err.println("Looper: callback failed: ${failure.javaClass.name}")
            }
        }
    }

    companion object {
        private val current = ThreadLocal<Looper?>()
        private val mainLooper = lazy {
            val looper = Looper(MessageQueue())
            Thread({ current.set(looper); looper.run() }, "android-main").apply { isDaemon = true }.start()
            looper
        }
        private val main: Looper by mainLooper

        @JvmStatic fun getMainLooper(): Looper = main
        @JvmStatic fun myLooper(): Looper? = current.get()

        @JvmStatic fun prepare() {
            check(current.get() == null) { "Only one Looper may be created per thread" }
            current.set(Looper(MessageQueue()))
        }

        @JvmStatic fun loop() {
            val looper = checkNotNull(current.get()) { "No Looper; Looper.prepare() wasn't called on this thread." }
            looper.run()
        }

        /** Development isolation: drops queued callbacks whose code came from [loader] (a retired generation). */
        @JvmStatic internal fun removeCallbacksFrom(loader: ClassLoader): Boolean = mainLooper.isInitialized() && main.queue.removeIf { message ->
            listOfNotNull(message.callback, message.target, message.obj).any { it.javaClass.classLoader === loader }
        }
    }
}

/** Time-ordered queue of a [Looper]. */
class MessageQueue internal constructor() {
    // wait()/notifyAll() need a java.lang.Object monitor, which Kotlin's Any does not expose.
    @Suppress("PLATFORM_CLASS_MAPPED_TO_KOTLIN")
    private val lock = Object()
    private val sequence = AtomicLong()
    private val messages = PriorityQueue<Message>(compareBy<Message>({ it.`when` }, { it.sequence }))
    private var quitting = false

    internal fun enqueue(message: Message, at: Long): Boolean = synchronized(lock) {
        if (quitting) return false
        check(messages.size < MAX_PENDING) { "Too many pending Handler messages" }
        message.`when` = at
        message.sequence = sequence.incrementAndGet()
        messages.add(message)
        lock.notifyAll()
        true
    }

    internal fun next(): Message? = synchronized(lock) {
        while (true) {
            val head = messages.peek()
            if (quitting && (head == null || head.`when` > SystemClock.uptimeMillis())) return null
            if (head == null) { lock.wait(); continue }
            val wait = head.`when` - SystemClock.uptimeMillis()
            if (wait > 0) { lock.wait(wait); continue }
            return messages.poll()
        }
        @Suppress("UNREACHABLE_CODE") null
    }

    internal fun removeIf(predicate: (Message) -> Boolean): Boolean = synchronized(lock) { messages.removeIf(predicate) }

    internal fun anyMatch(predicate: (Message) -> Boolean): Boolean = synchronized(lock) { messages.any(predicate) }

    internal fun quit(safely: Boolean) = synchronized(lock) {
        quitting = true
        if (safely) messages.removeIf { it.`when` > SystemClock.uptimeMillis() } else messages.clear()
        lock.notifyAll()
    }

    private companion object { const val MAX_PENDING = 10_000 }
}
