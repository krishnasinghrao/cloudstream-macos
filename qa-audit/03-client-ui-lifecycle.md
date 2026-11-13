# Audit Report: Client UI, Application Lifecycle & IPC Orchestration

## Scope and Methodology

This audit covers the native macOS client application lifecycle, daemon supervision, IPC communication, view model coordination, multi-window session isolation, profile management, software updating, and user uninstallation in `client/Sources/App/`, `client/Sources/ViewModels/`, `client/Sources/UI/`, `client/Sources/Services/System/`, `client/Sources/Models/IPC/`, and corresponding test suites in `client/Tests/`.

We traced real execution paths across:
- **Daemon Lifecycle & IPC**: Child process termination, signal handling (`SIGTERM`/`SIGINT`), timeout backoff, state synchronization via `DaemonSupervisor`, and bearer token / connection handshake in `EngineConnection` and `AppState`.
- **Application Teardown & Uninstaller**: MainActor coordination during graceful quit (`ApplicationShutdown`), modal teardown flows in `DeleteCloudStreamView` and `Uninstaller`, and filesystem wiping safety guards.
- **View Models & Multi-Window Session State**: `AppState` singleton vs `WindowSession` isolation, navigation path invalidation, cross-profile switching, and background task cancellation races.
- **UI Performance & Main Thread Invariants**: SwiftUI view evaluation loops, synchronous SwiftData reads inside `body`, and Keychain IPC calls on `@MainActor`.
- **Software Updates & Staging Lifecycle**: Background update checking, DMG extraction via `hdiutil`, verification, staging cleanup, and swap-in during process termination (`SoftwareUpdater`).

All defects were verified by direct code analysis against the documented architectural invariants in `docs/Architecture.md`, `docs/Rules.md`, `docs/Security.md`, `docs/ipc-api.md`, and `docs/adr/`.

---

## Findings

### F-clientcore-01: MainActor Deadlock and App Quit Hang on Daemon Supervisor Child Process Termination Failure
- **Severity**: Critical
- **Confidence**: high
- **Type**: hang
- **Location**: `client/Sources/App/DaemonSupervisor.swift:242-247`, `client/Sources/App/ApplicationShutdown.swift:46-54`, `client/Sources/Services/System/Uninstaller.swift:316-318`, `client/Sources/App/CloudStreamMacApp.swift:73-82, 148-156`
- **Trigger**: Application termination or uninstallation is triggered while an owned child process (e.g., engine daemon JVM or subprocess) takes longer than `terminateGrace + forceWait` (4.5s) to exit, or fails to terminate due to an unhandled signal/state.
- **Trace**:
  1. During application quit or uninstall, `ApplicationShutdown.shared.begin` is invoked with a completion handler.
  2. `ApplicationShutdown.shared.begin` calls `terminate { [weak self] in Task { @MainActor in self?.finish() } }`, passing the completion closure to `DaemonSupervisor.shared.stop(completion:)`.
  3. `DaemonSupervisor.stop(completion:)` appends the completion closure to `stopCompletions`, sets `wantsEngine = false`, and wakes the supervisor loop.
  4. In `DaemonSupervisor.driveTransitions()`, lines 232-238 iterate over `managedProcesses` and call `Self.terminateAndWait(child, grace: configuration.terminateGrace, forceWait: configuration.forceWait)`.
  5. If any child process fails to terminate within the timeout, `stopped` is `false`.
  6. At lines 242-247:
     ```swift
     if stopped {
         let completions = stopCompletions
         stopCompletions.removeAll()
         completions.forEach { $0() }
     } else { state = .error("An owned child process could not be stopped.") }
     continue
     ```
  7. When `stopped == false`, `stopCompletions` is NOT invoked and NOT cleared. The supervisor enters state `.error(...)` and loops.
  8. In `ApplicationShutdown`, `self?.finish()` is never reached because the callback passed to `DaemonSupervisor.stop` was never invoked.
  9. In `Uninstaller.perform()`, execution is suspended at:
     ```swift
     await withCheckedContinuation { continuation in
         ApplicationShutdown.shared.begin(persistProgress: false) { continuation.resume() }
     }
     ```
     Because `finish()` is never called, `continuation.resume()` is never invoked. The uninstaller permanently hangs with the UI modal dialog locked (`interactiveDismissDisabled(true)`).
  10. In `CloudStreamMacApp.applicationShouldTerminate(_:)`, the app returns `.terminateLater` waiting for `sender.reply(toApplicationShouldTerminate: true)` from `ApplicationShutdown.begin`. Since the callback is dropped, the reply is never sent. The application permanently hangs in a zombie quit state, requiring `kill -9` from Activity Monitor or Terminal.
- **Impact**: Permanent application hang and unresponsiveness during standard macOS Quit (Cmd+Q) or when performing "Delete CloudStream". The uninstaller dialog deadlocks, and the quit process fails to complete.
- **Evidence**:
  ```swift
  // client/Sources/App/DaemonSupervisor.swift:242-247
  if stopped {
      let completions = stopCompletions
      stopCompletions.removeAll()
      completions.forEach { $0() }
  } else { state = .error("An owned child process could not be stopped.") }
  continue
  ```
  ```swift
  // client/Sources/Services/System/Uninstaller.swift:316-318
  await withCheckedContinuation { continuation in
      ApplicationShutdown.shared.begin(persistProgress: false) { continuation.resume() }
  }
  ```
- **Recommended fix**: In `DaemonSupervisor.driveTransitions()`, invoke `stopCompletions` regardless of whether `stopped` succeeded or failed. If stopping failed with an error, invoke the callbacks after transitioning `state = .error(...)` so callers can unblock, report the error, and conclude shutdown:
  ```swift
  let completions = stopCompletions
  stopCompletions.removeAll()
  if !stopped {
      state = .error("An owned child process could not be stopped.")
  }
  completions.forEach { $0() }
  ```
- **Guards considered**: `DaemonSupervisor.terminateAndWait` attempts SIGTERM followed by SIGKILL. However, if a process is in an uninterruptible sleep (D state on macOS, e.g. hung NFS/disk I/O) or PID tracking is delayed, `terminateAndWait` returns `false`. There is no timeout guard or fallback continuation resume in `ApplicationShutdown` or `Uninstaller`.

---

