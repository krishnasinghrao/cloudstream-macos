# CloudStream macOS — Player Remediation Plan

**Date:** 2026-09-30
**Scope:** Native video player — `MetalVideoView`, `MpvPlayerView`, `PlayerViewModel`,
`PlayerScreenView`, `PlayerHUDView`, `PlayerWindowController`, `NowPlayingService`,
`LibraryStore` (progress path) — plus the daemon `/links` pipeline
(`ProviderExecutor.loadLinks`, `URLSanitizer`).
**Method:** static code review (no runtime profiling). Items marked **(verify)** are strongly
implied by libmpv semantics but should be confirmed with Instruments / mpv properties.
**Relationship to other plans:** `Implementation-Plan.md` owns daemon/IPC defects,
`UI-Remediation-Plan.md` owns general UI. IDs here are prefixed per area
(A = architecture, R = rendering, T = threading/lifecycle, U = UI-thread cost,
N = system integration, D = design).

## TL;DR — root causes

1. **Software rendering, likely software decoding.** The render context uses mpv's `"sw"`
   API: every frame is converted and scaled on the CPU into a `CVPixelBuffer`, then
   GPU-blitted. The sw path has no hwdec interop, so `hwdec=videotoolbox` most likely falls
   back to CPU decode **(verify: `hwdec-current`)**.
2. **No frame pacing, one shared frame buffer.** Render is driven by mpv's update callback,
   not a display link; `report_swap` is never called; one pixel buffer is overwritten while
   the GPU may still sample it → judder and tearing.
3. **Slow start is a backend problem.** `/links` blocks until *every* extractor finishes
   (up to 90 s); the player then opens at 0:00 and seeks to the resume point; no loading UI.
4. **Main-thread blocking and churn.** Synchronous mpv calls on main; HUD re-evaluated at
   4 Hz; progress saves every 5 s invalidate the whole main window.

---

## 1. Architecture & backend

| # | Sev | Finding | Where |
|---|---|---|---|
| A1 | P0 | `"sw"` render API: CPU convert/scale to `bgr0` at up to 1920 px sized to the **window**, not the video. | `MetalVideoView.swift` |
| A2 | P0 | `/links` returns only after all extractors finish (`withTimeoutOrNull(90_000)`). | `ProviderExecutor.kt` |
| A3 | P1 | Links ranked by `quality` only; no liveness/throughput probe; no per-episode cache; no next-episode prefetch. | `ProviderExecutor.kt` |
| A4 | P1 | `URLSanitizer` strips `ref`/`track`/`crc`/`spm`/`aff`/`subid` from **stream** URLs → breaks whole-query signatures (403 → failover). | `Sanitizer.kt` |
| A5 | P1 | Client ignores `type`, `isPlaylist`, `extractorData`, and **per-audio-track headers** (`audio-add` with no headers → 403). | `MetalVideoView.swift` |
| A6 | P1 | No single owner of the mpv handle; transport goes through two paths (VM → view, and SwiftUI binding → `updateNSView`). | throughout |

**Target architecture**

```
PlaybackEngine (dedicated serial queue)        ← owns mpv_handle exclusively
  ├─ commands: async (mpv_command_async / mpv_set_property_async)
  ├─ events:   ordered delivery to the main actor (one queue, one consumer)
  └─ renderer: display-link driven, report_swap, rotating buffers, occlusion-aware
PlayerViewModel = projection of engine state + intents (no bindings written back)
```

