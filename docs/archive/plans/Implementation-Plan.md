# CloudStream macOS — Verified-Defect Implementation Plan

> **Superseded (4 October 2026).** Kept for history; its open rows date from September and are largely fixed. The single list of open work is [Remaining-Work.md](../../Remaining-Work.md).


**Status:** Proposed — **rev 3** (updated after the 2nd-pass review against the current tree; see Revision History)
**Date:** 2026-09-29
**Scope:** All issues confirmed by the rigorous code review + fact-check pass (`Remediation-Plan.md` supersedes nothing; this document is the executable form of the *verified* register). False positives from review passes — mirror-failover dead code, HUD staleness, `total_size` semantics, the stdin watchdog race, Safari cookie attribution, and `URLSanitizer` ref-shadowing (V-13) — are explicitly **out of scope**; they were retracted.

**Rev 3 note:** the tree changed materially between the 1st and 2nd review passes (parallel fixes landed: plugin install/uninstall lifecycle, `installAll` sync, shortcode repos, per-provider search filters, mute persistence, mpv log plumbing). Every V-item below was re-verified against the **current** code; items fixed by that parallel work are marked ✅ SHIPPED and pruned from workstreams. The 2nd pass also added 15 new verified findings (N1–N15), incorporated as WS-11/WS-12/WS-13.

## Revision History

| Rev | Date | Change |
|-----|------|--------|
| 1 | 2026-09-29 | Initial plan from fact-check pass (V-01…V-28). |
| 2 | 2026-09-29 | V-13 retracted (URLSanitizer false positive); WS-8 retired; V-18 rescoped after `unmarkPluginRemoved` shipped. |
| 3 | 2026-09-29 | 2nd-pass re-verification against the changed tree: marked V-18 ✅ partially shipped; rescoped WS-5.6; added WS-11 (episode advance, N1/N2), WS-12 (repo trust chain, N7/N8/N9), WS-13 (plugin persistence + engine-state races, N13/N5/N6); recorded N3–N6, N10–N12, N15 into existing workstreams; refreshed execution order and merge train. |

## Status legend

- **OPEN** — verified present in current code, not yet fixed.
- **✅ SHIPPED** — fixed by parallel work already merged in the tree (verified 2026-09-29); kept for the audit trail only.
- **PARTIAL** — some fix landed; residual scope listed.

**Source of truth for verified defects:**

| ID | Severity | Status | One-line summary |
|----|----------|--------|------------------|
| V-01 | P0 | OPEN | Local downloaded files cannot be played back (local path fed to daemon `/links`) |
| V-02 | P0 | OPEN | Resume seek races mpv `loadfile`; position silently discarded |
| V-03 | P0 | OPEN | Watch progress keyed per **title**, not per episode; Android parity break |
| V-04 | P0 | OPEN | Download mirror failover loops on the same mirror (`activeLinkIndex` reset in `process`) |
| V-05 | P0 | OPEN | NDJSON search stream byte-wise decoding corrupts multi-byte UTF-8 |
| V-06 | P1 | OPEN | Daemon provider overrides (`overrideWithNewData`) never re-applied after daemon restart (`overrideFor` still has zero call sites in `Main.kt`) |
| V-07 | P1 | OPEN | `/plugins` `verified` flag: any signed repo marks every plugin verified (`repoTrust(...) \|\| repos.any { it.signed }` still present) |
| V-08 | P1 | OPEN | Cancel during `.resolving` spawns ffmpeg anyway; no resolution-abort token |
| V-09 | P1 | OPEN | Cancelled downloads reclassified as `failed` by termination handler |
| V-10 | P1 | OPEN | Daemon never adopted after slow start (timeout → `.error`, heartbeat never installed) |
| V-11 | P1 | OPEN | `cleanupStrayDaemons` kills any matching process on the machine; two app instances ping-pong |
| V-12 | P1 | OPEN | Solve bridge submits/caches non-clearance cookies from app's persistent cookie store (`WKWebsiteDataStore.default()` + `contains("cf_")` confirmed unchanged in `WebViewSolverService.swift`) |
| V-13 | — | [RETRACTED] | `URLSanitizer` ref-shadowing (false positive) |
| V-14 | P2 | OPEN | `SolveInterceptor` `catch { true }` + 90 s `runBlocking` park: solve-task spam, thread starvation |
| V-15 | P2 | OPEN | Rate limiter: `solve`/`write` groups unused; `/solve/*`, `/diagnostics`, `/plugins` unthrottled |
| V-16 | P2 | OPEN | `MetalVideoView.deinit` frees mpv render context off-main (use-after-free window) |
| V-17 | P2 | OPEN | `sub-file` option overwritten in loop — only last subtitle loads |
| V-18 | P2 | PARTIAL | `unmarkPluginRemoved` + install-path un-marking shipped; **remaining**: restore endpoint for plugins removed without a later install, and `.cs3`/`.jar` pruning for long-removed hashes |
| V-19 | P2 | OPEN | No size cap on repository manifest / plugin downloads (DoS) — `fetchUrlBytes`/`fetchUrlText` unbounded in current `RepositoryService` |
| V-20 | P2 | OPEN | NDJSON writer shared across `async` coroutines without serialization (still unsynchronized in current `Main.kt`) |
| V-21 | P2 | OPEN | Download `classifyFailure` substring match false-positives (e.g. "403" inside a URL) |
| V-22 | P2 | OPEN | No restart backoff on daemon crash loop |
| V-23 | P3 | OPEN | "Mark as Watched" only zeroes progress (does not set `.completed`) |
| V-24 | P3 | OPEN | Sub+dub duplicate episode rows (no DubStatus separation) |
| V-25 | P3 | OPEN | Quality label buckets mislabel `Unknown(400)` as "480p" |
| V-26 | P3 | OPEN | Daemon slow-start timeout treats still-running process as failure state (same root as V-10) |
| V-27 | P3 | OPEN | Repo sync offline false-negative in onboarding when engine not yet ready |
| V-28 | P3 | OPEN | Episode sort ignores `airDate`/`score` (Android parity) |
| N-01 | P0 | OPEN | **[2nd pass]** Next-episode advance selects the *other audio variant* of the same episode for anime (`playNextEpisode` advances through the unfiltered `details.episodes`; daemon orders sub-list before dub-list) |
| N-02 | P0 | OPEN | **[2nd pass]** `END_FILE` → `playNextEpisode()` can double-advance: old session stays live during async `/links` resolution, `keep-open=yes` EOF pause + Space re-fires END_FILE |
| N-03 | P2 | OPEN | **[2nd pass]** `MpvPlayerView.updateNSView` pushes `isPlaying` into mpv on every SwiftUI update — state echo loop with mpv's own `pause` property |
| N-04 | P2 | OPEN | **[2nd pass]** Solver `didFail` navigation → same task retried every 2 s for the daemon's 90 s TTL (no per-task attempt tracking; `startSolvePolling` loop) |
| N-05 | P1 | OPEN | **[2nd pass]** Out-of-order endpoint completion in `AppState.observeEngine`: stale iteration can overwrite `.ready` with `.error` after a newer spawn already won (needs generation counter) |
| N-06 | P2 | OPEN | **[2nd pass]** `startSolvePolling` retargets all pending tasks each poll while `WebViewSolverService.solve()` drops all but the first — retry storm against a dead challenge URL |
| N-07 | P1 | OPEN | **[2nd pass]** `RepositoryService.parseRepoUrl` performs network I/O (cutt.ly / py.md shortener follow) inside `sync()`, which `reTrust()` also calls — a trust action silently follows a URL shortener and re-pins TOFU to the result |
| N-08 | P1 | OPEN | **[2nd pass]** `fetchVerifiedCs3` loads plugins with **no** manifest hash (warn-only), and `installPlugin` constructs hash-less `SitePlugin`s from arbitrary URLs — SEC-07 gate regressed from mandatory to optional |
| N-09 | P1 | DONE (RT-09) | **[2nd pass]** `fetchUrlBytes` sends forged `x-robot-challenge-berlin=passed` cookie to Codeberg — brittle, ToS risk, impersonates a solved challenge |
| N-10 | P2 | OPEN | **[2nd pass]** `findLoadedByInternalNameOrManifest` matches `filename.contains(internalName)`, but `filename` is a hash-named `.cs3` path — effectively only `manifestName` matches; same-named manifest forks unload each other on install |
| N-11 | P3 | OPEN | **[2nd pass]** Ghost plugin entries: `uninstallPlugin` deletes `.cs3` but `pluginsJson` metadata persists until next sync; `getRepoPlugins` can report `isInstalled=true` for an unloaded plugin |
| N-12 | P3 | OPEN | **[2nd pass]** `PipService.toggle()` mutates state nothing observes — PiP button is a no-op |
| N-13 | P1 | OPEN | **[2nd pass]** Individually-installed plugins are never written into any `PersistedRepository.pluginsJson` — lost on daemon restart unless the repo list happens to cover them (`bootFromCache` requires a `fileHash`) |
| N-14 | P3 | OPEN | **[2nd pass]** Solver force-unwraps `URL(string: "about:blank")!` and burns the full 45 s deadline polling a blank page |
| N-15 | P3 | OPEN | **[2nd pass]** Global `audio-channels=stereo` + `audio-format=s32` downmix all content — documented tradeoff, revisit per-title |