### F-clientcore-02: Broken IPC Reconnection and Permanent Failure State on Initial Handshake Timeout
- **Severity**: High
- **Confidence**: high
- **Type**: logic
- **Location**: `client/Sources/ViewModels/AppState.swift:190-192`, `client/Sources/App/EngineConnection.swift:81-84`
- **Trigger**: The headless Kotlin engine daemon takes longer than 600ms (3 retries × 200–300ms) to respond to the initial `/health` handshake (e.g., cold JVM launch, slow system disk, or CPU throttling on battery).
- **Trace**:
  1. The engine daemon is launched by `DaemonSupervisor`. Once the socket listener is bound, `DaemonSupervisor` yields `.ready(endpoint)` to its `connectionChanges` stream.
  2. `AppState.observeEngine()` receives the snapshot at line 190 and runs:
     ```swift
     if case .ready = snapshot.state, let endpoint = snapshot.endpoint {
         guard connection.endpoint != endpoint else { continue }
         resetEngineWork()
         connection.beginVerification(endpoint)
         let generation = engineGeneration
         verificationTask = Task { [weak self] in
             await self?.verifyConnection(endpoint, generation: generation)
         }
     }
     ```
  3. `connection.beginVerification(endpoint)` sets `self.endpoint = endpoint` and `phase = .verifying`.
  4. In `AppState.verifyConnection(_:generation:)`, the client attempts 3 consecutive `/health` requests with 200ms and 300ms backoff intervals.
  5. If the JVM cold start exceeds this window (~600ms total), all 3 attempts fail.
  6. Line 238 executes: `connection.fail(lastError.localizedDescription, generation: generation)`.
  7. In `EngineConnection.fail()` (`EngineConnection.swift:81-84`), `phase` is set to `.failed(message)`. Crucially, `self.endpoint` is NOT cleared and remains set to `endpoint`.
  8. A few seconds later, the engine finishes booting. The daemon is now running and fully functional.
  9. If `DaemonSupervisor` re-evaluates or emits a state update with the same `endpoint`, `AppState.observeEngine()` executes line 191:
     `guard connection.endpoint != endpoint else { continue }`
  10. Because `connection.endpoint == endpoint`, the guard fails and skips verification! The ready event is discarded.
  11. The client connection remains permanently stuck in `phase = .failed`, showing "The CloudStream engine could not be verified" with a disabled UI, even though the engine daemon is healthy and listening.
- **Impact**: The application fails to connect to its engine on cold starts or under moderate system load, leaving the user permanently locked out with no automatic recovery.
- **Evidence**:
  ```swift
  // client/Sources/ViewModels/AppState.swift:190-193
  if case .ready = snapshot.state, let endpoint = snapshot.endpoint {
      guard connection.endpoint != endpoint else { continue }
      resetEngineWork()
      connection.beginVerification(endpoint)
  ```
  ```swift
  // client/Sources/App/EngineConnection.swift:81-84
  mutating func fail(_ message: String, generation: UInt64) {
      guard generation == self.generation else { return }
      phase = .failed(message)
  }
  ```
- **Recommended fix**: Clear `endpoint = nil` in `EngineConnection.fail()` so that subsequent `.ready` notifications for the endpoint can re-trigger verification:
  ```swift
  mutating func fail(_ message: String, generation: UInt64) {
      guard generation == self.generation else { return }
      phase = .failed(message)
      endpoint = nil
  }
  ```
  Additionally, in `AppState.observeEngine()`, allow verification if `connection.phase` is `.failed`, even if the endpoint has not changed:
  ```swift
  guard connection.endpoint != endpoint || connection.phase.isFailed else { continue }
  ```
- **Guards considered**: `AppState.restartEngine()` restarts the daemon, which generates a new port/endpoint. However, automatic recovery without manual user intervention is broken because `guard connection.endpoint != endpoint` unconditionally discards the supervisor's ready event.

---

### F-clientcore-03: ExtensionsView Mount Bootstrap Race Spawns Unnecessary 120-Second Health Polling Loop and Duplicate Credential Re-sends
- **Severity**: High
- **Confidence**: high
- **Type**: race
- **Location**: `client/Sources/UI/Extensions/ExtensionsView.swift:120-122`, `client/Sources/ViewModels/AppState.swift:373-425`, `client/Sources/ViewModels/ExtensionsStore.swift:101-118`
- **Trigger**: The user opens or navigates to the "Extensions" tab while the engine connection is becoming ready, or switches to the tab immediately following an engine restart.
- **Trace**:
  1. When `AppState.verifyConnection()` succeeds, line 236 launches:
     `bootstrapTask = Task { [weak self] in await self?.bootstrap() }`
  2. Simultaneously, `ExtensionsView` has a `.task` modifier bound to `appState.isEngineReady`:
     ```swift
     .task(id: appState.isEngineReady) {
         if appState.isEngineReady { await appState.bootstrap() }
     }
     ```
  3. When `isEngineReady` transitions to `true`, both `bootstrapTask` and `ExtensionsView.task` execute `AppState.bootstrap()` concurrently on `@MainActor`.
  4. Both tasks pass line 376 (`guard connection.providersRestored`) and execute line 391:
     `let refreshed = await extensions.refresh()`
  5. In `ExtensionsStore.refresh()`, line 102 increments `refreshGeneration &+= 1`.
  6. The second concurrent call increments `refreshGeneration` again.
  7. When the first `extensions.refresh()` finishes its network requests (`api.repos()`, `api.plugins()`), it checks:
     `guard !Task.isCancelled, generation == refreshGeneration, engine == epoch else { return false }`
  8. Because `refreshGeneration` was incremented by the competing call, `generation == refreshGeneration` is `false`. The first call immediately returns `false`!
  9. Back in `AppState.bootstrap()`, line 393 checks:
     `guard refreshed else { watchExtensionRestore(generation: generation); return }`
  10. Because `refreshed` returned `false`, the first bootstrap path concludes that extension restoration failed and invokes `watchExtensionRestore(generation:)`.
  11. `watchExtensionRestore` spawns a background `Task` with a 120-second timeout that continuously polls `/health` every 250ms, generating hundreds of unnecessary HTTP IPC requests against the engine.
  12. Meanwhile, both tasks proceed to line 396:
     `ProviderCredentialStore.resendAll(availableProviderIds: ...)`
     sending all stored provider credentials to the daemon twice concurrently.
