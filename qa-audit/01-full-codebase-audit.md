# Adversarial QA Audit: Full Codebase Audit

**Scope:**
Full-codebase adversarial audit across the native Swift 6 client (`client/Sources/`), headless Kotlin/JVM engine (`engine/src/main/kotlin/`), and shared models and IPC contracts (`docs/ipc-api.md`, `client/Sources/Models/IPC/`). Traced execution paths end-to-end for process lifecycle, shutdown sequences, inter-process communication, connection handshakes, media resolution, streaming playback failover, download concurrency, background store import, and keychain security. Verified all findings against documented invariants, ADRs, existing test suites, and regression guards.

---

### F-SYSTEM-01: Critical Hang & Deadlock on Termination Failure in DaemonSupervisor & ApplicationShutdown
- **Severity**: Critical
- **Confidence**: high
- **Type**: hang / deadlock
- **Location**: `client/Sources/App/DaemonSupervisor.swift:233-247`, `client/Sources/App/ApplicationShutdown.swift:33-47`, `client/Sources/App/CloudStreamMacApp.swift:99-103`, `client/Sources/Services/System/Uninstaller.swift:316-318`
- **Trigger**: Any child process (engine JVM, worker process, ffmpeg) fails to terminate cleanly within `grace` + `forceWait` (3.5 seconds) upon shutdown (e.g., stuck on uninterruptible I/O, hung daemon thread, or unresponsive worker).
- **Trace**:
  1. The app begins shutdown via `ApplicationShutdown.shared.begin` from `applicationShouldTerminate:` or `Uninstaller.perform()`.
  2. `ApplicationShutdown` calls `DaemonSupervisor.shared.stop(completion:)`, which registers a closure in `self.stopCompletions` and calls `requestTransition()`.
  3. `driveTransitions()` runs and calls `waitForProcessTermination(processes: targets, grace: 2.5, forceWait: 1.0)`.
  4. If any child process does not exit, `stopped` evaluates to `false`.
  5. Lines 242-246 check `if stopped { self.stopCompletions.forEach { $0() }; self.stopCompletions.removeAll() }`. Because `stopped == false`, `stopCompletions` is never executed.
  6. As a result, `ApplicationShutdown.finish()` is never called, and `state` remains `.stopping` forever.
  7. In `CloudStreamMacApp.swift:100`, `sender.reply(toApplicationShouldTerminate: true)` is never called, leaving the app indefinitely stuck in Cocoa's `.terminateLater` state (macOS "Application Not Responding").
  8. In `Uninstaller.swift:317`, `await withCheckedContinuation { continuation.resume() }` deadlocks permanently, aborting uninstallation before any files or keychain items are removed.
- **Impact**: App hangs permanently during quit or shutdown, requiring `kill -9`; uninstaller deadlocks and cannot finish removing app data.
- **Evidence**:
  ```swift
  // client/Sources/App/DaemonSupervisor.swift:233-246
  let stopped = waitForProcessTermination(processes: targets, grace: 2.5, forceWait: 1.0)
  if stopped {
      self.stopCompletions.forEach { $0() }
      self.stopCompletions.removeAll()
  }
  ```
- **Recommended fix**: Always invoke and clear `stopCompletions` even if `stopped == false`, logging an error that process termination timed out after force kill:
  ```swift
  let stopped = waitForProcessTermination(processes: targets, grace: 2.5, forceWait: 1.0)
  if !stopped {
      DaemonLog.client("supervisor.force_kill_timeout")
  }
  let completions = self.stopCompletions
  self.stopCompletions.removeAll()
  completions.forEach { $0() }
  ```
- **Guards considered**: Looked at `forceWait: 1.0` and `process.terminate()` / `kill(pid, SIGKILL)` in `waitForProcessTermination`. While `SIGKILL` is issued, processes stuck in kernel uninterruptible sleep (D-state) or zombie states will not return exit status within 1.0s, triggering this condition.

---

