package android.webkit

import android.content.Context
import kotlinx.coroutines.launch

/*
 * Android's embedded browser types, as extensions link against them.
 *
 * Extensions use a WebView in two ways: as UI (settings and challenge dialogs,
 * never shown on macOS) and as a hidden JavaScript engine for decrypting
 * sources. No browser runs inside an extension worker: a WebView here is a
 * handle onto an isolated WebKit view in the Mac app (WebViewSessionBridge).
 * Loading, evaluateJavascript, onPageFinished and JavaScript-interface calls
 * work through it; nothing is rendered or shown. Without the app (or in a
 * runtime with no host), evaluateJavascript fails with a named error and no
 * result is ever fabricated.
 */

/** Receives an asynchronous value, as Android's ValueCallback. */
fun interface ValueCallback<T> {
    fun onReceiveValue(value: T)
}

/** Marks methods exposed to page scripts on Android. No page script runs here. */
@Retention(AnnotationRetention.RUNTIME)
@Target(AnnotationTarget.FUNCTION)
annotation class JavascriptInterface

open class WebSettings internal constructor() {
    private var userAgent: String = com.lagradost.cloudstream3.USER_AGENT

    open fun setJavaScriptEnabled(flag: Boolean) {}
    open fun setDomStorageEnabled(flag: Boolean) {}
    open fun setDatabaseEnabled(flag: Boolean) {}
    open fun setAllowFileAccess(allow: Boolean) {}
    open fun setAllowContentAccess(allow: Boolean) {}
    open fun setBlockNetworkImage(flag: Boolean) {}
    open fun setLoadsImagesAutomatically(flag: Boolean) {}
    open fun setMediaPlaybackRequiresUserGesture(require: Boolean) {}
    open fun setJavaScriptCanOpenWindowsAutomatically(flag: Boolean) {}
    open fun setSupportMultipleWindows(support: Boolean) {}
    open fun setSupportZoom(support: Boolean) {}
    open fun setUseWideViewPort(use: Boolean) {}
    open fun setLoadWithOverviewMode(overview: Boolean) {}
    open fun setCacheMode(mode: Int) {}
    open fun setMixedContentMode(mode: Int) {}
    open fun setUserAgentString(ua: String?) { userAgent = ua ?: com.lagradost.cloudstream3.USER_AGENT }
    open fun getUserAgentString(): String = userAgent
}

open class WebViewClient {
    open fun onPageFinished(view: WebView?, url: String?) {}
    open fun onLoadResource(view: WebView?, url: String?) {}
    @Deprecated("Android deprecated the String overload") open fun shouldOverrideUrlLoading(view: WebView?, url: String?): Boolean = false
    open fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean = false
    @Deprecated("Android deprecated this overload") open fun onReceivedError(view: WebView?, errorCode: Int, description: String?, failingUrl: String?) {}
}

open class WebChromeClient {
    open fun onProgressChanged(view: WebView?, newProgress: Int) {}
    open fun onReceivedTitle(view: WebView?, title: String?) {}
}

interface WebResourceRequest {
    fun getUrl(): android.net.Uri
    fun isForMainFrame(): Boolean
    fun hasGesture(): Boolean
    fun getMethod(): String
    fun getRequestHeaders(): Map<String, String>
}