- **Impact**: Spurious 120-second polling storm against the engine daemon, duplicate network requests, and potential race conditions in provider credential hydration.
- **Evidence**:
  ```swift
  // client/Sources/UI/Extensions/ExtensionsView.swift:120-122
  .task(id: appState.isEngineReady) {
      if appState.isEngineReady { await appState.bootstrap() }
  }
  ```
  ```swift
  // client/Sources/ViewModels/ExtensionsStore.swift:118
  guard !Task.isCancelled, generation == refreshGeneration, engine == epoch else { return false }
  ```
  ```swift
  // client/Sources/ViewModels/AppState.swift:391-393
  let refreshed = await extensions.refresh()
  guard generation == engineGeneration, !Task.isCancelled else { return }
  guard refreshed else { watchExtensionRestore(generation: generation); return }
  ```
- **Recommended fix**: Remove the redundant `await appState.bootstrap()` call from `ExtensionsView.swift:120-122`. `ExtensionsView` should only observe `store.isRefreshing` or call `store.refresh()`. Alternatively, coalesce in-flight `bootstrap()` calls in `AppState` using a single deduplicated `Task`.
- **Guards considered**: `AppState.watchExtensionRestore` checks `guard healthWatchTask == nil else { return }`, which prevents multiple watcher tasks, but does not prevent the initial spurious watcher task from starting due to the `refreshGeneration` mismatch.

---

### F-clientcore-04: Custom Library Page View Fails with Broken State and Cross-Profile Item Cache Confusion Across Profile Switches
- **Severity**: High
- **Confidence**: high
- **Type**: logic
- **Location**: `client/Sources/UI/Navigation/WindowSessionRegistry.swift:84-90`, `client/Sources/UI/Library/LibraryPageView.swift:16-35, 53-83`
- **Trigger**: A window is displaying a custom user-created library page (`session.selection = .page(id)` from Profile A); the user switches to Profile B using the profile selector.
- **Trace**:
  1. In `WindowSessionRegistry.invalidateProfileNavigation()`, profile invalidation resets:
     ```swift
     for session in entries.values.compactMap(\.session) + [pending] {
         session.detailPath.removeAll()
         session.clearSearch()
         session.libraryFilter = ""
     }
     ```
  2. Notice that `session.selection` is NOT reset. If `session.selection` was `.page(id)`, it remains `.page(id)`.
  3. Profile B activates. `LibraryStore.shared` rebinds its model container to Profile B's SwiftData SQLite database.
  4. In `LibraryPageView`, SwiftUI evaluates `body` for `pageID`:
     ```swift
     let _ = cache.update(.init(version: LibraryStore.shared.version, pageID: pageID, options: options.orderingAndFilters, query: query)) {
         let store = LibraryStore.shared
         let page = store.readForDisplay(or: nil, { try store.page(id: pageID) })
         let entries = store.readForDisplay(or: [], { try store.pageEntries(pageID: pageID) })
         return (page, Self.content(entries, query: query, options: options))
     }
     ```
  5. Because custom pages are scoped to the profile, `store.page(id: pageID)` returns `nil` in Profile B.
  6. Lines 80-82 execute:
     ```swift
     ContentUnavailableView("Page Not Found", systemImage: "rectangle.stack",
                            description: Text("This page was deleted."))
     ```
     The user is shown an error saying their page was deleted, and the window sidebar remains stuck on an invalid page selection.
  7. Furthermore, consider `Cache.Key`:
     ```swift
     struct Key: Equatable {
         var version: UInt64
         var pageID: String
         var options: LibraryViewOptions
         var query: String
     }
     ```
     `Key` does NOT contain `profileID` or `profileGeneration`. If Profile A and Profile B have identical `LibraryStore.shared.version` counters (e.g. initial counter `0`), `cache.update` detects `key == self.key` and returns immediately without running the closure. `cache.page` and `cache.content` from Profile A are rendered under Profile B.
- **Impact**: Broken UI with misleading "Page Not Found / This page was deleted" errors upon profile switching, accompanied by potential cross-profile data leakage in the in-memory cache.
- **Evidence**:
  ```swift
  // client/Sources/UI/Navigation/WindowSessionRegistry.swift:84-90
  func invalidateProfileNavigation() {
      for session in entries.values.compactMap(\.session) + [pending] {
          session.detailPath.removeAll()
          session.clearSearch()
          session.libraryFilter = ""
      }
  }
  ```
  ```swift
  // client/Sources/UI/Library/LibraryPageView.swift:16-21
  struct Key: Equatable {
      var version: UInt64
      var pageID: String
      var options: LibraryViewOptions
      var query: String
  }
  ```
- **Recommended fix**: In `WindowSessionRegistry.invalidateProfileNavigation()`, reset `session.selection` to `.home` (or `.watching`) if `session.selection` matches `.page(_)`. Additionally, include `LibraryStore.shared.profileID` or `profileGeneration` in `LibraryPageView.Cache.Key`.
- **Guards considered**: `WindowSessionRegistry` cleans up detail navigation paths and search filters, but omitted resetting `selection` when viewing a profile-specific page.

---

### F-clientcore-05: Staged Software Updates Dropped Without Installation on SIGTERM/SIGINT Shutdown
- **Severity**: High
- **Confidence**: high
- **Type**: logic
- **Location**: `client/Sources/App/CloudStreamMacApp.swift:50-71, 148-156`, `client/Sources/Services/Updates/SoftwareUpdater.swift:130-139, 230-244`
- **Trigger**: A software update has been downloaded and staged (`phase = .ready(release)`). The application process receives a `SIGTERM` or `SIGINT` signal (e.g., system shutdown, user logout, `kill`, or launchd daemon stop).
- **Trace**:
  1. In `CloudStreamMacApp.setupSignalHandlers()`, signal sources for `SIGTERM` and `SIGINT` are registered:
     ```swift
     termSource.setEventHandler {
         MainActor.assumeIsolated {
             ApplicationShutdown.shared.begin { exit(0) }
         }
     }
     ```
  2. When `SIGTERM` is delivered, `ApplicationShutdown.shared.begin` executes asynchronously and invokes `exit(0)` upon completion.
  3. `exit(0)` terminates the process directly at the Darwin C library runtime level.
  4. Because `exit(0)` is invoked directly, AppKit's run loop terminates abruptly without invoking `NSApplicationDelegate.applicationWillTerminate(_:)`.
  5. In `CloudStreamMacApp.applicationWillTerminate(_:)`:
     ```swift
     func applicationWillTerminate(_ notification: Notification) {
         MainActor.assumeIsolated {
             guard !AppEnvironment.isUnitTestHost else { return }
             ApplicationShutdown.shared.begin()
             SoftwareUpdater.shared.installAtTermination()
         }
     }
     ```
     Notice that `SoftwareUpdater.shared.installAtTermination()` is ONLY invoked from `applicationWillTerminate`. Since `exit(0)` bypassed `applicationWillTerminate`, `installAtTermination()` is never called.
  6. On the subsequent app launch, `SoftwareUpdater.start()` runs line 133:
     `removeLeftoverStaging()`
     which unconditionally deletes the staged `.app` bundle from the staging directory.
  7. The staged update is completely lost, requiring the user to re-download the entire update.
