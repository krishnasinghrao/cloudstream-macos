package com.lagradost.macos

import android.os.Handler
import android.os.Looper
import android.os.Message
import android.os.SystemClock
import android.text.TextUtils
import org.junit.Assume.assumeTrue
import org.objectweb.asm.ClassReader
import org.objectweb.asm.ClassVisitor
import org.objectweb.asm.Opcodes
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.zip.ZipFile
import kotlin.test.*

/** Plan RT-14: Android scheduling performs its work, in order, on a worker-owned loop. */
class AndroidSchedulingTest {
    private fun await(latch: CountDownLatch) = assertTrue(latch.await(5, TimeUnit.SECONDS), "callback did not run")

    @Test fun `main looper runs posts in time order and honours delay and removal`() {
        val handler = Handler(Looper.getMainLooper())
        val seen = CopyOnWriteArrayList<String>()
        val done = CountDownLatch(1)
        val removed = Runnable { seen += "removed" }
        val start = SystemClock.uptimeMillis()
        handler.postDelayed({ seen += "late"; done.countDown() }, 200)
        handler.postDelayed(removed, 50)
        handler.post { seen += "first" }
        handler.post { seen += "second" }
        assertTrue(handler.hasCallbacks(removed))
        handler.removeCallbacks(removed)
        assertFalse(handler.hasCallbacks(removed))
        await(done)
        assertEquals(listOf("first", "second", "late"), seen.toList())
        assertTrue(SystemClock.uptimeMillis() - start >= 200)
    }

    @Test fun `messages reach handleMessage and the callback, and callbacks run on the looper thread`() {
        val received = CopyOnWriteArrayList<Int>()
        val done = CountDownLatch(2)
        var loopThread: Thread? = null
        val handler = object : Handler(Looper.getMainLooper()) {
            override fun handleMessage(msg: Message) {
                received += msg.what * 100 + msg.arg1
                loopThread = Thread.currentThread()
                assertSame(Looper.getMainLooper(), Looper.myLooper(), "myLooper on the loop thread is its looper")
                done.countDown()
            }
        }
        handler.sendEmptyMessageDelayed(2, 30)
        handler.obtainMessage(1, 5, 0).sendToTarget()
        handler.sendEmptyMessageDelayed(9, 1_000)
        assertTrue(handler.hasMessages(9))
        handler.removeMessages(9)
        assertFalse(handler.hasMessages(9))
        await(done)
        assertEquals(listOf(105, 200), received.toList())
        assertSame(Looper.getMainLooper().getThread(), loopThread)
        assertNull(Looper.myLooper(), "a thread without Looper.prepare() has no looper")

        val intercepted = CountDownLatch(1)
        Handler(Looper.getMainLooper()) { msg -> if (msg.what == 7) intercepted.countDown(); true }.sendEmptyMessage(7)
        await(intercepted)
    }

    @Test fun `a failing callback does not stop the loop`() {
        val handler = Handler(Looper.getMainLooper())
        val after = CountDownLatch(1)
        handler.post { error("extension bug") }
        handler.post { after.countDown() }
        await(after)
    }

    @Test fun `handlers need a looper and quit refuses later work`() {
        assertFailsWith<RuntimeException> { Handler() }
        val ran = CountDownLatch(1)
        lateinit var looper: Looper
        val ready = CountDownLatch(1)
        val thread = Thread {
            Looper.prepare()
            looper = Looper.myLooper()!!
            Handler().post { ran.countDown() } // implicit looper: this thread's
            ready.countDown()
            Looper.loop()
        }.apply { isDaemon = true; start() }
        await(ready)
        await(ran)
        looper.quit()
        thread.join(5_000)
        assertFalse(thread.isAlive, "loop() returns after quit()")
        assertFalse(Handler(looper).post {}, "posting after quit is refused, like Android")
    }

