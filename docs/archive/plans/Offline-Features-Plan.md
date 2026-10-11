# Offline Features & Robustness — Implementation Plan

> **Status (2026-09-30): Phases 0–10 implemented.** IPC contract v3 ([ipc-api.md](../../ipc-api.md));
> decisions in ADR-0011…0014; manual pass in [qa-ui-checklist.md](../../qa-ui-checklist.md).

**Scope.** Features that bring the macOS client up to Android's feature set (and beyond) **without any
third-party account or web API** (no MAL/AniList/Simkl/Kitsu, no OpenSubtitles/Subdl, no AniSkip, no
TMDB). Everything here runs on local data, on the installed provider plugins, or on the daemon itself.

**Status baseline (already in macOS — not re-planned here).**

| Area | Already present | Where |
|---|---|---|
| Library buckets | Watching / Plan to Watch / Completed / On Hold / Dropped, favorites, counts | `Models/StoredMediaItem.swift`, `Services/LibraryStore.swift` |
| Library sort | Recently updated / Newest / … | `UI/Library/LibraryView.swift:63` |
| Continue Watching | Home row from `StoredMediaItem` progress | `UI/Home/HomeView.swift`, `UI/Components/MediaCards.swift` |
| Resume | Per-**title** resume (`lastEpisode`, `progressSeconds`), unseekable-source failover | `LibraryStore.recordProgress`, `PlayerViewModel.handleSeekable` |
| Continuous playback | Next episode on EOF (no countdown) | `PlayerViewModel.handleEndOfFile` |
| Player | Speed, sub delay, audio/sub tracks, aspect, mirror failover, PiP, Now Playing | `PlayerViewModel`, `PlayerHUDView` |
| Downloads | Queue, per-provider concurrency, ffmpeg HLS, notifications | `Services/DownloadService.swift` |
| Menus | "Go" + "Playback" command menus | `App/CloudStreamMacApp.swift:104,162` |
| Search | Grouped by provider, recent searches, suggestions | `UI/Search/SearchView.swift`, `UserPreferences.recentlySearched` |

**Key gap discovered while auditing:** progress is stored **per title, not per episode**. A series row
only knows the *last* episode touched. Phase 1 fixes this first because half the UX features below
(watched ticks, "mark previous watched", "play next unwatched", per-episode progress bars) depend on it.

---

## Phase overview

| # | Phase | Size | Depends on |
|---|---|---|---|
| 0 | Foundations: schema versioning, feature flags, test fixtures | S | — |
| 1 | Per-episode watch history | M | 0 |
| 2 | Full metadata passthrough + `/details` cache (daemon) | M | — |
| 3 | Network robustness: DNS-over-HTTPS, HTTP disk cache, timeouts, retry | M | — |
| 4 | Playback UX: next-up countdown, skip, remembered prefs, source/quality priority | L | 1, 2 |
| 5 | Subtitles offline: local files, styling, auto-select, per-title offset | M | 4 (prefs store) |
| 6 | Library & discovery richness | M | 1, 2 |
| 7 | Backup / restore + profiles + Touch ID lock | L | 1 |
| 8 | Diagnostics: provider test runner, log viewer, health panel | M | — |
| 9 | macOS integration: Spotlight, Handoff, menu bar, shortcuts, external player | M | 1 |
| 10 | Hardening & QA pass | M | all |

Phases 2, 3 and 8 are daemon-heavy and can run in parallel with 1 on the client.

---

## Phase 0 — Foundations

**Goal:** make the rest of the plan safe to ship incrementally.

1. **SwiftData versioned schema.** Introduce `VersionedSchema` (`SchemaV1` = current models) and a
   `SchemaMigrationPlan` in `Services/LibraryStore.swift`. Every later phase that adds a `@Model`
   bumps the schema instead of relying on implicit lightweight migration.
   - Test: open a V1 store fixture, migrate, assert no data loss (`Tests/LibraryMigrationTests.swift`).
2. **Feature flags.** `UserPreferences.features: Set<String>` + `FeatureFlag` enum, surfaced in a hidden
   Settings → Advanced section, so half-finished features can be merged dark.