- **Impact**: Users who shut down or restart their Mac with an update staged for installation will never receive the update; the staged update is discarded on every reboot.
- **Evidence**:
  ```swift
  // client/Sources/App/CloudStreamMacApp.swift:56
  ApplicationShutdown.shared.begin { exit(0) }
  ```
  ```swift
  // client/Sources/Services/Updates/SoftwareUpdater.swift:133
  func start() {
      guard environment.isEnabled else { return }
      location = environment.location()
      removeLeftoverStaging()
  ```
- **Recommended fix**: In `CloudStreamMacApp.setupSignalHandlers()`, invoke `SoftwareUpdater.shared.installAtTermination()` inside the `ApplicationShutdown.shared.begin` completion block before calling `exit(0)`:
  ```swift
  termSource.setEventHandler {
      MainActor.assumeIsolated {
          ApplicationShutdown.shared.begin {
              SoftwareUpdater.shared.installAtTermination()
              exit(0)
          }
      }
  }
  ```
- **Guards considered**: `CloudStreamMacApp.applicationShouldTerminate` handles standard menu Quit (`NSApp.terminate`), but terminal signals (`SIGTERM`/`SIGINT`) bypass `applicationShouldTerminate` and invoke `setupSignalHandlers` directly.

---

### F-clientcore-06: Synchronous SwiftData Queries and Sorting Inside SwiftUI Body on Every Search Keystroke
- **Severity**: Medium
- **Confidence**: high
- **Type**: perf
- **Location**: `client/Sources/UI/Library/LibraryView.swift:87-94, 371-399`
- **Trigger**: The user types into the search/filter toolbar field while viewing any library collection (e.g. "Watching", "Completed", "Favorites") containing a large number of titles.
- **Trace**:
  1. Each keystroke updates `windowSession.libraryFilter`.
  2. Because `windowSession` is an `@Observable` model bound to the view, SwiftUI re-evaluates `LibraryView.body`.
  3. Inside `body`, lines 89-93 execute:
     ```swift
     let _ = arrangement.update(.init(version: storeVersion, collection: collection, options: options.orderingAndFilters,
                                      query: windowSession.libraryFilter)) {
         let all = unfilteredItems()
         return (all, filteredAndSortedItems(all))
     }
     ```
  4. `arrangement.update` compares the new key with `self.key`. Because `query` changed with the keystroke, `key != self.key` is `true`.
  5. The closure executes `let all = unfilteredItems()`.
  6. `unfilteredItems()` calls `Self.items(in: collection)`, which calls `store.readForDisplay(or: [], { try store.items(withWatchType: ...) })`.
  7. This triggers a synchronous SwiftData `FetchDescriptor` query against SQLite directly on the `@MainActor`.
  8. Once the database fetch completes, `filteredAndSortedItems(all)` performs in-memory filtering and sorting across all items.
  9. On libraries with hundreds or thousands of items, performing synchronous database queries and sorting on every keystroke blocks the main thread, causing frame drops and typing hitching.
- **Impact**: Noticeable UI lag, unresponsive search field, and main thread frame drops during typing in large libraries.
- **Evidence**:
  ```swift
  // client/Sources/UI/Library/LibraryView.swift:89-93
  let _ = arrangement.update(.init(version: storeVersion, collection: collection, options: options.orderingAndFilters,
                                   query: windowSession.libraryFilter)) {
      let all = unfilteredItems()
      return (all, filteredAndSortedItems(all))
  }
  ```
  ```swift
  // client/Sources/UI/Library/LibraryView.swift:377-387
  static func items(in collection: LibraryCollection) -> [StoredMediaItem] {
      let store = LibraryStore.shared
      switch collection {
      case .watching: return store.readForDisplay(or: [], { try store.items(withWatchType: .watching) })
  ```
- **Recommended fix**: Separate the query/version cache from the search filter cache. The SwiftData fetch (`unfilteredItems()`) should only execute when `storeVersion` or `collection` changes, while `filteredAndSortedItems(all)` should operate on the already fetched in-memory `all` items when `query` changes.
- **Guards considered**: The view uses an `Arrangement` cache, but because `query` is packed inside the same `Arrangement.Key`, changing `query` invalidates the entire cache and triggers a re-fetch of `unfilteredItems()`.

---

### F-clientcore-07: Synchronous System Keychain IPC Queries on MainActor in Delete CloudStream View
- **Severity**: Medium
- **Confidence**: high
- **Type**: perf
- **Location**: `client/Sources/UI/Settings/DeleteCloudStreamView.swift:245-247`, `client/Sources/Services/Security/GenericPasswordKeychain.swift:102-116`
- **Trigger**: The user opens "Settings ▸ General ▸ Delete CloudStream…", triggering the modal sheet's `.task(id: options) { await rescan() }`.
- **Trace**:
  1. `DeleteCloudStreamView` mounts and invokes `rescan()` on the `@MainActor`.
  2. In `rescan()`, line 247 correctly offloads size measurements:
     `sizes = await Task.detached(priority: .userInitiated) { scanned.measuredSizes() }.value`
  3. However, lines 245-246 execute synchronously on `@MainActor`:
     ```swift
     keychainItems = AppEnvironment.isIsolated() ? 0
         : Uninstaller.keychainServices.reduce(0) { $0 + GenericPasswordKeychain.accounts(service: $1).count }
     ```
  4. For each service in `Uninstaller.keychainServices` (such as `cloudstream.providers`, `cloudstream.subtitles`), `GenericPasswordKeychain.accounts(service:)` calls `SecItemCopyMatching` with `kSecMatchLimitAll` and `kSecReturnAttributes`.
  5. As documented in Apple's Security framework and in `ProviderCredentialStore.swift:50-51`, `SecItemCopyMatching` performs synchronous IPC over Mach ports to the `securityd` daemon.
  6. If the keychain is locked, waiting on user authorization, or if `securityd` is under load, `SecItemCopyMatching` blocks the calling thread.
  7. Because `rescan()` runs on `@MainActor`, the entire UI thread freezes while communicating with `securityd`.
