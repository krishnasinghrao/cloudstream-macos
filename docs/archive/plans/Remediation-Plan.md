# CloudStream macOS — Remediation & Hardening Plan

> **Superseded (4 October 2026).** Kept for history; its "OPEN" rows date from September and are largely fixed. The single list of open work is [Remaining-Work.md](../../Remaining-Work.md).


**Status:** Proposed · **Baseline:** Post-implementation audit (2026-09-28)
**Scope:** Close every gap in the audit — 7 P0 defects, P1 functional completeness, P2 enterprise hardening — with a test-first workflow, versioned IPC contract, and CI-gated delivery.

---

## 0. Principles (apply to every workstream)

1. **Contract first.** The daemon↔client IPC schema is a versioned contract (`ipcVersion`). Any endpoint change bumps it; both sides must pass golden-file contract tests against the same fixtures before merge.
2. **Empirical verification or it didn't happen** (repo AI-POLICY rule 2). Every workstream ends with a runnable verification command whose output is pasted into the PR description.
3. **Tests are written in the same PR as the code** — daemon logic in JUnit, client logic in XCTest. No workstream is "done" with red or missing tests.
4. **No silent failures.** Every error path added by this plan surfaces to (a) the user where actionable, (b) structured local logs always (SEC-03 compliant — local only).
5. **ADRs for decisions.** Each Decision Point (DP-x) below gets a short Architecture Decision Record in `docs/adr/`.

---

## 1. Workstreams

### WS-1 — IPC Contract v2 (foundation; enables 5 other workstreams)

**Objective:** Evolve the daemon↔client protocol once, versioned, instead of piecemeal.

| Change | Design |
|---|---|
| **1.1 `POST /links`** | Move link resolution to a JSON body: `{"plugin": "...", "data": "..."}`. Multi-KB `episode.data` strings currently ride in the GET URI and will exceed Netty's request-line limits for real providers. GET kept for one release, logged as deprecated. |
| **1.2 `GET /home`** | New endpoint: `?plugin=<id>&page=1` → `HomePageDto {provider, lists: [{name, isHorizontal, items: [SearchResultDto]}]}`. Calls `MainAPI.getMainPage(page, HomePageRequest())` under `withTimeoutOrNull(getMainPageTimeoutMs ?: 10s)` on `Dispatchers.IO`, with the same `safeProvider` barrier. Handle the legacy `getMainPage()` overload via the existing `NotImplementedError` fallback pattern. |
| **1.3 Anti-bot loop (closes P0-1)** | Full circuit: <br>• **Detection:** an OkHttp interceptor installed on the global `var app` client (the library exposes it as `var` in `library/.../MainActivity.kt` — we rebuild `app` at daemon startup with our interceptor + cookie jar; investigate whether `Requests` accepts a custom client directly, else rely on the `var` reassignment). Trigger: status 403/503 + `server: cloudflare` header or `__cf_chl` body marker. <br>• **Park & notify:** interceptor creates `SolveBridge.newTask(url)`, awaits ≤90 s, retries the request once with the solved cookies. <br>• **Exposure:** new `GET /solve/pending` → `[{taskId, targetUrl, ageMs}]`. <br>• **Client:** `WebViewSolverService` polls `/solve/pending` every 2 s while any IPC scrape is in flight (and once on user-visible failure), runs the offscreen WKWebView, POSTs `/solve-callback`. <br>• **Application:** solved cookies are injected by the interceptor for the matching host, not stored in a map nobody reads. |
| **1.4 `GET /search/stream` (progressive results)** | SSE (ktor-server-sse) emitting `provider_result` / `provider_error` / `done` events; per-provider 5 s timeout unchanged; overall stream closes at 6 s. Client consumes via `URLSession.bytes` `AsyncSequence`, updating `AppState.searchResults` incrementally. Non-streaming `/search` retained for tests/compat. Fallback if SSE proves brittle: NDJSON chunked response. |
| **1.5 Versioning & docs** | `HealthDto` gains `ipcVersion: Int` and real build version (replaces hardcoded `1.0.0`); client verifies at connect and shows an explicit incompatibility banner on mismatch. New `docs/ipc-api.md` is the single source of truth; golden JSON fixtures live in `engine/src/test/resources/contracts/` and are consumed by both daemon contract tests and Swift tests. |

