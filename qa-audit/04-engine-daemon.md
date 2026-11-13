# Audit Report: Headless Scraper Daemon & Kotlin Engine

## Scope

This audit covers the headless scraper daemon, local IPC server, worker isolation subsystem, media relay proxy, and the Android compatibility layer in `engine/src/main/` and `engine/src/test/`. We traced the end-to-end execution flows across:
- **Daemon Lifecycle & IPC**: Ktor Netty embedded HTTP server (`Main.kt`), local loopback host validation (`LoopbackHost.kt`), Bearer token authentication, file-based IPC locks (`DaemonLock.kt`), atomic state persistence (`AtomicFiles.kt`, `StateRepository.kt`), foreign-linker Darwin fsync (`FullFsync.java`), and shutdown hooks (`ShutdownWatchdog.kt`).
- **Worker Subprocess & Isolation**: Out-of-process worker management (`WorkerClient.kt`, `WorkerLauncher.kt`, `WorkerPool.kt`), binary frame protocol (`FrameCodec.kt`, `FrameWriter.kt`), SOCKS5 egress proxy and slot rate-limiting (`WorkerEgressProxy.kt`, `WorkerEgress.kt`), and dynamic plugin loading (`PluginBridge.kt`, `VerifiedClassLoader.kt`).
- **Media Relay & Streaming**: Streaming relay HTTP proxy (`MediaRelay.kt`), HLS/DASH manifest rewriting (`ManifestRewriter.kt`), LL-HLS delta update queries, and range-request forwarding (`StreamingConnection.kt`).
- **Android Compatibility Mock Layer**: Looper message dispatching and coroutine integration (`android/os/Looper.kt`, `LooperMainDispatcher.kt`), Android Context and sandboxed file storage (`android/content/Context.kt`, `android/content/ContextWrapper.kt`, `FileSharedPreferences.kt`), URI parsing and percent decoding (`android/net/Uri.kt`), and string utilities (`android/text/TextUtils.kt`).

Test suite behavior was verified against `./gradlew -q :engine:test --tests "com.lagradost.macos.AndroidDescriptorConformanceTest"`.

---

## Findings

### F-engine-01: SOCKS5 Reverse Pipe Hang and Permit Exhaustion on Unidirectional Disconnect
- **Severity**: High
- **Confidence**: high
- **Type**: hang
- **Location**: `engine/src/main/kotlin/com/lagradost/macos/worker/WorkerEgressProxy.kt:92-109`
- **Trigger**: A worker process issues an outbound HTTP request through the daemon's internal SOCKS5 egress proxy (`WorkerEgressProxy`). The client shuts down its outbound direction or terminates, or the upstream remote server sends an immediate response and half-closes (or TCP resets) the inbound direction.
- **Trace**:
  1. In `serve()`, when a SOCKS5 connect command succeeds, the forward pipe (`pipe(input, remote.getOutputStream(), remote, activity)`) runs on the calling thread, while the reverse pipe (`pipe(remote.getInputStream(), output, socket, activity)`) is dispatched to `pool.submit` as `back`.
  2. When the forward pipe finishes (client sends EOF or disconnects), `pipe(...)` finishes and executes `remote.shutdownOutput()`.
  3. Execution in `serve()` immediately reaches line 108: `runCatching { back.get() }`. The calling thread blocks waiting for the `back` task to complete.
  4. In `back`, `remote.getInputStream().read(buffer)` is blocked waiting for data from the remote server. Because `remote.close()` is not called until `upstream.use { ... }` block exits (which cannot happen until `back.get()` returns), `remote.getInputStream()` remains open.
  5. If the remote server keeps the connection open or enters a half-closed state, `pipe()` only wakes when `idleTimeoutMs` elapses (default 10 minutes, checked via `poll` interval of up to 5,000ms).
  6. During this entire 10-minute window, the calling thread is blocked at line 108, the reverse pipe thread is blocked in `pool`, and the concurrency permit `slots.acquire()` (limited to `MAX_CONCURRENT_TUNNELS = 256`) remains held.
  7. Under normal scraping workloads with multiple providers fetching metadata, these hung permits accumulate, exhausting the 256-slot semaphore and starving subsequent worker egress requests (`worker.egress_saturated`).
- **Impact**: SOCKS5 egress proxy saturation, worker network requests timing out with 503/refusal errors, and thread pool exhaustion across the engine daemon.
- **Evidence**:
  ```kotlin
  // engine/src/main/kotlin/com/lagradost/macos/worker/WorkerEgressProxy.kt:105-109
  val activity = AtomicLong(System.currentTimeMillis())
  val back = pool.submit { pipe(remote.getInputStream(), output, socket, activity) }
  pipe(input, remote.getOutputStream(), remote, activity)
  runCatching { back.get() }
  ```
- **Recommended fix**: In `serve()`, ensure that when the forward pipe terminates, the reverse pipe is promptly interrupted or the underlying sockets are closed immediately to unblock `back.get()`:
  ```kotlin
  try {
      pipe(input, remote.getOutputStream(), remote, activity)
  } finally {
      runCatching { socket.close() }
      runCatching { remote.close() }
      runCatching { back.cancel(true) }
      runCatching { back.get() }
  }
  ```
- **Guards considered**: Line 100 sets `socket.soTimeout = poll` (up to 5s) and checks `activity.get()`. However, the activity timeout check only trips if `now - activity.get() > idleTimeoutMs`, which is explicitly configured to 10 minutes. A dead or hanging upstream connection thus holds the slot for 10 minutes instead of closing upon forward EOF.

---