- **Impact**: UI hitching and potential beachball when opening the "Delete CloudStream" modal dialog.
- **Evidence**:
  ```swift
  // client/Sources/UI/Settings/DeleteCloudStreamView.swift:245-246
  keychainItems = AppEnvironment.isIsolated() ? 0
      : Uninstaller.keychainServices.reduce(0) { $0 + GenericPasswordKeychain.accounts(service: $1).count }
  ```
  ```swift
  // client/Sources/Services/Security/GenericPasswordKeychain.swift:105
  let status = SecItemCopyMatching(query as CFDictionary, &result)
  ```
- **Recommended fix**: Offload the Keychain count query to a background task alongside `measuredSizes()`, assigning the result back to `@MainActor` upon completion:
  ```swift
  let services = Uninstaller.keychainServices
  keychainItems = await Task.detached(priority: .userInitiated) {
      services.reduce(0) { $0 + GenericPasswordKeychain.accounts(service: $1).count }
  }.value
  ```
- **Guards considered**: Disk footprint measurements were properly detached to a background task in line 247, but the Keychain IPC query was left on the main actor.

---

### F-clientcore-08: SoftwareUpdater.cancelDownload Fails to Cancel In-Flight Extraction or Remove Staged DMG Bundles
- **Severity**: Medium
- **Confidence**: high
- **Type**: leak
- **Location**: `client/Sources/Services/Updates/SoftwareUpdater.swift:189-196`, `client/Sources/Services/System/Uninstaller.swift:319`
- **Trigger**: The user cancels an update, or uninstallation begins, while the updater is in the `.preparing` (DMG mounting/codesign verification) or `.ready` state.
- **Trace**:
  1. In `SoftwareUpdater`, an update transitions through `.checking -> .available -> .downloading -> .preparing -> .ready`.
  2. In `cancelDownload()`:
     ```swift
     func cancelDownload() {
         guard case .downloading(let release, _) = phase else { return }
         work?.cancel()
         work = nil
         downloadGeneration += 1
         discardStaged()
         phase = .available(release)
     }
     ```
  3. The guard strictly checks `case .downloading`. If `phase` is `.preparing` (where `hdiutil attach`, binary copying, and codesign validation occur) or `.ready` (where the `.app` bundle is waiting in staging), the guard fails immediately and returns.
  4. In `Uninstaller.perform()`, line 319 calls `SoftwareUpdater.shared.cancelDownload()` to ensure no updates are staged or running during uninstallation.
  5. Because `phase` is `.preparing` or `.ready`, `cancelDownload()` does nothing. `work?.cancel()` is never called, and `discardStaged()` is never called.
  6. The staged 100+ MB `.app` bundle remains on disk, and in-flight background processes (`hdiutil`) continue running uncancelled.
- **Impact**: Leaked staging files (100+ MB), orphaned extraction subprocesses, and inability to reset updater state once download completes.
- **Evidence**:
  ```swift
  // client/Sources/Services/Updates/SoftwareUpdater.swift:189-191
  func cancelDownload() {
      guard case .downloading(let release, _) = phase else { return }
      work?.cancel()
  ```
- **Recommended fix**: Expand `cancelDownload()` to handle `.preparing` and `.ready` phases:
  ```swift
  func cancelDownload() {
      let candidate: UpdateRelease
      switch phase {
      case .downloading(let r, _), .preparing(let r), .ready(let r): candidate = r
      default: return
      }
      work?.cancel()
      work = nil
      downloadGeneration += 1
      discardStaged()
      phase = .available(candidate)
  }
  ```
- **Guards considered**: `cancelDownload()` was designed only with the active network download phase in mind, neglecting the subsequent disk extraction and staging phases.

---

### F-clientcore-09: Unthrottled Tight Busy-Spin Polling Loop in Media Task Queue Processing (CRIT-02)
- **Severity**: Critical
- **Confidence**: high
- **Type**: perf / hang
- **Location**: `client/Sources/ViewModels/AppState.swift:486-505`, `client/Sources/Services/MediaResolverService.swift:32-38`, `engine/src/main/kotlin/com/lagradost/macos/PendingSignal.kt:27-36`
- **Trigger**: A media resolution request is enqueued by an extension into the daemon's `/media/pending` queue that cannot be immediately started by the client (for example: `MediaResolverService.sessions.count >= MediaResolverService.maxConcurrent` (2), or the task URL violates `WebContentNetworkPolicy.shared.allowsNavigation(to:)`, or has an invalid scheme).
- **Trace**:
  1. `AppState.mediaPollTask` continuously queries the daemon for pending media tasks:
     ```swift
     mediaPollTask = Task { [weak self] in
         while !Task.isCancelled {
             ...
             let pending: [MediaPendingDto]
             do { pending = try await DaemonClient.shared.pendingMedia(waitMs: Self.longPollMilliseconds) }
             catch { try? await Task.sleep(for: .seconds(2)); continue }
             ...
             let active = MediaResolverService.shared.activeTaskIds
             let fresh = pending.filter { !active.contains($0.taskId) }
             for task in fresh { MediaResolverService.shared.start(task) }
             // A provider call is waiting on these: re-check soon, without spinning.
             if !pending.isEmpty && fresh.isEmpty { try? await Task.sleep(for: .milliseconds(500)) }
         }
     }
     ```
  2. When tasks exist in the daemon's queue, the Ktor daemon route `/media/pending` returns immediately with the list of pending tasks (without long-poll waiting).
  3. `MediaResolverService.shared.start(task)` applies strict preconditions:
     ```swift
     guard sessions[task.taskId] == nil, sessions.count < Self.maxConcurrent, task.timeoutMs > 0,
           let url = URL(string: task.url), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
           url.host != nil, url.user == nil, url.password == nil,
           WebContentNetworkPolicy.shared.allowsNavigation(to: url) else { return }
     ```
  4. If any task in `fresh` fails these guards (e.g., concurrency is saturated at 2, or the URL is blocked by network policy), `start()` returns early without creating a session.
  5. Crucially, `task.taskId` is NEVER added to `activeTaskIds`.
  6. On line 502, `if !pending.isEmpty && fresh.isEmpty` evaluates to `false` because `fresh` still contains the un-started task.
  7. As a result, the loop does NOT sleep at all (0ms sleep).
  8. The task remains unacknowledged in the daemon's `/media/pending` queue. On the immediate next loop iteration, `pendingMedia()` returns the exact same pending task instantly.
  9. `activeTaskIds` still does not contain it, so `fresh` is still non-empty.
  10. The client enters an unthrottled, infinite HTTP polling spin loop against the daemon on the local loopback interface, driving CPU core utilization to 100%, generating massive socket traffic, and starving the engine and UI runloops.
