# CloudStream macOS: code audit and Android parity review (2026-10-01)

## Scope and method

The review read the code by hand and checked each finding against the working tree. No builds, tests or runtime traces were run.

Line numbers refer to the working tree on `macos/extensions-remediation` at the time of review.

| Area | Depth |
|---|---|
| Daemon: `Main.kt`, `MediaRoutes.kt`, `ProviderExecutor.kt`, `PluginBridge.kt`, `ProviderRuntimeBootstrap.kt`, `SolveBridge.kt`, `SolveInterceptor.kt`, `VerifierJobs.kt`, `RateLimiter.kt` | Full read |
| Client: `DaemonSupervisor.swift`, `DaemonClient.swift`, `AppState.swift`, `PlayerViewModel.swift`, `DownloadService.swift`, `WebViewSolverService.swift`, `EpisodeUpdateChecker.swift` | Full read |
| Client: `LibraryStore.swift`, `MetalVideoView.swift` (threading and render path) | Targeted read |
| Extension install/repository subsystem (`InstallationManager`, `RepositoryService`, `worker/*`) | **Not audited.** Another session was editing these files during the review, and `docs/audit/extension-runtime-2026-10-01/` already covers them. |
| SwiftUI views, Settings, Backup, Profiles | Grep only |

**Confidence:** **Confirmed** means the defect can be read directly from the code. **Likely** means the reasoning is sound but it has not been reproduced.

---

## 1. High severity

### H1. Cloudflare clearance cookies are replayed with a different User-Agent (Confirmed)
- `client/Sources/Services/WebViewSolverService.swift:44` solves the challenge with a Safari UA.
- `daemon/.../SolveInterceptor.kt:56-61` retries the provider request with only the `Cookie` header, keeping the provider's own UA.
- `cf_clearance` is bound to the UA that solved the challenge, so Cloudflare usually rejects the retried request. The anti-bot bridge then fails silently.
- Android's `CloudflareKiller` sends the WebView's UA with the cookies.
- **Fix:** return the solver's UA with the cookies (for example in the `/solve-callback` payload). Store it per origin in `SolveBridge`, and override `User-Agent` on requests that carry clearance.

### H2. The solve interceptor overwrites provider cookies and sends an internal header upstream (Confirmed)
- `SolveInterceptor.kt:32`: clearance is injected only when the request has no `Cookie` header. Providers that set their own cookies therefore never get clearance.
- `SolveInterceptor.kt:58`: on retry, `.header("Cookie", cookieHeader)` replaces the provider's session cookies instead of merging with them.
- `SolveInterceptor.kt:59`: `X-CS-Solve-Retry: 1` is sent to the remote site. That is a fingerprint and can trigger WAF rules.
- **Fix:** merge cookie headers, and keep the loop guard in a request tag (`request.tag()`) instead of an HTTP header.

### H3. A solve blocks an OkHttp thread for up to 90 seconds, and parallel challenges are solved one at a time (Confirmed)
- `SolveInterceptor.kt:46-50` calls `runBlocking { awaitSolution }` with a 90 s timeout (`SolveBridge.kt:54`). Provider deadlines are 5-30 s and do not interrupt `runBlocking`, so the thread stays parked after the caller has given up.
- There is no de-duplication by origin. N concurrent requests to one host create N tasks.
- The client solves them one at a time (`AppState.swift:350`, `!isSolving`). Each solve uses a fresh non-persistent data store (`WebViewSolverService.swift:35`), so each one faces a new challenge.
- **Fix:** keep one in-flight solve per origin and have all waiters share its deferred result. After a solve completes, re-check the cookie cache before parking.

### H4. The daemon stdout/stderr logs are overwritten from byte 0 on every spawn, and file handles leak (Confirmed)
- `DaemonSupervisor.swift:341-350` uses `FileHandle(forWritingAtPath:)`, which opens at offset 0 without truncating or seeking.
- Each restart overwrites the start of the previous log and leaves stale bytes after it, so the log is corrupt for diagnostics.
- These logs never rotate.
- The parent never closes the two handles, so every restart leaks two file descriptors.
- **Fix:** open with `O_APPEND` (or call `seekToEndOfFile()`), rotate by size, and close the parent's copies after `run()`.

### H5. The app can crash with SIGPIPE when the daemon dies right after spawn (Likely)
- `DaemonSupervisor.swift:397-399` writes the token and options to the child's stdin immediately after `run()`.
- If the JVM exits first (bad runtime, jar missing, lock held), the write goes to a pipe with no reader.
- Nothing in the client ignores `SIGPIPE`, so the default action terminates the app.
- **Fix:** call `signal(SIGPIPE, SIG_IGN)` at launch, or set `F_SETNOSIGPIPE` on the write fd, and treat `EPIPE` as a spawn failure.