open class WebView(context: Context?) {
    private val settings = WebSettings()
    private val session = java.util.UUID.randomUUID().toString()
    private val interfaces = java.util.concurrent.ConcurrentHashMap<String, Any>()
    @Volatile private var client: WebViewClient? = null
    @Volatile private var destroyed = false
    private val polling = java.util.concurrent.atomic.AtomicBoolean(false)
    private val scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.IO)
    /** Operations run one at a time, in the order the extension issued them, as on Android's UI thread. */
    private val operations = kotlinx.coroutines.channels.Channel<suspend (suspend (com.lagradost.macos.WebViewRequest) -> com.lagradost.macos.WebViewResponse) -> Unit>(
        kotlinx.coroutines.channels.Channel.UNLIMITED)
    private val main by lazy { android.os.Handler(android.os.Looper.getMainLooper()) }

    init {
        scope.launch {
            for (operation in operations) {
                val transport = com.lagradost.macos.WebViewSessions.transport ?: continue
                try { operation(transport) } catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
                catch (failure: Exception) { System.err.println("WebView: ${failure.javaClass.simpleName}: ${failure.message?.take(200)}") }
            }
        }
    }

    open fun getSettings(): WebSettings = settings
    open fun setWebViewClient(client: WebViewClient) { this.client = client }
    open fun setWebChromeClient(client: WebChromeClient?) {}
    open fun addJavascriptInterface(obj: Any, name: String) { interfaces[name] = obj }
    open fun removeJavascriptInterface(name: String) { interfaces.remove(name) }
    open fun loadUrl(url: String) = load(url = url)
    open fun loadUrl(url: String, additionalHttpHeaders: Map<String, String>) = load(url = url)
    open fun loadData(data: String, mimeType: String?, encoding: String?) = load(html = data)
    open fun loadDataWithBaseURL(baseUrl: String?, data: String, mimeType: String?, encoding: String?, historyUrl: String?) =
        load(html = data, baseUrl = baseUrl)
    open fun stopLoading() {}
    open fun clearCache(includeDiskFiles: Boolean) {}
    open fun clearHistory() {}

    open fun destroy() {
        if (destroyed) return
        destroyed = true
        operations.trySend { transport ->
            transport(com.lagradost.macos.WebViewRequest(session, "destroy"))
            scope.coroutineContext[kotlinx.coroutines.Job]?.cancel()
        }
    }

    private fun load(url: String? = null, html: String? = null, baseUrl: String? = null) {
        if (destroyed) return
        operations.trySend { transport ->
            transport(com.lagradost.macos.WebViewRequest(session, "load", url = url, html = html, baseUrl = baseUrl,
                userAgent = settings.getUserAgentString(), interfaces = interfaces.keys.toList()))
            if (polling.compareAndSet(false, true)) scope.launch { poll(transport) }
        }
    }

    /**
     * Runs [script] in the page. The result reaches [resultCallback] on the main looper as its JSON
     * encoding, as on Android. Without a host browser (no Mac app serving this engine) it fails by name.
     */
    open fun evaluateJavascript(script: String, resultCallback: ValueCallback<String>?) {
        if (com.lagradost.macos.WebViewSessions.transport == null) throw UnsupportedOperationException(UNAVAILABLE)
        if (destroyed) return
        operations.trySend { transport ->
            val result = try {
                transport(com.lagradost.macos.WebViewRequest(session, "eval", script = script)).result ?: "null"
            } catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled } catch (failure: Exception) {
                System.err.println("WebView: evaluateJavascript failed: ${failure.message?.take(200)}")
                "null" // Android reports null when a script throws
            }
            resultCallback?.let { callback -> main.post { callback.onReceiveValue(result) } }
        }
    }

    /** Delivers page events for as long as the session lives. */
    private suspend fun poll(transport: suspend (com.lagradost.macos.WebViewRequest) -> com.lagradost.macos.WebViewResponse) {
        while (!destroyed) {
            val response = try { transport(com.lagradost.macos.WebViewRequest(session, "poll")) }
                catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
                catch (_: Exception) { kotlinx.coroutines.delay(2_000); continue }
            for (event in response.events) when (event.kind) {
                "finished" -> client?.let { c -> main.post { c.onPageFinished(this, event.url) } }
                "call" -> invoke(event)
            }
            if (!response.alive) { polling.set(false); return }
        }
    }

    /** Calls a method the page invoked. Only methods annotated [JavascriptInterface] are reachable, as on Android. */
    private fun invoke(event: com.lagradost.macos.WebViewEvent) {
        val target = interfaces[event.name] ?: return
        val method = target.javaClass.methods.firstOrNull {
            it.name == event.method && it.parameterCount == event.args.size && it.isAnnotationPresent(JavascriptInterface::class.java)
        } ?: return
        val arguments: List<Any> = method.parameterTypes.mapIndexed { index, type ->
            val raw = event.args[index]
            when (type) {
                String::class.java, Any::class.java, CharSequence::class.java -> raw
                Int::class.javaPrimitiveType, Int::class.javaObjectType -> raw.toDoubleOrNull()?.toInt() ?: return
                Long::class.javaPrimitiveType, Long::class.javaObjectType -> raw.toDoubleOrNull()?.toLong() ?: return
                Double::class.javaPrimitiveType, Double::class.javaObjectType -> raw.toDoubleOrNull() ?: return
                Float::class.javaPrimitiveType, Float::class.javaObjectType -> raw.toFloatOrNull() ?: return
                Boolean::class.javaPrimitiveType, Boolean::class.javaObjectType -> raw == "true"
                else -> return
            }
        }
        try { method.isAccessible = true; method.invoke(target, *arguments.toTypedArray()) }
        catch (failure: Exception) { System.err.println("WebView: interface call failed: ${failure.javaClass.simpleName}") }
    }

    companion object {
        const val UNAVAILABLE = "android.webkit.WebView cannot run JavaScript here: no browser is serving this engine."
    }
}

/** Android's cookie store for WebViews. No WebView loads pages here, so it holds nothing. */
open class CookieManager private constructor() {
    open fun setAcceptCookie(accept: Boolean) {}
    open fun setAcceptThirdPartyCookies(webview: WebView?, accept: Boolean) {}
    open fun getCookie(url: String?): String? = null
    open fun setCookie(url: String?, value: String?) {}
    open fun removeAllCookies(callback: ValueCallback<Boolean>?) { callback?.onReceiveValue(false) }
    open fun flush() {}

    companion object {
        private val instance = CookieManager()
        @JvmStatic fun getInstance(): CookieManager = instance
    }
}

open class WebStorage private constructor() {
    open fun deleteAllData() {}

    companion object {
        private val instance = WebStorage()
        @JvmStatic fun getInstance(): WebStorage = instance
    }
}