- **Impact**: 100% CPU core utilization, battery drain, thermal throttling, and local network socket starvation whenever media resolution tasks cannot be started or when concurrency exceeds 2.
- **Evidence**:
  ```swift
  // client/Sources/ViewModels/AppState.swift:501-503
  // A provider call is waiting on these: re-check soon, without spinning.
  if !pending.isEmpty && fresh.isEmpty { try? await Task.sleep(for: .milliseconds(500)) }
  ```
  ```swift
  // client/Sources/Services/MediaResolverService.swift:32-35
  guard sessions[task.taskId] == nil, sessions.count < Self.maxConcurrent, task.timeoutMs > 0,
        let url = URL(string: task.url), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
        url.host != nil, url.user == nil, url.password == nil,
        WebContentNetworkPolicy.shared.allowsNavigation(to: url) else { return }
  ```
- **Recommended fix**: 
  1. Always add an unthrottled backoff sleep of at least 500ms when `!pending.isEmpty`, regardless of `fresh.isEmpty`:
     ```swift
     if !pending.isEmpty {
         try? await Task.sleep(for: fresh.isEmpty ? .seconds(1) : .milliseconds(500))
     }
     ```
  2. If `MediaResolverService.start(task)` rejects a task permanently (invalid URL or policy rejection), immediately notify the daemon of failure via `DaemonClient.shared.completeMedia(taskId: task.taskId, ...)` so the daemon dequeues the task rather than re-offering it forever.
- **Guards considered**: The comment on line 501 notes "do not spin", yet line 502 only throttles when `fresh.isEmpty`, leaving the `!fresh.isEmpty` path completely unthrottled whenever a task cannot be started.

---

### F-clientcore-10: Missing applicationShouldHandleReopen Leaves App Non-Responsive When Clicked in macOS Dock
- **Severity**: Low
- **Confidence**: high
- **Type**: ux
- **Location**: `client/Sources/App/CloudStreamMacApp.swift:7-157`
- **Trigger**: The user closes all application windows (Cmd+W) while keeping the application running, then clicks the CloudStream icon in the macOS Dock.
- **Trace**:
  1. In `CloudStreamMacApp.swift`, `AppDelegate` conforms to `NSApplicationDelegate`.
  2. When all windows are closed, CloudStream remains running as an active background process.
  3. When the user clicks the application icon in the Dock, macOS calls `NSApplicationDelegate.applicationShouldHandleReopen(_:hasVisibleWindows:)`.
  4. `AppDelegate` does NOT implement `applicationShouldHandleReopen(_:hasVisibleWindows:)`.
  5. Because this delegate method is omitted, the app does not reactivate or create a new `WindowGroup` window.
  6. The application activates in the menu bar, but no window appears. To the user, clicking the Dock icon appears completely broken/unresponsive.
- **Impact**: Degraded macOS user experience where clicking the app in the Dock fails to surface any window when all windows were closed.
- **Evidence**:
  `AppDelegate` in `CloudStreamMacApp.swift` implements `applicationDockMenu`, `applicationShouldTerminate`, and `applicationWillTerminate`, but completely omits `applicationShouldHandleReopen`.
- **Recommended fix**: Implement `applicationShouldHandleReopen(_:hasVisibleWindows:)` in `AppDelegate`:
  ```swift
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
      if !flag {
          // Bring main window to front or open a new window
          for window in sender.windows where window.canBecomeMain {
              window.makeKeyAndOrderFront(self)
              return true
          }
      }
      return true
  }
  ```
- **Guards considered**: In SwiftUI 5+ lifecycle apps with `WindowGroup`, omitting `applicationShouldHandleReopen` relies on system default behavior, which frequently fails to unminimize or reopen closed non-document window groups.

---

### F-clientcore-11: VOD Playback Progress Silently Written to Incorrect Profile After Mid-Playback Profile Switch
- **Severity**: High
- **Confidence**: high
- **Type**: logic / security
- **Location**: `client/Sources/ViewModels/PlayerViewModel.swift:2236-2252`, `client/Sources/Services/ProfileStore.swift:100-109`
- **Trigger**: User starts watching a movie or series episode under Profile A (e.g., adult/personal profile); while playback continues in the detached player window, the user or another window switches to Profile B (e.g., kids profile) via the profile switcher.
- **Trace**:
  1. In `PlayerViewModel`, `liveHistoryOwner` (`LibraryStore.ProfileOperationContext?`) was implemented strictly for live TV channels (`isLive`):
     `liveHistoryOwner = isLive ? try? LibraryStore.shared.captureProfileOperation() : nil`
  2. For all standard VOD media (movies and series episodes), `liveHistoryOwner` is `nil`.
  3. `PlayerViewModel.persistProgress(notify:)` has no profile owner context and blindly invokes:
     ```swift
     private func persistProgress(notify: Bool) {
         guard let session, session.persistsProgress, !isLive else { return }
         let save = {
             try LibraryStore.shared.recordProgress(
                 details: session.details,
                 episode: session.episode,
                 progressSeconds: self.elapsed,
                 totalDurationSeconds: self.duration,
                 notifyObservers: notify,
             )
         }
         if notify {
             LibraryStore.shared.perform(save)
             return
         }
         LibraryStore.shared.writeSilently(save)
     }
     ```
  4. When the user switches to Profile B, `ProfileStore.shared.select(profile)` calls `library.activateProfileStore(named: profile.storeName)`.
  5. `LibraryStore.shared` immediately rebinds its model container to Profile B's SQLite database. It does NOT close the player or notify `PlayerViewModel`.
  6. As the video continues playing in `PlayerViewModel`, line 2200 triggers `persistProgress(notify: false)` every 5 seconds, as well as on pause, seek, and window close (`close()`).
  7. `LibraryStore.shared.recordProgress` executes against Profile B's database. It upserts the movie/show, marks it in continue watching, and saves the resume timestamps of Profile A directly into Profile B.