### F-ASYNC-02: Infinite 100% CPU Long-Polling HTTP Spin Loop on Dropped Media Tasks
- **Severity**: Critical
- **Confidence**: high
- **Type**: perf / hang
- **Location**: `client/Sources/ViewModels/AppState.swift:498-503`, `client/Sources/Services/MediaResolverService.swift:32-38`, `engine/src/main/kotlin/com/lagradost/macos/PendingSignal.kt:27-36`
- **Trigger**: The engine queues a media resolve task that fails `MediaResolverService.start`'s entry guard (e.g. `sessions.count >= 2`, unnavigable URL, rejected by `WebContentNetworkPolicy.allowsNavigation`, or `timeoutMs <= 0`).
- **Trace**:
  1. Engine receives a media resolve request and parks it in `MediaResolveBridge`, incrementing `PendingSignal.version`.
  2. `AppState.startMediaPolling()` fetches pending tasks via `DaemonClient.shared.pendingMedia(waitMs: 25000)`.
  3. `fresh` is computed as `pending.filter { !active.contains($0.taskId) }`.
  4. For each task in `fresh`, `MediaResolverService.shared.start(task)` is called.
  5. If `start`'s guard fails (e.g. `sessions.count >= 2` because two sessions are already active, or `WebContentNetworkPolicy` blocks the host), `start` returns immediately without adding the task to `sessions` and without reporting completion to the daemon.
  6. In `AppState`, line 502 checks `if !pending.isEmpty && fresh.isEmpty { try? await Task.sleep(...) }`. Because `fresh` was non-empty, line 502 does NOT sleep!
  7. On the next loop iteration, `pendingMedia(waitMs: 25000)` is called again.
  8. In the engine, `PendingSignal.awaitNonEmpty` evaluates `items.isNotEmpty()`. Because the unhandled task is still parked, it returns immediately without waiting.
  9. In `AppState`, `activeTaskIds` still does not contain the task. `fresh` is still non-empty!
  10. The loop repeats continuously without delay, generating thousands of HTTP requests per second and pegging `@MainActor` at 100% CPU.
- **Impact**: Main thread starvation, severe macOS UI freeze, battery drain, and thermal throttling until the task reaches engine timeout (up to 120 seconds).
- **Evidence**:
  ```swift
  // client/Sources/ViewModels/AppState.swift:498-503
  let active = MediaResolverService.shared.activeTaskIds
  let fresh = pending.filter { !active.contains($0.taskId) }
  for task in fresh { MediaResolverService.shared.start(task) }
  // A provider call is waiting on these: re-check soon, without spinning.
  if !pending.isEmpty && fresh.isEmpty { try? await Task.sleep(for: .milliseconds(500)) }
  ```
- **Recommended fix**:
  1. In `MediaResolverService.swift`, if a task cannot be started due to network policy or invalid input, immediately report it completed with empty results to remove it from `MediaResolveBridge`.
  2. In `AppState.swift`, enforce a sleep whenever no new tasks were successfully admitted into `sessions`, or queue excess tasks rather than discarding them.

---

### F-PERSIST-03: Permanent Background Store Lockout & Profile Switch Brick on Task Cancellation
- **Severity**: High
- **Confidence**: high
- **Type**: logic / state inconsistency
- **Location**: `client/Sources/Services/LibraryStore.swift:2313-2332`
- **Trigger**: A background restore or import (`importSnapshotInBackground`) is initiated and its calling `Task` is cancelled before completion (e.g., user navigates away, closes the import sheet, or the window session terminates).
- **Trace**:
  1. `importSnapshotInBackground` sets `isImporting = true` on line 2315.
  2. Line 2322 launches `Task.detached` and awaits `.value`.
  3. When the enclosing task is cancelled, `await Task.detached { ... }.value` propagates `CancellationError`.
  4. Execution aborts immediately to the caller, bypassing line 2325 (`isImporting = false`).
  5. `isImporting` remains `true` permanently on the `LibraryStore` singleton.
  6. Subsequent attempts to switch profiles (`activateProfileStore`) fail with `ImportError.restoreInProgress`.
  7. All library writes via `withMutation` fail with `ImportError.restoreInProgress`.
  8. Line 780 (`if isImporting { return }`) silences playback progress flushes, preventing progress from saving to disk.
- **Impact**: The application library is permanently locked into a read-only state. Profile switching, library updates, and progress saving are completely broken until the app is restarted.
- **Evidence**:
  ```swift
  // client/Sources/Services/LibraryStore.swift:2313-2326
  func importSnapshotInBackground(_ snapshot: LibrarySnapshot, mode: ImportMode) async throws -> ImportReport {
      let container = try prepareImport(snapshot)
      isImporting = true
      ...
      let outcome = await Task.detached(priority: .userInitiated) {
          Result { try Self.applySnapshot(snapshot, mode: mode, container: container, fault: fault.call) }
      }.value
      isImporting = false
      if case .success = outcome { finishImport(container) }
  ```
- **Recommended fix**: Wrap `isImporting = false` in a `defer` statement inside `importSnapshotInBackground`:
  ```swift
  isImporting = true
  defer { isImporting = false }
  let outcome = await Task.detached(priority: .userInitiated) { ... }.value
  ```