---

## Guiding principles

1. **One workstream = one PR-shaped unit** with its own test plan. No PR mixes workstreams.
2. **IPC contract is frozen at v2.** Every change below is backward-compatible with the current `HealthDto.expectedIpcVersion = 2`. Only WS-10 may bump to v3, behind a negotiated handshake.
3. **No behavior change without a regression test.** Swift changes get unit tests where reachable via the existing `PlayerTransport` seam and `CS_IN_MEMORY_DB` SwiftData flag; Kotlin changes extend the existing `engine/src/test` suite (`cs.cloudstream.home` temp-root harness).
4. **Fail-open vs fail-closed decided per issue.** Solve-cookie changes fail *closed* only where a wrong decision cannot brick legitimate streams (V-12). Adoption/liveness fixes fail *open* (V-10) — availability over strictness.
5. **Observability first.** Every fix ships with a structured log event (`DaemonLog` / `DaemonLog.client`) so the fix itself is verifiable in production logs.

---

## WS-1 — Player correctness (V-01, V-02, V-16, V-17, V-23)

### 1.1 Local-file playback (V-01) — `PlayerViewModel`, `DownloadsView`

**Design.** Introduce an explicit playback source enum instead of overloading `movieData`:

```swift
enum PlaybackSource {
    case remote(provider: String, data: String)   // goes through daemon /links
    case localFile(URL)                           // direct mpv loadfile, no daemon
}
```

* `PlayerViewModel.play(details:episode:resumeAt:preferences:source:)` gains `source` (default `.remote` computed from `details.movieData` for backward compatibility with all existing call sites).
* For `.localFile`: skip `DaemonClient.links` entirely; synthesize a single `StreamLinkDto(url: fileURL.absoluteString, name: "Local file", source: "Local", quality: 0, type: "direct", headers: [:], extractorData: nil, isPlaylist: false, playlist: [])`, build `Session` with `links: [thatDto]`, `subtitles: []`. Mirror failover is a no-op for single-link sessions (`handlePlaybackError` already guards `links.indices.contains(next)`).
* `DownloadsView.play` action builds `PlaybackSource.localFile(record.destinationURL)` and also passes `durationSeconds` through `details.durationMinutes` (already does).
* Guard: if the file was deleted between tap and play, surface `error = "File missing on disk"` and return before creating a session.

**Tests.** Unit-test `PlayerViewModel` with a fake `PlayerTransport` (existing seam): local source produces a session with exactly one link whose `url` has `file://` scheme; missing file produces `error != nil` and `session == nil`.

### 1.2 Resume seek timing (V-02) — `MetalVideoView`

**Design.** Replace the fire-and-forget post-`loadfile` seek with mpv's `start` property, set **before** `mpv_initialize` (per-file via `loadfile` local options is the alternative; `start` before init is simpler and correct here because the view owns one file per mpv instance):

```swift
if let seconds, seconds > 1 {
    mpv_set_option_string(mpv, "start", String(format: "%.2f", seconds))
}
```

placed in `setup()` before `mpv_initialize`. Remove the post-load `seek(absolute)` command entirely. Rationale: `start` is consumed by the demuxer at open time — no race, no event plumbing.

* Additionally: guard `loadStream()` (failover path) the same way — it currently does `seek(to:)` after `loadfile replace`; switch to passing `start=` via `loadfile`'s options parameter: `["loadfile", url, "replace", "0", "start=\(seconds)"]` (mpv ≥ 0.38 positional index form; verify against bundled 0.41.x — fallback: `set_property "start"` before the command and clear after `file-loaded`).
* `PlayerViewModel.seek(to:)` continues to work for user scrubs (post-load seeks are fine); only **initial** load uses `start`.

**Tests.** Not unit-reachable without mpv; covered by a manual QA script (below) + an integration smoke target flagged `[LongRunning]`.

### 1.3 Render-context teardown race (V-16) — `MetalVideoView`