### F-engine-02: Leaked Process Input Stream File Descriptors Across Worker Process Recycles
- **Severity**: High
- **Confidence**: high
- **Type**: leak
- **Location**: `engine/src/main/kotlin/com/lagradost/macos/worker/WorkerClient.kt:198-228`, `engine/src/main/kotlin/com/lagradost/macos/worker/WorkerClient.kt:351-375`
- **Trigger**: Worker processes are periodically recycled due to idle timeout (`WORKER_IDLE_TIMEOUT_MS`), memory limits (`MAX_HEAP_MB = 256`), or unexpected worker crashes.
- **Trace**:
  1. `WorkerClient.readLoop()` initializes the reading pipeline: `val input = DataInputStream(BufferedInputStream(process.inputStream))`.
  2. When the worker process exits or is killed, `FrameCodec.read` receives EOF and returns `null`, breaking out of the `while (true)` loop at line 202.
  3. `readLoop()` terminates without closing `input` or `process.inputStream` (there is no `finally` block or `use` construct).
  4. Concurrently, `handleExit()` is triggered on process termination. In `handleExit()` (lines 372-375):
     ```kotlin
     scope.cancel()
     deadlines.cancel()
     output.close()
     onExit(this, expected, reason)
     ```
     `output` (`process.outputStream`) is explicitly closed, but `process.inputStream` is never closed.
  5. In Java `ProcessImpl` on UNIX/macOS, `process.inputStream` is backed by a `FileInputStream` owning a native pipe file descriptor. Because it is never closed, the file descriptor remains open in the daemon's file descriptor table until finalization or GC garbage collection.
  6. Over extended runs with repeated extension invocations and recycling, the daemon leaks open pipe file descriptors, eventually reaching system limit (`EMFILE: Too many open files`).
- **Impact**: Gradual file descriptor exhaustion in the daemon process, resulting in inability to open new database connections, cache files, or spawn new worker processes.
- **Evidence**:
  ```kotlin
  // engine/src/main/kotlin/com/lagradost/macos/worker/WorkerClient.kt:198-202
  private fun readLoop() {
      val input = DataInputStream(BufferedInputStream(process.inputStream))
      try {
          while (true) {
              val frame = FrameCodec.read(input, ::reportStrayOutput) ?: break
  ...
  // engine/src/main/kotlin/com/lagradost/macos/worker/WorkerClient.kt:372-375
  scope.cancel()
  deadlines.cancel()
  output.close()
  onExit(this, expected, reason)
  ```
- **Recommended fix**: Wrap the input stream in a `use` block inside `readLoop()`, or explicitly close both `process.inputStream` and `process.errorStream` inside `handleExit()`:
  ```kotlin
  runCatching { output.close() }
  runCatching { process.inputStream.close() }
  runCatching { process.errorStream.close() }
  ```
- **Guards considered**: `output.close()` is present in `handleExit()`, showing an intent to clean up streams, but input streams were omitted, relying on GC cleaner mechanisms which are non-deterministic and easily delayed under low-heap daemon conditions.

---

### F-engine-03: `Context.getResources()` and `getAssets()` Hardcoded to `null` Causing Immediate Crash on Android Resource Lookups
- **Severity**: High
- **Confidence**: high
- **Type**: crash
- **Location**: `engine/src/main/kotlin/android/content/Context.kt:69-70`
- **Trigger**: An extension provider accesses strings, string arrays, or raw assets using standard Android idiom `context.resources` (e.g., `context.resources.getString(...)`, `context.resources.getIdentifier(...)`, or `context.assets.open(...)`).
- **Trace**:
  1. In CloudStream Android plugins, `context.resources` is universally expected to be non-null (as guaranteed by the Android platform `@NonNull Context.getResources()`).
  2. In `PluginBridge.kt:124-131`, `resources` (`android.content.res.Resources`) is parsed from the APK's `resources.arsc` and attached to `plugin.resources`.
  3. However, when the plugin is loaded via `plugin.load(context)`, the context supplied to the plugin and subsequent provider calls is an instance of `android.content.Context`.
  4. In `engine/src/main/kotlin/android/content/Context.kt:69-70`:
     ```kotlin
     open fun getResources(): Resources? = null
     open fun getAssets(): AssetManager? = null
     ```
  5. Any extension code or library utility that calls `context.resources` or `context.getResources()` receives `null`. When attempting to invoke any method on the result (such as `context.resources.getString(resId)`), a `NullPointerException` is thrown immediately.
- **Impact**: Any CloudStream extension relying on compiled Android string resources or bundled assets crashes during initialization or metadata extraction.
- **Evidence**:
  ```kotlin
  // engine/src/main/kotlin/android/content/Context.kt:69-70
  open fun getResources(): Resources? = null
  open fun getAssets(): AssetManager? = null
  ```
  Compare with Android API contract where `Context.getResources()` and `Context.getAssets()` are `@NonNull`.
- **Recommended fix**: Allow `Context` to store and expose references to the loaded `Resources` and `AssetManager` instances:
  ```kotlin
  open class Context(
      private val root: File = File(CloudDirs.extensionDataDir, "_host"),
      private val resources: Resources? = null,
      private val assets: AssetManager? = null
  ) {
      open fun getResources(): Resources? = resources
      open fun getAssets(): AssetManager? = assets
  ...
  ```
- **Guards considered**: `PluginBridge.kt` parses `resources.arsc` and sets `plugin.resources`, but failed to thread this instance into the `Context` passed into `plugin.load(context)`.

---