- **Guards considered**: Checked `applySnapshot` error handling. While `applySnapshot` catches errors within `Result { ... }`, cancellation of the *outer* task awaiting `.value` throws across the assignment, skipping line 2325.

---

### F-UPDATE-04: Signal Exit Bypasses Staged Update & Unsynchronized Bundle Swap in applicationWillTerminate
- **Severity**: High
- **Confidence**: high
- **Type**: logic / race
- **Location**: `client/Sources/App/CloudStreamMacApp.swift:55-57, 65-67, 148-156`, `client/Sources/Services/Updates/SoftwareUpdater.swift:230-244`
- **Trigger**: The user or system terminates the app via `SIGTERM`/`SIGINT`, or system shutdown/logout fires `applicationWillTerminate:` directly.
- **Trace**:
  1. Under `SIGTERM`/`SIGINT`, `termSource` executes `ApplicationShutdown.shared.begin { exit(0) }`.
  2. Calling `exit(0)` terminates the process immediately without running Cocoa's run loop exit, completely bypassing `applicationWillTerminate:`. As a result, `SoftwareUpdater.shared.installAtTermination()` is never invoked, discarding staged updates.
  3. Conversely, during system-initiated shutdown/logout, Cocoa calls `applicationWillTerminate:`.
  4. Line 151 calls `ApplicationShutdown.shared.begin()` (which is asynchronous and returns immediately), and line 154 immediately calls `SoftwareUpdater.shared.installAtTermination()`.
  5. `installAtTermination()` invokes `environment.swap(staged.app, environment.installedApp)` (`renamex_np`) while child subprocesses (JVM daemon, ffmpeg, libmpv) are still actively executing from inside the application bundle.
- **Impact**: Staged updates fail to install when the app is quit via standard Unix signals; during system shutdown, bundle replacement races against running subprocesses, risking update installation failure or corrupted app bundles.
- **Evidence**:
  ```swift
  // client/Sources/App/CloudStreamMacApp.swift:54-57
  termSource.setEventHandler {
      MainActor.assumeIsolated {
          ApplicationShutdown.shared.begin { exit(0) }
      }
  }
  ...
  // client/Sources/App/CloudStreamMacApp.swift:148-155
  func applicationWillTerminate(_ notification: Notification) {
      MainActor.assumeIsolated {
          guard !AppEnvironment.isUnitTestHost else { return }
          ApplicationShutdown.shared.begin()
          SoftwareUpdater.shared.installAtTermination()
      }
  }
  ```
- **Recommended fix**: Move `SoftwareUpdater.shared.installAtTermination()` into the completion callback of `ApplicationShutdown.shared.begin(...)`, and ensure the signal handler invokes `installAtTermination()` before calling `exit(0)`.

---

### F-STATE-05: Transient Desynchronized Connection Snapshot Published During Daemon Transition
- **Severity**: Medium
- **Confidence**: high
- **Type**: race / state inconsistency
- **Location**: `client/Sources/App/DaemonSupervisor.swift:203-211`, `client/Sources/ViewModels/AppState.swift:187-205`, `client/Sources/App/EngineConnection.swift:42-52`
- **Trigger**: `restart()` or `requestTransition()` is invoked on `DaemonSupervisor` when the daemon is in `.ready` state.
- **Trace**:
  1. `requestTransition()` runs on `DaemonSupervisor`.
  2. Line 209 sets `endpoint = nil`. Because `endpoint` has a `didSet` observer, it immediately calls `publishConnectionSnapshot()`.
  3. At this moment, `self.state` has not yet been updated and remains `.ready(port: X)`.
  4. The published snapshot has `state: .ready(port: X)` and `endpoint: nil`.
  5. In `AppState.swift:190`, `if case .ready = snapshot.state, let endpoint = snapshot.endpoint` fails because `snapshot.endpoint` is `nil`.
  6. The `else` branch executes, calling `connection.invalidate(snapshot.state)`, passing `.ready` as the invalidation reason.
  7. In `EngineConnection.invalidate(_:)`, `case .ready` sets `phase = .verifying` with `endpoint = nil` and increments `generation &+= 1`.
  8. Immediately afterward, line 210 in `DaemonSupervisor` sets `state = wantsEngine ? .restarting : .initializing`, triggering another snapshot that calls `invalidate(.restarting)`, incrementing `generation &+= 1` a second time and setting `phase = .recovering`.
- **Impact**: Engine connection phase spuriously flashes through `.verifying` with a `nil` endpoint and increments the connection generation counter twice, risking discarded valid requests and desynchronized handshake states.
- **Evidence**:
  ```swift
  // client/Sources/App/DaemonSupervisor.swift:209-211
  endpoint = nil
  state = wantsEngine ? .restarting : .initializing
  transportReset = Task { await DaemonClient.shared.clearEndpoint() }
  ```