### H6. An immediately crashing daemon respawns in a tight loop (Confirmed)
- `DaemonSupervisor.swift:371-376`: every unexpected exit calls `restart()` right away, with no backoff and no cap.
- `CrashLoopDetector` only switches to safe mode. Failures unrelated to extensions keep looping at full speed: a port collision, the data-root lock held by another instance, or a missing jar (see H7).
- It also mislabels them as an extension crash loop.
- **Fix:** add exponential backoff and a maximum restart count, then stop in `.error` with a clear message.

### H7. The "daemon jar missing" check can never fire in production (Confirmed)
- `DaemonSupervisor.swift:492-504` falls back to a `#filePath` development path and never returns `nil`.
- A broken bundle therefore reaches `java -jar <nonexistent>`, which exits at once and feeds H6.
- The guard at `:296` that reports "daemon jar missing" is dead code for the jar.
- **Fix:** use the development fallback only in `#if DEBUG` and only if the file exists.

### H8. Loopback IPC shares `URLSession.shared` and its 6-connections-per-host limit (Likely)
- The heartbeat (`DaemonSupervisor.swift:470`) and all IPC calls (`DaemonClient.swift:263, 349, 381, 455, 470`) go to the same `127.0.0.1:<port>` through `URLSession.shared`.
- Several long-held requests can fill every connection:
  - NDJSON search stream
  - link stream
  - batch `/links` from each active download (up to about 92 s each)
  - next-episode prefetch
  - `/test/run` (600 s)
- When that happens the heartbeat queues behind them, misses its 5 s timeout four times, and the supervisor **kills a busy, healthy daemon** (`:451-456`).
- **Fix:** use a dedicated `URLSession` with a higher `httpMaximumConnectionsPerHost` for IPC, and a separate session for the heartbeat.

### H9. Playlist-type links download the wrong content (Confirmed)
- The player expands `ExtractorLinkPlayList` segments through EDL (`PlayerViewModel.swift` `playableURL`).
- The downloader passes only `link.url` to ffmpeg (`DownloadService.swift:1679`) and ignores `link.playlist`.
- The download either fails or saves only the first segment.
- **Fix:** use ffmpeg's concat demuxer for playlist links (whitelist `concat`, keep http(s) for segments), or exclude them in `DownloadPolicy.isDownloadable`.

### H10. In-process mode: each extension overwrites the global provider context (Confirmed; worker mode is not affected)
- `PluginBridge.kt:121-122` calls `ProviderRuntimeBootstrap.initialize(context)` for every extension it loads.
- That sets the process-wide `CloudStreamApp.context` and `setContext()`.
- After restore, every extension's `getKey`/`setKey` and shared preferences resolve to the **last loaded** extension's private storage. Data leaks across extensions and gets clobbered.
- **Fix:** give each plugin its own context (or scope storage by the calling class loader). Never repoint the global per load.

---

## 2. Medium severity

### Engine and IPC
- **M1. `ready` state can publish before the client has the new endpoint (Confirmed).** `AppState.swift:217-222` sets `.ready` from `stateChanges`. The new endpoint arrives on a separate stream (`:149-157`).
  - For a short window `isEngineReady == true` while `DaemonClient` still points at the dead port, so requests made then fail.
  - **Fix:** derive readiness only from the endpoint task.
- **M2. The health wait can end in a permanent error (Confirmed).** In `DaemonSupervisor.swift:425-430`, if the process is still running but not healthy after 20 s, the state becomes `.error` with no heartbeat and no retry. Recovery then requires user action.
- **M3. Stray-daemon cleanup runs `pgrep` synchronously on the main actor at launch (Confirmed).** See `DaemonSupervisor.swift:262-264`.
  - The asynchronous kill it schedules races the new spawn, which can hit the data-root lock the stray still holds (and then feeds H6).
  - The regex escaping misses `* ? ^ $ | {`.
- **M4. Malformed request bodies return plain 500 errors (Confirmed).** `Main.kt` installs no `StatusPages`.
  - `call.receive<…>()` in `MediaRoutes.kt:218, 272` and elsewhere throws on bad JSON.
  - `/home?page=0` hits `require(page > 0)` outside `safeProvider` (`ProviderExecutor.kt:131`).
  - Both return untyped 500s, which the client classifies as *transient* and retries (`DownloadService.classifyResolutionError`).