### F-engine-04: `ContextWrapper` Fails to Delegate Storage Calls to Base Context, Bleeding Data Into Host Directory
- **Severity**: High
- **Confidence**: high
- **Type**: logic
- **Location**: `engine/src/main/kotlin/android/content/ContextWrapper.kt:9-11`, `engine/src/main/kotlin/android/content/Context.kt:19-27`
- **Trigger**: An extension wraps its context using `ContextWrapper` (standard Android pattern used by third-party Android libraries, HTTP interceptors, or themed components).
- **Trace**:
  1. An extension receives an isolated `Context` rooted at `File(CloudDirs.extensionDataDir, record.id)`.
  2. The extension or an included library wraps this context: `val wrapped = ContextWrapper(context)`.
  3. The extension then writes preferences or files via `wrapped.getSharedPreferences("auth", 0)` or `wrapped.getFilesDir()`.
  4. `ContextWrapper` is declared as:
     ```kotlin
     open class ContextWrapper(private val base: Context?) : Context() {
         open fun getBaseContext(): Context? = base
     }
     ```
  5. `ContextWrapper` invokes `super()`, which defaults to `Context(root = File(CloudDirs.extensionDataDir, "_host"))`.
  6. `ContextWrapper` overrides *none* of `Context`'s methods: `getFilesDir()`, `getCacheDir()`, `getSharedPreferences()`, `getDataDir()`, etc.
  7. As a result, all storage operations on the wrapper bypass `base` completely and operate on `_host`.
  8. Storage files from different extensions using `ContextWrapper` collide in `_host`, and files written through the wrapper are not removed when the extension is uninstalled (since uninstall only purges `File(CloudDirs.extensionDataDir, record.id)`).
- **Impact**: Violation of extension storage isolation; credential/preference collision between distinct extensions; orphaned files persisting indefinitely in `_host`.
- **Evidence**:
  ```kotlin
  // engine/src/main/kotlin/android/content/ContextWrapper.kt:9-11
  open class ContextWrapper(private val base: Context?) : Context() {
      open fun getBaseContext(): Context? = base
  }
  ```
- **Recommended fix**: Delegate all virtual methods in `ContextWrapper` to `base` when non-null:
  ```kotlin
  open class ContextWrapper(private val base: Context?) : Context() {
      open fun getBaseContext(): Context? = base
      override fun getFilesDir(): File = base?.getFilesDir() ?: super.getFilesDir()
      override fun getCacheDir(): File = base?.getCacheDir() ?: super.getCacheDir()
      override fun getDataDir(): File = base?.getDataDir() ?: super.getDataDir()
      override fun getSharedPreferences(name: String, mode: Int): SharedPreferences =
          base?.getSharedPreferences(name, mode) ?: super.getSharedPreferences(name, mode)
      override fun getResources(): Resources? = base?.getResources() ?: super.getResources()
      override fun getAssets(): AssetManager? = base?.getAssets() ?: super.getAssets()
  }
  ```
- **Guards considered**: The comment in `ContextWrapper.kt` notes that "here the wrapper keeps the engine's host context", which appears to be an intentional shortcut, but this directly violates the contract expected by Android libraries and breaks extension isolation.

---

### F-engine-05: Non-Hierarchical and Opaque Scheme URI Parsing Failure
- **Severity**: Medium
- **Confidence**: high
- **Type**: logic
- **Location**: `engine/src/main/kotlin/android/net/Uri.kt:27-28`
- **Trigger**: An extension parses an opaque or non-hierarchical URI (such as `data:image/png;base64,...`, `javascript:...`, `mailto:...`, or `urn:...`).
- **Trace**:
  1. `Uri.parse(uriString)` delegates to `Uri.Impl.from(raw)`.
  2. Lines 27-28 determine the scheme:
     ```kotlin
     val scheme = if (rest.contains("://")) rest.substringBefore("://") else null
     if (scheme != null) rest = rest.substringAfter("://")
     ```
  3. Opaque and non-hierarchical URIs do not contain `"://"`, but rather a single `":"` separating scheme from scheme-specific part (per RFC 3986).
  4. Because `rest.contains("://")` is false, `scheme` is assigned `null`.
  5. As a consequence:
     - `uri.getScheme()` returns `""`.
     - `uri.isAbsolute()` returns `false`.
     - `uri.isRelative()` returns `true`.
     - `uri.isOpaque()` returns `false`.
     - The entire scheme name and scheme-specific part are erroneously treated as relative path and authority segments.
- **Impact**: Incorrect URL routing, failure of data URI extractors (e.g., base64 captcha or poster image parsing), and broken scheme checks in extension scrapers.
- **Evidence**:
  ```kotlin
  // engine/src/main/kotlin/android/net/Uri.kt:27-28
  val scheme = if (rest.contains("://")) rest.substringBefore("://") else null
  if (scheme != null) rest = rest.substringAfter("://")
  ```
- **Recommended fix**: Parse the scheme per RFC 3986 using regular expression `^([a-zA-Z][a-zA-Z0-9+.-]*):`:
  ```kotlin
  val match = Regex("^([a-zA-Z][a-zA-Z0-9+.-]*):(.*)$").matchEntire(rest)
  val scheme = match?.groupValues?.get(1)
  if (scheme != null) {
      val afterScheme = match.groupValues[2]
      rest = if (afterScheme.startsWith("//")) afterScheme.substring(2) else afterScheme
  }
  ```
- **Guards considered**: The existing tests in `AndroidDescriptorConformanceTest` only verify standard `http://` and `https://` URLs, missing opaque and data URIs.

---