- **Recommended fix**: Update both `state` and `endpoint` in a single batch, or update `state` before `endpoint = nil` so intermediate snapshots never report `.ready` without an endpoint.

---

### F-DOWNLOAD-06: DirectFileJob Stale Metric Retention & False Completion on Fresh Retry
- **Severity**: Medium
- **Confidence**: high
- **Type**: corruption / logic
- **Location**: `client/Sources/Services/Downloads/DirectFileJob.swift:156-160, 397-402, 441-468`
- **Trigger**: A resumed direct file download encounters HTTP 416 (Range Not Satisfiable) or an invalid Content-Range, triggering `retryFresh = true` and `start(allowResume: false)`.
- **Trace**:
  1. When range resumption fails, `requestFreshResponse()` cancels the task and sets `retryFresh = true`.
  2. In `urlSession(_:task:didCompleteWithError:)`, line 399 calls `removePartial()` and line 400 calls `start(allowResume: false)`.
  3. `removePartial()` unlinks the partial file from disk.
  4. In `start(allowResume: false)`, line 158 sets `resumeOffset = 0` and `metadata = nil`, but does NOT reset `written` or `total`.
  5. If the retried connection encounters an error (network drop, timeout, or cancellation) before `restartFromZero` is called, `didCompleteWithError` reads `let bytes = written` and `let expected = total` from the previous aborted attempt.
  6. If the server closed the connection without body bytes and without an HTTP error, line 424 evaluates `bytes != expected`. If `written == total` from the first attempt, it reaches line 436 and reports `finish(.completed)` even though the file on disk was deleted!
- **Impact**: Erroneous progress reporting and potential false `.completed` download records where the destination file on disk does not exist.
- **Evidence**:
  ```swift
  // client/Sources/Services/Downloads/DirectFileJob.swift:156-160
  } else {
      removePartial()
      resumeOffset = 0
      metadata = nil
  }
  ```
- **Recommended fix**: Inside `start(allowResume:)`, acquire `lock` and reset `written = 0` and `total = nil`:
  ```swift
  lock.lock()
  written = 0
  total = nil
  resumeOffset = 0
  metadata = nil
  lock.unlock()
  ```
- **Guards considered**: Checked `restartFromZero`. It resets `written = 0` only *after* receiving a valid HTTP 200/206 response header, leaving a window between `start()` and `didReceive response:` where stale metrics persist.

---

### F-CONCURRENCY-07: Unsynchronized Cross-Thread Access to resumeOffset in DirectFileJob
- **Severity**: Medium
- **Confidence**: high
- **Type**: race
- **Location**: `client/Sources/Services/Downloads/DirectFileJob.swift:60, 143, 258, 293, 303`
- **Trigger**: Concurrent download execution where `start()` runs on a worker thread and `URLSession` delegate callbacks execute on the operation queue.
- **Trace**:
  1. `resumeOffset` is declared as a plain instance variable (`private var resumeOffset: Int64 = 0`) on `DirectFileJob`.
  2. `start()` writes to `resumeOffset` on line 143 and line 158 without acquiring `lock`.
  3. `urlSession(_:dataTask:didReceive:completionHandler:)` reads `resumeOffset` on lines 258, 293, 296, and 303 without acquiring `lock`.
  4. These calls occur on different threads without synchronization barriers.
- **Impact**: Unsynchronized shared mutable state violation under Swift Concurrency, leading to potential torn reads/writes of `Int64` on 32-bit/emulated architectures or stale register cache reads.
- **Evidence**:
  ```swift
  // client/Sources/Services/Downloads/DirectFileJob.swift:258
  if status == 416, resumeOffset > 0 { ... }
  ```
- **Recommended fix**: Guard all reads and writes of `resumeOffset` with `lock`, or store it in an atomic container.
- **Guards considered**: Other properties (`fileHandle`, `written`, `total`) are guarded with `lock.lock() ... lock.unlock()`, but `resumeOffset` was left unsynchronized outside the lock blocks.

---