3. **IPC version bump policy.** Every daemon DTO change bumps `HealthDto.expectedIpcVersion`
   (`Models/IPC/EngineDtos.swift`) and `ipc-api.md`. New fields are **optional with defaults** on both sides so an
   older daemon never breaks a newer client.
4. **Fixture provider.** A tiny in-repo test `MainAPI` (daemon test source set) returning deterministic
   search/home/load/links, used by Phases 2, 4, 8 tests.

**Done when:** migration test green; flag toggle visible; fixture provider loads in `ProviderExecutorTest`.

---

## Phase 1 — Per-episode watch history

**Goal:** Android parity for `DataStoreHelper` episode positions/watch state.

### Data model (SchemaV2)
```swift
@Model final class EpisodeProgress {
    @Attribute(.unique) var id: String       // "\(itemID)|\(episodeData.sha256)"
    var itemID: String                       // StoredMediaItem.id ("provider|url")
    var episodeData: String
    var season: Int?
    var episode: Int?
    var positionSeconds: Double
    var durationSeconds: Double
    var watched: Bool                        // explicit or ≥ 90% (Android uses ~0.9)
    var updatedAt: Date
}
```
- Hash `episodeData` for the key (data strings can be multi-KB).
- Keep `StoredMediaItem.lastEpisode*`/`progressSeconds` as the denormalised "resume pointer"
  so Continue Watching stays a single query.

### LibraryStore API
- `recordProgress(...)` → also upserts `EpisodeProgress`; auto-marks `watched` at ≥ 90 % or when
  < 2 min remain (credits).
- `progress(for itemID:) -> [String: EpisodeProgress]` (one fetch per detail page, not per row).
- `setWatched(_:episodes:)`, `markPreviousWatched(upTo:)`, `markSeasonWatched(_:)`, `clearProgress(itemID:)`.
- `nextUnwatched(details:) -> EpisodeDto?` — first episode after the last watched one, falling back to
  first-in-season.
- Auto-promote: all episodes watched → `watchType = .completed` (opt-out in Settings); first play of a
  Plan-to-Watch item → `.watching`.

### UI
- `EpisodeRow` (`MediaDetailView.swift:752`): thin progress bar under the thumbnail, ✓ badge when
  watched, dimmed title when watched.
- Context menu on `EpisodeRow`: *Mark as Watched / Unwatched*, *Mark All Previous as Watched*,
  *Download*, *Copy Link*.
- Season picker menu: *Mark Season Watched*, shows "8/12 watched".
- Primary button label: **"Resume S2 · E5 (12:34 left)"** / **"Play S2 · E6"** / **"Play"** based on
  `nextUnwatched`.