### F-engine-06: `Uri` Accessors Return Empty String Instead of Null for Absent Components
- **Severity**: Medium
- **Confidence**: high
- **Type**: platform
- **Location**: `engine/src/main/kotlin/android/net/Uri.kt:57-63`
- **Trigger**: Extension code checks whether a component is present via null check: `if (uri.host != null)` or `if (uri.scheme != null)` on relative or host-less URIs.
- **Trace**:
  1. In the Android SDK, `android.net.Uri.getHost()`, `getScheme()`, `getPath()`, and `getAuthority()` are defined to return `@Nullable String`, returning `null` when the component is absent.
  2. In `engine/src/main/kotlin/android/net/Uri.kt:57-63`:
     ```kotlin
     fun getScheme(): String = impl.scheme ?: ""
     fun getHost(): String = impl.host ?: ""
     fun getPort(): Int = impl.port
     fun getPath(): String = impl.path ?: ""
     fun getQuery(): String? = impl.query
     fun getFragment(): String? = impl.fragment
     fun getAuthority(): String = impl.authority ?: ""
     ```
  3. When an extension checks `uri.host != null` on a relative URI such as `"/api/v1/stream"`, the check evaluates to `true` (since it returns `""`).
  4. Subsequent logic attempting to resolve the host or checking `uri.host.startsWith(...)` operates on an empty string or attempts network DNS lookups on empty hostnames.
- **Impact**: Broken conditional branching in third-party extension scrapers; unexpected behavior on relative URI resolution.
- **Evidence**:
  ```kotlin
  // engine/src/main/kotlin/android/net/Uri.kt:57-60
  fun getScheme(): String = impl.scheme ?: ""
  fun getHost(): String = impl.host ?: ""
  fun getPort(): Int = impl.port
  fun getPath(): String = impl.path ?: ""
  ```
- **Recommended fix**: Align the mock API return types with Android SDK `android.net.Uri`:
  ```kotlin
  fun getScheme(): String? = impl.scheme
  fun getHost(): String? = impl.host
  fun getPath(): String? = impl.path
  fun getAuthority(): String? = impl.authority
  ```
- **Guards considered**: In Kotlin, non-null return types prevent idiomatic safe-call checks (`uri.host?.let { ... }`) and force code into `uri.host.isNotEmpty()`, which breaks standard multi-platform Android scraper code.

---

### F-engine-07: Surrogate Pair Truncation and Byte Corruption in `Uri.decodeComponent`
- **Severity**: Medium
- **Confidence**: high
- **Type**: corruption
- **Location**: `engine/src/main/kotlin/android/net/Uri.kt:148`
- **Trigger**: An extension decodes a URI or query parameter containing supplementary Unicode characters (e.g. emojis or CJK ideographs above U+FFFF represented as UTF-16 surrogate pairs in Java Strings).
- **Trace**:
  1. `Uri.decode(s)` invokes `decodeComponent(s, false)`.
  2. In `decodeComponent`:
     ```kotlin
     var i = 0
     while (i < value.length) {
         val c = value[i]
         ...
         if (c == '+' && plusAsSpace) out.write(' '.code) else out.write(c.toString().toByteArray(Charsets.UTF_8))
         i++
     }
     ```
  3. When `value[i]` is a high surrogate (`\uD800..\uDBFF`), `c.toString()` produces a 1-character String with an isolated, unpaired surrogate.
  4. In Java/Kotlin, converting an unpaired surrogate String to UTF-8 (`c.toString().toByteArray(Charsets.UTF_8)`) replaces the malformed surrogate with the 3-byte UTF-8 replacement character `0xEF 0xBF 0xBD` (U+FFFD).
  5. The loop then advances `i++` and encounters the low surrogate (`\uDC00..\uDFFF`), which is likewise converted to an isolated string and replaced with a second replacement character `0xEF 0xBF 0xBD`.
  6. The output byte stream contains two replacement characters (`\uFFFD\uFFFD`) instead of the valid 4-byte UTF-8 encoding of the supplementary character.
- **Impact**: Irreversible data corruption of media titles, search queries, or stream URLs containing emoji or international symbols.
- **Evidence**:
  ```kotlin
  // engine/src/main/kotlin/android/net/Uri.kt:148
  if (c == '+' && plusAsSpace) out.write(' '.code) else out.write(c.toString().toByteArray(Charsets.UTF_8))
  ```
- **Recommended fix**: Handle surrogate pairs by checking `Character.isHighSurrogate(c)` or iterating by code points:
  ```kotlin
  if (c.isHighSurrogate() && i + 1 < value.length && value[i + 1].isLowSurrogate()) {
      val codePoint = Character.toCodePoint(c, value[i + 1])
      out.write(String(Character.toChars(codePoint)).toByteArray(Charsets.UTF_8))
      i += 2
      continue
  }
  ```
- **Guards considered**: The percent-decoding branch (`%XX`) works at the byte level, but unencoded supplementary characters in the URI string pass into the `else` branch where character-by-character conversion breaks surrogate pairs.

---

### F-engine-08: Coroutine Dispatch Thread Crash on Looper MessageQueue Capacity Limit
- **Severity**: Medium
- **Confidence**: high
- **Type**: crash
- **Location**: `engine/src/main/kotlin/android/os/Looper.kt:76`, `engine/src/main/kotlin/com/lagradost/macos/LooperMainDispatcher.kt:35-38`
- **Trigger**: High volume of concurrent Handler messages or coroutine dispatches to `Dispatchers.Main` reaches `MAX_PENDING` (10,000) on the Android Looper message queue.
- **Trace**:
  1. In `android/os/Looper.kt:74-82`:
     ```kotlin
     internal fun enqueue(message: Message, at: Long): Boolean = synchronized(lock) {
         if (quitting) return false
         check(messages.size < MAX_PENDING) { "Too many pending Handler messages" }
         ...
         true
     }
     ```
  2. In `LooperMainDispatcher.dispatch`:
     ```kotlin
     override fun dispatch(context: CoroutineContext, block: Runnable) {
         // A looper that has quit refuses work; the coroutine must still complete somewhere.
         if (!handler.post(block)) Dispatchers.IO.dispatch(context, block)
     }
     ```
  3. `LooperMainDispatcher` expects `handler.post(block)` to return `false` if the message queue refuses work, so it can safely fall back to `Dispatchers.IO.dispatch`.
  4. However, when `messages.size >= MAX_PENDING`, `enqueue` executes `check(...)`, which throws an unhandled `IllegalStateException("Too many pending Handler messages")`.
  5. The exception escapes `handler.post(block)` and bubbles out of `dispatch()`, crashing the calling coroutine dispatcher thread or invoking the uncaught exception handler, rather than gracefully falling back to `Dispatchers.IO`.