- **M5. `/search/stream` bypasses the search concurrency permit (Confirmed).** `searchAll` bounds fan-out to 8 (`ProviderExecutor.kt:70, 83`). The streaming route that the UI actually uses (`MediaRoutes.kt:125-139`) launches every provider at once on `Dispatchers.IO`.
- **M6. `/extract` can exceed the client's timeout (Confirmed).** It tries up to four worker extractors one after another, each with the full timeout plus margin (`ProviderExecutor.kt` `extract`). The worst case exceeds the client's 120 s request timeout.
- **M7. The daemon holds a latency-critical activity for the app's whole lifetime (Confirmed).** `DaemonSupervisor.swift:86-91` begins `.latencyCritical` and never ends it until quit. This defeats App Nap and costs battery when idle.

### Player
- **M8. Anime next/previous crosses between sub and dub lists (Confirmed).** `nextEpisode()` (`PlayerViewModel.swift:1252`) indexes the flat `details.episodes`, which is sub + dub concatenated.
  - After the last sub episode, "Up Next" and auto-advance jump to dub episode 1.
  - Library auto-promotion already filters by `audio`; the player does not.
- **M9. Torrent and magnet links reach mpv (Confirmed).** No playback path filters `type == TORRENT/MAGNET`.
  - The ranker can put them first, which wastes a failover cycle and causes "All mirrors failed" reports.
  - Android plays them through its torrent engine.
- **M10. The player never starts `extractorVerifierJob` (Confirmed).** Only downloads call it (`DownloadService.swift:1369`). Android calls it for playback too (`GeneratorPlayer.kt:265`), so hosts that expire links without keep-alive die mid-playback on macOS.
- **M11. Rendering uses CPU (`sw`) frames capped at 1920 px (Confirmed; design limitation).** See `MetalVideoView.swift:122`.
  - 4K sources are downscaled, HDR is not preserved, and CPU/energy use is high compared with a GPU render path.

### Downloads, library and background work
- **M12. Episode checks starve behind failing titles (Confirmed).** `EpisodeUpdateChecker.swift:52` `continue`s on a details failure without updating `lastEpisodeCheck`.
  - Titles that always fail stay oldest and fill every 12-title batch.
  - With 12 or more of them (for example a provider was removed), no other title is ever checked.
- **M13. Resume breaks when a provider changes episode data (Confirmed).** In `LibraryStore.swift:570-577`, if no episode matches, `episode` is nil for a series, so `play` falls back to `movieData`, which is nil. The user sees "no playable stream data".
  - The `season == lastSeason && episode == lastEpisode` fallback also matches when both are `nil`, which can pick the wrong episode.
- **M14. A finished episode drops the series from Continue Watching (Likely).** Progress is stored per title, and items at 95% or more are hidden (`LibraryStore.swift:542`). Finishing E1 removes the series instead of offering E2, as Android does.
- **M15. Network loss ignores items that are resolving (Confirmed).** `suspendForNetworkLoss` (`DownloadService.swift:704`) pauses only `.downloading` items. Items in `.resolving` continue into an attempt while offline and burn through mirrors until they fail.
- **M16. Verifier lookup is by display name and requires a unique match (Confirmed).** `VerifierJobs.start` → `findProvider(link.source)` uses `singleOrNull` on the name. Two installed providers with the same name disable the verifier, whereas Android takes the first match.

---

## 3. Low severity, dead code and tidy-ups

- **Solve bridge contradiction (Confirmed).** `SolveBridge.kt:43-48` says worker cookies "go only to the requester (not the shared cache)", but `complete()` always calls `cache(origin, cookies)` (`:86`).
- **Case-sensitive challenge marker (Confirmed).** `SolveInterceptor.kt:79-80` checks for `"just a moment"`, but the page says "Just a moment…". Other markers usually catch it.
- **Exceptions from `newTask()` escape the interceptor (Confirmed).** `SolveBridge.newTask` throws `IllegalArgumentException`/`IllegalStateException` for http origins or when more than 32 tasks are pending. These are not `IOException`, so they escape OkHttp's normal error path.
- **Detail-cache eviction is random (Confirmed).** `AppState.trimDetailsCache` (`:481-490`) iterates a `Dictionary`, so eviction order is random, not "most recent" as its comment says.
- **Solve poll loop never exits (Confirmed).** In `AppState.startSolvePolling`, `guard let self … else { continue }` should `return`.
- **Unrestricted search scope (Confirmed).** `AppState.performSearch` always passes `plugins: nil`. There is no per-search provider scope.
- **Premature screenshot notice (Confirmed).** `PlayerViewModel.takeScreenshot` shows "Screenshot saved" before mpv reports success.
- **Misleading state after dismissing an error (Confirmed).** `PlayerViewModel.dismissError` sets `phase = .ready` even though nothing is loaded.
- **Late links are unranked (Confirmed).** Links that arrive after playback starts are appended without ranking (`PlayerViewModel.swift:401`).
- **Dead `"error"` event case (Confirmed).** The `"error"` case in `resolveLinks` is never emitted by the daemon.
- **Seeded batch downloads are slow (Confirmed).** `enqueueBatch` re-fetches every `DownloadRecord` and stats the disk for each request (`reservedBasePaths` in `DownloadService.swift:514`). This is O(n·m) for season downloads.
- **Heavy writes on the volume slider (Confirmed).** `setVolume` writes `UserDefaults` on every slider tick.
- **Unvalidated `/home` page (Confirmed).** `MediaRoutes.kt:158` does not validate `page`.
  - The legacy `GET /links` returns 400 for a missing provider while `POST` returns 422 (the client maps both to "provider missing").
  - It has no rate limit and should be removed if nothing uses it.