* Short term: keep the sw path but decode with `videotoolbox-copy`, render at **video**
  size, rotate three buffers, pace with a display link. Mid term: OpenGL render API on
  `CAOpenGLLayer` with zero-copy VideoToolbox (IINA's approach). Strategic: dual engine —
  AVPlayer for HLS/MP4 (PiP, AirPlay, HDR), mpv fallback for MKV/ASS/exotic codecs.
* Daemon: `POST /links/stream` (NDJSON, like `/search/stream`); client plays the first
  link while the rest populate the Mirrors menu. Short-TTL per-episode link cache;
  prefetch next episode at ~80 %.
* Do not rewrite stream/subtitle URLs; keep sanitizing only persisted/displayed URLs.

## 2. Performance & stability

### Rendering

| # | Sev | Finding |
|---|---|---|
| R1 | P0 | No display link; `BLOCK_FOR_TARGET_TIME=0`; `mpv_render_context_report_swap` never called → uneven cadence. |
| R2 | P0 | Single `pixelBuffer` rewritten each frame while the GPU may still sample the previous frame → tearing. |
| R3 | P1 | `mpv_render_context_update()` flags ignored; `layout()`/`draw()` trigger full CPU re-renders. |
| R4 | P1 | Renders at full cost while occluded/minimized; `nextDrawable()` can stall the render queue ≤ 1 s. |
| R5 | P2 | `CVMetalTextureCacheFlush` never called; pixel buffer reallocated every live-resize step. |

### Threading / races / lifecycle

| # | Sev | Finding |
|---|---|---|
| T1 | P0 | `mpv_command` / `set_property` / `get_property` synchronous on main; `renderQueue.sync` + `mpv_terminate_destroy` on main during close. |
| T2 | P0 | Bidirectional `isPlaying` binding: late `pause=true` echo after `play()` sets `isPlaying=true` → **next episode starts paused**; rapid Space flip-flops. |
| T3 | P0 | Mirror failover loads twice: `failover()` → `loadStream(elapsed)`, then `updateNSView` sees new key → `loadStream(pendingStart)`; the second wins and seeks to the original resume point or 0. |
| T4 | P0 | `keep-open=yes` suppresses `END_FILE(eof)`; `eof-reached` observed but ignored → auto-next never fires. |
| T5 | P1 | Overlapping `play()` tasks are never cancelled; last network response wins. |
| T6 | P1 | One `Task { @MainActor }` per mpv event — no ordering guarantee; stale `END_FILE(error)` from a replaced file can double-failover. |
| T7 | P1 | Headers only set when non-empty → previous mirror's Referer/cookies leak into the next load. |
| T8 | P1 | `http-header-fields` is a comma-separated list but is set as a `\r\n`-joined string → UAs/cookies with commas are split; Referer/UA duplicated. |
| T9 | P1 | Resume opens at 0:00 then seeks on `FILE_LOADED` (double open). Use `start=`. |
| T10 | P1 | Fabricated audio track IDs from `link.audioTracks` don't match mpv's IDs. |
| T11 | P2 | `close()` inside `windowWillClose` re-enters `performClose`. |

### Main-thread / SwiftUI cost

| # | Sev | Finding |
|---|---|---|
| U1 | P1 | `PlayerHUDView.body` reads `elapsed` → whole HUD (all menus, episode list, linear `hasNext/hasPrevious`) rebuilt at 4 Hz. |
| U2 | P1 | `recordProgress` every 5 s bumps `LibraryStore.version` → main window re-renders and re-fetches on main. |
| U3 | P1 | Every mouse-move allocates a new HUD-hide `Task`; `acceptsMouseMovedEvents` unset **(verify)**. |
| U4 | P1 | Scrubber snaps back after seek (pre-seek `time-pos` ticks overwrite the optimistic value). |
| U5 | P1 | Display sleeps mid-movie — nothing takes `idleDisplaySleepDisabled`. |
| U6 | P2 | DEBUG mpv log level `v` through `NSLog`. |

### System integration

| # | Sev | Finding |
|---|---|---|
| N1 | P1 | `MPNowPlayingInfoCenter.playbackState` never set (required on macOS). |
| N2 | P2 | Control Center scrub bypasses the VM; no skip ±10 s commands. |

## 3. UI/UX vs macOS standards

| # | Finding | Fix |
|---|---|---|
| D1 | No loading/buffering state; first-play resolution errors are invisible. | Open window immediately with a "Finding streams…" state; buffering from `paused-for-cache` / `seeking`. |
| D2 | Single-click pauses; pairing with double-click delays every click ~300 ms. | Drop single-click pause; double-click = full screen, handled without the delay. |
| D3 | Key monitor ignores modifiers (⌘M, ⌘F, ⌘K hijacked); Space auto-repeat toggles. | Only bare keys; ignore `isARepeat` for Space. |
| D4 | Playback menu incomplete (no speed, tracks, delay, aspect, full screen; Play/Pause has no shortcut). | Complete it; disabled when idle. |
| D5 | Hand-built menu checkmarks (`HStack` + `Spacer` + `Image`) — `Spacer` is ignored in macOS menus. | `Picker(.inline)` / `Toggle` → native checkmarks. |
| D6 | Hand-rolled glass; no Reduce Transparency/Motion. | `glassEffect(.clear)` on 26+ over a scrim, material otherwise; solid under Reduce Transparency. |
| D7 | Traffic lights hidden via `superview.alphaValue` hack. | Keep; scoped and restored (low risk) — revisit with titlebar accessory. |
| D8 | No aspect-locked window, no black window background, no float-on-top. | `contentAspectRatio` from `video-params`, `.black`, "Float on Top". |
| D9 | Error banner only offers Dismiss. | "Try Next Mirror" / "Close" actions. |
| D10 | Volume slider hover-only; `.monospaced()` + `.monospacedDigit()` redundant. | Tidy; keyboard reachable via menu/arrows. |
| D11 | No trackpad scroll-to-seek / volume. | `scrollWheel` in the video view. |
| D12 | Episode menu unbounded and rebuilt at 4 Hz. | Isolated from the clock (U1); season-scoped. |

## 4. Implementation phases

1. **Correctness:** T4, T3, T7/T8, T2, D3, U5, N1.
2. **Responsiveness:** T1, U1/U2/U3/U4, T5/T6, T9, T10, T11.
3. **Perceived load:** A2 (`/links/stream`), D1, A3 (cache), A4/A5.
4. **Rendering:** A1 + R1–R5 (display link, report_swap, buffer ring, video-size render,
   occlusion, texture-cache flush).
5. **Design:** D2, D4–D12, N2.

Strategic items (OpenGL/`CAOpenGLLayer` zero-copy renderer, AVPlayer dual engine,
real PiP) are tracked as follow-up features — they need ADR updates (ADR-0001) and
runtime validation beyond this plan.

## 5. Implementation status (2026-09-30)

**Result:** phases 1–5 implemented. Client: Debug and Release build clean under
Swift 6 strict concurrency; **91/91** unit + live-engine tests pass. Daemon:
**72** tests, 0 failures (3 network-gated skips as before).

### Done

| Area | IDs | Implementation |
|---|---|---|
| Decode / render | A1, R1–R5 | `MetalVideoView`: `hwdec=videotoolbox-copy` (log-verified: *"Using hardware decoding (videotoolbox-copy)"*); render target = drawable aspect at ≤ native video resolution (`renderSize`), capped at 1920; `CVPixelBufferPool` + 3-frame in-flight semaphore, buffers recycled only after GPU completion; `NSView.displayLink` pacing, `mpv_render_context_report_swap`, default `BLOCK_FOR_TARGET_TIME`; render only on `MPV_RENDER_UPDATE_FRAME`; occluded windows consume frames via `MPV_RENDER_PARAM_SKIP_RENDERING`; texture-cache flush per frame. |
| Async engine | T1 | All transport via `mpv_command_async` / `mpv_set_property_async`; teardown = sync callback detach + ordered off-main chain (event queue → render queue → `mpv_terminate_destroy` on a utility queue). |
| Single state direction | T2, T3 | `@Binding isPlaying` removed; engine `pause` is projected read-only (`handleEnginePause`). `StreamLoadRequest` (monotonic `id`) is the only load path — failover/episode change issue one request; the representable loads once per id. |
| EOF | T4 | `eof-reached` → `onEndOfFile`, deduplicated per file with END_FILE(eof). |
| Overlapping plays | T5 | `playGeneration`; stale resolutions/sessions are discarded. |
| Event ordering | T6 | Main-queue FIFO delivery (`MpvCore.deliver`); END_FILE filtered by `playlist_entry_id` of the current START_FILE. |
| Headers / start | T7, T8, T9 | Per load: `http-header-fields` as `MPV_FORMAT_NODE_ARRAY` (no comma splitting), `referer` / `user-agent` always reset (UA restored to mpv's default); `loadfile … replace -1 start=<t>`. |
| Tracks | T10 | IDs from `track-list` only; `aid`/`sid` = "no" surfaces as 0 ("Off"). |
| Close | T11 | `close(fromWindow:)`. |
| HUD cost | U1 | `PlaybackClock` observed only by `ClockedTimelineScrubber`; `hasNext/PreviousEpisode` cached. |
| Progress writes | U2 | 15 s cadence; `recordProgress(notifyObservers: false)` saves without bumping `LibraryStore.version`; session boundaries notify. |
| HUD timer | U3 | One deadline-driven hide task; `acceptsMouseMovedEvents = true`. |
| Scrub snap-back | U4 | `seekTarget` suppresses stale ticks until the engine confirms; relative seeks become absolute from the optimistic clock. |
| Display sleep | U5 | `ProcessInfo.beginActivity(.idleDisplaySleepDisabled)` while a session plays. |
| Logging | U6 | DEBUG mpv log level `info` (was `v`). |
| Now Playing | N1, N2 | `playbackState`, media type, previous-track and ±10 s skip commands; scrubbing routed through the VM. |
| Progressive links | A2 | Daemon `POST /links/stream` (NDJSON). Client `DaemonClient.linksStream` (falls back to `/links` on 404/405); the VM starts 1.5 s after the first link (or at `done`) with the best link so far; late links join Mirrors, late subtitles are `sub-add`ed live. |
| Cache / prefetch | A3 | Daemon 3-min LRU cache per `(provider, data)` (non-empty only); client warms the next episode at 80 %. |
| Stream URLs | A4 | `URLSanitizer.sanitizeStream` — only unambiguous marketing IDs removed; untouched URLs returned byte-for-byte. |
| Playlist links | A5 | `ExtractorLinkPlayList` plays through length-prefixed `edl://`. |
| Loading / errors | D1, D9 | Window opens at resolution start ("Finding Streams…"); loading/buffering spinners (`paused-for-cache`); error card with "Try Next Mirror" / "Close"; first-play failures are now visible. |
| Interaction | D2, D3, D11 | Single-click pause removed (no double-click delay); key monitor handles bare keys only (⌘M/⌘F/⌘K restored), ignores Space/F/M/N auto-repeat; Z/X subtitle delay; trackpad horizontal = seek, vertical = volume. |
| Menus | D4, D5, D12 | Playback menu: Play/Pause, skip, next/previous episode, mute/volume, Speed, Audio & Subtitles, Aspect Ratio, Quality & Mirrors, Float on Top, Player Full Screen — disabled without a session. All selections are `Picker(.inline)` → native checkmarks. Episode menu scoped to the current season. |
| Glass / a11y | D6, D10 | `PlayerHUDSurface`: `glassEffect(.clear)` on macOS 26+, material before, opaque under Reduce Transparency, stroke under Increase Contrast; top/bottom scrim; Reduce Motion → opacity transitions; volume slider always visible. |
| Window | D8 | `contentAspectRatio` from `dwidth/dheight` + one-time fit per aspect; black background; `.fullScreenPrimary`; Float on Top. |

### Verification

* **Live engine tests** (`PlayerEngineLiveTests`, `PlayerViewModelLiveTests`; run with
  `CS_MPV_ENGINE_TESTS=1 CS_IN_MEMORY_DB=1` and the `/tmp/test_stereo.mp4` fixture):
  30 fps fixture presents 64–65 of 65 available frames over ~2.2 s across 5 runs (no drops);
  CPU render ≈ **3.8 ms/frame** at 720p with target-time blocking disabled for measurement
  (≈ 19 ms/frame including mpv's intentional pacing wait); 200 transport commands < 50 ms
  on main; `shutdown()` < 20 ms on main; `start=` opens at ≥ 2.0 s for a 2.5 s resume;
  EOF under keep-open fires exactly once; mirror replace produces no failover;
  replacing a playing session starts unpaused; no clock snap-back after seek;
  movie EOF closes the player.
* **Stability:** 8 consecutive full-suite runs, 91/91 each. One earlier run presented 0
  frames in the pacing window while the clock advanced — consistent with the test
  window being occluded by the host app (occluded windows skip rasterization by
  design, R4). The test window now floats above other windows and the assertion reports
  its occlusion state; no recurrence since.
* **Pure logic** (`PlayerRemediationTests`, `QuietProgressPersistenceTests`): render sizing,
  header splitting, EDL encoding, track projection, delay stepping, quiet progress saves.
* **Daemon** (`LinksStreamingTest`, `URLSanitizerTest`): first link emitted immediately
  while a slow extractor is still running; quality-sorted final response; subtitle
  de-dup; cache replay without re-running extractors; signed query preservation.
  An isolated daemon (scratch `cs.cloudstream.home`) answered `/links/stream` with 401
  unauthenticated and 400 + usage for an unknown provider.
* **HUD render check:** layout snapshot of the player window (title, scrubber, transport,
  always-on volume, trailing menus).

### Regression found in use and fixed (2026-09-30)

Every mirror failed ("All N mirrors failed"). Cause: T8 moved Referer out of
`http-header-fields` into mpv's referer option, but the option is spelled
`referrer`; mpv ignored the misspelling silently (the pre-existing code had the
same misspelling, masked by also sending Referer as a header line). Result: no
Referer on any request → 403 on protected CDNs. Also, the `referrer` option
cannot be unset once written (an empty value still sends `Referer:`).

Fix: Referer is sent only as a header line (the list resets cleanly per load);
User-Agent keeps the dedicated option. Guard rails: every setup option's return
code is checked (`rejectedOptions`, logged) — this immediately exposed a second
long-dead option, `sw-fast`, now removed — and async property/command failures
are logged from `MPV_EVENT_SET_PROPERTY_REPLY` / `COMMAND_REPLY`. New live tests
serve the fixture from a header-logging HTTP server and assert Referer, User-Agent
and a comma-containing header arrive, that nothing leaks into a later header-less
load, and that no setup option is rejected. Client suite: 93/93.

### Not done / residual risk

* **Client happy path of `/links/stream` against real providers** was not exercised
  live (requires synced plugins + network). Covered by daemon tests; the client parser
  mirrors the proven `/search/stream` path and falls back to `/links`.
* **Before/after CPU comparison** of the old pipeline was not measured; only the new
  pipeline's per-frame cost is recorded above.
* **Per-audio-track headers (A5):** external audio uses the load's global headers.
  The daemon defaults audio headers to the link's, so this only differs when an
  extractor sets distinct audio headers.
* `type` / `extractorData` remain unused by the client (mpv probes the container).
* **D7** (traffic-light fade via the titlebar container) intentionally kept.
* **Strategic follow-ups** (need ADR updates and runtime validation): OpenGL render API on
  `CAOpenGLLayer` for zero-copy VideoToolbox; AVPlayer engine for HLS/MP4 with real PiP,
  AirPlay and HDR/EDR.

---

## 6. Startup, resume, and A/V sync (2026-09-30)

Reported: slow start with initial jitter; resume at 10:00 starting at 0:00 with no
audio, then visibly "fast-forwarding"; audio/video desync.

### What the providers actually deliver (measured)

| Provider | Delivery | Notes |
|---|---|---|
| YouTube (NewPipe) | **Split DASH-style progressive**: video-only MP4/WebM per quality + 5 separate audio files (AAC 48/128 kbps, Opus 50/70/160 kbps) | googlevideo CDN, Range-capable, no custom headers |
| Twitch / Dailymotion | HLS (muxed) | |
| Invidious | YouTube-derived (split or proxied) | |

### Root causes (reproduced)

| # | Finding | Evidence |
|---|---|---|
| S1 | **CDN throttling of open-ended GETs.** mpv/ffmpeg open a single `Range: bytes=0-` request; googlevideo throttles it to ~2 Mbit/s. | curl: 248 KB/s open-ended vs. 1 MB in 0.68 s bounded. Current path, resume 5:00: 0.10× for 2 s, 2.5 s frozen, only 4.4 s buffered after 10 s. |
| S2 | **Split audio attached after load** (`audio-add` ×N on FILE_LOADED): silent first frames, one connection per track, and a starved video track falling behind free-running audio. | Resume timeline: video frozen at 300.17 while audio advanced to 301.20, then snapped back to 300.25. `aid=no` for the first 100–200 ms. |
| S3 | **Unseekable sources silently discard the resume point.** Server ignoring Range (or live/event playlists) → `Cannot seek in this stream` → plays from 0:00. The old post-load `seek` instead read/decoded forward to the target — the visible "fast-forward". | Bench `norange … resume600`: `firstPos=0.00` + mpv error. |
| S4 | **"Ready" signalled on FILE_LOADED**: the spinner hid over a frozen first frame while the audio renderer started (~0.5 s cold start of AVFoundation's renderer, once per process). | Bench: first frame at 0.5 s, playback at 1.1 s (cold) vs. 0.75 s (warm). `ao=coreaudio` produces no audio (not an option). |
| S5 | Provider runtime metadata used as the initial timeline (YouTube reports seconds as minutes → ~10-hour timeline). | `durationMinutes: 597` for a 9:57 video. Resolved separately by not seeding the timeline from metadata. |
| S6 | Lazily opened EDL tracks listed as "null": `!delay_open` must carry `codec=` and precede `!track_meta`. | Verified against mpv 0.41 with three syntax variants. |

### Fixes

* **Chunked, resilient HTTP** (`stream-lavf-o`): `request_size=4MiB`, keep-alive,
  `reconnect*`. Bounded ranges defeat throttling; reconnect hides transient errors.
* **Unified split streams** (`PlayerViewModel.loadPlan` → `mergedSplitURL`): one EDL
  manifest (`!new_stream` per audio) — video and the preferred audio (user language →
  AAC → bitrate) open, buffer and seek together on one timeline; alternates are
  `!delay_open` with codec + title/language, downloaded only if selected.
* **Resume policy** (`handleSeekable`): if mpv reports the source unseekable while a
  resume is pending → fail over to the next mirror at the resume point; if none is
  left, keep playing and show a notice instead of silently restarting.
* **Ready = PLAYBACK_RESTART** only; the loading spinner covers the audio start-up.

### Results — real YouTube (Big Buck Bunny, 720p), 10 s windows

| Path | Start → playing | Rate first 2 s | Stall samples | Buffered after 10 s | Resume lands at |
|---|---|---|---|---|---|
| Before, fresh | 0.92 s | 0.85× | 0 | 8.3 s | — |
| Before, resume 5:00 | 2.44 s | **0.10×** | **25** | **4.4 s** | 300.00 (then froze) |
| **After, fresh** | **0.53 s** | **1.01×** | **0** | **279 s** | — |
| **After, resume 5:00** | **1.05 s** | **0.99×** | 0 before the deliberate audio switch | **121 s** | **300.04** |

A/V offset after start: ≤ 37 ms converging to 0 (within ±45 ms lip-sync tolerance).
Unseekable-first mirror + seekable second mirror, resume 300 → fails over, lands at 300.0.

### Industry-standard follow-ups (not in this change)

* **Adaptive bitrate for progressive DASH**: choose the initial quality from measured
  throughput (start ~720p, up-switch after buffer health) the way AVPlayer/ExoPlayer do
  with HLS/DASH ABR; today the highest quality link is chosen.
* **Real DASH/HLS manifests** where the source offers them (YouTube's DASH MPD /
  HLS for some formats) so the player can switch bitrate mid-stream.
* **Audio renderer pre-warm** at app launch to remove the one-time ~0.5 s cold start.
* **AVPlayer engine** for HLS/MP4 (native ABR, PiP, AirPlay) as in §1.

Benchmarks: `PlayerStartupBenchmarkTests` (gated by `CS_MPV_BENCH=1`; a
range-capable, latency/bandwidth-throttled local CDN simulator + optional real
YouTube URLs via `CS_YT_DIR`).