- **Impact**: Severe cross-profile state leakage and privacy breach. Mature or private titles watched in Profile A are injected into children's or secondary profiles with full watch history and resume state.
- **Evidence**:
  ```swift
  // client/Sources/ViewModels/PlayerViewModel.swift:2236-2247
  private func persistProgress(notify: Bool) {
      guard let session, session.persistsProgress, !isLive else { return }
      let save = {
          try LibraryStore.shared.recordProgress(
              details: session.details,
              episode: session.episode,
              progressSeconds: self.elapsed,
              totalDurationSeconds: self.duration,
              notifyObservers: notify,
          )
      }
  ```
  ```swift
  // client/Sources/Services/ProfileStore.swift:101-104
  guard profile.id != activeID else { return }
  WindowSessionRegistry.shared.invalidateProfileNavigation()
  try library.activateProfileStore(named: profile.isDefault ? nil : profile.storeName, identityProviders: identityProviders)
  activeID = profile.id
  ```
- **Recommended fix**: 
  1. Capture `profileOwner = try? LibraryStore.shared.captureProfileOperation()` when any VOD session begins in `PlayerViewModel`.
  2. In `persistProgress`, guard `library.owns(profileOwner)` before writing; if the active profile changed, either drop the write or route it to the originating profile's store context.
  3. Alternatively, close or pause the player in `ProfileStore.select` when switching profiles.
- **Guards considered**: `liveHistoryOwner` protected live streams, but standard VOD playback omitted the profile operation context guard.

---

### F-clientcore-12: Global Deep-Link Broadcast Causes Redundant Navigation and Duplicate Modal Sheet Presentation Across Multi-Window Sessions
- **Severity**: Medium
- **Confidence**: high
- **Type**: race / ux
- **Location**: `client/Sources/UI/Navigation/RootView.swift:130-133`, `client/Sources/ViewModels/WindowSession.swift:179-195`, `client/Sources/UI/Navigation/WindowSessionRegistry.swift:20-25`
- **Trigger**: Multiple windows are open simultaneously in the application; the user opens an external deep link (e.g. `cloudstreamrepo://...` or `cloudstreamapp://search?q=...` via browser, Terminal, or Spotlight).
- **Trace**:
  1. In `RootView.swift:130`:
     ```swift
     .onOpenURL { url in
         guard !AppLock.shared.isLocked else { return }
         windowSession.handleDeepLink(url)
     }
     ```
  2. Because `RootView` is the top-level view of the `WindowGroup`, SwiftUI attaches an `.onOpenURL` listener to every active window scene.
  3. When an external URL is delivered to the application, SwiftUI broadcasts the URL event to every window scene's `RootView`.
  4. Neither `RootView` nor `windowSession.handleDeepLink` checks whether `windowSession.id == WindowSessionRegistry.shared.activeID` or whether the window is currently focused/key.
  5. All open windows concurrently invoke `windowSession.perform(DeepLinkRouter.route(url))`.
  6. If the route is `.addRepository(target)`: every window sets `pendingRepoAdd = target`, triggering the "Add Repository" confirmation sheet simultaneously across all open windows.
  7. If the route is `.search(query)` or `.openTitle(...)`: every window unconditionally navigates and replaces its current view state, blowing away the user's browsing context in background windows.
- **Impact**: Confusing multi-window behavior: duplicate modal dialogs spawn across all windows, and background browsing sessions are unintentionally overridden by incoming external links.
- **Evidence**:
  ```swift
  // client/Sources/UI/Navigation/RootView.swift:130-133
  .onOpenURL { url in
      guard !AppLock.shared.isLocked else { return }
      windowSession.handleDeepLink(url)
  }
  ```
- **Recommended fix**: In `RootView.swift`, ensure that only the active/focused window session processes deep links:
  ```swift
  .onOpenURL { url in
      guard !AppLock.shared.isLocked else { return }
      guard windowSession.id == WindowSessionRegistry.shared.activeID else { return }
      windowSession.handleDeepLink(url)
  }
  ```
- **Guards considered**: `AppLock.shared.isLocked` prevents deep link execution when the app is locked, but no check fences execution to the frontmost window.

---

## Pass 2 & Fact-Checking Results

During Pass 2, all 10 Pass 1 findings were re-verified against the codebase, test suites, and cross-layer contracts. Two new subtle defects (F-clientcore-11 and F-clientcore-12) were discovered through deep trace analysis of cross-profile playback and multi-window event distribution.

### Fact-Checking Verdicts for Pass 1 Findings:
1. **F-clientcore-01**: **[CONFIRMED]**
   - *Line Verification*: `DaemonSupervisor.swift:242-247`, `ApplicationShutdown.swift:46-54`, `Uninstaller.swift:316-318`.
   - *Verdict*: When `stopped == false`, `stopCompletions` is dropped without execution. `UninstallerTests` only tests footprint generation, not `perform()`. Deadlock path confirmed.
2. **F-clientcore-02**: **[CONFIRMED]**
   - *Line Verification*: `AppState.swift:190-192`, `EngineConnection.swift:81-84`.
   - *Verdict*: `connection.fail()` retains `endpoint`. When the engine becomes healthy and yields the same endpoint, `guard connection.endpoint != endpoint` drops the ready notification. Permanent lock out confirmed.
3. **F-clientcore-03**: **[CONFIRMED]**
   - *Line Verification*: `ExtensionsView.swift:120-122`, `AppState.swift:391-394`, `ExtensionsStore.swift:101-118`.
   - *Verdict*: Concurrent `bootstrap()` calls from view mount and `verifyConnection` bump `refreshGeneration`, returning `false` on line 118 and triggering a 120-second `/health` polling loop.
4. **F-clientcore-04**: **[CONFIRMED]**
   - *Line Verification*: `WindowSessionRegistry.swift:84-90`, `LibraryPageView.swift:16-35, 55-60`.
   - *Verdict*: Profile switch leaves selection on `.page(id)`. Custom pages are profile-scoped SwiftData entities, resulting in "Page Not Found", and `Cache.Key` omits profile identifier.