**Design.**
* Move all teardown into a `teardownIfNeeded()` that must run on the main actor (both `deinit` and `shutdown()` funnel into it; `deinit` uses `DispatchQueue.main.async` + retain hop via `Unmanaged.passRetained(self)` pattern already present for `RenderUpdateContext` — but simpler and stricter: make `deinit` assert `Thread.isMainThread` in DEBUG and perform the same three-step detach (update-callback nil, render-context free, wakeup-callback nil) synchronously, because view teardown is already main-thread-bound by AppKit's `dismantleNSView`).
  Concretely: `dismantleNSView` already calls `shutdown()` on main. **The only off-main path is `deinit`** — so the fix is: `deinit` only nils weak refs and enqueues the C teardown onto the main queue with the retained context pointers moved into the closure (retain them for the closure's lifetime):

```swift
deinit {
    let renderContext = self.renderContext
    let mpvHandle = self.mpvHandle
    let corePtr = self.coreRetainedPtr
    let updatePtr = self.renderUpdateContextPtr
    DispatchQueue.main.async {
        // detach callbacks first, then free — same order as shutdown()
        ...
    }
}
```

  `shutdown()` remains the synchronous main-actor path used by `dismantleNSView`; it nils the stored pointers so a later `deinit` finds nothing to free (idempotent).
* Add a `static var activeInstances` DEBUG-only leak counter (inc in `setup`, dec in `shutdown`/teardown closure) to catch leaks in CI.

**Tests.** DEBUG assertion + leak counter; manual QA: open/close player 50× under `MallocStackLogging` in dev build; memory flat, no CrashReporter hits.

### 1.4 Subtitle loading (V-17) — `MetalVideoView.setup`

**Design.** Replace the `sub-file` option loop with post-init `sub-add` commands:

```swift
mpv_initialize(mpv) // existing
for subtitle in subtitles.prefix(16) {
    var argv = Self.cArgs(["sub-add", subtitle.url, "auto", subtitle.label ?? subtitle.language])
    mpv_command(mpv, &argv)
    Self.freeArgs(argv)
}
```

* `auto` flag keeps default-selection behavior; title arg gives the HUD track picker real labels (bonus fix: HUD currently shows raw track labels only).
* Keep `prefix(16)` cap.

**Tests.** Unit: `cArgs` round-trip for label strings with spaces/CJK (grapheme-safe, `strdup` handles UTF-8). Manual: multi-subtitle episode shows all tracks in the captions menu.

### 1.5 "Mark as Watched" (V-23) — `DesignSystem.ContinueWatchingCard` + `LibraryStore`

**Design.** `ContinueWatchingCard` gains a third closure `onMarkWatched`. `HomeView` implements it as:

```swift
LibraryStore.shared.upsertLibraryEntry(details: LibraryStore.shared.detailsPreview(for: item), watchType: .completed)
LibraryStore.shared.removeProgress(id: item.id)
libraryRevision += 1
```

* `detailsPreview` already fabricates the `DetailsDto` used by `LibraryView` context menus — reuse it so the id-keying (`provider|url`) matches.
* `removeProgress` is called after the upsert so `recordProgress` during a concurrent playback session can't resurrect the row with a stale fraction (upsert sets `watchTypeRaw = 2`; `removeProgress` zeroes `progressSeconds`; `continueWatching` filters `.watching` only, so the row leaves the shelf regardless).

**Tests.** Unit with `CS_IN_MEMORY_DB=1`: mark-watched on an in-progress row → `items(withWatchType: .completed)` contains it, `continueWatching` doesn't.

---

## WS-2 — Progress & library model (V-03, V-28-parity groundwork)

### 2.1 Per-episode progress (V-03) — `StoredMediaItem`, `LibraryStore`, `MediaDetailView`

**Design.** Follow Android's model (`DataStoreHelper.setViewPosAndResume` keys by episode id) while keeping the SwiftData schema migration-cheap:

* Add two fields to `StoredMediaItem`: `episodeProgress: [String: EpisodeProgress]?` is **not** SwiftData-friendly; instead add a second `@Model`:

```swift
@Model final class EpisodeProgressRecord {
    @Attribute(.unique) var id: String        // "\(provider)|\(url)|\(deterministicHash(episodeData))" — deterministic across launches (Swift's String.hash is SipHash-randomized per execution)
    var parentID: String                      // "\(provider)|\(url)" → StoredMediaItem.id
    var episodeData: String
    var season: Int?
    var episode: Int?
    var progressSeconds: Double
    var totalDurationSeconds: Double
    var updatedAt: Date
}
```

  Episode key: use `episodeData` itself when stable (CloudStream `Episode.data` is the provider's canonical per-episode identifier — this is exactly what Android stores). If a provider emits unstable `data` (rare), the season/episode fallback matching in `play()` already covers resume; the record is simply keyed by data and naturally orphaned — acceptable. Deterministic hashing: use SHA-256 / SHA-1 hex or the raw `episodeData` string directly for `id`, never Swift's standard `String.hash` / `hashValue` which is SipHash-salted per app launch.

* `LibraryStore.recordProgress(details:episode:...)`: when `episode != nil`, write the `EpisodeProgressRecord` (upsert by `id`) **and** keep updating the title row's `lastEpisodeData/lastSeason/lastEpisode/lastUpdated` (for Continue Watching shelf metadata) but **stop** overwriting `progressSeconds/totalDurationSeconds` on the title row with episode values; set title-row progress only for movies (`episode == nil`).
* New `LibraryStore.resumeFor(details:episode:)` lookup: exact `episodeData` → else season/episode match → else nil (mirrors `MediaDetailView.play()` matching, moved into the store so both call sites share it).
* `MediaDetailView.play()`: per-episode resume lookup replaces title-level `resume.progressSeconds`; "Resume" pill shows when *any* episode has `progressSeconds > 10`.
* `HomeView.resume(item:)`: passes `item.lastEpisodeData` through to the new lookup.
* Migration: schema is additive (new model); SwiftData lightweight migration handles it. Update `LibraryStore.init()` to register `Schema([StoredMediaItem.self, DownloadRecord.self, EpisodeProgressRecord.self])`. Continue Watching shows the last episode's data from the title row — old progress for previously-watched episodes is not backfilled (documented; acceptable for a v1.1 desktop client).
* Pruning: cap `EpisodeProgressRecord` rows per parent at 100 (delete oldest by `updatedAt` on write) to bound growth.

**Tests.** In-memory DB unit tests: two episodes of same title get independent positions; title row untouched by episode writes; resume lookup prefers exact `episodeData`, falls back to season/episode; pruning keeps ≤100.

### 2.2 Episode sort parity groundwork (V-28)

* `MediaDetailView` `newestFirst` toggle becomes a 3-way menu: Oldest/Newest/Most recent aired, sorting by `($0.episode ?? .max)` and `($0.date ?? 0)` respectively. (Rating sort deferred; `date` is present in `EpisodeDto`.)

---

## WS-3 — Download pipeline (V-04, V-08, V-09, V-21)

### 3.1 Failover loop (V-04) — `DownloadService`

**Design.** Make the attempt cursor authoritative and resolution idempotent:

1. Split `process(item)` into `resolveIfNeeded(item)` and `spawnFFmpeg(for:)`.
2. `resolveIfNeeded` runs only when `item.orderedLinks.isEmpty` (first attempt) — it must **not** touch `activeLinkIndex`.
3. `drainQueue` picks `.queued` items; after a failed ffmpeg attempt the handler sets `.queued` with the incremented `activeLinkIndex`; `drainQueue` routes straight to `spawnFFmpeg` (no re-resolution) because `orderedLinks` is non-empty.
4. `process` disappears; `enqueue`/`restorePersistedQueue` → `.queued`; loop body:

```swift
while activeProcesses.count < maxConcurrent,
      let item = queue.first(where: { $0.state == .queued }) {
    if item.orderedLinks.isEmpty { await resolveIfNeeded(item) }   // may fail → .failed
    if item.state == .queued { spawnFFmpeg(for: item) }            // uses activeLinkIndex as-is
}
```

5. Attempt cap: `maxAttempts = max(orderedLinks.count, 3) * 2`; when `activeLinkIndex >= orderedLinks.count` after wrap-avoidance, mark `.failed` with the classified reason (exhausted).

**Tests.** Fake `DaemonClient` seam (inject a `linksResolver: (String, String) async throws -> LinksResponseDto` closure into `DownloadService.init` — default is the daemon client): first mirror always fails → second mirror attempted without a second `/links` call; resolution failure → `.failed` without ffmpeg spawn; cancel during resolution → no spawn (see 3.2).

### 3.2 Cancellation correctness (V-08, V-09) — `DownloadService`

**Design.**
* Add `private var cancelledIDs: Set<UUID>` (main-actor state). `cancel(item)`: if `item.state == .resolving`, insert id, set `.cancelled`, return (no process to kill). In `resolveIfNeeded`, immediately after the `await` returns: `guard !cancelledIDs.contains(item.id) else { cancelledIDs.remove(item.id); return }` — the item stays `.cancelled`, nothing spawns. Also support real cooperative cancellation: hold the `Task` handle per resolving item (`resolvingTasks: [UUID: Task<Void, Never>]`) and cancel it in `cancel()` so the HTTP call aborts; the post-await guard is the backstop.
* Termination handler: restructure so the cancelled state is sticky:

```swift
if exitStatus == 0 { ...completed... }
else if item.state == .cancelled { /* stay cancelled; do not requeue, do not fail */ }
else if item.activeLinkIndex + 1 < item.orderedLinks.count { item.activeLinkIndex += 1; item.state = .queued; ... }
else { item.state = .failed; item.failureReason = classify(...) }
```

  (`cancel()` for a *downloading* item keeps terminating the process; the handler now respects `.cancelled`.)
* `pause/resume` on a suspended ffmpeg: keep `suspend()/resume()` but add a stall watchdog — if a paused process is still `.paused` after 30 min, auto-cancel with reason "paused too long" (prevents indefinite socket holds). Configurable constant, not user-facing.

**Tests.** Unit (with fake resolver + fake process runner seam): cancel during resolve → `.cancelled` persisted, no ffmpeg; cancel during download → `.cancelled` after handler, record status 6; cancel → resume → cancel sequence invariants.

### 3.3 Failure classification (V-21) — `DownloadService.classifyFailure`

**Design.** Match on ffmpeg's own log grammar instead of raw substrings: ffmpeg prints `HTTP error 403 Forbidden` / `Server returned 404 Not Found` / `Protocol not found` / `No space left on device` as complete log lines. Parse the stderr tail line-by-line; a status code must appear in a line containing `HTTP error` or `Server returned`, or as `error 403`/`error 404` adjacency. Keep the existing keyword checks for `No space left` / `Protocol not found` (those phrases don't appear in URLs). Unit-test with real ffmpeg stderr samples (fixture strings), including a URL containing "403" that must **not** classify as forbidden.

### 3.4 Progress honesty (V-21-adjacent, already correct core)

* Keep `total_size` handling (verified correct). Add file-size stat every 5 s via `FileManager.attributesOfItem` as a cross-check displayed only when `total_size` is absent (playlists). No behavior change otherwise.

---

## WS-4 — Engine adoption & supervisor (V-10, V-22, V-26, V-11)

### 4.1 Slow-start adoption (V-10/V-26) — `DaemonSupervisor`

**Design.** `awaitHealthy` never dead-ends: on timeout with a still-running process, install the heartbeat in "adoption mode" instead of erroring:

```swift
// after the 20s deadline:
if process?.isRunning == true {
    // slow start (CDS miss, cold dex2jar) — keep waiting via heartbeat with relaxed cadence
    startHeartbeat(endpoint: endpoint, adoptionMode: true)   // 5s interval, no miss-triggered restart until first success
} else {
    restart()
}
```

* `startHeartbeat(adoptionMode:)`: on first successful `/health`, publish the endpoint (`state = .ready`, `endpointContinuation.yield`), then switch to the normal 3 s cadence. In adoption mode, misses only log (no restart) until first success — a slow daemon gets as long as it needs; a *crashed* one is caught by the `terminationHandler`.
* Keep user-facing `.error` only for spawn failure or process exit (real errors).

### 4.2 Restart backoff (V-22) — `DaemonSupervisor`

**Design.** Exponential backoff on consecutive unexpected exits: delay = `min(2^restartCount * 1.0, 30) s` before `spawn()` in the `terminationHandler` path and in heartbeat-triggered restarts. Reset the backoff counter when a spawn reaches `.ready`. Cap `restartCount` used for backoff at 6. Log `daemon.backoff` with the delay. (The existing `restartCount` becomes the backoff input; UI unchanged.)

### 4.3 Stray-process scoping (V-11) — `DaemonSupervisor`

**Design.** Replace `pgrep -f` kill with identity verification:

1. Enumerate candidate PIDs via `pgrep -f "daemon.jar|com.lagradost.macos.MainKt"` (unchanged discovery).
2. For each PID, read `ps -p <pid> -o ppid=` — claim only processes whose parent chain terminates at **our own** `launchd`-owned session *and* whose start time is older than the current app launch (i.e. orphans of a previous run of this app). Simplest robust proxy: `ppid == 1` (reparented orphan) — daemons we or a dead app instance spawned become children of launchd when the parent dies.
3. Never kill processes whose `ppid` is another live GUI app. If in doubt, log and leave.
4. Two-instance ping-pong: additionally write the daemon's listening port + app instance UUID into `~/.cloudstream-macos/state/instance.json` at spawn; `cleanupStrayDaemons` skips PIDs whose port file maps to a live instance whose app PID is still alive (checked via `kill(pid, 0)`). Belt-and-braces; the ppid check is the primary gate.

**Tests.** Not unit-reachable (process semantics); covered by a shell-based QA script: spawn decoy `java -jar other.jar` → not killed; orphaned daemon (kill parent) → killed on next launch.

---

## WS-5 — IPC contract & daemon state (V-06, V-07, V-15, V-20, V-19, V-18)

### 5.1 Provider override re-application (V-06) — `ProviderExecutor`/`Main.kt`

**Design.** After `DaemonState.load()` and `RepositoryService.bootFromCache()` in `main()`, before the server starts:

```kotlin
fun applyPersistedOverrides() {
    for (provider in PluginBridge.allProviders()) {
        DaemonState.overrideFor(provider.name)?.let { override ->
            provider.overrideWithNewData(
                ProvidersInfoJson(
                    name = provider.name,
                    url = override.url ?: provider.mainUrl,
                    credentials = override.credentials ?: provider.storedCredentials,
                    status = 1,
                )
            )
        }
    }
}
```

* Call site order matters: `NetworkSetup.install()` → `DaemonState.load()` → `bootFromCache()` → `applyPersistedOverrides()` → server start.
* Edge: plugin loaded later via `/repos/sync` — extend `Main.kt`'s sync loop to call the same re-application for the newly loaded providers (small helper reused).
* Note: `/plugins/config` currently persists `url = request.url` (null when the client sends null to clear) — keep behavior, but normalize: `setProviderOverride(provider, if (url == null && credentials == null) null else override)` so clearing works.

**Tests.** Extend `DaemonStateTest` + a new `OverrideReapplicationTest` with a fake `MainAPI`: override persisted → `applyPersistedOverrides` → `mainUrl` equals override; no override → untouched.

### 5.2 Per-plugin verified flag (V-07) — `Main.kt` `/plugins`

**Design.** Replace the fallback:

```kotlin
verified = repoTrust(meta?.repositoryUrl) || DaemonState.snapshot().repos.any { it.signed }
```

with a precise rule: a plugin is verified iff its **own** repository is signed:

```kotlin
val repoOfPlugin = meta?.repositoryUrl?.let { repoUrl ->
    DaemonState.snapshot().repos.firstOrNull { signed ->
        signed.url == repoUrl || repoUrl.startsWith(signed.url.trimEnd('/') + "/")
    }
}
verified = repoOfPlugin?.signed == true
```

* Prefix-match handles repositories whose manifest `repositoryUrl` carries a trailing path (community repos commonly do `.../repo.json` vs the registered base URL). Conservative: no match → `verified = false`.
* Client unchanged (`PluginDto.verified` semantics unchanged).

**Tests.** New `PluginsEndpointTest` with two repos (one signed, one not): plugin from unsigned repo reports `verified=false` even with the signed repo present.

### 5.3 Rate limiter coverage (V-15) — `Main.kt`, `RateLimiter`

**Design.**
* Apply `RateLimiter.check("solve")` to `GET /solve/pending` and `POST /solve-callback`; `check("write")` to `POST /plugins/setEnabled|config|remove` (write-shaped mutations share the write bucket).
* `/diagnostics`, `/repos`, `/plugins` (reads) get a new `read` bucket (capacity 120, refill 60/s) — generous, prevents log-spam loops.
* `RateLimiter.check` fallback for unknown groups stays `true` (fail-open) but logs once.

**Tests.** Extend `RateLimiterTest`: burst beyond capacity on `solve` → `false`; recovery over time; unknown group → `true`.

### 5.4 NDJSON writer serialization (V-20) — `Main.kt` `/search/stream`

**Design.** Serialize writes through a `kotlinx.coroutines.sync.Mutex`:

```kotlin
val writeMutex = Mutex()
val jobs = providers.map { provider ->
    async(Dispatchers.IO) {
        val event = ...
        val line = json.encodeToString(SearchStreamEventDto.serializer(), event)
        writeMutex.withLock {
            write(line); write("\n"); flush()
        }
    }
}
```

* The `done` event after `awaitAll()` needs no lock (single writer by then).
* Alternative considered (channel feeding a single writer coroutine) rejected as more moving parts for the same guarantee.

**Tests.** Existing `ProviderExecutorTest` covers ordering logic; add a stress test that runs 50 providers × 200 events through a captured writer asserting line integrity (no interleaved fragments) — pure JVM test, no Ktor needed if the writer serialization is extracted into a small helper class.

### 5.5 Download size caps (V-19) — **moved to WS-12.4**

The size-cap work now lives in WS-12 (Repository trust chain) because `fetchUrlBytes` — the single choke point for manifests, plugin lists, and `.cs3` artifacts — was restructured by the parallel-work shortcode/Codeberg changes and is owned by WS-12. See §12.4 for the design; the constants and tests are unchanged.

### 5.6 Plugin removal lifecycle (V-18 — PARTIAL, residual scope) — `Main.kt`, `PluginBridge`, `DaemonState`

**Shipped by parallel work (verified 2026-09-29):** `DaemonState.unmarkPluginRemoved(hash)`; `installPlugin` un-marks the hash before install (both the manifest-published and actual hash); `uninstallPlugin` deletes `.cs3` + `.jar` artifacts; `removeRepository` cascades uninstalls.

**Remaining design:**
* Add `POST /plugins/restore` (accepts `pluginId` / internalName / hash; resolves the plugin from persisted repository manifests, calls `unmarkPluginRemoved`, then `fetchVerifiedCs3` + `loadPluginFromCs3`) for plugins removed **without** a subsequent install.
* Client: recovery view in the Settings extensions card listing removed-but-restorable plugins.
* Long-tail hygiene: track `removedAt` timestamps in `DaemonState` (migrate `Set<String>` → `Map<String, Long>`, absent = now) and prune `.cs3`/`.jar` artifacts older than 30 days from `bootFromCache`.
* Related: N-11 ghost entries — `getRepoPlugins` should treat a deleted `.cs3` with no in-memory descriptor as `isInstalled=false` (currently `PluginBridge.isLoaded` alone can report true mid-teardown), and `/plugins` should drop metadata for hashes with neither descriptor nor artifact.

**Tests.** Extend `PluginBridgeTest`: remove → restore → providers registered again; restore endpoint idempotency; `getRepoPlugins` `isInstalled` truth table across (loaded / artifact-only / removed / ghost) states.

---

## WS-6 — Solve bridge hardening (V-12, V-14)

### 6.1 Cookie store isolation (V-12) — `WebViewSolverService`

**Design.**
* Replace `WKWebsiteDataStore.default()` with a **dedicated persistent solver store**:

```swift
private let solverStore = WKWebsiteDataStore(forIdentifier: UUID(uuidString: "7B2B6D4A-0E39-44F5-8C71-6C0F32E50628")!) // macOS 14+ requires UUID identifier; fallback: nonPersistent()
```

  Persistent is preferred over ephemeral: Cloudflare clearance cookies legitimately outlive a single solve; ephemeral forces re-solving per session. If the `forIdentifier` API is unavailable at deployment target, fall back to `nonPersistent()` and accept re-solves.
* Clearance filter: require the cookie name to be exactly `cf_clearance` (case-insensitive) — not `contains("cf_")`. If none found by deadline, submit **nothing** (fail the solve; the daemon proceeds without clearance). Remove the "send all host cookies" fallback branch entirely.
* `submitSolve` payload: send only `{name, value, domain, path, expires}` of the clearance cookie(s); daemon reconstructs the `Cookie` header. This stops leaking unrelated app cookies into the scraper.

### 6.2 Daemon-side cookie validation (V-12 server half) — `SolveBridge`

**Design.**
* `SolveBridge.complete` parses the submitted header into name/value pairs and **stores only `cf_clearance`** (and `__cf_bm` if present — both are Cloudflare-issued). Everything else is dropped.
* Cap stored header size (4 KB) and host count (LRU 64 hosts) to bound memory.
* `SolveInterceptor` continues to inject only the stored header — unchanged mechanics, now sanitized at ingestion.

**Tests.** Kotlin: `complete()` with junk cookies + one `cf_clearance` → only clearance persisted; oversize header rejected. Swift: unit-test the filter against a fixture cookie list (requires extracting `clearanceCookies` filtering into a testable pure function).

### 6.3 Solve-task hygiene (V-14) — `SolveInterceptor`

**Design.**
* `isChallenge`: on body-peek failure, **return false** (fail-closed to *not* solving) instead of `true`. Status+server markers alone are too weak; a peek failure means TLS/compression weirdness, not a challenge.
* One solve task per host per 60 s: `SolveBridge.newTask` returns the *existing* pending task for the host if one was created within the window (dedupe by host, not URL) — prevents N parked requests from creating N tasks and N WebKit loads.
* Park timeout stays 90 s, but the interceptor now checks `SolveBridge.hasRecentFailure(host)` (set when a solve times out) and skips parking for 60 s after a failed solve — prevents the retry-against-brick-wall pattern.
* Thread pressure: acceptable after dedupe (max 1 parked thread per host per solve window); document in `NetworkSetup` that the dispatcher cost is bounded by distinct challenged hosts, matching the Android `CloudflareKiller` cost model (1 WebView per challenge).

**Tests.** Kotlin: dedupe (two intercepts same host → one task), post-failure skip window, `isChallenge` peek-failure → false.

---

## WS-7 — IPC client robustness (V-05, plus review-adjacent hardening)

### 7.1 NDJSON decoding (V-05) — `DaemonClient.searchStream`

**Design.** Replace byte-wise `Character` assembly with `Data` buffering and explicit UTF-8 line decoding:

```swift
var buffer = Data()
for try await byte in bytes {
    if byte == 0x0A {
        let lineData = buffer
        buffer.removeAll(keepingCapacity: true)
        guard !lineData.isEmpty else { continue }
        guard let event = try? JSONDecoder().decode(SearchStreamEventDto.self, from: lineData)
        else { continue }
        continuation.yield(event)
        if event.type == "done" { break }
    } else {
        buffer.append(byte)
    }
}
// flush trailing partial line (daemon always terminates lines; defensive)
if !buffer.isEmpty, let event = try? JSONDecoder().decode(...) { continuation.yield(event) }
```

* `Data.append(byte)` is O(1) amortized; lines are small (<64 KB). Remove `lineBuffer: String` entirely.
* Keep the `Task.isCancelled` check between bytes.

**Tests.** Unit-test the line-splitting logic by extracting it into `NDJSONLineDecoder` (struct with `append(Data) -> [Data]` API): multi-byte UTF-8 across chunk boundaries, `\r\n` tolerance (daemon sends `\n`; be liberal), CRLF-only input, empty lines, 3-byte emoji split across three chunks.

### 7.2 Debounce retention (adjacent hardening, no behavior change)

* `AppState.performSearch` already cancels `searchTask`; `onTermination` cancels the URLSession bytes task — verified correct. No change.

---

## WS-8 — [RETRACTED — V-13 False Positive]

**Status:** Retracted.
Code inspection and empirical testing confirmed that in `Sanitizer.kt`, `PROTECTED_PREFIXES` (`"token"`, `"auth"`, `"key"`, `"sig"`, `"signature"`, `"expires"`, `"expire"`, `"hmac"`, `"hash"`, `"id"`, `"cont"`, `"session"`, `"device"`, `"cdn"`) contains no prefix that matches or overlaps with `"ref"`, `"referrer"`, `"ref_src"`, or `"ref_url"`. `URLSanitizer.isTrackingParameter("ref")` evaluates to `true` and is already stripped correctly. No code changes required.

---

## WS-9 — UI parity fixes (V-24, V-25, V-27, N-12, N-15)

### 9.1 Dub/sub dedupe (V-24)

* `MediaDetailView.episodesForSelectedSeason`: when both `sub` and `dub` variants exist, group by `episode` number and render one row per episode number with a small "Sub/Dub" picker on the row (default from `preferDub`). When only one variant exists, no picker. Implementation: build `[Int?: [EpisodeDto]]` keyed by episode number; row shows the selected variant; `preferDub` remains the global default.
* This matches Android's DubStatus model without a full data-model change.

### 9.2 Quality labels (V-25)

* Replace the invented buckets with Android's exact mapping (`ExtractorApi.kt` `Qualities`): `0 → name`, `Unknown(400) → name`, `P144(144)…P1080(1080) → "\(q)p"`, `P1440(1440) → "1440p"`, `P2160(2160) → "4K"`, default → `name`. Concretely:

```swift
var qualityLabel: String {
    switch quality {
    case 0, 400: return name
    case 144, 240, 360, 480, 720, 1080, 1440: return "\(quality)p"
    case 2160: return "4K"
    default: return name
    }
}
```

  (Non-standard scraped heights fall back to the extractor's own label — honest.)

### 9.3 Onboarding engine-readiness (V-27)

* `OnboardingView.syncDefaultRepo`: before syncing, wait for engine readiness up to 15 s (`while !appState.isEngineReady && elapsed < 15 { try? await Task.sleep(0.25s) }`). If still not ready, show "Engine still starting — will sync automatically when ready" and re-run `syncDefaultRepo` from an `onChange(of: appState.isEngineReady)` handler.

### 9.4 PiP button is a no-op (N-12)

* `PipService.toggle()` flips `isDetached`/`isPipActive`, but no view observes either — the HUD's PiP button silently does nothing.
* Decision required (out of plan's hands): either implement the detachable mini-window described in `NowPlayingService`'s PiP comment, or **remove the button** until then. Plan assumes removal (1-line diff) — a real PiP window is its own feature work.

### 9.5 Audio downmix is global (N-15 — documented tradeoff)

* `audio-channels=stereo` + `audio-format=s32` are compatibility workarounds applied to every title; 5.1 content is force-downmixed. Keep as-is for v1.1; revisit behind a per-title capability probe (query `audio-params/channels` after load and relax the option only when the device accepts the layout). No action this cycle.

---

## WS-10 — Contract hardening (optional, separate release)

* Bump `IPC_VERSION` to 3 with additive fields only: `HealthDto.providersLoaded` stays; add `GET /plugins/removed`; `SolveCallbackRequestDto` gains optional `cookieDomain`/`cookiePath`/`cookieExpires` fields (WS-6.1 payload change). The Swift client negotiates: `ipcVersion >= 3` → new solve payload; else legacy.
* Ship after WS-5/WS-6 merge; single PR; both sides updated in lockstep.

---

## WS-11 — Episode advance correctness (N-01, N-02, N-03) — `PlayerViewModel`, `MpvPlayerView`

### 11.1 Audio-variant-aware next episode (N-01)

**Design.** `playNextEpisode()` must advance within the *variant group* the user is watching, not the raw `details.episodes` array:

```swift
func playNextEpisode() {
    guard let session else { return }
    let episodes = session.details.episodes
    guard let current = session.episode else { return }

    // Variant group: same audio track family (anime) — "dub", "sub", or nil.
    let variant = current.audio
    let candidates = episodes.filter { $0.audio == variant || (variant == nil && $0.audio == nil) }

    // Prefer next-by-(season, episode) inside the variant; fall back to next-by-index.
    let next: EpisodeDto?
    if let ep = current.episode {
        next = candidates.first {
            $0.season == current.season && $0.episode == (ep + 1)
        } ?? candidates.first {
            $0.season == (current.season.map { $0 + 1 }) && ($0.episode ?? -1) == 1
        }
    } else {
        guard let idx = candidates.firstIndex(where: { $0.data == current.data }),
              candidates.indices.contains(idx + 1) else { return }
        next = candidates[idx + 1]
    }
    guard let next else { return }
    Task { await play(details: session.details, episode: next, preferences: preferences) }
}
```

* Rationale: the daemon's `AnimeLoadResponse` mapping flatMaps sub list before dub list, so `details.episodes` interleaves variants; naive index+1 crosses variants. Season rollover (E12 → S2E1) is handled by the second `first` clause; providers with `episode == nil` fall back to index order within the variant.
* This also fixes dub/sub *duplicates* being offered as "next" regardless of WS-9.1's UI dedupe — defense in depth, two independent layers.

**Tests.** Unit (`PlayerViewModel` + fake transport): sub/dub interleaved fixture list → next from a dub episode is the next dub episode; season rollover; un-numbered fallback; single-variant series unaffected.

### 11.2 END_FILE double-advance guard (N-02)

**Design.**
* `PlayerViewModel` gains `private var episodeTransitionInFlight = false`. `playNextEpisode()` (and `onEndOfFile` path) sets it `true` before starting the async `play`; `play(...)` clears it once the new `Session` is assigned (or on failure).
* While `episodeTransitionInFlight`, **ignore** further `onEndOfFile`/`playNextEpisode` calls (`guard !episodeTransitionInFlight else { return }`). This kills the Space-during-transition double-advance: mpv's re-fired END_FILE on the keep-open EOF file is swallowed.
* Belt-and-braces in `MetalVideoView`: `onEndOfFile` fires only for `MPV_END_FILE_REASON_EOF`, and `loadfile replace` of the *new* episode naturally resets the ended state — no mpv-side change needed.
* Optional polish: show a brief "Loading next episode…" HUD state while `episodeTransitionInFlight` (the old video freezes instead of looking hung).

**Tests.** Unit: two rapid `onEndOfFile` deliveries → `play()` invoked once; failure path (`links` throws) clears the flag so the user can retry manually.

### 11.3 Pause-state echo loop (N-03)

**Design.** `MpvPlayerView.Coordinator` gains `var lastPushedPlaying: Bool?`. `updateNSView` pushes only on change:

```swift
if coordinator.lastPushedPlaying != isPlaying {
    coordinator.lastPushedPlaying = isPlaying
    nsView.setPlaying(isPlaying)
}
```

* mpv's own `pause` property events flow back through `onPropertyChange` → `isPlaying` binding; the coordinator dedupe breaks the echo (push → property change → SwiftUI update → would-push-same-value → suppressed).
* Reset `lastPushedPlaying = nil` in `makeNSView` and on `loadStream` (so a failover always re-establishes the desired state).

**Tests.** Unit with a recording fake transport: repeated `updateNSView` with unchanged `isPlaying` → exactly one `setPlaying`; a toggle → exactly one more.

---

## WS-12 — Repository trust chain (N-07, N-08, N-09, V-19-tightened) — `RepositoryService`

### 12.1 No network I/O inside `reTrust` (N-07)

**Design.** Split `parseRepoUrl` into two layers:

* `normalizeInput(raw)`: pure string work — trim quotes, strip `cloudstreamrepo://` / `cs.repo/` prefixes, apply the `WELL_KNOWN_SHORTCODES` table, prepend `https://` when scheme-less. **No I/O.**
* `resolveShortener(raw)`: the cutt.ly / py.md `Location`-follow, dead-repo rewrites, and final scheme fix. **Network + redirects.**
* Call sites: `sync()` resolves shorteners **only when the repo URL is not already persisted** (`DaemonState.snapshot().repos.none { it.url == candidate }`); `reTrust(repoUrl)` operates on the **already-normalized persisted URL** and never touches shorteners. A re-trust of an unknown URL is rejected with `IllegalArgumentException("repository must be synced before it can be re-trusted")` — trust actions must not introduce new URLs.
* The Settings client passes `status.url` (the daemon-normalized URL) into `repositoryURLs` (already does) — the client-side trust path therefore also carries normalized URLs only.

**Tests.** Kotlin: `reTrust("https://cutt.ly/xyz")` → throws; `reTrust(normalizedPersistedUrl)` → clears pin + syncs without any shortener HTTP call (fake `app` client asserting request URLs); `sync("https://hexated")` resolves via shortcode table without network.

### 12.2 Restore the mandatory SEC-07 hash gate (N-08)

**Design.**
* `fetchVerifiedCs3`: a plugin whose manifest entry has **no** `fileHash` is refused again:

```kotlin
val expected = plugin.fileHash?.lowercase()?.removePrefix("sha256-")?.trim()
if (expected.isNullOrBlank()) {
    throw SecurityException("SEC-07: repository did not publish a SHA-256 hash for '${plugin.name}'; refusing to load")
}
if (!sha256(body).equals(expected, ignoreCase = true)) {
    throw SecurityException("SEC-07: SHA-256 mismatch for '${plugin.name}'")
}
```

* The `warn("fetch.no_hash")` branch and the `effectiveHash = expected ?: hash` fallback are **deleted** — a self-computed hash proves nothing about provenance (it equals TOFU-less trust-on-download).
* `installPlugin`'s hash-less `SitePlugin` construction (client-driven `pluginUrl` without `fileHash`) must **reject** up front: `require(!fileHash.isNullOrBlank())` with a 400-mapped error, and the client's RepositoryDetailView install action must pass `plugin.fileHash` (it already does) and disable install buttons when `fileHash == nil` (add this UI guard).
* Repo catalogs whose manifests genuinely lack hashes become uninstallable until the repo author publishes them — intentional, matching the documented Security.md posture and the official repo (which publishes hashes for all plugins).

**Tests.** Kotlin: no-hash manifest → `SecurityException`; mismatch → throws; client fixture: install button disabled for hash-less catalog rows.

### 12.3 Remove the forged Codeberg challenge cookie (N-09)

**Design.**
* `fetchUrlBytes`: drop the `x-robot-challenge-berlin=passed` header/cookie pair entirely. Keep the Gitea contents-API fallback (`/api/v1/repos/.../contents/...`) with a plain `User-Agent` — the API endpoint is the legitimate machine interface and does not require the challenge cookie; the cookie was cargo-culted and is brittle to rotation.
* If Codeberg blocks the plain API path in future, the correct escalation is a configurable `Cookie` header in settings (user-supplied), not a hardcoded forged value.

**Tests.** Kotlin: fake client asserts the Codeberg API request carries no `x-robot-challenge` cookie; API-200 path still decodes base64 content; API-failure falls back to direct fetch.

### 12.4 Size caps (V-19 — unchanged from rev 2, re-affirmed)

* `MAX_MANIFEST_BYTES = 2 MiB`, `MAX_PLUGIN_BYTES = 64 MiB`; cap via a bounded `InputStream` wrapper in `fetchUrlBytes`/`fetchUrlText`; exceed → `SecurityException` → 403 mapping. Note the current `fetchUrlBytes` returns `ByteArray` from `app.get(...).body.bytes()` — implement the cap at the OkHttp body stream, before bytes are buffered.

**Tests.** (unchanged) capped reader throws at limit; under limit passes byte-identical.

### 12.5 Load-descriptor matching (N-10)

**Design.** `PluginBridge.findLoadedByInternalNameOrManifest` matches `descriptor.filename.contains(internalName)` where `filename` is `<hash>.cs3` — always false in practice. Fix:
* Match on `manifestName` (case-insensitive) **plus** the persisted `SitePlugin.internalName` looked up via `pluginMetadataFor(sha256)` — i.e. resolve each loaded descriptor's manifest metadata first, then compare `internalName`.
* Same-name forks are disambiguated by `repositoryUrl`: prefer a descriptor whose `pluginMetadataFor(...).repositoryUrl` equals the installing repo. If still ambiguous, refuse with `IllegalStateException("multiple loaded plugins match '<name>' — specify a hash")` rather than silently unloading a sibling.

**Tests.** Kotlin: two loaded plugins whose manifests share a name, different repos → installing an update for one must not unload the other; ambiguous uninstall without hash → error, not silent removal.

---

## WS-13 — Client state races & plugin persistence (N-13, N-05, N-06, N-04, N-11)

### 13.1 Persist individually-installed plugins (N-13)

**Design.**
* `RepositoryService.installPlugin`: after a successful `loadPluginFromCs3`, upsert the effective `SitePlugin` (with resolved absolute `url`, `internalName`, `fileHash` = actual hash, `repositoryUrl` = repoUrl) into the owning repository's `pluginsJson` via `DaemonState.update` — merge by `fileHash`/`internalName`, replacing any older entry. This makes `bootFromCache` self-sufficient for installs: the plugin's `.cs3` is content-addressed in the store **and** its manifest entry (with hash) is persisted.
* Uninstall already deletes both the artifact and (via `markPluginRemoved`) the boot path; additionally remove the entry from `pluginsJson` at uninstall so catalogs and boot lists agree (fixes N-11's ghost-metadata half).
* `removeRepository(deleteDownloaded=false)` keeps plugin entries but they reference a repo that no longer exists — keep them (plugins still boot from cache; repo row removal only drops the *repository* record). Document this in `DaemonState.PersistedRepository`'s KDoc.

**Tests.** Kotlin (temp `cs.cloudstream.home`): install → simulated restart (`DaemonState.load()` + `bootFromCache()`) → providers registered again with no network; uninstall → restart → not registered; `getRepoPlugins` reports `isInstalled=false`.

### 13.2 Endpoint-stream generation counter (N-05)

**Design.** `AppState` gains `private var endpointGeneration = 0`. Each `endpointChanges` iteration increments it and captures `let gen = endpointGeneration` before the retry loop; the post-loop state writes are guarded:

```swift
if let health, gen == endpointGeneration {
    ...ready...bootstrap...
} else if let lastError, gen == endpointGeneration {
    ...error...
}
```

* A newer endpoint arriving mid-retry invalidates the stale iteration's writes; the newer iteration (which runs after on the actor) wins. Deterministic because `endpointTask` serializes iterations on the main actor.
* Same guard applied to `daemonVersion`/`engineError` writes.

**Tests.** Unit with a stubbed `DaemonSupervisor` stream + failing-then-succeeding `connectAndVerify`: stale error after newer ready is not surfaced (`daemonState` remains `.ready`).

### 13.3 Solver retry & task hygiene (N-04, N-06)

**Design.**
* `WebViewSolverService` gains `private var attemptedTaskIds: [String: Int]` (taskId → attempts). `solve()` refuses a task with ≥3 attempts (`guard (attemptedTaskIds[taskId] ?? 0) < 3`); every `solve()` entry increments the count. Attempts map is cleared when the daemon reports a *different* task set (stale entries age out) — simplest: clear entries older than 2 minutes.
* `didFail` navigation currently clears state without reporting failure — also call `finish(taskId:)` so `isSolving` bookkeeping stays consistent (it already sets `isSolving=false`; make it go through `finish` for deadline/webView cleanup parity).
* `AppState.startSolvePolling`: iterate pending oldest-first and attempt only the first non-attempted-out task per cycle (the service is single-slot anyway) — `if let task = pending.first(where: { !WebViewSolverService.shared.isSolving }) { solve(...) }`, which stops hammering when one task is in flight.

**Tests.** Unit: 4th solve attempt for the same taskId is refused; `didFail` cleanup matches deadline-path cleanup; poller starts at most one solve per cycle.

### 13.4 Ghost plugin entries (N-11)

* Covered by 13.1's uninstall change plus WS-5.6's `getRepoPlugins` truth-table fix. No additional code beyond those two.

---

## Execution order & dependencies (rev 3)

```
WS-12 (repo trust chain)      ── SECURITY: ship first — N-07/N-08 close a real trust bypass
WS-7  (client stream fix)     ── independent, smallest, highest user pain
WS-11 (episode advance)       ── independent; 11.1 + 11.2 one PR (same file), 11.3 separate
WS-3  (download pipeline)     ── independent
WS-1  (player)                ── independent; 1.2 & 1.4 touch same file, one PR
WS-4  (supervisor)            ── independent
WS-13 (client state races)    ── 13.1 daemon-side, 13.2/13.3 client-side; can split
WS-5  (daemon state)          ── 5.1/5.2 one PR; 5.6 residual
WS-6  (solve bridge)          ── 6.1 (Swift) and 6.2/6.3 (Kotlin) ship separately
WS-2  (progress model)        ── after WS-1.5 (shares LibraryStore); schema additive
WS-9  (UI parity)             ── after WS-2 for episode rows; 9.4 independent
WS-10 (contract v3)           ── after WS-5 + WS-6
```

**Suggested merge train (rev 3):** WS-12 → WS-7 → WS-11 → WS-3 → WS-1 → WS-4 → WS-13 → WS-5 → WS-6 → WS-2 → WS-9 → WS-10.

**Parallel-work reconciliation:** several rev-2 items were fixed by work merged outside this plan (plugin install/uninstall lifecycle, `installAll`, shortcode catalogs, per-provider filters, mute persistence). Before starting any workstream, re-run its "Tests" section against the current tree as a baseline; skip items marked ✅ SHIPPED in the register.

## Definition of done (per workstream)

1. Re-verify the workstream's findings against HEAD before coding (the tree changed between review passes once already); update the register's Status column first.
2. Code + tests merged; existing `daemon` test suite green (`./gradlew :engine:test`).
3. New tests green; no regression in `RepoSignatureTest`, `ProviderExecutorTest`, `URLSanitizerTest`, `PluginBridgeTest`, `RepositoryServiceTest`.
4. Structured log events added where the plan specifies (`daemon.backoff`, `solve.dedupe`, `plugins.restore`, `repo.trust_rejected`, …).
5. Manual QA script executed (player resume, local playback, download failover with a host that 403s mirror 1, anime sub/dub next-episode advance, two-instance launch, slow-start adoption with `-Xmx16m` forced-slow daemon, hash-less repo install refusal).
6. `docs/Remediation-Plan.md` updated: row moved to "fixed in <WS>" with the PR link; this plan's Status column flipped to ✅ SHIPPED.

## Risks

| Risk | Mitigation |
|------|-----------|
| mpv `start` option ignored by some demuxers (rare HLS) | Keep `file-loaded` seek as fallback if `time-pos` stays < `start` after 3 s (log + seek once) |
| `WKWebsiteDataStore(forIdentifier:)` unavailable on deployment target | `#available` gate → `nonPersistent()` fallback; acceptance: re-solve per session, no correctness loss |
| SwiftData schema change (WS-2) breaks existing installs | Additive-only `@Model`; lightweight migration test with a v1.1 fixture store |
| Override re-application fights plugins that self-configure | Apply only when persisted override exists; never call `overrideWithNewData` with nil-url overrides (normalize to deletion per 5.1) |
| Rate limiter breaks legitimate bursts (e.g. 50-provider search) | Read bucket sized 120/60s; stream path untouched; existing `search` bucket already sized for this |
| dex2jar cache poisoning via `.cs3` re-hash every boot (perf, not security) | Boot-time hash check already gates; cache keyed by content hash — no action needed (V-18 boot cost accepted unless profiling shows pain) |
| **(rev 3)** Mandatory hash gate (WS-12.2) makes hash-less community repos uninstallable | Intentional fail-closed per Security.md; Settings surfaces the per-plugin `fileHash == nil` state so users understand why; repo authors publish hashes (official repo already does) |
| **(rev 3)** `pluginsJson` upsert (WS-13.1) races a concurrent `/repos/sync` rewrite of the same repo record | Both go through `DaemonState.update`'s `synchronized(mutex)` — last-writer-wins on the transform closure is safe because each transform re-reads `current`; add a regression test for interleaved install+sync |
| **(rev 3)** Variant-group next-episode (WS-11.1) misses providers that mark audio with values other than `dub`/`sub`/nil | Filter treats unknown variant strings as their own group (`$0.audio == current.audio`), preserving current behavior for such providers; add fixture for custom `audio` tags |
| **(rev 3)** Removing the PiP button (WS-9.4) is a visible UX regression | Ship behind a feature-flag constant defaulting to "remove"; re-introduce when the real detachable window lands |
| **(rev 3)** Tree drifts again before workstreams start (as it did between passes) | Each workstream's DoD includes re-running its tests against HEAD first; the register's Status column is the reconciliation mechanism |