- Detail page auto-selects the season containing the next unwatched episode.
- **Resume prompt** (Android's resume dialog): when opening an episode with 1 %–90 % progress, show a
  popover *Resume from 34:12 / Start Over*; setting "Always resume" skips it.

### Migration
- Backfill one `EpisodeProgress` per existing `StoredMediaItem` that has `lastEpisodeData`.

**Tests:** watched threshold, mark-previous ordering across seasons, `nextUnwatched` for
movie/series/anime dub+sub, backfill migration, auto-complete.

---

## Phase 2 — Full metadata passthrough & details cache (daemon)

**Goal:** stop discarding what providers already return. No external APIs — this is data the plugin
already fetched.

### DTO changes (`daemon/.../models/Dtos.kt`, `client/Sources/Models/IPC/`)
Add optional fields to `DetailsDto`:

| Field | Source (`LoadResponse`) | Notes |
|---|---|---|
| `recommendations: [SearchResultDto]` | `recommendations` | cap at 30 |
| `trailers: [TrailerDto{url, referer, headers}]` | `trailers` | play via existing mpv player |
| `showStatus: String?` | `TvSeriesLoadResponse.showStatus`, `AnimeLoadResponse.showStatus` | Ongoing / Completed |
| `nextAiring: NextAiringDto{episode, unixTime, season}` | `nextAiring` | countdown badge |
| `seasonNames: [SeasonNameDto{season, name, displaySeason}]` | `seasonNames` | real season titles |
| `syncIds: [String: String]` | `syncData` | **stored only** — used as a stable cross-provider identity, never called |
| `posterHeaders: [String:String]?` | `posterHeaders` | fixes referer-checked posters |
| `uniqueUrl: String?` | `uniqueUrl` | better library identity |
| `dubStatus` map | `AnimeLoadResponse.episodes` keys | replaces " (Dub)" name suffix hack in `ProviderExecutor.kt:360` |
| `actors` | drop `take(20)` → `take(60)`, include `voiceActor` | |
| `EpisodeDto.isFiller`? | skip — needs external API | |

Also `SearchResultDto.posterHeaders`, `HomePageDto` row `isHorizontal` (Android uses it for wide rows).

### Details cache
- Port `APIRepository.load` caching into `ProviderExecutor.loadDetails`: key `(provider, fixUrl(url))`,
  TTL 10 min, LRU 50 entries, cleared on plugin reload / enable / disable.
- `?refresh=1` query param bypasses cache (wired to ⌘R on the detail page).
- Strip blank tags (Android does this).

### Per-provider timeout
- Wrap `load`/`search`/`getMainPage`/`loadLinks` with `withTimeout(getTimeout(api.loadTimeoutMs))`
  using Android's clamp constants; return `504` with a clear message instead of hanging.

### Client
- `PosterImage` accepts headers; image cache key includes headers hash.
- Detail page: status chip, "Next episode in 2d 4h" badge, season titles, **More Like This** row
  (reuses `MediaCards`), **Trailer** button (opens player with trailer link, no library progress).
- Persist `syncIds` + `uniqueUrl` on `StoredMediaItem` (SchemaV3) for Phase 6 dedup.

**Tests:** `ProviderExecutorTest` with fixture provider asserts every new field; cache hit/miss/evict;
timeout returns 504; Swift decoding of old-daemon payload (fields absent) still succeeds.

---

## Phase 3 — Network robustness (daemon)

**Goal:** Android's `RequestsHelper.buildDefaultClient` parity, plus better failure behaviour.

1. **DNS-over-HTTPS.** Port `app/.../network/DohProviders.kt` into `engine/.../network/`.
   Options: System, Google, Cloudflare, AdGuard, DNS.Watch, Quad9, DNS.SB, Canadian Shield, **Custom
   URL** (new). Bootstrap IPs as on Android.
2. **HTTP disk cache.** `Cache(~/.cloudstream-macos/cache/http, 50 MiB)`; size configurable; purge in
   Settings → Maintenance.
3. **Settings endpoint.** `GET/POST /settings/network { dns, customDohUrl, cacheMb, userAgent? }`.
   `NetworkSetup` rebuilds `app` + `insecureApp` base clients *preserving* `SolveInterceptor`.
   Persisted in `state.json` so the daemon boots with it.
4. **Retry & backoff.** Interceptor: 1 retry on `IOException`/`SocketTimeout` for idempotent GETs,
   jittered 300–800 ms. Never retry POST or solve-parked requests.
5. **Connectivity awareness (client).** `NWPathMonitor` in `AppState`: offline banner, pause the
   download queue, disable network actions, auto-resume when back.
6. **Connection test.** Settings button: resolves + HEADs each enabled provider's `mainUrl` through the
   configured DNS, shows latency / failure per provider.

**UI:** Settings → *Network* section (DNS picker, custom URL field with validation, cache size, Test).

**Tests:** DoH builder per option; state persistence round-trip; interceptor chain order
(DoH → Solve → retry); client offline banner snapshot.

---

## Phase 4 — Playback UX

### 4.1 Next-up countdown
- When `remaining ≤ max(credits, 20 s)` and a next episode exists, show a HUD card
  "Next: S1 · E6 — Title  [Play Now] [Cancel]" with a 10 s ring countdown.
- Pre-resolve next episode links in the background at 90 % (uses existing `/links/stream`) so the
  switch is instant.
- Settings: countdown length (0 = off, 5/10/15 s).

### 4.2 Skip controls (no AniSkip)
- **mpv chapters**: read `chapter-list`; titles matching `/intro|opening|op|recap|outro|ending|ed|credits/i`
  get a *Skip Intro* / *Skip Credits* pill. Remove `!no_chapters` from single-file loads
  (`PlayerViewModel.mergedSplitURL` keeps it only for EDL parts).
- **Manual "Skip 85 s" button** (Android's `skip op` fallback), amount configurable.
- **Per-series learned intro**: user presses *Mark intro end* once → stored `(itemID, introStart,
  introEnd)`; offered on later episodes of the same series. Purely local.

### 4.3 Remembered per-title preferences
New `@Model TitlePlaybackPrefs { itemID, audioLanguage, subtitleLanguage, subtitleDelay, speed, dubPreferred, preferredSource }`.
Applied on session start, updated when the user changes them mid-play.

### 4.4 Source & quality priority (Android `source_priority/`)
- `@Model QualityProfile { name, qualityWeights[Int:Int], sourceWeights[String:Int], isDefault }`.
- `PlayerViewModel` sorts `session.links` by `sourceWeight + qualityWeight` (negative = hidden) before
  choosing `selectedLinkIndex`; failover walks that order.
- Profile editor sheet in Settings → Player: drag-to-reorder sources seen so far (collected from
  resolved links), quality sliders.
- Downloads reuse the same ordering (replace `preferredQuality` only logic in `DownloadPolicy`).

### 4.5 HUD details
- Source picker shows `source · quality · size (if known)`, current one ticked, switch keeps position
  (`failover(to:startAt:)` already supports it).
- Seek step settings (5/10/15/30 s), ←/→ and J/L use it; Shift doubles.
- Remember volume & mute globally.
- Scrubber hover time tooltip; **thumbnail preview** for downloaded/local files via a second headless
  mpv/ffmpeg thumbnailer (stretch goal, flag-gated).
- Screenshot (⌘⇧S) via mpv `screenshot-to-file` into `~/Pictures/CloudStream`.
- Sleep timer (end of episode / 15 / 30 / 60 min).
- A–B loop and frame step (`,` / `.`) — cheap with mpv.

**Tests:** link ordering given profile; countdown cancel; chapter-title classifier; prefs applied on
start; failover order honours hidden sources.

---

## Phase 5 — Subtitles (offline)

1. **Load local subtitle file**: HUD → Subtitles → *Add File…* (`NSOpenPanel`, .srt/.vtt/.ass/.ssa) and
   drag-and-drop onto the player window → mpv `sub-add`.
2. **Auto-load sidecar subs** for downloaded files (same basename, `.lang.srt` pattern).
3. **Auto-select language** list (ordered), with "Forced only" and "Off" options; falls back to
   `TitlePlaybackPrefs`.
4. **Styling parity**: font family picker, edge style (outline/shadow/raised/depressed), bold, vertical
   position (`sub-pos`), background opacity; live preview in Settings (already has `SubtitleStyle`).
5. **Offset UI**: ±50 ms / ±500 ms buttons, `Z`/`X` shortcuts, "sync to now" helper
   (press when a line appears → computes delay); saved per title (4.3).
6. **Download subtitles with video**: `DownloadService` fetches provider `SubtitleDto`s next to the file.

**Tests:** sidecar matching, language ranking, style → mpv option mapping.

---

## Phase 6 — Library & discovery richness

1. **New-episode badges (local)**: when a library series' details load (detail open or background
   refresh), compare episode count with stored `knownEpisodeCount`; show "3 new" badge + optional
   notification. Background refresh: `BGTask`-style timer, max N items/hour, only Watching items,
   rate-limited through the daemon.
2. **Cross-provider dedup / "Also on"**: group library entries sharing `syncIds`/normalised title+year;
   detail page shows other providers for the same title (search-based, provider-local).
3. **Home**:
   - Choose visible providers & row order; hide rows; per-row retry on failure instead of a page error.
   - "Random" (⌘⇧R) picks from loaded home rows.
   - Skeleton placeholders instead of spinners.
   - Continue Watching card shows "S2 · E5 · 12m left" and a *Remove* context action (exists) +
     *Mark Watched*.
4. **Search**:
   - Type filter chips (Movies / TV / Anime / Cartoon / Documentary / Live / Other) using `tvTypes`.
   - Provider scope menu and language filter.
   - Search history management (clear, remove single) — `recentlySearched` exists, add UI.
   - Quick search in global search field honouring `hasQuickSearch`.
5. **Library**:
   - Grid/list toggle, filter by type & provider, text filter within library.
   - Bulk select → change status / remove / export.
   - Stats header: titles, episodes watched, hours watched (from `EpisodeProgress`).
   - **Watch history** view: chronological list of `EpisodeProgress`, with clear-all / remove.
6. **Poster quick-look**: Space on a focused poster (or force-click) → popover with plot, status,
   add-to-library buttons, without navigating.
7. **Personal notes & rating** per title (`StoredMediaItem.userNote`, `userRating`).

---

## Phase 7 — Backup/restore, profiles, lock

### 7.1 Backup / restore
- Format: `CloudStreamBackup.json` (versioned) = library items, episode progress, per-title prefs,
  quality profiles, preferences (excluding secrets), repository URLs, enabled/disabled plugins,
  plugin configs (from daemon `state.json` via new `GET /state/export` + `POST /state/import`).
- Optional **Android backup import**: map Android `BackupUtils` JSON (bookmarks/result watch state,
  `result_resume_watching`, `video_pos_dur`) to macOS models. Offline and very valuable for migrating users.
- File → Export Backup… / Import Backup… (merge or replace, with preview of counts).
- **Automatic backups**: daily rolling copy (keep 7) in `~/Library/Application Support/CloudStream/Backups`.
- Tests: round-trip equality; import of a real Android fixture; corrupt file rejected without partial writes.

### 7.2 Profiles
- `@Model Profile { id, name, avatarSymbol, color, lockEnabled }`; every user-data model gains
  `profileID` (SchemaV4, backfill to default profile).
- Profile switcher in toolbar + at launch when >1 profile (Android `AccountSelectActivity`).
- Per-profile preferences namespace in `UserPreferences`.

### 7.3 Lock
- Touch ID / password via `LAContext` per profile; auto-lock after idle N minutes or on sleep.
- Keychain stores only a flag/nonce — never a password in `UserDefaults`.

---

## Phase 8 — Diagnostics & provider health

1. **Provider test runner** (Android `settings/testing`): daemon `POST /test/run {plugins?}` streams
   NDJSON per provider: homepage → search("the") → load(first) → links(first) with timings and error.
   UI table with pass/fail/latency, *Disable failing*, *Copy report*.
2. **Health panel**: surface `/diagnostics` (already collected) — success rate, p50/p95 latency per
   provider; red/yellow badges in Extensions list.
3. **Log viewer**: Settings → Diagnostics → tail `daemon.log` + client log, filter by level/provider,
   *Export logs…* zip (redacting tokens/cookies via existing `Sanitizer`).
4. **Plugin details sheet**: version, repo, authors, size, sha256, last error, supported types,
   language, `vpnStatus` badge (new DTO field), "Open repo".
5. **Crash-safe daemon restart UX**: `DaemonSupervisor` shows a non-modal banner with restart count
   and last error rather than silent retries.

---

## Phase 9 — macOS integration

| Feature | API | Notes |
|---|---|---|
| Spotlight | `CSSearchableIndex` | index library titles + posters; open via `NSUserActivity` |
| Handoff / state restoration | `NSUserActivity` on detail & player | reopen last detail page on relaunch |
| Menu bar extra | `MenuBarExtra` | Continue Watching (top 5), download progress, pause-all |
| Dock | badge = active downloads; Dock menu with Continue Watching |
| Shortcuts | `AppIntents` | "Continue watching", "Search CloudStream for…" |
| External player | open link in IINA / VLC / mpv / QuickTime (`NSWorkspace`) with headers via CLI args | Android `VideoClickAction` parity |
| Deep links | `cloudstream://search?q=`, `cloudstream://open?provider=&url=` | alongside existing `cloudstreamrepo://` |
| Keyboard | ⌘F search, ⌘1–5 sections, ⌘R refresh, ⌘D add to library, ⌘⇧W mark watched, ⌘, settings | extend existing `CommandMenu`s; add a Shortcuts cheat sheet (⌘/) |
| Share | `ShareLink` exists → add "Copy as Markdown" / "Copy stream URL" (debug) | |
| Power | `IOPMAssertion` prevent sleep during playback & active downloads | |

---

## Phase 10 — Hardening & QA

- **Data integrity:** SwiftData saves batched & debounced (progress writes ≤ 1 / 5 s per session);
  flush on `applicationWillTerminate` and player close.
- **Downloads:** resume-after-reboot test, disk-full handling, orphan `.part` cleanup at launch.
- **Memory:** image cache limits (NSCache cost), cap recommendations/actors images, profile
  `MetalVideoView` long sessions.
- **Accessibility:** VoiceOver labels on all new controls, Reduce Motion for countdown ring.
- **Performance budgets:** detail page first paint < 150 ms from cache; library of 2 000 items scrolls
  at 60 fps; `progress(for:)` single fetch.
- Extend `qa-ui-checklist.md` with every new surface; UI tests for resume prompt, next-up, backup
  round-trip, profile switch.

---

## File-level change map

| Area | Files |
|---|---|
| Models | `Models/StoredMediaItem.swift` (+fields), new `Models/EpisodeProgress.swift`, `Models/TitlePlaybackPrefs.swift`, `Models/QualityProfile.swift`, `Models/Profile.swift`, `Models/Schema.swift` |
| Services | `LibraryStore.swift` (progress API, migration plan), new `BackupService.swift`, `SpotlightIndexer.swift`, `ConnectivityMonitor.swift`, `LinkRanker.swift` |
| ViewModels | `PlayerViewModel.swift` (countdown, chapters, prefs, ranking), `AppState.swift` (profiles, offline) |
| UI | `MediaDetailView.swift`, `EpisodeRow`, `PlayerHUDView.swift`, `HomeView.swift`, `SearchView.swift`, `LibraryView.swift`, `SettingsView.swift` (Network, Player profiles, Diagnostics, Backup), new `HistoryView.swift`, `ProviderTestView.swift`, `LogViewer.swift`, `ProfilePicker.swift` |
| App | `CloudStreamMacApp.swift` (commands, MenuBarExtra, URL routes), `DaemonSupervisor.swift` |
| Daemon | `models/Dtos.kt`, `ProviderExecutor.kt` (fields, cache, timeouts), `NetworkSetup.kt` + new `network/DohProviders.kt`, `RetryInterceptor.kt`, `Main.kt` (`/settings/network`, `/state/export|import`, `/test/run`), `StateRepository.kt` |
| Docs | `ipc-api.md` (v3), `Architecture.md`, `qa-ui-checklist.md`, ADR for per-episode history & backup format |

## Suggested sprint order

1. Phase 0 + Phase 2 (daemon) in parallel with Phase 1 (client) — biggest visible win.
2. Phase 4.1–4.3 + Phase 5.1/5.5 — playback polish.
3. Phase 3 — network robustness.
4. Phase 7.1 backup (incl. Android import) — protects user data before adding profiles.
5. Phase 6, then 4.4 source priority.
6. Phase 8, Phase 9, Phase 7.2/7.3.
7. Phase 10 continuously; formal pass before release.

## Explicitly out of scope (needs external APIs)
MAL / AniList / Kitsu / Simkl sync, OpenSubtitles / Subdl / SubSource / Addic7ed search, AniSkip
timestamps, filler-episode lists, TMDB/IMDb metadata enrichment, Chromecast. Phase 2 stores `syncIds` so
these can be added later without a migration.
