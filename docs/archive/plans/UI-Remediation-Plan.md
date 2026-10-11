# CloudStream macOS — UI & Platform Remediation Plan

**Status:** ✅ **Implemented** (2026-09-29) — all U-items landed on the decisions below; 49/49 unit tests green; Debug + Release compile clean; grep gates pass. Verification evidence and deviations noted per workstream in §6.
**Date:** 2026-09-29
**Scope:** Every finding from the full UI code review of `client` (2026-09-29): the Apple-TV design system ported to macOS, unobserved-store refresh hacks, fake/disabled controls, keyboard & menu-bar integrity, the player-as-overlay architecture, mpv integration bugs not already tracked, dead code, and packaging risks.
**Relationship to other plans:** This document is the executable plan for the **UI/platform dimension**. `Implementation-Plan.md` (rev 3) already owns the daemon/IPC/playback-defect register (V-xx, N-xx). Items already tracked there are **not re-planned here** — see §1 Disposition table. `Remediation-Plan.md` owns security hardening. Where a workstream below touches the same file as one of theirs, the coordination note says so.

## Implemented decisions (user-approved)

| DP | Decision |
|---|---|
| DP-1 | Player = AppKit `PlayerWindowController` + `NSWindow` (ADR-0008) |
| DP-2 | Library observation via store `version` counter; `@Query` deferred (ADR-0009) |
| DP-3 | Semantic system colors, both appearances (ADR-0010) |
| DP-4 | Deployment target stays macOS 15.0; no availability-gated glass needed for the shipped controls |
| DP-5 | PiP button removed; `PipService` deleted; real PiP tracked as feature (N-12) |
| DP-6 | Home shelf kept, unified with the sidebar's five watch states |

---

## 0. Principles

1. **Platform-native or delete.** Where macOS ships a control (`Settings` scene, `.searchable`, `Picker(.segmented)`, `ContentUnavailableView`, `Form`), the hand-rolled replacement is deleted, not restyled. Custom survives only where the platform genuinely has no equivalent (media grid cards, player HUD, poster cache).
2. **No fake affordances.** Any control that does not perform its visible function is removed in the same PR that would have fixed it (PiP, Continuous Playback toggle, dead sort). A shipped lie is worse than a missing feature.
3. **Observation over refresh hacks.** Every `.id(revision)` nuke, polling `Timer`, and `onAppear` state sync is replaced by real observation. A PR that adds a new revision counter or timer is rejected.
4. **One source of truth per fact.** Singletons stop being read directly from `body`; stores are injected via `.environment`. Strings that the UI needs from services arrive as state that changes, not as values snapshotted in `onAppear`.
5. **Both appearances, every state.** Colors are semantic or tokenized-dynamic; text uses the macOS type scale; hover never scales; destructive actions confirm or undo; every control has `help(_:)` and an accessibility label.
6. **Same-PR tests** for pure logic (sanitizers, converters, sort/filter, filename rules), matching the house rule in `Remediation-Plan.md` §0.
7. **Every workstream ends with a runnable verification** whose output lands in the PR description.

---

## 1. Disposition of the audit register

Findings already tracked in `Implementation-Plan.md` rev 3 — **executed there, not here**:

| Audit finding | Their ID | Note |
|---|---|---|
| Resume seek races `loadfile` | V-02 | Their design (`start=` before init) is adopted as-is; our WS-C only adds the `updateNSView` gating that keeps it stable. |
| NDJSON byte-wise UTF-8 mojibake | V-05 | Their `NDJSONLineDecoder` design. |
| `sub-file` loop overwrite | V-17 | Their post-init `sub-add` design. |
| `MetalVideoView.deinit` off-main free | V-16 | Related: our WS-C adds the drain-queue barrier in `shutdown()` (main-thread path); both must merge together or the UAF window remains. |
| "Mark as Watched" only zeroes progress | V-23 | Their upsert-`.completed`-then-`removeProgress` design; our WS-D supplies the separate `onMarkWatched` closure it needs in `ContinueWatchingCard`. |
| PiP button no-op | N-12 | Their plan assumes button removal. WS-A aligns: **remove the HUD PiP button now**; a real detachable PiP window is a feature request, not a fix. |
| Double-advance / audio-variant next-episode | N-01, N-02 | Playback-domain; theirs. |
| Stale endpoint overwrite, solve retry storm, ghost plugins | N-05, N-06, N-11 | Engine-domain; theirs. |
| `newestFirst` dead flag | (their §WS) | Their 3-way episode-sort menu supersedes our item; WS-G only deletes the dead `@State` if their WS hasn't landed first. |
| `normalizeRepoUrl` scheme duplication | (their WS-12 `normalizeInput`) | Their repo workstream owns normalization; WS-I deletes `DeepLinkRouter`'s duplicate stripper and calls the one implementation. |

New items planned here get IDs **U-xx**, grouped into workstreams **WS-A…WS-L**.

### Priority legend
- **P0** — broken input, broken data, or a control that lies to the user.
- **P1** — platform-convention violations that make the app feel foreign, and jank-class performance.
- **P2** — dead code, silent failures, polish.

---

## 2. Workstreams

### WS-A — Keyboard, menu bar & window identity (P0)

**Objective:** The app stops eating keystrokes, gains a standard menu bar and a real Settings scene (⌘,), and every window has a title.