**Tests:** ktor `testApplication` contract tests per endpoint against golden fixtures; MockWebServer test proving the interceptor parks, receives cookies via a fake `/solve-callback`, and retries; SSE stream test with a slow fake provider (assert early results arrive before timeout).
**DoD:** `curl` transcript for every endpoint in PR; contract fixtures pass on both sides; `/solve` loop demonstrated with a local mock challenge server.

---

### WS-2 — Daemon resilience & lifecycle (closes P0-2)

| Change | Design |
|---|---|
| **2.1 Persistent engine state** | Daemon persists repos + plugin metadata to `~/.cloudstream-macos/state/state.json` (inside the SEC-06 sandbox). On boot: auto-load cached `.cs3` sources → re-verify hashes against cached manifests (offline-safe) → attempt repo refresh in background. A daemon restart self-heals without client involvement. |
| **2.2 Supervisor redesign** | `DaemonSupervisor` publishes `daemonState` plus an `AsyncStream<DaemonEndpoint>`; `AppState` consumes the stream and re-points `DaemonClient` on every (re)spawn. After `ready`, a heartbeat task pings `/health` every 2 s; 3 consecutive misses → restart. On respawn, client refreshes `/plugins` + `/repos` (cheap; state self-heals per 2.1). |
| **2.3 Graceful quit, no orphans** | `NSApplicationDelegateAdaptor` + `applicationShouldTerminate` → `supervisor.stop()` (SIGTERM → 3 s → SIGKILL), daemon spawned in its own process group so the group dies with it. Unit-test the restart state machine; manual test: `kill -9` the java process while the app runs and assert recovery ≤ 5 s. |
| **2.4 Logging & diagnostics (closes "logs to nullDevice")** | Replace println-style output with a small `DaemonLog` writing JSON lines to `~/.cloudstream-macos/logs/daemon.log` (5 MB rotation, 3 files, no tokens/credentials — redaction helper). Supervisor tees child stdout/stderr into `process.log` instead of `FileHandle.nullDevice`. Uncaught-exception handler writes `last_error` (stack + plugin currently loading, mirroring Android). New authenticated `GET /diagnostics`: uptime, per-provider request/error counters, solve-task states. Settings gains an "Engine Diagnostics" pane rendering it. |
| **2.5 Provider enable/disable + config (enables 5.7)** | Disable list + per-provider overrides (`mainUrl` clone-site, free-form `storedCredentials`) persisted in `state.json`; `/search`, `/home`, `/links` skip disabled providers; `/plugins` reports `enabled`, `lastError`, `apiVersion`, `verified` fields. |

**Tests:** state-file round-trip; boot-from-cached-sources with network disabled; heartbeat/restart state machine (virtual clock); log redaction unit tests.
**DoD:** `kill -9` chaos test green; daemon restart with airplane-mode simulation still serves search from cached plugins.

---

### WS-3 — Media pipeline correctness

**Objective:** Playback and downloads behave correctly under failure, matching Rules.md §4.3.

