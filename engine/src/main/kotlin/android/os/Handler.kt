package android.os

/**
 * Android's Handler (plan RT-14): posts runnables and messages to a [Looper]'s
 * queue. Times use [SystemClock.uptimeMillis], as on Android.
 */
open class Handler @JvmOverloads constructor(looper: Looper? = null, private val callback: Callback? = null) {
    private val looper: Looper = looper ?: Looper.myLooper()
        ?: throw RuntimeException("Can't create handler inside thread ${Thread.currentThread()} that has not called Looper.prepare()")

    constructor(callback: Callback?) : this(null, callback)

    fun interface Callback {
        fun handleMessage(msg: Message): Boolean
    }

    fun getLooper(): Looper = looper

    open fun handleMessage(msg: Message) {}

    open fun dispatchMessage(msg: Message) {
        msg.callback?.let { it.run(); return }
        if (callback?.handleMessage(msg) == true) return
        handleMessage(msg)
    }

    fun post(r: Runnable): Boolean = postAtTime(r, SystemClock.uptimeMillis())
    fun postDelayed(r: Runnable, delayMillis: Long): Boolean = postAtTime(r, SystemClock.uptimeMillis() + delayMillis.coerceAtLeast(0))
    fun postDelayed(r: Runnable, token: Any?, delayMillis: Long): Boolean =
        enqueue(Message.obtain(this, r).also { it.obj = token }, SystemClock.uptimeMillis() + delayMillis.coerceAtLeast(0))
    fun postAtTime(r: Runnable, uptimeMillis: Long): Boolean = enqueue(Message.obtain(this, r), uptimeMillis)
    fun postAtTime(r: Runnable, token: Any?, uptimeMillis: Long): Boolean = enqueue(Message.obtain(this, r).also { it.obj = token }, uptimeMillis)
    fun postAtFrontOfQueue(r: Runnable): Boolean = enqueue(Message.obtain(this, r), 0)

    fun sendMessage(msg: Message): Boolean = sendMessageAtTime(msg, SystemClock.uptimeMillis())
    fun sendMessageDelayed(msg: Message, delayMillis: Long): Boolean = sendMessageAtTime(msg, SystemClock.uptimeMillis() + delayMillis.coerceAtLeast(0))
    open fun sendMessageAtTime(msg: Message, uptimeMillis: Long): Boolean { msg.target = this; return enqueue(msg, uptimeMillis) }
    fun sendMessageAtFrontOfQueue(msg: Message): Boolean { msg.target = this; return enqueue(msg, 0) }
    fun sendEmptyMessage(what: Int): Boolean = sendMessage(Message.obtain(this, what))
    fun sendEmptyMessageDelayed(what: Int, delayMillis: Long): Boolean = sendMessageDelayed(Message.obtain(this, what), delayMillis)
    fun sendEmptyMessageAtTime(what: Int, uptimeMillis: Long): Boolean = sendMessageAtTime(Message.obtain(this, what), uptimeMillis)

    fun removeCallbacks(r: Runnable) { looper.queue.removeIf { it.target === this && it.callback === r } }
    fun removeCallbacks(r: Runnable, token: Any?) {
        looper.queue.removeIf { it.target === this && it.callback === r && (token == null || it.obj === token) }
    }
    fun removeMessages(what: Int) { looper.queue.removeIf { it.target === this && it.callback == null && it.what == what } }
    fun removeMessages(what: Int, obj: Any?) {
        looper.queue.removeIf { it.target === this && it.callback == null && it.what == what && (obj == null || it.obj === obj) }
    }
    /** A null token removes every callback and message of this handler. */
    fun removeCallbacksAndMessages(token: Any?) { looper.queue.removeIf { it.target === this && (token == null || it.obj === token) } }
    fun hasMessages(what: Int): Boolean = looper.queue.anyMatch { it.target === this && it.callback == null && it.what == what }
    fun hasMessages(what: Int, obj: Any?): Boolean =
        looper.queue.anyMatch { it.target === this && it.callback == null && it.what == what && (obj == null || it.obj === obj) }
    fun hasCallbacks(r: Runnable): Boolean = looper.queue.anyMatch { it.target === this && it.callback === r }

    fun obtainMessage(): Message = Message.obtain(this)
    fun obtainMessage(what: Int): Message = Message.obtain(this, what)
    fun obtainMessage(what: Int, obj: Any?): Message = Message.obtain(this, what, obj)
    fun obtainMessage(what: Int, arg1: Int, arg2: Int): Message = Message.obtain(this, what, arg1, arg2)
    fun obtainMessage(what: Int, arg1: Int, arg2: Int, obj: Any?): Message = Message.obtain(this, what, arg1, arg2, obj)

    private fun enqueue(message: Message, at: Long): Boolean {
        message.target = this
        return looper.queue.enqueue(message, at)
    }

    companion object {
        @JvmStatic fun createAsync(looper: Looper): Handler = Handler(looper)
        @JvmStatic fun createAsync(looper: Looper, callback: Callback): Handler = Handler(looper, callback)
    }
}

/** Android's Message. Instances are not pooled; [recycle] is accepted for compatibility. */
class Message {
    @JvmField var what: Int = 0
    @JvmField var arg1: Int = 0
    @JvmField var arg2: Int = 0
    @JvmField var obj: Any? = null
    internal var target: Handler? = null
    internal var callback: Runnable? = null
    internal var `when`: Long = 0
    internal var sequence: Long = 0
    private var data: Bundle? = null