- **Impact**: Daemon worker thread crash and uncaught coroutine failure during traffic bursts or message storms.
- **Evidence**:
  ```kotlin
  // engine/src/main/kotlin/android/os/Looper.kt:76
  check(messages.size < MAX_PENDING) { "Too many pending Handler messages" }
  ```
- **Recommended fix**: Return `false` instead of throwing `IllegalStateException`:
  ```kotlin
  internal fun enqueue(message: Message, at: Long): Boolean = synchronized(lock) {
      if (quitting || messages.size >= MAX_PENDING) return false
      message.`when` = at
      message.sequence = sequence.incrementAndGet()
      messages.add(message)
      lock.notifyAll()
      true
  }
  ```
- **Guards considered**: On real Android, `Handler.sendMessageAtTime` returns `false` on failure and never throws `IllegalStateException`. `LooperMainDispatcher` already has the fallback logic `if (!handler.post(block)) Dispatchers.IO.dispatch(context, block)`, but it is defeated by the throwing `check(...)`.

---

### F-engine-09: `TextUtils.split` Drops Trailing Delimiters Contrary to Android Contract and Class Specification
- **Severity**: Medium
- **Confidence**: high
- **Type**: logic
- **Location**: `engine/src/main/kotlin/android/text/TextUtils.kt:11-14`
- **Trigger**: An extension parses delimited data (e.g., CSV, metadata tokens) where trailing fields may be empty (e.g., `TextUtils.split("title,year,", ",")`).
- **Trace**:
  1. The KDoc for `TextUtils.kt:10` explicitly states:
     `/** Android splits on a regular expression and, unlike String.split, keeps trailing empty strings. */`
  2. In `android.text.TextUtils.java` on Android, `split` is implemented as `text.split(expression, -1)`, which preserves all trailing empty tokens.
  3. However, in `engine/src/main/kotlin/android/text/TextUtils.kt:11-12`:
     ```kotlin
     @JvmStatic fun split(text: String, expression: String): Array<String> =
         if (text.isEmpty()) emptyArray() else text.split(Regex(expression)).toTypedArray()
     ```
  4. In Kotlin, `CharSequence.split(Regex)` calls `Regex.split(input, limit = 0)`.
  5. A limit of 0 drops trailing empty strings.
  6. For `"a,b,"`, `TextUtils.split` returns `["a", "b"]` instead of `["a", "b", ""]`.
  7. Scrapers relying on fixed array indexing (e.g., expecting 3 columns) fail with `IndexOutOfBoundsException`.
- **Impact**: Off-by-one and `IndexOutOfBoundsException` crashes in scrapers parsing structured text with empty trailing fields.
- **Evidence**:
  ```kotlin
  // engine/src/main/kotlin/android/text/TextUtils.kt:10-12
  /** Android splits on a regular expression and, unlike String.split, keeps trailing empty strings. */
  @JvmStatic fun split(text: String, expression: String): Array<String> =
      if (text.isEmpty()) emptyArray() else text.split(Regex(expression)).toTypedArray()
  ```
- **Recommended fix**: Pass `limit = -1` or use `Pattern.compile(expression).split(text, -1)`:
  ```kotlin
  @JvmStatic fun split(text: String, expression: String): Array<String> =
      if (text.isEmpty()) emptyArray() else java.util.regex.Pattern.compile(expression).split(text, -1)
  ```
- **Guards considered**: None; the implementation directly contradicts its own docstring and Android's documented behavior.

---

### F-engine-10: Query String Parameter Corruption on URLs Ending With Trailing Question Mark During LL-HLS Reload
- **Severity**: Medium
- **Confidence**: high
- **Type**: logic
- **Location**: `engine/src/main/kotlin/com/lagradost/macos/MediaRelay.kt:539-551`
- **Trigger**: An upstream HLS playlist URL ends with a trailing question mark without query parameters (e.g., `https://origin.cdn/live.m3u8?`), and the player requests an LL-HLS playlist reload with delta updates (`_HLS_msn=...`).
- **Trace**:
  1. `MediaRelay.reloadURL(url, query)` is called to append validated LL-HLS control fields to the upstream root URL.
  2. At line 546: `val uri = URI(url)`.
  3. When `url` is `https://origin.cdn/live.m3u8?`, `java.net.URI` sets `uri.rawQuery` to `""` (empty string, not `null`).
  4. At lines 549-550:
     ```kotlin
     val prefix = url.substringBefore('#')
     return prefix + (if (uri.rawQuery == null) "?" else "&") + query
     ```
  5. Because `uri.rawQuery` is `""`, `uri.rawQuery == null` is `false`. The ternary operator selects `"&"`.
  6. The returned string is `https://origin.cdn/live.m3u8?&_HLS_msn=100`.
  7. Upstream CDN origins and proxy servers reject URLs with leading empty parameters (`?&`) or fail to extract `_HLS_msn`, causing reload requests to fail with 400 Bad Request.