- **Incomplete `/diagnostics/export` health (Confirmed).** It builds a `HealthDto` without extensions, safe-mode or isolation fields.
- **`translationLocks` never shrinks (Confirmed).** See `PluginBridge.kt:48`.
- **Orphaned KDoc (Confirmed).** A doc comment above the links cache in `ProviderExecutor.kt` documents nothing.
- **Time source split (Confirmed).** The links cache uses `System.currentTimeMillis` while the details cache uses the injectable `now`, which blocks TTL tests for links.
- **PID reuse risk (Likely).** `terminateProcess` / `terminateAllManagedProcesses` send `SIGKILL` by PID after 1.5 s without checking the PID is still ours.
- **Headers visible in argv (Confirmed, documented).** ffmpeg header values, including auth/referer tokens, appear in argv and can be read by other processes of the same user.

---

## 4. Android and macOS feature comparison

Android reference: `app/src/main/java/com/lagradost/cloudstream3/`.

| Android capability (source) | macOS status | Impact |
|---|---|---|
| Tracker sync: AniList, MAL, Simkl, Kitsu (`syncproviders/providers/*`) | **Missing.** `DetailsDto.syncIds` is fetched but unused. | High for anime users: no progress sync, no import of lists. |
| Online subtitle search: OpenSubtitles, SubDL, SubSource, Addic7ed (`SubtitleRepo`) | **Missing.** Only provider subtitles and local files. | High: many sources ship no subtitles. |
| Torrent playback (`ui/player/Torrent.kt`) | **Missing**, and torrent links are not filtered (M9). | Medium. |
| Casting: Chromecast, FCast (`ControllerActivity`, `actions/temp/fcast`) | **Missing.** AirPlay could be the macOS equivalent. | Medium. |
| Manual/visible WebView for interactive challenges (`WebviewFragment`) | **Missing.** The solver is offscreen only, so Turnstile checks that need a click cannot be solved. | Medium. |
| `extractorVerifierJob` during playback | **Missing** (M10). | Medium. |
| Plugin settings screens (`Plugin.openSettings`) | **Not supported.** Android-UI settings cannot render. | Medium: some extensions need login or configuration there. |
| Extensions with `requiresResources` | Rejected with a clear message (`PluginBridge.kt:109`). | Known limitation. |
| Repository shortcodes (e.g. short names resolved through the CloudStream link service) and plain-http repositories | `normalizeRepoUrl` forces `https://` and has no shortcode resolution (`DaemonClient.swift:116-120`). | Medium: repository links shared in the community fail. |
| Per-search provider and type filters (`SearchFragment` provider chips, TvType filters) | Type chips filter results only after the search. Every provider is always queried. | Low/Medium. |
| Sub/dub-aware episode navigation | Mixed lists (M8). | Medium. |
| "Resume next episode" in Continue Watching | Title-level only (M14). | Medium. |
| External actions: VLC, mpv, Web Video Cast, aria2, copy link, browser (`actions/temp/*`) | Partial: handoff to IINA, VLC, mpv and QuickTime only (`ExternalPlayer.swift`). No downloader, clipboard or browser actions. | Low. |
| Cloud backup targets (`BackupAPI`) | Local backups only. | Low. |
| Picture-in-picture (`PlayerPipHelper.kt`) | **Missing.** Only "float on top" exists; `NowPlayingService.swift:177` notes that real PiP is not implemented. | Low/Medium. |
| Source priority, profiles, local library, new-episode checks, auto backup | Present on macOS. | At parity (not deeply verified). |

---

## 5. Suggested fix order

1. **H4-H7** (supervisor robustness). These are cheap, and they stop the crash and respawn-loop class of bugs.
2. **H8** (dedicated IPC `URLSession`). This prevents spurious daemon kills under load.
3. **H1-H3** (anti-bot bridge: UA binding, cookie merge, per-origin de-duplication). Without them the Cloudflare bridge is largely ineffective.
4. **H9, M9, M10** (link-type handling in download and playback).
5. **H10**, if in-process isolation is still used in any shipped configuration.
6. **M8, M12-M14** (library and episode correctness).
7. The parity gaps, starting with subtitle search and tracker sync.
