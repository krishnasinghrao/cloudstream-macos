# Audit Fix Plan

Implementation plan for the issues found in the October 2026 adversarial audit
of the engine and client (branch `engine-logic-fixes`). Issue numbers (#n)
refer to the audit findings.

- Nothing here needs an IPC version bump, a SwiftData schema change or a backup
  format change.
- **New finding (from planning):** in `PlayerViewModel`, `skipUnloadable`
  returns `loadRequest != nil`. If the next mirror needs a relay (split stream),
  that is `false` even though the load is in progress, so `startSession` returns
  early and skips the HUD, the window present and the Now Playing commands.
  Fixed with Q1.
- **#21 (comma-joined provider filter) affects nobody today:** the only caller
  (`WindowSession.swift:45`) passes `plugins: nil`. Moved to deferred.

---

## Sequencing at a glance

| Order | Change set | Contents | Depends on |
|---|---|---|---|
| 1 | Engine fixes before the current branch is committed | Q5 (#6), M5 (#9), Q7 (#15) | — |
| 2 | Engine quick fixes | Q2 (#10), Q3 (#13), Q4 (#7), M4 (#8) | — |
| 3 | Client IPC transport | A1 (#1), M1 (#5) | — |
| 4 | Player | Q1 (#4 and the new finding), M6a (#12), M7 (#18), Q9 (#17) | 3 helps with testing |
| 5 | Download reliability | M2 (#3), M3 (#11), Q6 (#14), M6b (#12) | — |
| 6 | Credentialed manifest downloads | A2 (#2) | 2 (Q3), 3 (A1), 5 (M6b) |
| 7 | Small items, any time | Q8 (#16), M8 (#19), M9 (#20) | — |

#6 and #9 are in uncommitted code on `engine-logic-fixes`, so fix them before
that refactor is committed. A1 goes early because false engine restarts (#1)
would make every later playback and download test flaky.

---

## Part 1 — Quick fixes

Each is small, stays in one place and doesn't change any contract.

### Q1. Failover clears its own error, and the relayed-mirror start is skipped (#4 + new finding)

**Files:** `client/Sources/ViewModels/PlayerViewModel.swift` — `failover`
(~1077), `skipUnloadable` (~755), `startSession` (~589).

**Change:**
- `failover(to:startAt:)` returns `@discardableResult Bool`. It only clears the
  error and resumes playback when the load was issued and nothing failed:
  ```swift
  let issued = issueLoad(...)
  guard issued, phase != .failed else { return false }
  error = nil; setPlaying(true); return true
  ```
- `skipUnloadable` returns what `failover(...)` returns, not
  `loadRequest != nil`. `beginRelayedLoad` legitimately leaves `loadRequest`
  nil while it registers the relay.
- Existing callers that ignore the result (`handlePlaybackError`,
  `tryNextMirror`, `selectMirror`, `engineReconnected`) need no change.

**Interactions:** `startSession`'s `guard issueLoad(...)` now goes ahead for
relayed fallbacks, so the HUD, the window present and the Now Playing commands
run. `fail()` still owns the window present when `session == nil`.

**Risk:** low. Don't let `selectMirror` remember a source whose load failed: it
already calls `rememberForTitle` after `failover`, so gate that on the return
value.

**Tests:** in `PlayerRemediationTests`:
- last mirror rejected by policy → `phase == .failed` and `error != nil`
- first mirror unloadable, second needs a relay → session presented and
  `isPlaying`

### Q2. State-recovery gate blocks `/lock` and download routes (#10)

**File:** `engine/src/main/kotlin/com/lagradost/macos/Main.kt` (~186).

**Change:** exempt `path == "/lock"` and `path in DaemonLock.downloadPaths`
from the 503 recovery gate. This mirrors the lock gate just above it.

**Interactions:** the gate exists to protect persistent state. `/lock` changes
only memory, and so do the relay and verifier routes. `/links` reads provider
state and doesn't write it; `ProviderExecutor.storeLinks` only touches the
in-memory cache.

**Risk:** low.

**Tests:** a `DaemonLockTest` / `RouteHarness` case with `recoveryError` set:
POST `/lock` → 200, POST `/plugins/install` → still 503.

### Q3. HEAD on a relayed manifest returns 415 (#13)

**File:** `engine/src/main/kotlin/com/lagradost/macos/MediaRelay.kt` (~299).

**Change:** when `manifest != null && head && response.code == 200`, close the
upstream response and reply `200` with the manifest content type and no
length. Don't call `serveManifest`.

**Risk:** none.

**Tests:** a HEAD case in `MediaRelayTest`.

### Q4. ResourceTable reads past its bounds and throws the wrong exception (#7)

**File:** `engine/src/main/kotlin/com/lagradost/macos/ResourceTable.kt`.

**Change:**
- `strings()`: `require(size >= 28 && headerSize >= 28 && headerSize <= size)`
  before reading offsets 8, 16 and 20.
- `typeChunk()`: `require(headerSize >= 20 && headerSize <= size)` before
  reading offsets 12 and 16.
- Backstop in `parse()`: catch `IndexOutOfBoundsException` and
  `BufferUnderflowException` and rethrow them as
  `IllegalArgumentException("Malformed resource table")`.

**Interactions:** `PluginBridge.kt:126` already maps IAE to
`UnsupportedExtensionException`, so no caller changes.

**Tests:** truncated-chunk cases in `ResourceTableTest` / `ParserFuzzTest`. An
8-byte string-pool chunk is the minimal reproduction.

### Q5. Icon URL can fail a whole repository sync (#6, uncommitted)

**File:** `engine/src/main/kotlin/com/lagradost/macos/CatalogTrust.kt` (~99).

**Change:**
- Never resolve a hostname. Treat the host as a literal only if it's IPv6
  (contains `:`) or matches a strict IPv4 pattern with four octets, each ≤ 255.
  Only then call `InetAddress.getByName`, which doesn't do DNS for a valid
  literal.
- Hosts that are digits and dots but not a valid IPv4 address → `null` (icon
  dropped).
- Wrap the whole function in `runCatching { … }.getOrNull()`.
- Move `plugin.copy(...)`, including `artifactUrl` and `iconUrl`, inside the
  per-entry `try`, so per-entry failures drop that entry. Leave the
  `SecurityException` for a signed entry without a hash outside the try; that
  one should still fail the whole catalog.

**Tests:** in `CatalogEntriesTest`, icons `https://999.999.999.999/i.png` and
`https://1.2.3.4.5/i.png` → entry kept, `iconUrl == null`, no network access.
Also confirm in the test how OkHttp canonicalises these hosts.

### Q6. DASH links labelled as direct files fail instead of falling back to ffmpeg (#14)

**File:** `client/Sources/Services/Downloads/DirectFileJob.swift` (~236) and the
first-bytes sniff.

**Change:**
- Treat a MIME type containing `dash+xml` like `mpegurl` and return
  `finishNotDirect()`.
- Sniff `data.prefix(512)`. If the text contains `<MPD` (case-insensitive,
  after an optional `<?xml` prolog), return `.notDirect`.

**Interactions:** `attempt()` already sends `.notDirect` to `attemptFFmpeg`.
Confirm the bundled ffmpeg has the `dash` demuxer in
`scripts/build_media_stack.sh`.

**Tests:** in `DownloadReliabilityTests`, an MPD body with
`Content-Type: application/dash+xml` and another with
`application/octet-stream` both give `.notDirect`.

### Q7. Busy loop on worker call admission (#15)

**File:** `engine/src/main/kotlin/com/lagradost/macos/worker/WorkerRuntime.kt`
(~186).

**Change:** replace `yield()` with `delay(20)`.

**Risk:** none.

### Q8. Repeated "couldn't import saved repositories" banner during restore (#16)

**File:** `client/Sources/ViewModels/AppState.swift` (~355).

**Change:** record the generation that has already shown the legacy-import
failure (`legacyImportFailureShown: UInt64?`). Show the message only once per
engine generation. The import is still retried on later bootstrap passes, but
silently. Log every attempt.

### Q9. Progress-save error banner spam (#17)

**File:** `client/Sources/ViewModels/PlayerViewModel.swift` —
`persistProgress`.

**Change:**
- When `notify == false` (periodic writes): `do/catch`,
  `DaemonLog.client("player.progress_save_failed")`, and call `presentError` at
  most once per session. Use a `progressFailureShown` flag, reset in
  `startSession` and `close`.
- When `notify == true` (episode change, close): keep using `perform`, so a
  failure at a session boundary is still shown.

**Interactions:** `LibraryStore` keeps retaining unsaved positions in
`unownedProgress` and the journal, so no data is lost. Only the notification
frequency changes.

---

## Part 2 — Targeted correctness changes (moderate)

### M1. Streams that end without `done` count as success (#5)

**Files:** `client/Sources/Services/DaemonClient.swift` (~461),
`client/Sources/ViewModels/WindowSession.swift` (~113),
`PlayerViewModel.resolveLinks`, and the provider-test stream consumer
(diagnostics/extensions UI).

**Change:**
1. `consumeEvents` returns `Bool` (whether `done` arrived). Generalise its
   input from `URLSession.AsyncBytes` to `some AsyncSequence<String>` of lines
   so it can be unit-tested.
2. Each producer:
   `guard try await consumeEvents(...) || Task.isCancelled else { throw DaemonError.streamEnded }`.
   The new case reads: "The engine stopped before it finished. Try again." The
   404 fallback in `linksStream` already sends `done`.
3. `WindowSession` catch: set `searchResults = buffer` before setting
   `searchError`, so partial results stay visible next to the error. Check that
   the search view shows both rather than hiding results when `searchError` is
   set.
4. `PlayerViewModel.resolveLinks` needs no logic change. If links were
   collected it already starts with them; otherwise the message is now the
   accurate engine error.

**Compatibility:** all three NDJSON endpoints (`/search/stream`,
`/links/stream`, `/test/run`) already emit `done` (`MediaRoutes.kt` ~136, 319,
539).

**Tests:** in `DaemonClientTests`, feed lines without `done` → throws; with
`done` → completes; cancellation → no error.

### M2. Keep the finished file when the final rename fails (#3)

**Files:** `client/Sources/Services/DownloadService.swift` — `finalize`
(~1374), `reconcileFinalizing` (~1441), `fail` (~1488), `retry` (~558),
`upsertRecord` (~781); the `FailureReason` enum in
`client/Sources/Services/Downloads/DownloadPolicy.swift`.

**Change:**
1. Add `FailureReason.finalizeFailed(String)`, `.terminal`, labelled "Couldn't
   move the finished file into place — <detail>".
2. Factor the "rename the part file to its final name, then commit" sequence out
   of `reconcileFinalizing`'s second branch into one
   `commitFinalization(_:part:final:)`. `finalize` and `reconcileFinalizing`
   both use it.
3. `finalize` step 2:
   - if `moveItem` fails because the destination exists
     (`CocoaError.fileWriteFileExists`), compute a new `uniqueDestination` and
     retry once;
   - for any other error, call a new `failFinalization(item, reason)`:
     in-memory state `.failed` with `.finalizeFailed`, no deletion.
4. `upsertRecord`: while the reason is `.finalizeFailed`, persist status
   `finalizing` (not `failed`) with the reason text. Relaunch then goes through
   the existing `restorePersistedQueue` → `reconcileFinalizing` path and retries
   the rename automatically.
5. `fail()`: never delete `partURL` when the reason is `.finalizeFailed`. This
   is defensive; step 3 already avoids `fail()`.
6. `retry()`: if the reason is `.finalizeFailed`, call
   `reconcileFinalizing(item)` instead of requeueing. Requeueing would
   re-download, and `attemptFFmpeg` deletes the part file first.

**Compatibility:** no new persisted status values. `DownloadRecord` is
unchanged, and older builds already handle `finalizing` by reconciling.

**Risk:** an item that shows failed in the UI but is stored as `finalizing` in
the database is a deliberate mismatch. Document it at the `upsertRecord`
mapping.

**Tests:** in `DownloadReliabilityTests`, add a `.renameFails` point to the
existing `finalizationFault` hooks:
- the part file survives
- the record status is `finalizing`
- Retry completes the rename
- a simulated relaunch reconciles it

### M3. Strip credentials on cross-origin download redirects (#11)

**Files:** `client/Sources/Services/Downloads/DirectFileJob.swift` (~193), and
`client/Sources/Services/Playback/MediaResourcePolicy.swift` (~87) to expose its
`shareableHeaders` set internally.

**Change:**
1. Add a pure helper
   `redirectedRequest(_ new: URLRequest, from previous: URL) -> URLRequest?`.
   It validates the target with `MediaResourcePolicy.remoteURL`, which is
   stricter than the current scheme-only check. When the origin (scheme, host,
   port) changes, it removes every header not in `shareableHeaders`.
2. Keep `Range`, `If-Range` and `Accept-Encoding: identity`. Resume depends on
   them and they aren't credentials.
3. The delegate calls the helper and passes on its result.

**Interactions:** this matches what the engine relay already does
(`MediaRelay.open`) and what `relayResources` does for audio tracks.

**Risk:** a host that redirects to a CDN and expects the `Authorization` header
to follow will fail there and fall over to the next mirror. Signed CDN URLs, the
common case, are unaffected. Log `download.redirect_stripped_credentials` so you
can see whether it matters in practice.

**Tests:** unit-test the helper for same origin (headers kept), cross origin
(credentials dropped, Range kept) and a disallowed scheme (rejected).

### M4. Worker call can hang when the worker exits at the same moment (#8)

**File:** `engine/src/main/kotlin/com/lagradost/macos/worker/WorkerClient.kt`.

**Change:**
1. In `call()`, right after `pending[id] = entry`:
   ```kotlin
   if (exited.get()) {
       pending.remove(id, entry)
       throw WorkerFailure(CRASHED, killReason ?: "The extension process is not running.")
   }
   ```
   `handleExit` sets `exited` before it drains `pending`, so every interleaving
   either gets completed by the drain or sees the flag.
2. In `handleExit`, replace `pending.values.forEach { … }; pending.clear()` with
   a loop over a snapshot of keys that calls
   `pending.remove(k)?.deferred?.completeExceptionally(…)`. An entry added
   mid-drain is then never cleared without being completed.
3. Wrap `output.send(...)` in `call()`: `catch (e: IllegalStateException)` →
   throw `WorkerFailure(CRASHED, …)`, so callers get the failure type they
   already handle.

**Risk:** low. Behaviour only changes on the exit race.

**Tests:** in `WorkerPipeTest`, a worker that exits immediately after INIT, with
many concurrent calls → every call fails with CRASHED within the timeout and
none hangs.

### M5. Capacity wait turns fast failures into slow timeouts (#9, uncommitted)

**Files:** `engine/src/main/kotlin/com/lagradost/macos/worker/WorkerRuntime.kt`
(~276, `admit`), `WorkerHandle.ensure` / `start` / `call`, and
`engine/src/main/kotlin/com/lagradost/macos/ExtractorRouter.kt` (~138).

**Change:**
1. `admit(handle, maxWaitMs: Long = capacityWaitMs)`. Replace the fixed 30 s
   deadline with `maxWaitMs`.
2. Give `WorkerHandle.call` and `ensure` a `waitForCapacity: Boolean = true`
   parameter, passed through to `start()` → `admit`. When it's false,
   `maxWaitMs = 0` (the old immediate refusal).
3. In ExtractorRouter, pass `waitForCapacity = false` for nested extraction. The
   calling worker is the busy capacity, so waiting on it can only time out.
4. Lower the default `capacityWaitMs` to roughly the shortest normal operation
   budget, e.g. 10 s instead of 30 s, so search and home requests don't use
   their whole budget waiting.

**Interactions:** one in-flight `starting` deferred is shared by every caller of
`ensure()`. The wait policy of whichever caller created it applies to all of
them. Document that. Nested callers get a fast refusal at worst, which matches
their old behaviour.

**Tests:** in `WorkerAdmissionTest` (already modified on this branch), nested
extraction at full capacity → immediate `WorkerCapacityException`; a top-level
call → waits, then is admitted when a slot is released.

### M6. Relay sessions leak when a registration is cancelled (#12)

**Files:** `PlayerViewModel.beginRelayedLoad` / `releaseRelay` (~781, ~812),
`DownloadService.attemptFFmpeg` (~1291), and optionally the engine's
`MediaRelay.kt` (~84).

**Change:**
- **M6a, player:** `releaseRelay` keeps bumping `relayToken` but stops
  cancelling `relayTask`. The registration finishes, and the existing token
  check revokes the stale session. Keep the cancel only in `close()`, and shield
  the network call there too: run `register` in an unstructured `Task` whose
  `.value` is awaited, then revoke if the result is stale.
- **M6b, downloads:** wrap `registerMediaRelay` in the same shield. A pause or
  cancel during registration then revokes the session instead of leaking it.
- **Engine backstop (optional, small):** record `everRead` on `Session`. A
  session that has never been read can be evicted after 10 s instead of 60 s.
  This covers clients that crash between registering and first reading.

**Risk:** low. A registration that can no longer be used finishes and is revoked
at once.

**Tests:** `MediaRelayTest` for eviction of a never-read session;
`PlayerRemediationTests` for five rapid relayed mirror switches → at most one
live session.

### M7. Engine restart drops the stream keep-alive (#18)

**File:** `client/Sources/ViewModels/PlayerViewModel.swift` (~804,
`engineReconnected`).

**Change:** add a second branch. When there's no relay but the current link has
`extractorData`:
- set `verifierJobID = nil` (the old engine's job is gone, so don't send it a
  stop);
- call `ownVerifier(for: currentLink)` if
  `session.localResource == nil && session.persistsProgress`.

The relay branch already calls `ownVerifier` through `failover` → `commitLoad`.
Downloads keep their current behaviour: a dead link fails over and re-resolves.
Note that in the code.

**Tests:** a fake `startVerifier` called again after `engineReconnected()`.

### M8. Keychain reads on the main actor (#19)

**File:** `client/Sources/Services/ProviderCredentialStore.swift` (~44).

**Change:** in `resendAll`, read `storedProviderIds()` and each
`credential(for:)` inside `Task.detached(priority: .utility) { … }.value`. The
functions are plain static members of a non-isolated enum and use a `Mutex` for
isolated mode, so they can already run off the main actor.

**Risk:** none. Ordering is preserved because the loop awaits each read.

### M9. Random engine port isn't checked (#20)

**File:** `client/Sources/App/DaemonSupervisor.swift` — `makeBundledLaunch`.

**Change:** pick the port by binding a socket to `127.0.0.1:0`, reading the port
and closing the socket. Fall back to the current random choice if that fails.
The tiny race that remains doesn't matter.

**Alternative (not recommended):** a distinct engine exit code meaning "port in
use" plus a supervisor retry that doesn't count against the budget. It's more
code on both sides for the same result.

---

## Part 3 — Architectural changes

### A1. Dedicated connection pools for engine IPC (#1)

**Files:** `client/Sources/Services/DaemonClient.swift` (lines ~271, 346, 358,
487, 499, 507) and `client/Sources/App/DaemonSupervisor.swift` (~420).
`URLSession.shared` stays as it is for `SearchSuggestionService`, which talks to
remote hosts.

**Change:**
1. Add `DaemonClient.ipcSession`, a static ephemeral configuration:
   - `httpMaximumConnectionsPerHost = 24`
   - `connectionProxyDictionary = [:]`, so loopback never goes through a proxy
     or PAC file
   - `urlCache = nil`, `httpCookieStorage = nil`, `httpShouldSetCookies = false`
   - `waitsForConnectivity = false`
   - keep the per-request `timeoutInterval = 600` that `makeRequest` already
     sets
2. Replace all six `URLSession.shared` uses in `DaemonClient`, including the
   `bytes(for:)` streams.
3. Add `DaemonSupervisor.healthSession`, a separate ephemeral pool with
   `httpMaximumConnectionsPerHost = 2`, no proxy and a 5 s timeout. Health
   probes then never queue behind application traffic.
4. Log probe latency in `isHealthy` when it's over 1 s (`daemon.health_slow`).
   Future false restarts can then be told apart from real hangs.

**Interactions:**
- The engine's Netty side handles long polls as suspended coroutines, so more
  concurrent connections cost little.
- `RateLimiter` buckets are per endpoint group and unaffected.
- Tests don't intercept `URLSession.shared` (no `URLProtocol` use in
  `client/Tests`), and supervisor tests inject `healthProbe`, so nothing breaks.

**Not recommended now:** merging the three long polls into one `/pending`
endpoint. It needs a new engine route and an IPC version bump, and once the
pools are separate it fixes nothing further.

**Risk:** low.

**Validation:** with playback running, two downloads resolving and a search in
progress, health latency should stay well under 1 s. Watch the new log line or
`DiagnosticsView`.

### A2. Send credentialed manifest downloads through the relay (#2)

**Files:** `client/Sources/Services/DownloadService.swift` (~1279–1340,
`attemptFFmpeg`; ~1717, `ffmpegArguments`), `DownloadPolicy.FailureReason`, and
the engine's `MediaRelay.kt` (`MAX_SESSIONS`).

**Change:**
1. Drop the `!isManifest` condition. Any link with `Authorization`, `Cookie` or
   `Proxy-Authorization` headers is registered with the relay.
2. Change `ffmpegArguments(link:outputPath:format:)` to take the input kind from
   the original link. A relay URL (`/media/relay/<hex>`) has no extension, so
   `DownloadPolicy.isHLS(url:type:)` would wrongly report "not HLS" and drop the
   HLS input options. Add an `isHLS: Bool` parameter, computed from the original
   URL and type before rewriting. The relay already serves
   `application/vnd.apple.mpegurl` / `application/dash+xml`, so ffmpeg's probe
   also succeeds.
3. If registration fails (capacity or a rejected resource), fail closed with a
   new `FailureReason.relayUnavailable` (`.retrySameMirror`, then the next
   mirror). Don't fall back to sending the credentials straight to ffmpeg; that
   is the bug being fixed.
4. Engine: raise `MAX_SESSIONS` from 4 to 12. Today one player session plus 4
   credentialed downloads would exhaust it. Memory per session is a few small
   maps.

**What already works, verified by reading:**
- `ManifestRewriter` rewrites HLS `URI="…"` attributes (keys, maps, media), so
  AES-128 keys go through the relay.
- DASH manifests with absolute segment templates are refused
  (`Unsupported("absolute …")`). Those downloads will now fail with
  `relayUnavailable` instead of leaking.
- Lock behaviour is unchanged: `/media/relay` registration is in
  `DaemonLock.downloadPaths`, and relay reads bypass the lock.
- Engine restart mid-download: the relay URLs die, ffmpeg hits a network error,
  then `retrySameMirror` with `forceResolve` re-registers.

**Risks:**
- **Some catalogs that download today will start failing.** Causes:
  `MAX_DIRECTORIES = 64` on CDNs that use a separate directory per segment,
  absolute DASH templates, and the relay's 30 s read timeout. Before you merge,
  run `scripts/catalog_compat_run.py` against credentialed HLS/DASH providers,
  then decide whether to raise `MAX_DIRECTORIES`.
- Throughput: segments now pass through the engine JVM, which has a 64 KB buffer
  and a 64 MB direct-memory cap. With 3 or more parallel HLS downloads, check
  the engine's CPU and heap.

**Depends on:** A1 (more relay registrations go over IPC), M6b (no leaked
sessions), Q3 (HEAD).

---

## Deferred, with reasons

- **#21 comma-joined filter:** no caller passes `plugins` today. Fixing it means
  changing the wire format (repeated `plugins=` parameters or a JSON body), so
  do it only when a filtered search is added.
- **#22 `F_FULLFSYNC`:** JDK 17 can't call `fcntl(F_FULLFSYNC)` without JNA or
  FFM. Write it down as an accepted durability limit in `docs/Maintenance.md`
  and revisit when the engine moves to JDK 22+.
- **Minor engine items noted during the audit but not listed as findings:**
  `answerWebView` labels a malformed request as `capacity`, and `loadHome`
  records the timeout twice. Fix them opportunistically when touching those
  files.

## Decisions to make

1. **A2 fail-closed policy:** fail a credentialed download that can't be relayed
   (recommended), or keep today's direct fallback behind a setting?
2. **Player exposure:** mpv probably sends `http-header-fields` to every segment
   host of an HLS stream, the same pattern as #2 (not verified). Should playback
   of credentialed manifests also go through the relay? It would reuse A2's
   engine work, but changes playback for many providers, so decide separately
   after A2's compatibility run.
3. **M5 default wait:** is 10 s acceptable for `capacityWaitMs`, or should it be
   derived per operation from the provider's timeout hints?

## Verification for each change set

- **Engine:** `./gradlew :engine:test`, with new cases in `ResourceTableTest`,
  `CatalogEntriesTest`, `MediaRelayTest`, `WorkerPipeTest`,
  `WorkerAdmissionTest` and `DaemonLockTest`.
- **Client:** the `CloudStreamMac` scheme tests (`make test-client`), with new
  cases in `DaemonClientTests`, `PlayerRemediationTests` and
  `DownloadReliabilityTests`.
- **End to end after change sets 3, 4 and 6:** `scripts/smoke_launch.sh`, plus a
  manual run: play a relayed split stream, restart the engine from the menu,
  confirm the stream resumes and the keep-alive restarts, and confirm downloads
  continue or fail over cleanly.