- **Impact**: LL-HLS live stream playback stalls and fails when upstream stream manifests contain trailing question marks.
- **Evidence**:
  ```kotlin
  // engine/src/main/kotlin/com/lagradost/macos/MediaRelay.kt:549-550
  val prefix = url.substringBefore('#')
  return prefix + (if (uri.rawQuery == null) "?" else "&") + query
  ```
- **Recommended fix**: Check `isNullOrEmpty()` rather than just `== null`:
  ```kotlin
  val hasQuery = !uri.rawQuery.isNullOrEmpty()
  val separator = if (hasQuery) "&" else if (prefix.endsWith('?')) "" else "?"
  return prefix + separator + query
  ```
- **Guards considered**: Line 547 checks `uri.rawQuery.orEmpty()`, indicating awareness that `rawQuery` can be empty or null, but line 550 only checks `== null`.

---

## Reviewed / non-issues

1. **`LoopbackHost.kt` DNS Rebinding & Host Validation**:
   - *Considered*: Whether an attacker could execute DNS rebinding against the local Netty server using IPv6 loopback variants or non-standard headers.
   - *Cleared*: `LoopbackHost.isLoopback(host)` strictly tests against `localhost`, `127.0.0.1`, `[::1]`, and strict numeric IPv4/IPv6 loopback regexes. In addition, `Main.kt` verifies the `Authorization: Bearer <token>` header on every non-public endpoint, preventing browser-initiated cross-origin requests from succeeding even if DNS rebinding were attempted.

2. **`MediaRelay.kt` Range Request Forwarding vs Manifest Rewriting**:
   - *Considered*: Whether partial byte-range requests on HLS playlists could bypass `ManifestRewriter` or corrupt transformed manifests.
   - *Cleared*: Lines 118-135 explicitly check `isRange` (`call.request.headers.contains(HttpHeaders.Range)`). When range is requested, `MediaRelay` bypasses manifest rewriting and streams raw upstream bytes via `StreamingConnection.pumpDirectly()`. Manifest rewriting is only applied to full manifest GET requests.

3. **`ResponseTracker.kt` Spilled Body File Deletion**:
   - *Considered*: Whether large responses spilled to disk via `SpillableBody` could leak temporary files on aborted streams or exceptions.
   - *Cleared*: `SpillableBody.close()` deletes the temporary file unconditionally, and `ResponseTracker.cleanUp()` iterates all active trackers and purges lingering files on engine shutdown.

4. **`WorkerPool.kt` Solver and Media Slot Over-Admission**:
   - *Considered*: Whether concurrent challenges or media requests could bypass capacity limits and cause worker starvation.
   - *Cleared*: `WorkerPool.admit()` and `WorkerClient.answerSolve()` atomically check `solvesInFlight.incrementAndGet() > MAX_SOLVES` and immediately decrement and reject with `Op.ERROR` if capacity is exceeded.

5. **`FullFsync.java` Darwin Native Linker Safety**:
   - *Considered*: Whether JVM foreign function linkage to `fcntl(F_FULLFSYNC)` could crash on non-macOS or unsupported architectures.
   - *Cleared*: `FullFsync` contains a multi-tiered fallback: it checks `OperatingSystem.isMac()` and `Linker.nativeLinker()`, catching `Throwable` on lookup and falling back to standard Java NIO `FileChannel.force(true)`.

6. **`AtomicFiles.kt` Atomic Move and Fsync**:
   - *Considered*: Whether `AtomicFiles.write` could leave corrupt JSON state files during an abrupt power loss.
   - *Cleared*: Writes stage to `.tmp` files, invoke `FullFsync.fsync(channel)` on the staging file descriptor, atomically replace via `StandardCopyOption.ATOMIC_MOVE`, and execute `FullFsync.fsync(directoryChannel)` on the parent directory to commit the directory entry to disk.

---

## Areas not covered

- **QuickJS / Duktape Native Memory Footprint**: Low-level heap fragmentation or native memory leaks within the C JavaScript execution engine embedded inside the worker subprocess. These run in isolated worker processes managed by `WorkerLauncher`, so daemon stability is protected, but individual worker memory exhaustion was not profiled with native Instruments.
- **External CDN Anti-Bot Evolution**: Upstream video host Cloudflare Turnstile / Akamai Bot Manager protocol updates requiring client browser DOM interaction beyond headless mock capabilities.
- **Hardware-Specific Video Decoding**: Performance and memory interactions between the engine's `MediaRelay` proxy and macOS VideoToolbox/Metal texture pipelines (evaluated separately in player audit `01-player-media.md`).


---

## Pass 2 & Fact-Checking Results

### Pass 1 Fact-Checking Verdicts

Every finding from Pass 1 was subjected to rigorous code re-inspection, line-number verification, and execution-path tracing against tests and runtime guards:

| Finding ID | Verdict | Verified Location | Summary of Fact-Check Evidence |
| :--- | :---: | :--- | :--- |
| **F-engine-01** | **[CONFIRMED]** | `WorkerEgressProxy.kt:92-109` | Confirmed. `slots.acquire()` is held at line 74 until `serve()` returns. Line 108 executes `runCatching { back.get() }`. If the upstream server half-closes or stays idle, `back` blocks for the full 10-minute `idleTimeoutMs`, holding a concurrency permit and blocking 2 pool threads. |
| **F-engine-02** | **[CONFIRMED]** | `WorkerClient.kt:198-228, 372-375` | Confirmed. `readLoop()` terminates without closing `input` or `process.inputStream`. `handleExit()` invokes `output.close()` on `process.outputStream` but never closes `process.inputStream` or `process.errorStream`, leaking UNIX pipe file descriptors on the parent daemon process across worker recycles. |
| **F-engine-03** | **[CONFIRMED]** | `Context.kt:69-70` | Confirmed. `Context.getResources()` and `getAssets()` unconditionally return `null`. CloudStream extensions universally expect Android `@NonNull` resources; any invocation of `context.resources.getString(...)` immediately triggers an unhandled `NullPointerException`. |
| **F-engine-04** | **[CONFIRMED]** | `ContextWrapper.kt:9-11` | Confirmed. `ContextWrapper` extends `Context()` without overriding storage methods (`getFilesDir()`, `getSharedPreferences()`, etc.). All storage requests fall through to `Context` default (`_host`), bypassing the extension's isolated directory and colliding across extensions. |
| **F-engine-05** | **[CONFIRMED]** | `Uri.kt:27-28` | Confirmed. `Uri.Impl.from` checks `if (rest.contains("://"))`. Non-hierarchical or opaque URIs (`data:`, `mailto:`, `javascript:`) lack `://`, resulting in `scheme = null`, `isAbsolute() = false`, and misclassifying the payload as a relative path. |
| **F-engine-06** | **[CONFIRMED]** | `Uri.kt:57-63` | Confirmed. `getScheme()`, `getHost()`, `getPath()`, and `getAuthority()` return non-null `String` (`impl.host ?: ""`) rather than nullable `String?` as in Android SDK, defeating `if (uri.host != null)` checks on relative URIs. |
| **F-engine-07** | **[CONFIRMED]** | `Uri.kt:148` | Confirmed. `decodeComponent` iterates by 16-bit `Char`. In the non-percent branch, `c.toString().toByteArray(Charsets.UTF_8)` converts high and low surrogate characters independently, converting each into `0xEF 0xBF 0xBD` and irreversibly corrupting emojis and supplementary characters into `\uFFFD\uFFFD`. |
| **F-engine-08** | **[CONFIRMED]** | `Looper.kt:76`, `LooperMainDispatcher.kt:35-38` | Confirmed. `enqueue()` executes `check(messages.size < MAX_PENDING)` which throws `IllegalStateException`. `LooperMainDispatcher.dispatch` only catches boolean `false` from `handler.post`, allowing the exception to escape and crash the coroutine dispatch thread. |
| **F-engine-09** | **[CONFIRMED]** | `TextUtils.kt:11-14` | Confirmed. `text.split(Regex(expression))` uses Kotlin's `limit = 0` default, stripping trailing empty strings contrary to Android's `text.split(expression, -1)` contract and the method's own docstring. |
| **F-engine-10** | **[CONFIRMED]** | `MediaRelay.kt:539-551` | Confirmed. `URI("https://host/stream.m3u8?").rawQuery` evaluates to `""` (empty string, not `null`). Line 550 checks `if (uri.rawQuery == null) "?" else "&"`, evaluating to `"&"` and yielding `https://host/stream.m3u8?&_HLS_msn=...`, which upstream CDNs reject with HTTP 400. |

---

### Newly Uncovered Pass 2 Findings

### F-engine-11: `ManifestRewriter` Rejects HLS Playlists with Unencoded Brackets or Special Characters with HTTP 415
- **Severity**: Medium
- **Confidence**: high
- **Type**: logic
- **Location**: `engine/src/main/kotlin/com/lagradost/macos/ManifestRewriter.kt:53-57`, `engine/src/main/kotlin/com/lagradost/macos/MediaRelay.kt:593-599`
- **Trigger**: An upstream HLS playlist contains segment references or `#EXT-X-...:URI="..."` attributes containing square brackets (e.g. `segment[0].ts`, commonly used by CDNs for resolution or chunk indexing), braces, or unencoded characters.
- **Trace**:
  1. `MediaRelay.serveOwned` calls `ManifestRewriter.rewrite(kind, text, manifestUrl, map)`.
  2. For HLS manifests, lines 61-68 iterate over each line and invoke `absolute(base, reference)` on segment URLs and `#EXT-X-KEY` / `#EXT-X-MEDIA` URI attributes.
  3. In `absolute(base: URI, reference: String)`:
     ```kotlin
     val resolved = runCatching { base.resolve(reference.trim()) }.getOrNull() ?: throw Unsupported("reference")
     ```
  4. Java `java.net.URI.resolve(String)` delegates to `URI.create(String)` which parses `reference` using RFC 2396 grammar.
  5. In RFC 2396, characters like `[` and `]` are reserved for IPv6 host literals and are strictly illegal in URI path segments.
  6. When resolving `"segment[0].ts"`, `base.resolve` throws `IllegalArgumentException: Illegal character in path at index 7: segment[0].ts` (caused by `URISyntaxException`).
  7. `runCatching` catches the exception and returns `null`.
  8. `absolute()` immediately throws `ManifestRewriter.Unsupported("reference")`.
  9. In `MediaRelay.kt:593-599`:
     ```kotlin
     } catch (failure: Exception) {
         if (failure !is ManifestRewriter.Unsupported ...) throw failure
         DaemonLog.warn("relay.manifest_refused", mapOf("kind" to kind.name, "reason" to (failure.message ?: failure.javaClass.simpleName)))
         null
     }
     if (rewritten == null) { call.respond(HttpStatusCode.UnsupportedMediaType, ""); return }
     ```
  10. `MediaRelay` responds with `HttpStatusCode.UnsupportedMediaType` (HTTP 415) to mpv/player, failing playback entirely.
- **Impact**: HLS streams with bracketed segment naming conventions (widely used in anime/drama provider CDNs) unconditionally fail playback with HTTP 415.
- **Evidence**:
  Verified via JShell: `new java.net.URI("https://example.com/playlist.m3u8").resolve("segment[0].ts")` unconditionally throws `java.lang.IllegalArgumentException: Illegal character in path at index 7: segment[0].ts`.