| ID | Pri | Fix |
|---|---|---|
| U-01 | P0 | **Remove no-modifier menu key equivalents.** `CloudStreamMacApp.swift:130-157`: delete the `Button("Play / Pause").keyboardShortcut(.space, modifiers: [])` and the bare ←/→ seek items. Space/arrows are handled exclusively inside the player (WS-B scoped monitor). Playback menu keeps ⌘-modified items (⌘⇣/⌘⇡ volume, ⌘M mute, ⌘N next) and is `.disabled` unless `player.session != nil` (disable, don't hide). |
| U-02 | P0 | **Player event monitor passes unmatched keys through.** `PlayerWindowView.swift:314-323`: `handleKey` returns `Bool` (consumed?); the monitor returns `nil` only for consumed events, else `event`. ⌘W/⌘Q/⌘Tab/⌘C work again during playback. Move this monitor from the overlay view into the player window (WS-B) and scope it with `event.window === playerWindow`. |
| U-03 | P0 | **Real Settings scene.** Add `Settings { SettingsView() }` to `CloudStreamMacApp` (⌘, for free, standard Preferences window). Remove `.settings` from `AppDestination`, the sidebar row, and `RootView.detailContent`. `SettingsView` migrates to `Form` + `.formStyle(.grouped)` with a tab `Picker` in the toolbar (standard toolbar-tab layout). The custom header/page chrome is deleted. |
| U-04 | P1 | **Continuous Playback becomes a real preference.** Delete `Toggle(isOn: .constant(true)).disabled(true)` (`SettingsView.swift:219-224`). Add `UserPreferences.continuousPlayback: Bool = true`; `PlayerWindowView`'s `onEndOfFile` consults it (`PlayerWindowView.swift:34-40`). |
| U-05 | P1 | **Menu bar structure.** Add `SidebarCommands()`; rename `CommandMenu("Navigation")` → `CommandMenu("Go")`, drop its ⌘F item (`.searchable` owns Find/⌘F once WS-F lands); keep ⌘1…⌘6, add ⌘E Extensions, ⌘, is automatic. Order: default groups first, then `Go`, then `Playback`. |
| U-06 | P1 | **Window titles.** Add `.navigationTitle(...)` per detail destination (`HomeView`, `SearchView`, `LibraryView`, `DownloadsView`, `ExtensionsView`, `MediaDetailView` uses the media name). Flip `.windowToolbarStyle(.unified(showsTitle: true))`. Mission Control/Expose become navigable. |
| U-07 | P1 | **Duplicate back affordance.** `MediaDetailView.swift:44-52`: delete the custom toolbar Back button + ⌘[ (the `NavigationStack` already supplies back). Esc still closes via the existing player-agnostic handler or a focused `Esc` binding if desired. |
| U-08 | P1 | **Onboarding sheet is dismissible-by-rule, not by black hole.** `RootView.swift:52-57`: replace the write-discarding binding with `@State showOnboarding` synced from `preferences.onboardingComplete` via `onChange`, plus `.interactiveDismissDisabled(true)` while `step != .done`. Esc before completion is a no-op *by declaration*; after completion the sheet closes normally. |

**Files:** `App/CloudStreamMacApp.swift`, `UI/Navigation/RootView.swift`, `UI/Settings/SettingsView.swift`, `UI/Player/PlayerWindowView.swift`, `UI/Details/MediaDetailView.swift`, `UI/Components/OnboardingView.swift`, `ViewModels/AppState.swift`, `Services/UserPreferences.swift`, `ViewModels/PlayerViewModel.swift`.
**Coordination:** none (their plan doesn't touch the scene/menu layer).
**Tests:** unit — `continuousPlayback` preference round-trip; menu-structure can't be unit-tested, so verification is manual.
**Verification:** run app → type "star war" + spaces into Search (no playback toggle fires); during playback ⌘W closes window, ⌘Q quits; ⌘, opens Settings; every Mission Control tile shows a title; Esc does not dismiss onboarding mid-flow, does after "Start Watching".

---

### WS-B — Player becomes a real window (P1)

**Objective:** The player is its own window with system chrome. The main window stays alive underneath; no more hand-dodging the traffic lights.

**Decision DP-1 (record as ADR-0008):** *SwiftUI `Window` scene vs. AppKit `NSWindowController`.* **Recommendation: AppKit `PlayerWindowController`.** Rationale: the video surface is already an `NSView` (`MetalVideoView`); a controller gives precise styleMask/fullscreen/first-responder control, a window-scoped `localMonitorForEvents` (fixes U-02 cleanly), and deterministic close when `session` becomes nil. SwiftUI `Window` + `dismiss()` works but fights on programmatic close and monitor scoping. `UtilityWindow` is rejected — it auto-hides when the app deactivates, which is wrong for video.

| ID | Pri | Fix |
|---|---|---|
| U-09 | P1 | **Create `PlayerWindowController`** (`UI/Player/PlayerWindowController.swift`): `NSWindow` with `[.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]`, `titlebarAppearsTransparent = true`, `isMovableByWindowBackground = true`, content = `NSHostingView` rooting the existing HUD + `MetalVideoView` composition. Lifecycle driven by `PlayerViewModel`: `play()` opens/reuses the window; `close()` closes it. Delete the ZStack overlay in `RootView.swift:34-41`. |
| U-10 | P1 | **Delete the traffic-light compensation.** `PlayerWindowView.swift:206` `.padding(.leading, isFullScreen ? 24 : 80)` goes away — "Done" becomes the standard close button (red traffic light) plus a `Done` capsule positioned using the window's safe-area insets (`additionalSafeAreaInsets`), never hardcoded offsets. |
| U-11 | P1 | **Window-scoped input.** The key monitor is installed when the player window becomes `key` and removed on resign; `handleKey` consumes only the matrix (Space/K/arrows/F/M/N/Esc) and returns unmatched events. Fullscreen notifications and `isFullScreen` state move to the controller (`windowWillEnterFullScreen` etc.), replacing the four `onReceive` blocks (`PlayerWindowView.swift:113-124`). |
| U-12 | P2 | **Title.** Window title = "Title — S1,E2"; `titleVisibility = .visible` only in windowed mode (`.hidden` while the HUD is up, QuickTime-style). |

**Files:** new `PlayerWindowController.swift`; `UI/Player/PlayerWindowView.swift` (slims to HUD-only), `RootView.swift`, `PlayerViewModel.swift`.
**Coordination:** V-16/V-02 (`MetalVideoView` teardown, seek) land before or with this — the controller changes when `shutdown()` is called.
**Tests:** unit — `PlayerViewModel.play()`/`close()` session lifecycle with the existing `PlayerTransport` fake (controller injectable/mockable); manual — fullscreen F/double-click/Esc, window stays behind player, Stage Manager + tiling behave.
**Verification:** screenshot player windowed + fullscreen; ⌘W closes only the player; main window and its state survive playback; no hardcoded offset pixels remain (grep `padding(.leading, 80)`).

---

### WS-C — mpv integration & render-loop correctness (P0/P1)

**Objective:** Subtitle styling actually works, the main thread stops re-evaluating the player tree dozens of times a second, and teardown cannot race.

| ID | Pri | Fix |
|---|---|---|
| U-13 | P0 | **Subtitle color space fix.** Preferences store ARGB (`#FFFF0000`) but mpv `sub-color` expects `#RRGGBBAA` (`MetalVideoView.swift:546-560`). Introduce `SubtitleStyle` (struct: `fontSize`, `outlineWidth`, `textColor: Color`, `backgroundColor: Color`) with (a) canonical **RGBA** hex persistence, (b) a migration on read in `UserPreferences.init` mapping the four legacy ARGB strings (`#FFFFFFFF`, `#FFFFFF00`, `#FF00FFFF`, `#FF00FF00` → white/yellow/cyan/green RGBA), (c) one conversion point at the mpv boundary. Settings picker tags + `SubtitleStylePopover` consume the same model — today the 4-color list is defined twice (`SettingsView.swift:196-201`, `PlayerHUDView.swift:487-492`). |
| U-14 | P1 | **Hot-loop throttle.** `MpvPlayerView.swift:24-29`: coalesce `time-pos` forwards to ≥250 ms (timestamp on `MetalVideoView`), while `duration`/`pause`/`volume`/`mute` forward immediately. Then **stop reading `player.elapsed` in `PlayerWindowView.body`** (`PlayerWindowView.swift:29` `startAt:`) — capture resume position once in `PlayerViewModel.play()` (it already sets `elapsed`) and hand the representable a fixed value via the coordinator. |
| U-15 | P1 | **Gate `updateNSView`.** `MpvPlayerView.swift:58-64`: coordinator caches `lastIsPlaying` and only calls `setPlaying` on change; also re-points `player.videoView` only on identity change (already guarded) — net effect: no C-boundary traffic per SwiftUI pass. |
| U-16 | P1 | **Drain-queue teardown barrier** (complements their V-16). `MetalVideoView.shutdown()` order: detach render-update callback → detach wakeup callback → `core?.queue.sync { }` flush (all queued `drainEvents` blocks complete before the sync returns) → `mpv_render_context_free` → `mpv_destroy`. Guard with an `isTornDown` flag so no new blocks are enqueued between detach and destroy. |
| U-17 | P1 | **Progress persistence throttle.** `PlayerViewModel.handleProgress` (`PlayerViewModel.swift:311-320`): `Int(elapsed) % 5 == 0` saves on *every* callback within each 5 s band. Replace with `elapsed - lastPersistedAt >= 5` (plus persist on `close()` and on end-of-file). |
| U-18 | P1 | **Now-Playing artwork fetched once.** `NowPlayingService.swift:80-90` re-downloads the poster every `updateNowPlaying` (~5 s). Cache by URL (`[String: MPMediaItemArtwork]`); fetch only on URL change. |
| U-19 | P2 | **HUD scrubber accessibility.** Add `.accessibilityElement`, `.accessibilityValue(timeString)`, and an `.accessibilityAdjustableAction` seeking ±10 s to `PlayerTimelineScrubber`; fixed-width time labels (`PlayerHUDView.swift:324, 403`) become `.monospacedDigit()` + `minWidth` so 1:00:00 doesn't truncate. |

**Files:** `MetalVideoView.swift`, `MpvPlayerView.swift`, `PlayerWindowView.swift`, `PlayerViewModel.swift`, `Services/NowPlayingService.swift`, new `Models/SubtitleStyle.swift`, `Services/UserPreferences.swift`.
**Coordination:** V-02/V-17 designs are prerequisites for touching `setup()`/`loadStream()`; merge this after or together.
**Tests:** unit — `SubtitleStyle` legacy→RGBA migration table; RGBA serialization; U-17 throttle logic with injected clock; artwork cache keying. Manual — pick Yellow/Cyan/Green subs in Settings → visible correct colors in mpv; scrub during playback with VoiceOver.
**Verification:** Instruments Time Profiler during 4K playback: main-thread hitches from `MetalVideoView` Swift frames gone; `log stream` shows one persist per ~5 s, not 10+.

---

### WS-D — Library store: real observation & data correctness (P0)

**Objective:** Mutations show up without identity-nukes or timers; no title can be made to vanish by a menu; remaining-time never reads "0m left" as a lie.

**Decision DP-2 (ADR-0009):** *Observation strategy.* **Recommendation: version counter now, `@Query` later.** `LibraryStore` is already `@Observable`; give it `private(set) var version: UInt64` bumped in every mutation (it already funnels through a handful of methods), and have each screen read `store.version` once at the top of `body`. Full `@Query` adoption (modelContainer in environment) is the north star but drags a restructure of every screen; schedule it as its own workstream after the design rewrite (WS-E), not inside this fix train.

| ID | Pri | Fix |
|---|---|---|
| U-20 | P0 | **LibraryStore version counter.** Bump `version` in `upsertLibraryEntry`, `setWatchType`, `recordProgress`, `toggleFavorite`, `removeProgress`, `markDownloaded`. `HomeView.swift:42` and `LibraryView.swift:211` lose `.id(...)`; `HomeView.libraryRevision`, `LibraryView.revision` state deleted. |
| U-21 | P0 | **On Hold / Dropped cannot strand titles.** Today `WatchType.allCases` is offered in every status menu (`MediaDetailView.swift:211`, `HomeView.swift:202`, `LibraryView.swift:189`) but no screen lists those items — selecting them makes the title disappear from every view. Add `AppDestination.onHold`, `.dropped`; extend `LibraryCollection` (+ icons + empty messages); add sidebar rows (Library section grows to 7 — acceptable) ; extend `HomeShelf` picker. |
| U-22 | P0 | **"0m left" and the never-completing item.** `StoredMediaItem.swift:84-96` + `LibraryStore.continueWatching` (`:272-281`): when `totalDurationSeconds == 0`, `remainingLabel` returns `"0m left"` and `fractionWatched` is stuck at 0 so the 0.95 completion filter never fires. Fix: `remainingLabel` returns `nil` when total == 0 (subtitle renders "S1:E2" only; card hides the label); `< 60 s` renders `"<1m left"`; `continueWatching` predicate accepts `progressSeconds > 10 AND (totalDurationSeconds == 0 OR fractionWatched < 0.95)`; progress bar renders only when `fractionWatched` is meaningful (total > 0). |
| U-23 | P1 | **Details error smear + unbounded DTO cache.** `RootView.swift:96` reads `appState.detailsError` = error *of the top of the path*, so a just-pushed coordinate briefly shows the previous coordinate's failure. Fix: `DetailsDestinationView` owns its error state — `loadDetails` returns `Result<DetailsDto, Error>` and the view renders its own error/retry; `AppState.detailsErrors` dictionary is deleted. Evict `loadedDetails` on pop: `closeDetails()`/path mutation removes the cache entry for the popped coordinate and caps the map at ~12 entries. |
| U-24 | P1 | **Resume fails silently.** `LibraryStore.resume` (`:295-301`) `try? … else return` — dead tap. Return a `Result` and surface `appState.daemonState`-style error toast (reuse the EngineErrorBanner channel or a new `.alert`). |
| U-25 | P1 | **Silent SwiftData writes.** Every `try? context.save()` in `LibraryStore`/`DownloadService.upsertRecord` becomes `do/catch` logging via `DaemonLog.client("store.save_failed", …)`; init failure (`container = nil`) surfaces one persistent banner ("Library storage unavailable") instead of a silently empty app. |
| U-26 | P2 | **"Newest First" actually sorts by added date.** It is byte-identical to Recently Updated (`LibraryView.swift:242-249`). Add `createdAt: Date = Date()` to `StoredMediaItem` (SwiftData lightweight migration — new property with default), sort `.newest` by it; the Home shelf ordering note follows automatically. |

**Files:** `Services/LibraryStore.swift`, `Models/StoredMediaItem.swift`, `UI/Home/HomeView.swift`, `UI/Library/LibraryView.swift`, `UI/Navigation/RootView.swift`, `ViewModels/AppState.swift`.
**Coordination:** V-23 (their Mark-as-Watched design) touches `ContinueWatchingCard` + `LibraryStore` — land U-20's counter bump in the same file change; `Design.md` §4.3 watch-state model gains the two new destinations.
**Tests:** unit (in-memory container via `CS_IN_MEMORY_DB=1`; make `LibraryStore.init` accept `inMemory:` for tests) — version bumps per mutation; U-22 matrix (total=0 → nil label, predicate admits, completes never falsely); WatchType → collection mapping for all 5 statuses; DTO cache eviction.
**Verification:** set a title to On Hold → it appears under Library ▸ On Hold; wipe duration → no "0m left"; kill detail A with an error, push detail B → no A-error flash; edit library from Home → Library view updates with no scroll reset.

---

### WS-E — Design system rewrite (P1, design decision DP-3 required)

**Objective:** Retire the Apple-TV token sheet. The app adopts macOS semantics — native in light and dark, correct type scale, hover that doesn't scale.

**Decision DP-3 (ADR-0010):** *Color direction.* **Recommendation: semantic colors, both appearances** (`windowBackgroundColor` content, `.primary/.secondary` text, `controlAccentColor`, `separatorColor`) — the app is a front-end, not an immersive playback surface full-time, and screenshots 1–4 are ordinary browsing UI. Keeping a dark-only tokenized theme is the accepted alternative only if the product explicitly wants the TV look; if so the tokens become dynamic `NSColor` providers with light variants + increased-contrast variants, and every `.foregroundStyle(.white)` must be audited. **This decision gates WS-E and needs sign-off before it starts.**

| ID | Pri | Fix |
|---|---|---|
| U-27 | P1 | **Type scale.** Delete every `.font(.system(size: N))` (sizes in use: 8, 9, 9.5, 10, 11, 12, 12.5, 13, 13.5, 14, 16, 17, 18, 19, 20, 24, 28, 32). Map: page headers → `.largeTitle`(26)/`.title`(17) per view class, section headers → `.title3`/`.headline`, body 13 `.body`, metadata `.subheadline`/`.caption`, badges ≥10pt. Grep gate: `grep -rn "font(.system(size:" Sources/UI` returns zero at completion. |
| U-28 | P1 | **Color semantics.** Per DP-3: replace `tvCanvas/tvSurfaceDark/tvCardSurface*` with background styles; `.white` text → `.primary`/`.secondary`; `tvAccentBlue` → accent (asset AccentColor already exists; hardcoded `#0A84FF` ignores the user's accent); `tvTextTertiary` (fails 4.5:1) → `.tertiary` on proper surfaces. `Color.red/.green/.yellow` literals → `.accent`/semantic where meaningful; error states pair icon+text (Differentiate-Without-Color). |
| U-29 | P1 | **Glass discipline.** Hand-built `.ultraThinMaterial`+stroke capsules (`DesignSystem.GlassPillStyle`, `PlayerWindowView.swift:196-198, 234-236`, `SearchView` suggestions card, Library sort/search pills) → `.glassEffect()`/`.buttonStyle(.glass)` behind `if #available(macOS 26, *)`, `.regularMaterial` fallback below (deployment target stays 15.0 — DP-4: keep 15.0, gate new-API usage through one `Compatibility` helper; do **not** raise the target in a fix train). Glass only on functional-layer chrome; content-layer cards use plain rounded rects. |
| U-30 | P1 | **Hover behavior.** Remove every hover `scaleEffect` (1.02–1.03) and glow shadows (`PrimaryPillButton`, `PosterCard`, `ContinueWatchingCard`, `BrowseCategoryCard`, episode rows); hover = background/border change only, ~0.15s ease, gated by `@Environment(\.accessibilityReduceMotion)` for all transitions. |
| U-31 | P1 | **Primary button.** `PrimaryPillButton` (white capsule, black text, white glow) and the duplicate inline copy in `MediaDetailView.actionBar` → one component: `.buttonStyle(.glassProminent)` on 26+, `.borderedProminent` fallback. One prominent action per view. |
| U-32 | P1 | **Empty states.** Replace `StateView` empty/loading/error variants with `ContentUnavailableView` (empty), keep `ProgressView`+label (loading), and alerts or inline error+retry (error) — delete the bespoke `StateView` once call sites migrate (`DownloadsView`, `SearchView`, `ExtensionsView`, `MediaDetailView`, `LibraryView`, `HomeView`). |
| U-33 | P2 | **Sidebar polish.** Outline SF Symbols (`house`, `play.circle`…) with accent-by-default; counts move from shelf-header text to `.badge()`; fix "Currently Watching" vs "Watching" naming drift (`HomeView.swift:15` vs sidebar). |
| U-34 | P2 | **Adaptive cards.** `PosterCard` stops hardcoding `width * 1.5` inside `LazyVGrid` cells sized independently (`LibraryView.swift:166` vs card 168pt — gutters don't fill on resize). Card fills its grid cell: `maxWidth: .infinity` + `aspectRatio(2/3, contentMode: .fit)` on the poster, text width unbounded. Shelves keep fixed 168 cards (horizontal rails are fine). |
| U-35 | P2 | **Delete dead components.** `BrowseCategoryCard`, `ShelfRow`, `GlassPillStyle`/`glassPill`, `RecentlySearchedCard` if WS-F replaces it — `DesignSystem.swift` shrinks to: poster card(s), poster image + cache, shared button style helper. |

**Files:** `UI/Components/DesignSystem.swift` and every file under `Sources/UI`.
**Coordination:** lands *after* WS-D (no point restyling views that get restructured) and *with* WS-F/G per-screen.
**Tests:** compile-time only; visual gate = rendered screenshots in light+dark, Reduce Motion, Reduce Transparency, Increase Contrast (manual checklist per screen).
**Verification:** before/after screenshot pairs per screen in both appearances; contrast spot-check with Accessibility Inspector ≥4.5:1; grep gates for `font(.system(size:`, `tvCanvas`, `scaleEffect` hover.

---

### WS-F — Search & suggestions platformization (P1)

| ID | Pri | Fix |
|---|---|---|
| U-36 | P1 | **`.searchable` replaces the custom field.** `SearchView.swift:80-185` (440×34 hand-built field + fake focus ring + non-dismissible dropdown) → `.searchable(text:, prompt:)` on the detail column + `.searchToolbarBehavior(.minimized)` behind 26-gating; the custom `SuggestionItemButtonStyle` and hand-drawn focus ring are deleted. Library's filter field (`LibraryView.swift:91-118`) → `.searchable` with `"Filter \(collection.title)…"` prompt (scope: filters the collection, standard pattern). |
| U-37 | P1 | **Suggestions: keyboard + dismissal.** TMDB suggestions become `.searchSuggestions` (or a popover anchored to the field with `↑/↓/Return` handling via `@FocusState` + `onKeyPress`, Esc dismisses, outside-click dismisses). Fix the stale-overwrite race (`SearchView.swift:67-73`): store the fetch `Task`, cancel the previous one, and check *that* task's cancellation — the current `Task.isCancelled` check refers to a task that is never cancelled. |
| U-38 | P2 | **Dead filter machinery: restore or delete.** `AppState.filteredSearchResults/availableSearchTypes/availableSearchProviders` (`AppState.swift:302-319`) have no UI. Decision: delete (provider-grouped shelves already organize results). If product wants type/provider filters, that's a feature — not resurrected here. Results header count and shelf counts must agree with whatever source remains. |
| U-39 | P2 | **Provider errors visible.** `provider_error` currently only feeds the progress set (`AppState.swift:261-264`); after `done`, a provider that failed shows nothing. Track per-provider error strings; render a one-line `.foregroundStyle(.secondary)` note under an errored provider's shelf (or a consolidated footnote). |
| U-40 | P2 | **Recently Searched hygiene.** `result.type` renders raw provider casing ("movie", "tvseries") — map through a display formatter (same one used in Details metadata, WS-G). Clear button → confirmation-free but with undo toast? No — history clearing is low-stakes: keep immediate, no dialog. |

**Files:** `UI/Search/SearchView.swift`, `UI/Library/LibraryView.swift`, `ViewModels/AppState.swift`, `Services/SearchSuggestionService.swift`.
**Tests:** unit — suggestion task-cancellation sequence (old query can't land after new); type display mapping.
**Verification:** type query with keyboard only: ↓/Return commits a suggestion, Esc dismisses; paste a query with emoji → suggestions and results render correctly; filter a library collection via the searchable field.

---

### WS-G — Per-screen remediation (P1/P2)

**G-1 · Home**
| ID | Pri | Fix |
|---|---|---|
| U-41 | P2 | Deduplicate IA: the home shelf picker duplicates the four sidebar collections. Keep it (quick switching is legitimate) but unify labels/icons with the sidebar and include the WS-D additions; the menu-as-header (`Menu` with 19pt label) becomes `Picker(.menu)` + `.badge(count)`. |
| U-42 | P2 | `ContinueWatchingCard` gains the separate `onMarkWatched` closure required by their V-23 fix (today both menu items share `onRemove`, `HomeView.swift:196-212`). |

**G-2 · Library**
| ID | Pri | Fix |
|---|---|---|
| U-43 | P1 | Sort control = `Picker("Sort By", selection:).pickerStyle(.menu)` — the `Menu{Picker{}}` nesting that renders the redundant blue "Sort By ›" submenu (screenshot 2) is deleted (`LibraryView.swift:121-144`). Include `.newest` per U-26. |
| U-44 | P2 | Filter uses `localizedStandardContains` instead of `lowercased().contains` (diacritics, user-friendly matching). |

**G-3 · Downloads**
| ID | Pri | Fix |
|---|---|---|
| U-45 | P1 | **ETA is dead — remove or fix honestly.** `QueueItem.estimatedTotalBytes` is never assigned (`DownloadService.swift:108, 114`) so ETA always renders "—". Fix: parse ffmpeg `-progress`'s `speed=` key; `eta = (durationSec − out_timeSec) / speed` when `durationSeconds` known and speed > 0; hide ETA otherwise. Delete `estimatedTotalBytes`. Speed label becomes an EMA of bytes-delta/time-delta instead of lifetime average (`applyProgress`, `:486-513`). |
| U-46 | P1 | **Destructive actions confirm.** Delete download (`DownloadsView.swift:405-426`) → `.confirmationDialog` ("Delete file from disk?" with filename); cancelled items delete their partial file (`DownloadService.cancel` removes `destinationURL` since `-c copy` can't resume). |
| U-47 | P1 | **Native controls.** Custom segmented pills (`:101-132`) → `Picker(.segmented)`; "Clear Finished" moves to the toolbar/menu with a `.disabled` state; `statusRaw == 4` magic numbers (`:84, 200`) → `DownloadRecord.status: ItemState` computed property. |
| U-48 | P1 | **ffmpeg orphans on quit.** `DownloadService` registers every spawned `Process` with `DaemonSupervisor.track(child:)` (its doc contract already promises zero orphans; today only the JVM is tracked) — or, minimally, `AppDelegate.applicationShouldTerminate` awaits `DownloadService.terminateActiveProcesses()` alongside the daemon stop before replying. Cancel/pause also stops the readability handlers for the error pipe (`:359-363` never cleared). |
| U-49 | P1 | **Filename safety + enqueue dedup.** `MediaDetailView.swift:472-498`: sanitize destination filenames (replace `/` and `:`, strip trailing dots/spaces, resolve collisions with " (2)"); `DownloadService.enqueue` no-ops (with user-visible toast) when an item with the same `episodeData` is queued/active/downloading. |
| U-50 | P2 | Downloaded list: keep rows for v1; `Table` adoption is a follow-up feature, not a fix. Remove the unused `revision` state (`DownloadsView.swift:16`). |

**G-4 · Details**
| ID | Pri | Fix |
|---|---|---|
| U-51 | P1 | **Share/Open-in-Browser use absolute URLs.** `MediaDetailView.swift:63-73`: `URL(string: details.url)` succeeds on provider-relative paths, so ShareLink copies garbage. Resolve against the provider base (daemon already knows it — add `baseUrl` to `DetailsDto` or a client helper); disable both buttons when no absolute URL can be formed. |
| U-52 | P2 | Metadata row grammar (`:124-185`): "Others 799m • tags" — the `"•  "` lives *inside* the tags string (`:170`). Render type/duration/tags as separate `Text` elements separated by `Text(verbatim: "·")`; duration formats via `Duration.TimeFormatStyle` (13h 19m, not 799m); `TvType` strings map to display names ("Others" → "Other"). |
| U-53 | P2 | Plot expand affordance: tap-to-expand (`:325-329`) is invisible. Add a "More"/"Less" button (or chevron) adjacent to the truncated text; keep tap as secondary. |
| U-54 | P2 | Episode list: `VStack` of all episodes (`:388-407`) → `LazyVStack` (1000-episode anime builds 1000 `PosterImage` tasks today). Un-nest the download `Button` from the row's outer play `Button` (`:512-596`) — restructure as row `HStack` with `.onTapGesture` on the thumb + explicit buttons, so the a11y tree isn't button-in-button. DUB badge 8pt (`:535`) → `.caption2` minimum. |

**G-5 · Extensions**
| ID | Pri | Fix |
|---|---|---|
| U-55 | P1 | **Silent failures surface.** `try?` around `setProviderEnabled` (`:207-215`), `uninstallPlugin` (`:221-233`), `syncRepo` (`:302-308`), `removeRepo` (`:319-331`) → do/catch filling the existing error banner; a failed toggle reverts the switch (bind `get` from plugin state post-`bootstrap`, not optimistic local flip). |
| U-56 | P2 | **`isSyncing` renders or dies.** It's set 4× and read 0× (`:18, 304, 307, 533, 540`). Sync button shows `ProgressView` while syncing; Add button disables. |
| U-57 | P2 | Uninstall extension / remove repository get `.confirmationDialog`s (consistent with U-46). Header segmented picker stops forcing 320pt width. |

**G-6 · Settings**
| ID | Pri | Fix |
|---|---|---|
| U-58 | P1 | Subtitle color picker consumes `SubtitleStyle` (U-13) — the four-color ARGB tags and their popover twin are one component. |
| U-59 | P2 | "Clear Cache" clears memory too: `ImageCache.shared.clearAll()` (new API) does NSCache + disk; the Settings copy currently promises "memory image buffers" and code only deletes the disk folder (`SettingsView.swift:338-344`). `cacheCleared` resets when leaving the view (acceptable); drop the permanent `.disabled` in favor of a 2s disabled state. |
| U-60 | P2 | `NSOpenPanel.runModal()` (`:346-357`) → `fileImporter` (or sheet-modal panel). Engine status shows `version ?? "not connected"`, not `?? "Connected"` (`:273`). |

---

### WS-H — Services hygiene (P1/P2)

| ID | Pri | Fix |
|---|---|---|
| U-61 | P1 | **ImageCache off-main I/O.** `DesignSystem.swift:469-506` does `Data(contentsOf:)` + `NSImage(data:)` on the MainActor — grid scroll jank. Disk read + decode move to a `nonisolated` task (decode via `NSImage` off-main, hand the decoded image back); merge the duplicated `onAppear`+`task(id:)` sync into one `task`; add disk eviction (keep ~200 MB / 500 files, prune on launch); propagate cancellation so off-screen loads stop; `inFlight` entries removed by the task itself in a `defer`. New `clearAll()` per U-59. |
| U-62 | P1 | **HTML sanitizer single-pass entity decoding.** `HTMLStringSanitizer.swift:43` replaces `&#65;` with the literal `65`. One-pass scanner: regex `&(#[0-9]+|#x[0-9a-fA-F]+|\w+);` with closure substitution (decimal/hex → `UnicodeScalar`, named → map, unknown → leave verbatim); strip tags first, then entities (single pass = no `&amp;`-double-decode artifacts). |
| U-63 | P2 | **TMDB key out of source.** `SearchSuggestionService.swift:9` hardcodes an API key in the binary. Move to `xcconfig` build setting injected via Info.plist (read with `Bundle.main.object`) for dev, or route suggestions through the daemon like every other network dependency (preferred — one network stack, one key policy). |
| U-64 | P2 | **Remote command hygiene.** `NowPlayingService.installCommands` (`:21-60`) never removes handlers; handlers capture `PlayerViewModel` weakly so they no-op, but play/pause targets stay registered after close. Add `clearCommands()` on `close()` (remove all targets), reinstall on next `play()`. |
| U-65 | P2 | `UserPreferences.syncRepositories` (`:124-132`) drops failed repos silently — collect failures, return `([RepositoryDto], [String /*url→error*/])`, surface in Extensions (U-55) and Onboarding. |

---

### WS-I — Navigation & deep links (P1)

| ID | Pri | Fix |
|---|---|---|
| U-66 | P1 | **Register every handled scheme.** `DeepLinkRouter` handles `cloudstream`, `cs.repo`, `cs3` (`RootView.swift:190-191`) but Info.plist registers only `cloudstreamrepo/cloudstreamapp/cloudstreamplayer` (`Info.plist:21-40`, `project.yml:72-76`). Add the missing three to `CFBundleURLSchemes` (project.yml `info.properties` is the source; the checked-in static `Info.plist` is deleted per U-69). |
| U-67 | P1 | **One scheme-stripper.** `DeepLinkRouter`'s prefix loop vs `DaemonClient.normalizeRepoUrl`'s list drift (`cloudstreamapp` present in one, not the other). Their WS-12 `normalizeInput` design wins: DeepLinkRouter normalizes via the same single function, then routes. |
| U-68 | P2 | Singleton reach-through in `DeepLinkRouter.handle` (`RootView.swift:188`) — router becomes a method on `AppState` (or takes it as a parameter from `.onOpenURL` inside the environment-backed view), so the window can later become multi-window without hidden global state. |

---

### WS-J — Build, packaging & config (P1/P2)

| ID | Pri | Fix |
|---|---|---|
| U-69 | P1 | **One Info.plist.** `GENERATE_INFOPLIST_FILE: true` + a checked-in `Info.plist` (version 1.0/1) + xcodegen `info.properties` (MARKETING_VERSION 1.1.0) is two sources of truth with drifting versions. Delete the static file; keep the generated one; move URL types (U-66), ATS, and display name fully into `project.yml`. |
| U-70 | P1 | **Post-build symlink vs code signing.** `project.yml:77-80` symlinks `Contents/Frameworks` in a post-build script — if it runs after the sign phase the signature is invalidated (Gatekeeper kills the app). Verify phase order; if signing follows, copy instead of symlink and sign after; add a `codesign --verify --strict` step to `scripts/package_app.sh` output. |
| U-71 | P2 | **Dev-machine leakage.** `/opt/homebrew/opt/mpv/lib` rpath + `/opt/homebrew/bin/ffmpeg` fallback (`project.yml:50-58`, `DownloadService.swift:522`) are dev conveniences in release config. Gate behind a `CS_DEV_FALLBACK` xcconfig for Debug; Release fails loudly (actionable error banner "bundled runtime missing") instead of silently depending on Homebrew. |
| U-72 | P2 | `cleanupStrayDaemons` blocks the main thread (`pgrep.waitUntilExit()` + `usleep(100ms)` per stray, `DaemonSupervisor.swift:183-210`) — move off-main; keep behavior. Document the random-port collision retry (daemon bind failure currently costs a 20 s health timeout before restart). |
| U-73 | P2 | **Localization strategy.** `Localizable.xcstrings` holds 30 strings while the UI hardcodes hundreds. Decision: delete the catalog until localization is a roadmap item (recommended — honest), or adopt it fully (feature work, out of scope). |

---

### WS-K — Dead code deletion (P2, mechanical)

Single PR, grep-verified inventory:

- `AppState`: `home(for:)`, `refreshHome`, `homeCache`+TTL (`:66-68, 193-207`); `activeProviderName` (`:89-93`); `filteredSearchResults`/`availableSearchTypes`/`availableSearchProviders` (`:302-319`, unless U-38 restores UI); `engineError` (write-only, `:55, 101, 128, 133, 150`); unbounded `loadedDetails` handled in U-23.
- `DaemonClient`: `home(provider:)` (`:175-183`), `search(_:)` (`:185-191`, superseded by stream), `diagnostics()`, `reTrustRepo`, `configureProvider`, `removePlugin` if truly uncalled — grep each before deleting; daemon endpoints stay (contract), client wrappers go.
- `DesignSystem`: `BrowseCategoryCard`, `ShelfRow`, `GlassPillStyle` (`U-35`).
- `DownloadsView.revision`; `ExtensionsView.isSyncing` (or U-56 revives it); `MediaDetailView.newestFirst` (unless their episode-sort WS lands first — then it's consumed, not deleted).
- `MetalVideoView.selectVideoTrack` — keep (protocol completeness) or drop from `PlayerTransport` if no UI ever will.
- Stale doc comments fixed in the same PR: `DaemonSupervisor` "sidebar Engine Status footer" (`:10`) — either ship the footer (small: sidebar footer showing `daemonState`, genuinely useful) or fix the comment; `SecurityVault` "argv/stdin" → "stdin" (`:8`).

**Verification:** `swift build` clean; `grep -rn` for each deleted symbol returns zero; app smoke pass (launch → search → details → play → close).

---

### WS-L — Tests & verification infrastructure (P0 foundation)

| ID | Pri | Fix |
|---|---|---|
| U-74 | P0 | **Unit test target.** `project.yml` gains `CloudStreamMacTests` (`bundle.unit-test`, dependency on the app target). Suites: `HTMLStringSanitizerTests` (numeric/hex/named entities, double-encode safety, tag stripping), `SubtitleStyleTests` (ARGB→RGBA migration table, serialization), `FileNameSanitizerTests` (`/`, `:`, trailing dots, collisions), `RepoURLNormalizationTests` (shared with their WS-12 fixtures), `LibraryStoreTests` (in-memory `init(inMemory:)`; version bumps, U-22 matrix, WatchType↔collection mapping), `DownloadProgressTests` (speed EMA, ETA math, failure classification fixtures), `QualityLabelTests`, `RemainingLabelTests`. |
| U-75 | P1 | **Manual QA script** (`docs/qa-ui-checklist.md`): per-screen checklist incl. both appearances, Reduce Motion/Transparency, VoiceOver pass over grid + player, keyboard-only walkthrough (⌘1…⌘6, ⌘E, ⌘,, search, player matrix), deep-link matrix for all six schemes. |

---

## 3. Execution order & merge train

Dependencies, not calendar time. WS-A/B can start immediately; WS-C tracks their V-02/V-16/V-17 merges; WS-D precedes WS-E; WS-E rides along each screen in WS-F/G.

```
Wave 1 (foundations, parallel):
  WS-L (test target + first suites)      ← lands first, everything else depends on green
  WS-A (keyboard/menus/Settings scene)   ← small, unblocks nothing, fixes P0s users feel daily
  WS-C (mpv correctness, after V-02/V-16/V-17 merge)

Wave 2 (structure):
  WS-B (player window; consumes WS-A monitor decisions)
  WS-D (store observation + data fixes)

Wave 3 (per-screen, sequential per screen, parallel across screens):
  WS-E (design tokens) with WS-F (search) → G-1/G-2 (home/library)
  → G-3 (downloads) → G-4 (details) → G-5 (extensions) → G-6 (settings)
  WS-H (services) interleaves anywhere after Wave 1
  WS-I (deep links) anytime; WS-J (packaging) before the next release cut

Wave 4 (cleanup):
  WS-K (dead code sweep) — last, so nothing deleted gets resurrected by earlier waves
```

**Suggested PR slicing** (each ≤ ~400 lines of diff where practical): `ws-a-keyboard-menus`, `ws-c1-subtitle-style`, `ws-c2-render-loop`, `ws-b-player-window`, `ws-d1-store-observation`, `ws-d2-data-correctness`, `ws-e-tokens` (+1 PR per screen), `ws-f-search`, `ws-g3-downloads`, `ws-g4-details`, `ws-g5-extensions`, `ws-g6-settings`, `ws-h-services`, `ws-i-deeplinks`, `ws-j-packaging`, `ws-k-dead-code`, `ws-l-tests` (or per-suite with each feature PR).

## 4. Decision points requiring sign-off

| DP | Question | Recommendation |
|---|---|---|
| DP-3 | Semantic both-appearance colors vs. tokenized dark-only TV look (gates WS-E) | Semantic both-appearance |
| DP-1 | Player: AppKit `NSWindowController` vs SwiftUI `Window` scene | AppKit controller |
| DP-2 | Store observation: version counter now vs `@Query` restructure now | Version counter; `@Query` as follow-up |
| DP-4 | Deployment target: keep macOS 15 + availability gates vs raise to 26 | Keep 15, gate through one helper |
| DP-5 | PiP: remove button (their N-12 assumption) vs schedule the detachable mini-window as a feature | Remove now; file the feature |
| DP-6 | Home shelf IA: keep (unified labels) vs delete in favor of sidebar-only collections | Keep, unified |

## 5. Definition of done (per workstream)

1. Every listed U-xx item merged, each with its test where the item names one.
2. `swift build` + full test suite green in CI (`macos.yml`).
3. Workstream verification commands/checklists executed, output in the PR.
4. Grep gates for the touched anti-patterns pass (`font(.system(size:` zero; no new `try?` around user actions; no new `.id(` refresh hacks; no new `Timer` in views).
5. Screenshots (before/after) for any visual change, light+dark.
6. ADR filed for each decision point exercised (0008–0010 minimum).

## 6. Implementation record (2026-09-29)

**Verification evidence**

- Debug + Release `xcodebuild` compile: clean (Swift 6 strict concurrency).
- Unit tests: **49/49 green** (`xcodebuild test`, suites: SubtitleStyle, HTMLStringSanitizer, FileNameSanitizer, DownloadProgress, QualityLabel, RepoURLNormalization, StoredMediaItem, LibraryStore on an in-memory container).
- Grep gates: `font(.system(size:` = 0 in `Sources/UI`; `tv*` tokens = 0; `.id(revision` = 0; `Timer.scheduledTimer` in views = 0; bare-modifier key equivalents = 0; hover `scaleEffect` = 0; traffic-light offset = 0.
- Smoke launch: app stays alive, spawns exactly one daemon, stray-daemon cleanup runs, no crash reports.

**Bugs found and fixed by the new tests (beyond the audit register)**

1. `classifyFailure` ordering: "Protocol not found" matched the 404 rule first — protocol failures reported as 404.
2. `normalizeRepoUrl`: the `cs.repo://cs.repo/url=https://…` form parsed ambiguously via `URLComponents` and dropped the query — replaced with a targeted regex.
3. `HTMLStringSanitizer`: `<p>` open tags glued adjacent words ("three<p>four") — open tags now emit the paragraph break; hex entities accepted in both `#x`/`#X` forms.
4. `qualityLabel`: invented bucket ranges replaced with Android's exact `Qualities` mapping (parity with `Implementation-Plan` WS guidance).

**Deliberate deviations from the plan text**

- Playback menu uses ⇧⌘N/⇧⌘M (not ⌘N/⌘M as sketched in U-01) — ⌘N and ⌘M are standard New/Minimize equivalents and must not be repurposed.
- U-51 (Share/Open-in-Browser) shipped as *disable when the details URL is not absolute*; resolving provider-relative URLs to absolute needs a `baseUrl` on the daemon contract — deferred to the IPC workstream.
- U-26 "Newest First" uses a new `createdAt` field (SwiftData lightweight migration) instead of reusing `lastUpdated`.
- The Downloads "Downloaded Titles" list stays row-based; `Table` adoption remains a feature, not a fix.
- U-72's random-port collision retry remains daemon-side (bind-failure → supervisor restart loop is unchanged); only the main-thread `usleep` was moved off-main.

**Follow-ups filed**

- `@Query` migration to replace the version counter (ADR-0009 north star).
- Real detachable PiP window (Implementation-Plan N-12).
- Player HUD buttons could adopt `.glass`/`.glassProminent` behind `if #available(macOS 26, *)` when the product wants the Liquid Glass treatment; current controls are standard-bordered and correct on 15+.