### F-SECURITY-08: MediaResolver Unreported Dropped Tasks Leak Engine Concurrency Slots
- **Severity**: Medium
- **Confidence**: high
- **Type**: leak / logic
- **Location**: `client/Sources/Services/MediaResolverService.swift:32-38`, `engine/src/main/kotlin/com/lagradost/macos/MediaResolveBridge.kt:128-138`
- **Trigger**: An extension initiates media resolution with a URL that fails `WebContentNetworkPolicy.shared.allowsNavigation(to: url)`.
- **Trace**:
  1. Extension calls `WebViewResolver`, which sends a `MediaResolveSpec` to the engine.
  2. Engine creates a task in `MediaResolveBridge.tasks`, incrementing the slot count against `MAX_PENDING` (8).
  3. The macOS app long-polls `GET /media/pending` and receives the task.
  4. `MediaResolverService.start` tests `WebContentNetworkPolicy.shared.allowsNavigation(to: url)`. Because the URL is restricted, the guard fails and `start` returns.
  5. The task is never started in WebKit, and no response is ever sent back to `POST /media/complete`.
  6. The engine coroutine remains blocked in `task.done.await()` until its timeout expires (up to 120,000 ms).
  7. During this window, the task slot in `MediaResolveBridge` remains occupied.
- **Impact**: Consecutive disallowed URLs exhaust `MediaResolveBridge.MAX_PENDING`, causing subsequent legitimate media resolution requests to fail immediately with `WorkerCapacityException`.
- **Evidence**:
  ```swift
  // client/Sources/Services/MediaResolverService.swift:32-35
  guard sessions[task.taskId] == nil, sessions.count < Self.maxConcurrent, task.timeoutMs > 0,
        let url = URL(string: task.url), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
        url.host != nil, url.user == nil, url.password == nil,
        WebContentNetworkPolicy.shared.allowsNavigation(to: url) else { return }
  ```
- **Recommended fix**: If `allowsNavigation` returns false or URL is malformed, immediately send `client.completeMedia` with empty results (`MediaCompleteRequestDto(taskId: task.taskId)`) so the engine frees the slot and unblocks waiting coroutines.

---

### F-SYSTEM-09: MainActor Blocking Synchronous Pipe Write in Daemon Launch
- **Severity**: Low
- **Confidence**: high
- **Type**: hang / perf
- **Location**: `client/Sources/App/DaemonSupervisor.swift:273-275`
- **Trigger**: Engine JVM halts or deadlocks during early native bootstrap before reading launch parameters from stdin.
- **Trace**:
  1. `DaemonSupervisor.driveTransitions()` runs on `@MainActor`.
  2. Line 271 runs `prepared.process.run()`.
  3. Line 274 executes `try pipe.fileHandleForWriting.write(contentsOf: line)` synchronously.
  4. If the child process hangs before reading stdin, and the write payload exceeds the OS pipe buffer capacity, `write(contentsOf:)` blocks synchronously on the main thread.
- **Impact**: UI freeze on the main actor during engine startup failure until process kill or timeout.
- **Recommended fix**: Write to `pipe.fileHandleForWriting` asynchronously on a detached background task, or set the file handle to non-blocking mode.

---

## Reviewed / non-issues

1. **`WorkerEgressProxy.kt` Tunnel Disconnection & Slot Leaks**:
   - *Considered*: Whether hung upstream connections hold semaphore slots indefinitely.
   - *Cleared*: Verified lines 97-104 implement `soTimeout = poll` and check `activity.get() >= idleTimeoutMs` (default 60s), ensuring dead connections are reaped and slots are released.
2. **`URLSanitizer.kt` Query Parameter Stripping & CDN Signatures**:
   - *Considered*: Whether URL sanitization strips CDN auth tokens from stream URLs.
   - *Cleared*: Verified `SIGNATURE_PARAMETERS` and `STREAM_SAFE_TRACKING` explicitly preserve tokens and byte-for-byte query parameters when signatures (`sig`, `token`, `hmac`, etc.) are detected.
3. **`GenericPasswordKeychain.swift` Access Group Permissions**:
   - *Considered*: Whether missing keychain entitlements cause crashes or silent persistence failures.
   - *Cleared*: Verified fallback from `.dataProtection` to `.file` on `errSecMissingEntitlement`, ensuring test and ad-hoc builds operate without runtime panics.
4. **`MetalVideoView.swift` mpv Handle Lifecycle on Initialization Failure**:
   - *Considered*: Whether `mpv_destroy` vs `mpv_terminate_destroy` is invoked correctly on initialization failure.
   - *Cleared*: When `mpv_initialize()` fails, libmpv specification stipulates that the handle is uninitialized and must be freed with `mpv_destroy()`, which `MetalVideoView` does correctly on line 386.

---

## Areas not covered
- Runtime execution of DRM-protected content (FairPlay / Widevine), as CloudStream-macOS scopes only to unscrambled media streams.
- Heavy sustained performance benchmarking on legacy Intel GPUs (testing performed on Apple Silicon).
- Long-duration (>24h) continuous live HLS stream endurance testing.