- **Recommended fix**: Pre-encode or sanitize illegal characters in `reference` before resolving against `base`:
  ```kotlin
  private fun sanitizeReference(reference: String): String =
      reference.trim().replace("[", "%5B").replace("]", "%5D")
  ```
- **Guards considered**: The existing tests in `MediaRelayTest.kt` only test synthetic manifest lines (`directory$sequence/segment.ts`) and never exercise brackets or special characters in segment URLs.

---

### F-engine-12: `MediaRelay.under` Throws `URISyntaxException` on Unencoded Path Characters Returning 404
- **Severity**: Medium
- **Confidence**: high
- **Type**: logic
- **Location**: `engine/src/main/kotlin/com/lagradost/macos/MediaRelay.kt:294-307`, `engine/src/main/kotlin/com/lagradost/macos/MediaRelay.kt:430-432`
- **Trigger**: A player requests a media segment under a registered directory resource where the relative path contains unencoded square brackets (e.g., `GET /media/relay/<id>/chunk[0].ts`).
- **Trace**:
  1. `MediaRoutes.kt:388` handles `GET /media/relay/{id}/{rest...}` and invokes `MediaRelay.serve(..., rest = relayRest(call))`.
  2. In `serveOwned`:
     ```kotlin
     rest != null && registered.directory -> under(registered.url, rest)?.let { Resource(it, registered.headers) }
     ```
  3. In `under(base: String, rest: String)`:
     ```kotlin
     val target = runCatching { URI(base + rest).normalize() }.getOrNull() ?: return null
     ```
  4. When `base = "https://cdn.example.com/stream/"` and `rest = "chunk[0].ts"`, `URI(base + rest)` parses `"https://cdn.example.com/stream/chunk[0].ts"`.
  5. As verified in F-engine-11, `java.net.URI` throws `URISyntaxException: Illegal character in path at index 36: https://cdn.example.com/stream/chunk[0].ts`.
  6. `runCatching` catches `URISyntaxException` and returns `null`.
  7. `under()` returns `null`, causing `serveOwned` line 432 to execute:
     ```kotlin
     ?: run { call.respond(HttpStatusCode.NotFound, ""); return }
     ```
  8. The relay answers HTTP 404 Not Found, causing the video player to abort segment buffering and fail playback.
- **Impact**: Video playback fails mid-stream or during segment download with 404 Not Found for streams using unencoded bracketed filenames.
- **Evidence**:
  ```kotlin
  // engine/src/main/kotlin/com/lagradost/macos/MediaRelay.kt:304
  val target = runCatching { URI(base + rest).normalize() }.getOrNull() ?: return null
  ```
- **Recommended fix**: Percent-encode or escape illegal characters in `rest` prior to URI normalization, or perform path containment verification using path segment components rather than strict `java.net.URI` construction.
- **Guards considered**: Lines 300-303 decode percent-encoded dot segments, but line 304 uses raw `URI(base + rest)` which cannot parse unencoded square brackets.

---

### F-engine-13: Global Singleton Version StateFlow In `PendingSignal` Triggers Cross-Bridge Wakeup Storms
- **Severity**: Medium
- **Confidence**: high
- **Type**: perf
- **Location**: `engine/src/main/kotlin/com/lagradost/macos/PendingSignal.kt:17-36`, `engine/src/main/kotlin/com/lagradost/macos/MediaRoutes.kt:411-468`
- **Trigger**: Concurrent long-polling requests across independent IPC endpoints: `/solve/pending`, `/media/pending`, and `/webview/pending`.
- **Trace**:
  1. `PendingSignal` is implemented as an `internal object` singleton with a single version signal: `private val version = MutableStateFlow(0L)`.
  2. When any subsystem parks a task (`SolveBridge.parked()`, `MediaResolveBridge.parked()`, or `WebViewSessionBridge.parked()`), it invokes `PendingSignal.parked()`, incrementing `version.value++`.
  3. When an extension requests a Cloudflare solve, `SolveBridge.parked()` increments `version`.
  4. Coroutines suspended in `PendingSignal.awaitNonEmpty` waiting on `/media/pending` and `/webview/pending` wake up simultaneously because their collector `version.first { it != seen }` triggers.
  5. Both endpoints evaluate `items = list()` for their respective domains, find zero pending items, and either loop or exit with empty JSON arrays `[]`.
  6. In addition, when tasks are dropped on the client side (such as `MediaResolverService.swift` rejecting a navigation policy), the dropped task lingers in `MediaResolveBridge.tasks` for its full 60-second timeout.
  7. During this time, `PendingSignal.awaitNonEmpty` returns immediately because `items.isNotEmpty()` is true on line 33, which in turn drives the client's polling loop into a rapid, unthrottled spin loop until the task expires.
- **Impact**: Premature task wakeups across unrelated IPC subsystems, unnecessary CPU context switches, and excessive HTTP polling roundtrips between the macOS client and the engine daemon.
- **Evidence**:
  ```kotlin
  // engine/src/main/kotlin/com/lagradost/macos/PendingSignal.kt:17-20
  private val version = MutableStateFlow(0L)
  fun parked() { version.value++ }
  ```
- **Recommended fix**: Split `PendingSignal` into separate channels or scoped `StateFlow` signals per endpoint domain (`solveVersion`, `mediaVersion`, `webViewVersion`), preventing cross-subsystem wakeup storms.
- **Guards considered**: None; all three bridge endpoints currently route through the singular `PendingSignal` singleton.