5. **F-clientcore-05**: **[CONFIRMED]**
   - *Line Verification*: `CloudStreamMacApp.swift:50-71, 148-156`, `SoftwareUpdater.swift:133, 230-244`.
   - *Verdict*: `exit(0)` on `SIGTERM`/`SIGINT` bypasses AppKit's `applicationWillTerminate:`. Staged updates are never swapped in and are discarded on next launch by `removeLeftoverStaging()`.
6. **F-clientcore-06**: **[CONFIRMED]**
   - *Line Verification*: `LibraryView.swift:87-94, 371-399`.
   - *Verdict*: Synchronous SwiftData fetches and in-memory sorting execute directly inside SwiftUI `body` evaluation on every single character typed in the filter field.
7. **F-clientcore-07**: **[CONFIRMED]**
   - *Line Verification*: `DeleteCloudStreamView.swift:245-247`, `GenericPasswordKeychain.swift:102-116`.
   - *Verdict*: `GenericPasswordKeychain.accounts(service:)` calls `SecItemCopyMatching` on `@MainActor`, blocking the UI thread on `securityd` Mach port IPC.
8. **F-clientcore-08**: **[CONFIRMED]**
   - *Line Verification*: `SoftwareUpdater.swift:189-196`, `Uninstaller.swift:319`.
   - *Verdict*: `cancelDownload()` only guards `case .downloading`, silently ignoring `.preparing` and `.ready`, leaking extracted `.app` bundles and child extraction processes.
9. **F-clientcore-09**: **[REVISED & ESCALATED to Critical / High]**
   - *Line Verification*: `AppState.swift:486-505`, `MediaResolverService.swift:32-38`, `PendingSignal.kt:27-36`.
   - *Verdict*: Multi-component analysis reveals that when tasks are rejected by `MediaResolverService` preconditions (e.g. concurrency limit or policy), they are never added to `activeTaskIds` and remain pending in the daemon. The loop runs with 0ms sleep in an infinite 100% CPU busy-spin. Escalated to Critical / High in alignment with swarm synthesis `[CRIT-02]`.
10. **F-clientcore-10**: **[CONFIRMED]**
    - *Line Verification*: `CloudStreamMacApp.swift:7-157`.
    - *Verdict*: Missing `applicationShouldHandleReopen:hasVisibleWindows:` leaves the app unresponsive when clicked in the Dock with all windows closed.

### Newly Uncovered Findings Summary:
- **F-clientcore-11 (High | logic / security)**: `PlayerViewModel.persistProgress(notify:)` lacks profile context checks for VOD media, causing playback progress and watch history from Profile A to be silently written into Profile B's SQLite database if a profile switch occurs during playback.
- **F-clientcore-12 (Medium | race / ux)**: `.onOpenURL` on `RootView` broadcasts external deep links to all open windows, spawning duplicate repository sheets and overwriting active navigation across multi-window sessions.

---

## Reviewed / non-issues

During the audit, several complex subsystems were verified to be functioning correctly according to architectural specifications:

1. **`StaleEngineReaper` Orphan Process Protection (`client/Sources/App/StaleEngineReaper.swift`)**:
   - *Consideration*: Could the reaper accidentally kill other user processes that reused the PID recorded in `daemon.lock`?
   - *Verification*: `StaleEngineReaper.assess()` rigorously verifies:
     - The process UID matches the current user (`bsdInfo(pid)?.pbi_uid == getuid()`).
     - The parent process ID is launchd (`pbi_ppid == 1`), confirming it is genuinely orphaned.
     - The process command-line arguments match the exact `-Dcs.cloudstream.home=<root>` path for this app instance.
     - It sends `SIGCONT` and `SIGTERM` before escalating to `SIGKILL`, re-verifying process identity right before `SIGKILL`. This prevents PID collision issues.

2. **`ManagedExtensionPolicy` Profile Enforcement (`client/Sources/App/ManagedExtensionPolicy.swift`)**:
   - *Consideration*: Can a local non-admin user spoof or relax MDM configuration profiles via `defaults write`?
   - *Verification*: `ManagedExtensionPolicy.current()` strictly queries `defaults.objectIsForced(forKey:)`. Unforced keys set via `defaults write` are completely ignored. If any forced key has an invalid type, `from(forced:)` fails closed into `safeModeOnly = true`.

3. **`CDSArchivePolicy` JVM Cache Integrity (`client/Sources/App/CDSArchivePolicy.swift`)**:
   - *Consideration*: Can a corrupted or malicious CDS archive crash JVM startup?
   - *Verification*: `CDSArchivePolicy.validatedArchive()` checks SHA256 hex digests of the JAR, the Java `lib/modules` runtime image, and the `.jsa` archive itself against metadata bounded to 64KB. Any validation failure gracefully drops back to standard JVM execution.

4. **`DeepLinkRouter` Input Sanitization (`client/Sources/Services/System/DeepLinkRouter.swift`)**:
   - *Consideration*: Could malformed deep links trigger memory exhaustion, URL scheme injection, or path traversal?
   - *Verification*: `DeepLinkRouter.route()` enforces a strict 4096-character limit (`maxLength`), restricts repository schemes to HTTP/HTTPS, and truncates search query strings to 200 characters.

5. **`ApplicationShutdown` Re-entrancy Guards (`client/Sources/App/ApplicationShutdown.swift`)**:
   - *Consideration*: Can concurrent calls to `ApplicationShutdown.begin()` cause double termination or corrupt progress flushes?
   - *Verification*: `ApplicationShutdown` is an `@MainActor` singleton with an explicit `State` machine (`.idle`, `.stopping`, `.finished`). If already `.stopping`, subsequent callers append their completion callbacks and exit early without re-executing `persist()`, `quiesce()`, or `terminate()`.

---

## Areas not covered

1. **Metal Shader Compilation and mpv C Bridge**: Covered by the Player & Media Pipeline audit (`qa-audit/01-player-media.md`).
2. **SwiftData Schema Migration and SQLite WAL Consistency**: Covered by the Persistence & Security audit (`qa-audit/02-persistence-security.md`).
3. **Ktor Netty Socket Dispatch and Isolated ClassLoader Verification**: Covered by the Engine & Daemon audit (`qa-audit/04-engine-daemon.md`).
4. **Third-Party Extension Scraper Logic and Duktape JavaScript Bridges**: Covered by the Library & Scrapers audit (`qa-audit/05-library-scrapers.md`).