| Change | Design |
|---|---|
| **3.1 END_FILE reasons (closes P0-5)** | `MpvCore.drainEvents` reads `mpv_event_end_file` (`event.data` → `mpv_event_end_file.reason`). Map: `ERROR` → `PlayerViewModel.handlePlaybackError()` (advance to next mirror; user-visible banner only when mirrors exhausted), `EOF` → auto-play next episode (series only), `STOP/QUIT` → no-op. Remove the current unconditional "play next" wiring. |
| **3.2 Track enumeration & switching** | Observe `track-list` (`MPV_FORMAT_NODE`) with a small recursive `mpv_node` → `MpvNode` Swift walker. Publish `audioTracks` / `subtitleTracks` / `videoTracks` (`TrackInfo{id, type, title, lang, default, forced, codec}`); HUD menus populate from these; selection via `aid`/`sid`/`vid`. HLS variant quality stays automatic (mpv-native); the mirror menu remains the manual quality/server control. |
| **3.3 Subtitle styling** | HUD popover adds font size (`sub-font-size`), outline width, text/background color (`sub-color`, `sub-back-color`) + the existing ±2.5 s delay; styles persisted in `UserPreferences`. |
| **3.4 Error surfacing** | `PlayerViewModel.error` (published): link resolution failure, empty link list, all-mirrors-exhausted, mpv fatal error — rendered as a dismissible HUD banner. `play()` no longer silently no-ops on data-less details. |
| **3.5 Robust keyboard handling** | Replace the `KeyCatcher` NSView with an `NSEvent` local monitor installed only while a session is active; full Design.md §6 matrix; monitor removed on close. |
| **3.6 Downloads 1.0** | • SwiftData `DownloadRecord` (path, size, status, provider/episode coordinates, timestamps) = the "Downloaded Titles" tab (real files, existence-checked, missing-file state).<br>• Persisted queue: enqueue inserts a record; app start re-enqueues unfinished items (safe because resolution is JIT).<br>• Completion → `UNUserNotificationCenter` notification with Reveal action (permission requested on first download) + optional auto-add-to-library setting.<br>• Failure taxonomy: parse ffmpeg stderr tail (403/404, "Protocol not found", disk full) → user-facing reason + automatic mirror failover (existing) with the reason surfaced.<br>• Concurrency setting `maxConcurrentDownloads` (default 2). Pause semantics documented: >60 s pause restarts the item with a fresh JIT link (HLS `-c copy` cannot resume mid-file).<br>• Local playback: completed rows get a Play action (`loadfile` with `file://`). |
| **3.7 Budget regression gate** | `scripts/budget_check.sh`: daemon startup (target ≤1.2 s) + idle RSS + a deterministic `-c copy` throughput fixture (ffmpeg `testsrc` HLS generated locally, no network). Runs in CI. 4K-decode CPU remains a documented on-hardware manual check. |

**Tests:** END_FILE reason mapping table test via a fake event pump (extract drain logic behind a protocol); `mpv_node` walker tests on fixture bytes; DownloadRecord persistence; ffmpeg argument-builder golden tests; failure-taxonomy parser table tests.
**DoD:** scripted chaos run: play → kill link (proxy 403) → assert automatic mirror switch without dialog; download completes with notification + record; `budget_check.sh` green in CI.

---

### WS-4 — Security hardening (Fort Knox, made honest)

| Change | Design |
|---|---|
| **4.1 Token via stdin (closes ps-leak)** | Supervisor writes the token to the child's stdin pipe; daemon prefers stdin, still accepts argv with a loud warning for dev. `ps` no longer reveals the credential. |
| **4.2 Repo authenticity (SEC-07 upgrade)** | • Daemon rejects non-`https://` repo URLs (currently only the UI enforces this).<br>• Ed25519 (JDK 17 `java.security`) signature support: `repo.json` may carry `signature` over its canonical body. First sync pins the repo key (fingerprint shown to the user in Settings with an explicit trust action — TOFU); later syncs verify; mismatch → refuse with an actionable error. Unsigned repos remain usable but are badged **Unverified** in Settings with a settings-level warning toggle.<br>• ADR documenting the residual risk (in-process plugins remain fully trusted — inherent to the model). |
| **4.3 Rate limiting** | Simple per-endpoint token bucket on the daemon (e.g., 20 req/s search, 5 req/s sync) returning 429 — bounds runaway clients. |
| **4.4 `docs/Security.md`** | Assets, trust boundaries, plugin capability statement, threat model, residual risks. Required artifact for calling the posture "Fort Knox". |

