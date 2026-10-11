# Remaining work (macOS app)

Open-source companion client for macOS, built for Apple Silicon Macs.
Preparing for public open-source release under GPL-3.0. Sections are in
the order to do them. Tick items off as they are done.

## How to verify a change (standing rule, never ticked off)

- Build the app (`make build`) and use the built app, not only the test suites.
- Search, open a title and load links on 2–3 extensions you use.
- Check `~/Library/Logs/CloudStreamMac/daemon-stdout.log` for `worker.killed`, `worker.crashed` or `daemon.recovery` from that session.

## 1. Housekeeping (cheap, protects your work)

- [x] Commit this list (`docs/Remaining-Work.md`) and the Jackson re-triage (`engine/advisory-triage.json`, `Dependency-Review.md`): keeping Jackson 2.13 is fine for personal use.
- [x] Decide on the uncommitted entitlements comment and Xcode build-phase setting (`alwaysOutOfDate`); ignore or `.gitignore` `client/Resources/media-manifest.json`. Comment corrected and kept; the build-phase setting is kept (the archive is now recorded after Xcode's copy, so it no longer matters); the manifest is ignored.
- [x] Push the work to your own remote. Done on 6 October: the Mac product now lives in its own repository, extracted from the fork at `v1.0.0-macos`.
- [x] Free disk space: 7+ GB free of 228 GB, which a full build plus Temurin can exhaust. Stale build candidates and test products removed (13 GB free on 4 October).
- [x] Rebase the parked WebView branch (`macos/webview-sessions-wip`, 13 commits behind) onto the current branch, even though it does not compile yet, so it does not drift further before RT-14 (section 8). Rebased cleanly onto `5f8776e4` (worktree `../Cloudstream-webview-wt`).
- [x] Mark the old plans as superseded by this list, so they are not mistaken for open work: `Roadmap.md` (still lists notarization and an Intel DMG), `Implementation-Plan.md` and `Remediation-Plan.md` (their "OPEN" rows date from September and are largely fixed), `Siri-Integration-Plan.md` (a draft, nothing built).

## 2. Make the app robust

Evidence from 4 October: the extension stages themselves mostly work (the
last outcome of every stage of the 7 enabled extensions succeeded, except
UHDmovies links, where the site returned nothing). What failed came from
around them: one change killed every extension, a second copy of the app had
no engine, and nothing told you why. The recurring Oct 2–3 crash (an extension
killed when a link list was left mid-load) is fixed by HIGH-03.

- [x] **Test the built app, and make its class archive load.** Done: the archive is recorded in the finished app with a relative class path (`tools/daemon.jar`, run from `Contents/Resources`), so it stays valid when the app is published or copied; `selftest_bundle` runs the app's own engine, archive and flags with `-Xshare:on` through search, details and links in a sandboxed worker, and fails the build otherwise. Both problems have the same cause: checks run against files outside the finished app.
  - After every build, start the finished app's own engine (same runtime, same archive, same flags), sandboxed, and run a fixture extension through search, details and links; fail the build if it fails. Today's self-test runs before the archive exists and outside the app, which is why it missed the 4 October regression.
  - `daemon.jsa` is recorded against `client/Resources/tools/daemon.jar`, then the jar is copied into the app; Java sees a different file and ignores the archive (`A jar file is not the one used while building the shared archive file`), so the engine and every extension worker start without it. Record the archive against the jar inside the built app (or keep the copied jar identical), and have the same check fail if the archive does not load. This is the cheapest speed-up on the list.
- [x] **Never fail silently, and count only real crashes.** Done: engine errors show the reason and a Retry; a second copy of the app gets "Another copy of CloudStream is already running" instead of a retry loop; search lists each failed provider with its reason and a Retry; the worker pool records shutdown first and SIGTERM exits never count towards quarantine.
  - When the engine cannot start or an extension process dies, say so in the app with the reason and a Retry, instead of empty results.
  - Exit code 143 means the process was stopped with SIGTERM: extension processes stopped by a normal engine shutdown are logged as crashes. Have the worker pool record that it is shutting down before it stops workers, and ignore those exits when counting crashes towards quarantine.
- [x] **No lost watch progress.** Done: unsaved positions are journaled to `PendingProgress.json` beside the library and replayed into their own profile's store at the next launch. If a profile's library cannot be opened, progress played meanwhile is held in memory (`pendingProgress` in `LibraryStore.swift`, covered by `PersistenceBoundaryTests`) and is lost if the app quits first. Only the last step is missing: write it to a small file on disk and replay it once the library opens.

## 3. Portable build (needs you to install Temurin)

Today's build links the Homebrew JDK under `/opt/homebrew`, so it runs only on
a Mac with that same Homebrew install. The media stack (`client/build/media-stack`)
is already self-contained. Temurin is not installed yet; the only JDK on this
Mac is Homebrew's OpenJDK 17.0.20.1.

- [x] Install a self-contained JDK 17 (Eclipse Temurin). Not needed: the notarized Temurin 17.0.20.1 tarball in `client/build/vendor-jdk` (checksum-pinned) is used automatically by `bundle_runtime.sh`.
- [x] Rebuild with it so `bundle_runtime.sh` links the engine's runtime against Temurin; the build's check must report `verified`, not `not-portable`. Reports `verified` (56 Mach-O files).
- [x] Sign the app ad hoc (`codesign --sign -`), which is enough for your own Macs. `make build` already does this.
- [ ] **Needs you:** copy it to the other Mac and clear the download quarantine once (`xattr -dr com.apple.quarantine CloudStream.app`, or right-click → Open).
- [ ] **Needs you:** decide whether your other Mac runs an older macOS; if so, test there too. The build targets macOS 15 and the closure check confirms every binary does.

## 4. Measure, and confirm the 4K colour cause

Measure first, so every later fix shows a before/after number.

- [x] **Measure** on this Mac: idle memory of the app, the engine and each extension worker (budget 160 MB for the app at idle); CPU and memory while playing 1080p and 4K; launch time; scrolling a large library. Done (5 October): idle app 136 MB, engine 91 MB. GPU path, CPU-seconds per second of playback: 4K HDR10 0.37 (software 0.82), about 380 MB above idle; 1080p 0.31 (software 0.52), about 180 MB above idle. Launch: engine ready 1.4 s after the app starts (the engine itself listens 0.18 s after its own start). Large library (gated `LargeLibraryMeasurementTests`): scrolling 22–48 ms per 400 pt step at 1,000 and 10,000 titles; opening a collection 0.13 s at 1,000 titles and 0.9 s at 10,000; a re-render after a library change 0.2 s and 1.4 s. Sorting 10,000 titles went from 0.3–0.8 s to 0.08–0.14 s by reading each title's keys once, and the arranged collection is now cached, so selecting, dragging and hovering no longer re-read the store (0.5 s+ at 10,000 titles, now under 1 ms). What remains at 10,000 titles is SwiftData's fetch (0.4 s) and SwiftUI's grid; only collections of several thousand titles notice it.
- [x] **Stream info line** in the player: resolution, codec, colour primaries, transfer and HDR type. Use it to check that a pale 4K stream reports BT.2020 with PQ or HLG (section 5). Done: More → Show Stream Info, for example “3840×1600 · H.265 · BT.2020 / PQ · HDR10 · VideoToolbox · GPU”; the live run confirmed the pale 4K streams are BT.2020/PQ HDR10.

## 5. GPU rendering path (one project: fixes pale 4K and most of the heaviness)

4K streams look washed out, while 1080p and 720p of the same title look right.
Most 4K streams are HDR (HDR10/HLG: BT.2020 colours, PQ/HLG brightness curve);
lower resolutions are SDR (BT.709).

Cause, from the code (`MetalVideoView.swift`): frames are decoded by
VideoToolbox, copied back to the CPU (`hwdec=videotoolbox-copy`), then scaled
and converted by mpv's software renderer (`sw` render API, `bgr0`) before
Metal draws them. That path converts YUV to RGB but does not convert HDR
colours or brightness for the screen, and the Metal layer has no colour space,
so HDR is shown as if it were SDR: pale and flat. The same CPU path likely
dominates CPU, heat and battery during playback. Plan it as a single project;
it is the largest item outside RT-14.

- [x] **Diagnostic, not the fix:** set mpv's target to SDR (`target-prim=bt.709`, `target-trc=srgb`, tone mapping on) in the software path and compare. It confirms the diagnosis. Whether highlights tone-map or just clip depends on whether mpv's software path uses FFmpeg 9 `swscale`'s colour management; it also costs CPU at 4K. Superseded: went straight to the GPU fix, which uses these same target settings; a PQ mid-grey test frame renders as 176 instead of the raw 127 that looked pale.
- [x] **The fix:** render on the GPU (zero-copy VideoToolbox frames drawn by Metal, or mpv's GPU renderer through libplacebo, which is already linked into libmpv). It tone-maps HDR correctly, can show real HDR on an XDR screen through EDR, and removes the per-frame CPU work. Keep the current path as a fallback. Compare against the section 4 numbers. Done: mpv's GPU renderer (libplacebo, OpenGL) draws zero-copy VideoToolbox frames into IOSurfaces that Metal presents, with tone mapping to SDR; CPU at 4K roughly halved (section 4); `CS_PLAYER_RENDERER=sw` keeps the software fallback. Not done (optional): real HDR on an XDR screen through EDR.
- [x] Give the Metal layer an explicit colour space for SDR video too, so colours are not left to the system default. Done: sRGB on both paths.
- [x] Dolby Vision streams without an HDR10 base look green or purple rather than pale; only the GPU path can fix those. Until then, prefer a non-Dolby-Vision source when one exists. Done: such links rank after the others of the same source tier; the GPU renderer cannot reshape them either, so this stays the answer.

## 6. Make the app lighter (the rest)

- [x] **Extension workers.** Each extension runs in its own JVM (up to 256 MB heap). Check how many stay running when idle, and tune the idle shutdown, worker cap, heap size and shared class data so idle extensions cost little. Done: workers start with a 16 MB heap and hand freed heap back, stop after 5 idle minutes (was 10), and load the class archive, so a restart is quick.
- [x] **Engine at idle.** Background work while nothing is happening: polling (`solve/pending`, `media/pending`, health), episode checks, repository syncs. Done: the pending-task routes are long polls (up to 25 s, woken when a task is parked) instead of 3–6 s polling, and the health check runs every 15 s while the engine is unused.
- [x] **UI.** Unnecessary SwiftUI re-renders on Home, Library and the player overlay; image decode and cache sizes while scrolling. Done: the decoded-artwork cache drops to 48 MB when the app is in the background (256 MB in use); the Library no longer re-reads and re-sorts its collection on every re-render (section 4), and Home's shelves share the faster sort. The player overlay was not profiled separately; playback CPU is measured in section 4.

## 7. Smoother streaming

Already in place: at 80% of an episode the engine fetches the next episode's links in the background (link cache only, no video); the source, audio, subtitles and speed are remembered per title; a failing stream switches to the next mirror automatically and resumes at the same position; a new episode loads into the existing player view.

- [x] **Decide the memory budget for a preloaded stream first.** Preloading runs during playback, not at idle, so it does not touch the 160 MB idle budget, but it does add a second stream's buffer on top of the current one (the player buffers up to 128 MiB ahead). Measure playback memory (section 4), then set a playback budget and cap the preload to it (for example a few seconds of video rather than a full buffer). Done: 4K playback is about 400 MB above idle; the preload is capped at 32 MiB (under 10% more).
- [x] **Preload the next episode.** Near the end, resolve and verify a working source ahead of time (preferring the source used for this episode), set up headers/relay and subtitles, and open the stream so the first seconds are already buffered; switch to it instantly at the credits or Up Next. Do it only on the next episode, cancel it if the user seeks back, changes episode or closes, and keep it within the budget above. Sources that go through the media relay (separate audio, or credential headers) inherit its limits (section 9): progressive files only, and about 1 MB held before the first bytes. Done: in the last minute the best next link is queued in mpv with its first seconds buffered; seeking back, closing or changing episode drops it. Only plain streams with the same headers are preloaded (not relayed or separate-audio ones).
- [x] **Measure the episode change:** time from the end of one episode to the next one's first frame, and whether anything (renderer, relay, verifier) is rebuilt that could be kept. Done: 0.10 s to switch to a preloaded episode; the player view and renderer are kept.
- [x] **Faster first frame:** check whether playback waits for every source to resolve; if so, start the remembered or best-ranked source as soon as it arrives (links already stream in one by one). Done: the remembered or top-ranked source starts as soon as it arrives, without the 1.5 s wait; first-frame time is logged (`player.first_frame`).
- [x] **Fewer stalls:** tune buffering (currently 128 MiB ahead, 32 MiB back, 30 s read-ahead) by stream type; also switch mirrors when a stream keeps stalling, not only when it fails. Done: one 12 s stall, or 3 stalls within 90 s, switches to the next mirror. The buffer sizes were left as they are.
- [x] **Show what is happening:** check that buffering shows progress and a mirror switch is announced, rather than a silent spinner. Done: re-buffering shows a percentage, and every mirror switch is announced.

## 8. Extensions (alongside the rest)

- [x] **RT-14 — JavaScript in extension-created WebViews.** Needed by StreamPlay (EnmaDecryptor). The parked branch `macos/webview-sessions-wip` does not compile; finish it (rebase it first, section 1). Largest item. Done: an extension's WebView runs in the app's WebKit (offscreen, its own data store); tested with an Android-compiled fixture through a real worker.
- [ ] **RT-15 — Support missing configuration for extensions we use (only if needed).** Add a native adapter only when a specific extension needs useful configuration that the existing Extension Settings sheet cannot handle: sign-in/sign-out, custom server/account setup, source selection/order, or essential settings stored outside SharedPreferences. Working extensions whose current settings are sufficient need no further work. Keep configuration within the extension's existing settings entry; do not add a separate Advanced Settings screen or duplicate existing controls. Automatic extension-triggered browser launches and ad redirects are out of scope and must remain blocked; explicit Open in Browser, Copy Link and external-player actions belong to the app's own user-invoked controls.
- [x] **RT-17 — play a stream from a real extension** in the built app (not just test fixtures). Done 5 October: every one of 8 providers has a stream that reaches frames through the app's player code, 4K HDR10 included ([Extensions-Live-Matrix.md](archive/plans/Extensions-Live-Matrix.md)).
- [ ] **RT-11 — page-resolved links on real JavaScript-heavy sites.** **Partly done:** in the live app run, page resolution was refused once because all slots were busy; it now waits for a free slot, or reports `no_live_call` when nothing is waiting for it. A real site resolving through it has not been confirmed yet.
- [x] **Anti-bot challenges (Cloudflare “Just a moment…”)**, found in the live app run. Done: the hidden solver now loads the page with the requesting client's User-Agent, which clearance is bound to (0 → 119 of 123 cleared). It reuses a fresh clearance for 4 minutes, and backs off a site for 10 minutes when it rejects a fresh clearance (a TLS-fingerprint check). Like Android, it never shows a window: a challenge that needs a person times out after 30 s and that source is skipped.
- [x] **RT-08 — re-check extensions installed without a published hash** (update and "Check for Changes"). Checked live 5 October (`live_extension_run.py --recheck`, on a copy of your data): all 8 installed extensions carry a publisher hash, so none takes the hashless path; all 8 restored and resolved links afterwards. The hashless path itself is covered by `HashlessProvenanceTest` and the recheck tests; it matters only if you install an extension whose catalog has no hash.
- [ ] Only if an extension breaks: the test-only items RT-02 (method handles, inherited value-class members), RT-03 (downloader lifecycle), RT-05 (APIs reached by reflection), RT-09 (resolver diagnostics), RT-10 (challenge time limit, install progress). Playlist links are not carried across extensions (RT-12 limit).

## 9. Known limits worth fixing if they bite

- [x] The media relay serves progressive files only (not HLS/DASH) and stops when the engine restarts. Done: HLS and DASH manifests are rewritten so every segment goes through the relay; a relayed stream is registered again after an engine restart and resumes at the same position.
- [x] The relay holds up to about 1 MB before the player gets its first bytes (Ktor's response buffer); flush earlier if streams start slowly. Done: each chunk is flushed.

## 10. Extension compatibility, playback and UI fixes

Found 8 October 2026 (manual testing notes in [archive/plans/To-dos/to-dos.md](archive/plans/To-dos/to-dos.md), and a comparison
with CloudStream for Android across the wiki's extension list). Work through
[Compatibility-Fix-Plan.md](Compatibility-Fix-Plan.md), phase by phase,
starting with the catalog-wide baseline run (C0).

- [ ] M0 Baseline — **needs you:** `python3 scripts/catalog_compat_run.py --wiki` after `make build`
- [x] M1 Links play · [x] M2 Runtime parity · [x] M3 Network (N3 waits for M0)
- [ ] M4 Deeper parity — A3, L4, W2, X2, X3 done; A5 deferred (receipt format); W3 waits for M0
- [ ] M5 Cross-extension — X1 deferred (see the plan)
- [ ] M6 UI — U1, U2, U3 done; U4 needs an Instruments trace

## Optional checks

- [ ] The interactive list in [qa-ui-checklist.md](qa-ui-checklist.md), as you come across those screens.

## Done

- [x] **Confirm the 4 October audit fixes** (confirmed by you, 4 October): download continues behind the lock; long pause then seek; notes stay in their profile; deep links and Spotlight wait for unlock. Details in [Adversarial-QA-Status.md](archive/plans/Adversarial-QA-Status.md).