    @Test fun `text utilities match Android`() {
        assertTrue(TextUtils.isEmpty(null) && TextUtils.isEmpty(""))
        assertFalse(TextUtils.isEmpty(" "))
        assertTrue(TextUtils.isDigitsOnly("0123"))
        assertEquals("a,b", TextUtils.join(",", listOf("a", "b")))
        assertContentEquals(arrayOf("a", "b", ""), TextUtils.split("a,b,", ","))
        assertContentEquals(emptyArray(), TextUtils.split("", ","))
        assertEquals("&lt;a href=&quot;x&quot;&gt;", TextUtils.htmlEncode("<a href=\"x\">"))
    }

    /** Extensions link by exact JVM descriptor; each Android member we provide must match the real SDK. */
    @Test fun `scheduling types keep Android's descriptors`() {
        val sdk = File(System.getProperty("user.home"), "Library/Android/sdk/platforms/android-35/android.jar")
        assumeTrue("Android API 35 SDK required", sdk.isFile)
        val checked = mapOf(
            "android/os/Looper" to listOf("getMainLooper", "myLooper", "prepare", "loop", "quit", "quitSafely", "getThread", "isCurrentThread"),
            "android/os/Handler" to listOf("post", "postDelayed", "postAtTime", "postAtFrontOfQueue", "removeCallbacks",
                "removeCallbacksAndMessages", "removeMessages", "sendMessage", "sendMessageDelayed", "sendEmptyMessage",
                "sendEmptyMessageDelayed", "hasMessages", "hasCallbacks", "obtainMessage", "handleMessage", "dispatchMessage", "getLooper", "<init>"),
            "android/os/Message" to listOf("obtain", "sendToTarget", "getData", "setData", "getTarget", "getWhen", "recycle"),
            "android/os/SystemClock" to listOf("uptimeMillis", "elapsedRealtime", "elapsedRealtimeNanos", "sleep", "currentThreadTimeMillis"),
            "android/text/TextUtils" to listOf("isEmpty", "isDigitsOnly", "equals", "join", "split", "htmlEncode", "getTrimmedLength"),
        )
        ZipFile(sdk).use { jar ->
            for ((type, names) in checked) {
                val android = members(jar.getInputStream(jar.getEntry("$type.class")).readBytes()).filter { it.substringBefore('(') in names }
                val ours = members(javaClass.classLoader.getResourceAsStream("$type.class")!!.readBytes())
                val missing = android.filter { it !in ours }
                    // Deprecated/hidden-for-apps overloads extensions cannot use without newer SDK flags.
                    .filterNot { it.startsWith("<init>(Landroid/os/Handler\$Callback;Z)") || it.startsWith("<init>(Landroid/os/Looper;Landroid/os/Handler\$Callback;Z)") }
                assertEquals(emptyList(), missing, "$type members whose Android descriptor the engine lacks")
            }
        }
        // Android exposes these as public instance fields.
        listOf("what", "arg1", "arg2", "obj").forEach { Message::class.java.getField(it) }
    }

    private fun members(bytes: ByteArray): Set<String> {
        val out = mutableSetOf<String>()
        ClassReader(bytes).accept(object : ClassVisitor(Opcodes.ASM9) {
            override fun visitMethod(access: Int, name: String, descriptor: String, signature: String?, exceptions: Array<out String>?) = null.also {
                if (access and Opcodes.ACC_PUBLIC != 0 || access and Opcodes.ACC_PROTECTED != 0) {
                    out += name + descriptor + if (access and Opcodes.ACC_STATIC != 0) " static" else ""
                }
            }
        }, ClassReader.SKIP_CODE)
        return out
    }
}

/** Extensions use Dispatchers.Main as on Android: it must be the main looper, never missing. */
class MainDispatcherTest {
    @Test fun `Dispatchers Main runs on the Android main looper`() = kotlinx.coroutines.runBlocking<Unit> {
        val looper = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) { Looper.myLooper() }
        assertSame(Looper.getMainLooper(), looper)
        // immediate: already on the main looper, so no re-dispatch is needed.
        val order = mutableListOf<String>()
        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) {
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main.immediate) { order += "immediate" }
            order += "after"
        }
        assertEquals(listOf("immediate", "after"), order)
        // Off the main looper it dispatches there.
        assertSame(Looper.getMainLooper(), kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main.immediate) { Looper.myLooper() })
    }
}