**Tests:** Ed25519 verify/reject against fixture manifests (good, tampered, wrong-key, unpinned); stdin token delivery integration test; rate-limit burst test.
**DoD:** tampered `repo.json` fixture rejected with fingerprinted error; `ps` audit shows no token.

---

### WS-5 — Client UX completeness

| Change | Design |
|---|---|
| **5.1 Navigation refactor (closes P0-6 uniformly)** | Replace sheet-based details with a `NavigationStack` path in the detail column (`path: [DetailsDTO-ish]`). One `openDetails()` works from Home, Search, Library, Downloads, and deep links; Esc pops; keyboard-driven. |
| **5.2 Library & Downloads wiring** | Library poster → openDetails; context menu: WatchType set/clear, remove. Downloads completed rows: Play (local), Reveal in Finder, delete file + record. Disk meter refreshes on appear + while visible. |
| **5.3 Home with getMainPage** | HomeView renders `/home` shelves (2:3 vs 16:9 per `isHorizontalImages`), Continue Watching stays first, toolbar refresh, per-provider 5-min TTL cache, reload on provider switch. |
| **5.4 Details parity with Design.md §4.3** | Dub/Sub toggle (daemon maps `AnimeLoadResponse` episodes with an `audio: dub|sub` field; DTO + filter UI), episode sort selector (1-N / N-1 / latest), Server pill (Auto = quality-ordered; specific extractor filter applied client-side to `/links` results). |
| **5.5 Search parity** | TvType filter chips (client-side on `type`), infinite scroll using `page`, language chip, progressive results via SSE. |
| **5.6 Extensions management UI** | Settings → Extensions: plugin cards (providers, language, version, apiVersion, verified badge, enable toggle, error reason from `/plugins` + `/diagnostics`), remove plugin (daemon: `beforeUnload()` + registry removal + classloader drop; document GC caveat; restart prompt if unload is incomplete). |
| **5.7 Provider settings** | Per-provider URL override (clone-site) + `storedCredentials` editing → daemon 2.5 persistence (fixes Invidious returning zero results). |
| **5.8 Image pipeline** | `ImageCache` actor (NSCache + disk cache under `~/Library/Caches/CloudStreamMac/images`), `CachedPosterImage` view with in-flight cancellation. Replaces bare `AsyncImage` everywhere. |
| **5.9 Deep links** | `cloudstreamrepo://`, `cloudstreamapp://`, `cloudstreamplayer://` via `CFBundleURLTypes`; repo links open a confirm sheet (no persist-before-confirm — fixing the Android-side pattern at the source); player links route to search/details. |
| **5.10 Onboarding** | First launch: welcome → auto official-repo sync with progress → default provider pick. Gated by `UserDefaults` flag. |
| **5.11 State views & error surfaces** | Shared `StateView` (loading/empty/error + retry) adopted by Home/Search/Library/Downloads; engine errors surface beyond the current spawn-only banner. |

**Tests:** navigation path unit tests; view-model tests for Home caching and search filtering; deep-link router table tests; snapshot tests optional (decision: skip — brittle under SwiftUI churn — noted in ADR).
**DoD:** scripted end-to-end run: launch → onboarding → search → details → play → download → library badge update, executed on real hardware and recorded in the PR.

---

### WS-6 — Packaging & clean-machine launch (closes P0-4)