    fun getTarget(): Handler? = target
    fun setTarget(target: Handler?) { this.target = target }
    fun getCallback(): Runnable? = callback
    fun getWhen(): Long = `when`
    fun getData(): Bundle = data ?: Bundle().also { data = it }
    fun peekData(): Bundle? = data
    fun setData(data: Bundle?) { this.data = data }
    fun sendToTarget() { checkNotNull(target) { "Message has no target" }.sendMessage(this) }
    fun recycle() {}

    companion object {
        @JvmStatic fun obtain(): Message = Message()
        @JvmStatic fun obtain(orig: Message): Message = Message().also {
            it.what = orig.what; it.arg1 = orig.arg1; it.arg2 = orig.arg2; it.obj = orig.obj
            it.target = orig.target; it.callback = orig.callback; it.data = orig.data
        }
        @JvmStatic fun obtain(h: Handler?): Message = Message().also { it.target = h }
        @JvmStatic fun obtain(h: Handler?, callback: Runnable?): Message = obtain(h).also { it.callback = callback }
        @JvmStatic fun obtain(h: Handler?, what: Int): Message = obtain(h).also { it.what = what }
        @JvmStatic fun obtain(h: Handler?, what: Int, obj: Any?): Message = obtain(h, what).also { it.obj = obj }
        @JvmStatic fun obtain(h: Handler?, what: Int, arg1: Int, arg2: Int): Message =
            obtain(h, what).also { it.arg1 = arg1; it.arg2 = arg2 }
        @JvmStatic fun obtain(h: Handler?, what: Int, arg1: Int, arg2: Int, obj: Any?): Message =
            obtain(h, what, arg1, arg2).also { it.obj = obj }
    }
}

/** Android's monotonic clocks. Uptime and elapsed time both count from process start here (no device sleep). */
object SystemClock {
    private val origin = System.nanoTime()
    @JvmStatic fun uptimeMillis(): Long = (System.nanoTime() - origin) / 1_000_000
    @JvmStatic fun elapsedRealtime(): Long = uptimeMillis()
    @JvmStatic fun elapsedRealtimeNanos(): Long = System.nanoTime() - origin
    @JvmStatic fun uptimeNanos(): Long = System.nanoTime() - origin
    /** CPU time of this thread; falls back to uptime when the runtime lacks the management module. */
    @JvmStatic fun currentThreadTimeMillis(): Long = try {
        java.lang.management.ManagementFactory.getThreadMXBean().currentThreadCpuTime / 1_000_000
    } catch (_: LinkageError) { uptimeMillis() }
    @JvmStatic fun sleep(ms: Long) {
        val end = uptimeMillis() + ms
        while (true) {
            val left = end - uptimeMillis()
            if (left <= 0) return
            try { Thread.sleep(left) } catch (_: InterruptedException) { /* Android ignores interrupts here */ }
        }
    }
}

/** Android's key-value bundle, holding values in memory (no parceling across processes). */
open class Bundle() {
    private val values = LinkedHashMap<String, Any?>()

    constructor(other: Bundle) : this() { values.putAll(other.values) }

    fun size(): Int = values.size
    fun isEmpty(): Boolean = values.isEmpty()
    fun containsKey(key: String?): Boolean = values.containsKey(key)
    fun keySet(): Set<String> = values.keys
    fun remove(key: String?) { values.remove(key) }
    fun clear() = values.clear()
    fun putAll(bundle: Bundle) { values.putAll(bundle.values) }
    @Deprecated("Untyped access", ReplaceWith("getString(key)")) fun get(key: String?): Any? = values[key]

    fun putString(key: String?, value: String?) { values[key ?: return] = value }
    fun putInt(key: String?, value: Int) { values[key ?: return] = value }
    fun putLong(key: String?, value: Long) { values[key ?: return] = value }
    fun putBoolean(key: String?, value: Boolean) { values[key ?: return] = value }
    fun putDouble(key: String?, value: Double) { values[key ?: return] = value }
    fun putFloat(key: String?, value: Float) { values[key ?: return] = value }
    fun putStringArrayList(key: String?, value: ArrayList<String>?) { values[key ?: return] = value }
    fun putBundle(key: String?, value: Bundle?) { values[key ?: return] = value }
    fun putSerializable(key: String?, value: java.io.Serializable?) { values[key ?: return] = value }

    fun getString(key: String?): String? = values[key] as? String
    fun getString(key: String?, defaultValue: String?): String? = getString(key) ?: defaultValue
    @JvmOverloads fun getInt(key: String?, defaultValue: Int = 0): Int = values[key] as? Int ?: defaultValue
    @JvmOverloads fun getLong(key: String?, defaultValue: Long = 0): Long = values[key] as? Long ?: defaultValue
    @JvmOverloads fun getBoolean(key: String?, defaultValue: Boolean = false): Boolean = values[key] as? Boolean ?: defaultValue
    @JvmOverloads fun getDouble(key: String?, defaultValue: Double = 0.0): Double = values[key] as? Double ?: defaultValue
    @JvmOverloads fun getFloat(key: String?, defaultValue: Float = 0f): Float = values[key] as? Float ?: defaultValue
    @Suppress("UNCHECKED_CAST") fun getStringArrayList(key: String?): ArrayList<String>? = values[key] as? ArrayList<String>
    fun getBundle(key: String?): Bundle? = values[key] as? Bundle
    fun getSerializable(key: String?): java.io.Serializable? = values[key] as? java.io.Serializable

    override fun toString(): String = "Bundle[${values.keys}]"
}