| Change | Design |
|---|---|
| **6.1 Dependency closure** | `scripts/bundle_media.sh`: walk `otool -L` recursively for `ffmpeg` + `libmpv.dylib`, copy deps into `Contents/Frameworks/`, rewrite IDs/rpaths (`install_name_tool`), excluding `/usr/lib` + System frameworks; sign every rewritten dylib. Verification: copy the built `.app` to `/tmp`, run with `HOME=$(mktemp -d)` on a clean account/VM, confirm both binaries load (clean-machine proxy). |
| **6.2 Slim ffmpeg** | Replace Homebrew ffmpeg with a purpose-built minimal binary: demuxers/muxers only (mov/mp4, matroska, mpegts, adts, webm, HLS), protocols (http/https/tls/hls), no filters/encoders (pure `-c copy`). ~3–5 MB instead of dragging 36 Homebrew libs; also rescues the 180 MB/95 MB size budgets. Built reproducibly in CI (documented configure flags). |
| **6.3 Universal builds** | Client binary + media libs: lipo across arm64/x86_64 CI runners. JRE cannot lipo — ship `Resources/runtime-arm64` + `runtime-x86_64`, supervisor selects by `CPU_TYPE` (ADR). |
| **6.4 Full nested signing** | `package_app.sh` signs, in order: every bundled dylib → `runtime-*/bin/java` **with a dedicated java entitlements plist** (`allow-jit`, `allow-unsigned-executable-memory`, `disable-library-validation`) → jli/AI helper libs → the app. Then `codesign -vvv --strict` + `spctl assess`. |
| **6.5 Notarization & release** | notarytool `--wait` with timeout handling, stapler, release DMG upload; secrets documented (`CS_SIGNING_IDENTITY`, `CS_KEYCHAIN_PROFILE`). |
| **6.6 CI** | `.github/workflows/macos.yml`: `daemon` job (Gradle test + fat jar), `client` job (xcodegen + `xcodebuild build` + `xcodebuild test` — full Xcode runners also close the macro-compile gap), `package` job (tag-triggered, runs 6.1–6.5, uploads artifacts). Enable Dependabot for Gradle catalog. |
| **6.7 Versioning** | Single version source (`gradle.properties` `csVersion`) → BuildConfig + Info.plist via xcodegen settings; `/health` reports it; About window shows client/daemon/IPC versions. |
| **6.8 Updates** | v1: signed `latest.json` on GitHub Releases, semver compare, update banner with download link (no auto-install). Sparkle adoption deferred (DP-2). |

**DoD:** Phase 5 exit criterion executed for real — DMG installed on a machine with no Java/Dev Tools, app launches, providers load, playback + download work, zero Gatekeeper prompts; `du` sizes reported against Rules.md §3 budgets.

---

### WS-7 — Quality system (woven through all milestones)

| Area | Plan |
|---|---|
| **Daemon tests** | `SanitizerTest` (tracking stripped; `token/expires/signature/hmac/id` preserved — golden cases + property-based fuzz on param names), `RepositoryServiceTest` (missing/mismatched hash, size mismatch, https enforcement), `ProviderExecutorTest` (API fallback, timeout cancellation, provider isolation — fake `MainAPI`s), `SolveBridgeTest`, `PluginBridgeTest` with a **committed deterministic test plugin** (tiny `.cs3` built once and checked in) enabling offline end-to-end loading tests. |
| **Client tests** | URLProtocol-stubbed `DaemonClient` tests; `DownloadService` argument builder + state-machine tests; `LibraryStore` tests against in-memory `ModelContainer` (the `CS_IN_MEMORY_DB` hook already exists); view-model tests with a `TransportControlling` protocol seam replacing the concrete `MetalVideoView` reference in `PlayerViewModel`. |
| **Static analysis** | Detekt + ktlint for the daemon module; SwiftLint + warnings-as-errors for the client; both wired into CI. |
| **Accessibility** | Every interactive element labeled; VoiceOver pass per screen; hover-scale respects Reduce Motion; keyboard-only audit of the Design.md §6 matrix. |
| **Localization** | Extract all strings into a String Catalog (`Localizable.xcstrings`); export script producing Weblate-compatible JSON so the existing translation community can contribute. |
| **Performance** | `os_signpost` spans for launch → first render → engine-ready; image decode off main; CI-tracked daemon budgets (3.7); client budgets documented as on-hardware checks. |
| **Docs & ADRs** | `ipc-api.md`, `Security.md`, README refresh, and ADRs for: DP-1 sw-render fallback, DP-2 update mechanism, DP-3 plugin unload semantics, DP-4 PiP scope, DP-5 universal JRE layout. |

---

## 2. Decision Points (require a human call before the owning milestone)

| DP | Question | Recommendation |
|---|---|---|
| DP-1 | DMG distribution: universal single DMG (~130+ MB, blows the 95 MB budget) vs **per-arch DMGs** | Per-arch DMGs; document budget amendment in Rules.md |
| DP-2 | Auto-update: signed-banner v1 vs Sparkle | Banner v1; Sparkle later if desired |
| DP-3 | Plugin removal: best-effort runtime unload vs restart-prompted reload | Try unload, fall back to prompt |
| DP-4 | PiP: real `AVPictureInPictureController` requires SampleBuffer rendering mpv cannot provide — detachable mini-window vs cut the feature | Detachable mini-window, honest labelling in UI |
| DP-5 | Keep 5 s progressive-search budget when a provider is mid-challenge (solve may exceed it) | Failed-challenge providers surface a "solving…" chip and results arrive via the stream when solved |

## 3. Milestones, dependencies, estimates

| # | Milestone | Contains | Depends on | Est. |
|---|---|---|---|---|
| M1 | Self-healing engine | WS-2.1–2.4, WS-1.1, WS-4.1, CI skeleton (6.6 daemon job), budget_check.sh | — | 3 d |
| M2 | Contract v2 | WS-1.2, 1.4, 1.5 (+ client SSE consumption) | M1 | 3 d |
| M3 | Playback correctness | WS-3.1–3.5, 3.7 | M1 (test pump) | 3 d |
| M4 | Downloads 1.0 | WS-3.6 | M1 | 2 d |
| M5 | Security model | WS-4.2–4.4, Security.md | M1 | 2 d |
| M6 | UX completeness | WS-5.1–5.11 | M2 (home/SSE) | 5 d |
| M7 | Clean-machine packaging | WS-6.1–6.5, 6.7–6.8 | M1 (jar), ideally before M6 ends for discovery | 4 d |
| M8 | Quality closeout | WS-7 remaining (a11y, l10n, lint gates), docs/ADRs | all | 3 d |

**Total ≈ 25 working days** for one engineer with the CI runner available; M7's discovery work (6.1/6.2) should start during M2 because what it learns about bundle size can force scope changes (e.g., runtime pruning).

## 4. Traceability — audit finding → plan item

| Audit finding | Plan item(s) |
|---|---|
| P0-1 Anti-bot loop dead end-to-end | 1.3 |
| P0-2 Daemon restart loses engine + stale endpoint | 2.1, 2.2 |
| P0-3 No `/home` / getMainPage | 1.2, 5.3 |
| P0-4 Bundled binaries missing dylib closure; JRE unsigned | 6.1, 6.4 |
| P0-5 Playback failover never fires | 3.1 |
| P0-6 Library/Downloads don't navigate | 5.1, 5.2 |
| P0-7 `/links` GET length risk | 1.1 |
| Logs discarded (nullDevice) | 2.4 |
| Token visible via `ps` | 4.1 |
| SEC-07 integrity-only | 4.2 |
| Downloads: no real file tracking/persistence/notifications | 3.6 |
| Track lists, subtitle styling, error surfacing | 3.2, 3.3, 3.4 |
| Progressive search, TvType filters, pagination | 1.4, 5.5 |
| Provider config (Invidious instance), enable/disable | 2.5, 5.6, 5.7 |
| Image caching, deep links, onboarding, states | 5.8–5.11 |
| Universal builds, version sync, updates, CI, tests, a11y, l10n | 6.3, 6.6–6.8, 7 |

## 5. Definition of Done (repo-wide)

- [ ] Every audit P0 item has a merged fix with a test that fails without it.
- [ ] `./gradlew :engine:test` and `xcodebuild test` green in CI on every PR.
- [ ] `scripts/budget_check.sh` green; bundle sizes reported per build.
- [ ] Phase 5 exit criterion executed on a clean machine and recorded.
- [ ] `ipc-api.md`, `Security.md`, ADRs for DP-1…DP-5 merged.
- [ ] Zero silent-failure paths: every daemon error reachable from `/diagnostics`, every client error reachable from UI or logs.
