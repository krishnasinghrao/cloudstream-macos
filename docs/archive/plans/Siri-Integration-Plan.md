# Siri & Apple Intelligence Integration Plan

> **Superseded (4 October 2026).** A draft; nothing here was built and it is not planned work. The single list of open work is [Remaining-Work.md](../../Remaining-Work.md).


Status: draft, 2026-10-01. Nothing here is implemented yet.

Goal: let Siri (and Spotlight, Shortcuts, the Action button equivalents on Mac)
find the user's titles, act on them, and understand what is on screen — without
weakening App Lock, profiles, or the extension security model.

## 1. What Apple actually offers (verified)

Checked against the WWDC26 sessions (240, 343, 345) and the installed
`MacOSX27.0.sdk` `AppIntents.swiftinterface` (Xcode 27.0).

| Capability | API | Available from |
|---|---|---|
| Siri runs an intent from natural language | `@AppIntent(schema:)` — only for intents that fit an App Schema | macOS 27 |
| Entities Siri understands semantically | `@AppEntity(schema:)` | macOS 27 |
| Semantic Spotlight index of app content | `IndexedEntity`, `CSSearchableIndex.indexAppEntities` | macOS 15.0 |
| System-requested reindex | `IndexedEntityQuery` | macOS 27 |
| "Search CloudStream for …" | `.system.searchInApp` (27), `ShowInAppSearchResultsIntent` (14.2) | see left |
| "Open … in CloudStream" | `.system.open` / `OpenIntent` | 27 / 13 |
| "Play … on CloudStream" | `PlayVideoIntent` + `VideoCategory` (movies, tv, …) | macOS 14.2 |
| On-screen awareness, single item | `NSUserActivity.appEntityIdentifier` | macOS 15.2 |
| On-screen awareness, grids/lists | `.appEntityIdentifier(_:)`, `.appEntityIdentifier(forSelectionType:)` | macOS 15.4 |
| Spoken/visual replies | `ProvidesDialog`, `ShowsSnippetView` | macOS 13 |
| Interactive snippets, multiple choice | `SnippetIntent`, `requestChoice(between:dialog:)` | macOS 26 |
| Learning from UI actions | `IntentDonationManager.donate(intent:result:)` | macOS 13 |
| Intent tests without Siri | `AppIntentsTesting.framework` | Xcode 27 |

### The constraint that shapes the plan

**There is no video / TV / streaming App Schema domain.** The SDK's domains are:
assistant, audio, books, browser, calendar, camera, clock, files, journal, mail,
maps, messages, notes, phone, photos, presentation, reader, reminders,
spreadsheet, system, visualIntelligence, whiteboard, wordProcessor.

Consequences:

- Free-form Siri understanding is available only through the three generic
  routes: `searchInApp`, `open`, and `PlayVideoIntent`.
- Every other verb (favorite, set status, next episode, skip intro …) is a plain
  App Intent. Siri reaches those through **App Shortcut phrases** we declare, and
  they are fully available in Shortcuts and Spotlight.
- Entities without a schema still get semantic indexing and on-screen awareness.
- We do **not** adopt the audio schemas for video. They would compile, but they
  describe songs/podcasts and would make Siri treat titles as audio.
- `RelevantEntities` only has an audio context today — skipped.
- `SyncableEntity` is for cross-device conversations — skipped (library is local).

## 2. What exists today

- `SearchCloudStreamIntent`, `ContinueWatchingIntent`, `CloudStreamShortcuts`
  in [SystemIntegration.swift](../../../client/Sources/UI/Navigation/SystemIntegration.swift).
- Hand-built `CSSearchableItem`s in [SpotlightIndexer.swift](../../../client/Sources/Services/System/SpotlightIndexer.swift).
- `DeepLinkRoute` + `WindowSession.perform(_:)` as the single execution path,
  already blocked while App Lock is engaged.
- `.userActivity(UserActivityType.viewTitle)` on the title page (Handoff).

Gaps:

1. No entities — Siri cannot refer to a specific title.
2. Intents return `.result()` with no dialog. When the app is locked, `perform`
   logs and returns, so Siri reports success for something that did not happen.
3. `ContinueWatchingIntent` needs the engine (`DaemonClient.details`); a cold
   launch from Siri races engine start-up.
4. Library mutations take a `DetailsDto`, so they cannot run from an entity ID
   without a round trip through `detailsPreview(for:)`.

## 3. Design

### 3.1 Layout

New folder `client/Sources/Intents/` (add to `project.yml`; the `.pbxproj` is generated):

```
Intents/
  TitleEntity.swift          entity, query, IndexedEntity conformance
  IntentEnums.swift          WatchStatus, AppSection AppEnums
  IntentGate.swift           lock / profile / isolation / engine-ready checks
  NavigationIntents.swift    search, open title, open section
  PlaybackIntents.swift      play, resume, next episode, skip intro, subtitles
  LibraryIntents.swift       favorite, watch status, mark watched, rate
  QueryIntents.swift         what was I watching, new episodes, downloads status
  IntentSnippets.swift       SwiftUI snippet views
  CloudStreamShortcuts.swift AppShortcutsProvider (moved out of SystemIntegration)
```

### 3.2 `TitleEntity`

- `id` = `StoredMediaItem.id` (`"provider|url"`) — already stable and persistent,
  which on-screen annotations require.
- Properties: title, media type, provider name, watch status, favorite,
  last season/episode, progress fraction, new-episode count, rating.
  `userNote` is deliberately **not** exposed.
- `displayRepresentation`: title, subtitle `"S2 E3 · 18 min left"` or status,
  poster thumbnail from the existing poster cache (never a network fetch).
- `TitleQuery: EntityStringQuery`
  - `entities(for:)` → `LibraryStore.item(id:)`
  - `entities(matching:)` → localized-contains over library + history
  - `suggestedEntities()` → Continue Watching, then Favorites
  - `displayRepresentations(for:requestedComponents:)` for fast on-screen resolution
- `IndexedEntity` with `@Property(indexingKey:)`; `SpotlightIndexer` switches to
  `indexAppEntities` / `deleteAppEntities`, keeping the same identifiers, domain,
  debounce and `indexInSpotlight` preference. `IndexedEntityQuery` on macOS 27.

Episodes are not entities: they come from the engine per request and have no
stable local identity. Intents take optional `season` / `episode` integers.

### 3.3 `IntentGate`

One check used by every intent before it touches data, throwing a localized
error Siri reads aloud instead of silently no-op'ing:

- App Lock engaged → "CloudStream is locked. Unlock it to continue."
  (foreground intents bring the lock screen forward; background ones just fail)
- `AppEnvironment.isIsolated()` → intents unavailable
- onboarding incomplete → open the app
- engine-dependent intents await engine readiness with a bounded timeout,
  then fail with "CloudStream's engine isn't ready yet."

`TitleQuery` returns nothing while locked, matching the menu bar behaviour.

### 3.4 Intents

Siri-understood (schema or system protocol):

| Intent | Mechanism | Example |
|---|---|---|
| `SearchCloudStreamIntent` | `.system.searchInApp` on 27, `ShowInAppSearchResultsIntent` below | "Search CloudStream for Dune" |
| `OpenTitleIntent` | `.system.open` / `OpenIntent`, target `TitleEntity` | "Open Severance in CloudStream" |
| `PlayTitleIntent` | `PlayVideoIntent`, categories movies + tv | "Play Severance on CloudStream" |

`PlayTitleIntent` resolves `term` against the library first: one match resumes
it, several ask (`requestChoice` on 26+, otherwise open search), none runs a search.

Phrase-driven (App Shortcuts, Shortcuts app, Spotlight):

| Intent | Runs in | Notes |
|---|---|---|
| `ContinueWatchingIntent` | foreground | existing; add dialog "Resuming Severance, season 2 episode 3" |
| `ResumeTitleIntent(title)` | foreground | phrase `"Resume \(\.$title) in \(.applicationName)"` |
| `PlayNextEpisodeIntent`, `SkipIntroIntent`, `ToggleSubtitlesIntent` | background | fail clearly when nothing is playing |
| `ToggleFavoriteIntent(title)` | background | |
| `SetWatchStatusIntent(title, status)` | background | "Mark … as completed" |
| `MarkWatchedIntent(title)`, `RateTitleIntent(title, 1–5)` | background | |
| `WhatWasIWatchingIntent` | background | returns `[TitleEntity]` + snippet |
| `NewEpisodesIntent` | background | reads `newEpisodeCount`; no network |
| `DownloadsStatusIntent` | background | "2 active, 5 queued" |
| `OpenSectionIntent(section)` | foreground | Home, Library tabs, History, Downloads |

Plain play/pause/seek stay with `NowPlayingService` remote commands, which
Siri and media keys already drive.

**Deliberately not exposed:** adding repositories, installing or configuring
extensions, credentials, backup import/export, profile switching, clearing
history. These keep their confirmed in-app flows (see Security.md).

`AppShortcutsProvider` is capped at 10 shortcuts; the phrase set above fits.
Call `CloudStreamShortcuts.updateAppShortcutParameters()` when the library
changes so title names stay recognisable in phrases.

### 3.5 Store changes

Add ID-based variants to `LibraryStore` (`toggleFavorite(itemID:)`,
`setWatchType(itemID:watchType:)`, `setRating(itemID:)`) so background intents
do not need a `DetailsDto` or the engine. `markWatched(itemID:)` already exists.

## 4. Making it feel good

- **Answers, not just actions.** Every intent returns an `IntentDialog` with a
  self-sufficient `full` string and a short `supporting` one.
- **Snippets.** Poster, title, episode, progress bar. On macOS 26+ they are
  interactive: Resume, Next Episode, Favorite buttons run the same intents.
- **"This" and "that".** Add `appEntityIdentifier` to the existing title-page
  user activity (15.2+), `.appEntityIdentifier` on poster cards in
  `MediaCards.swift` and `forSelectionType:` on Library/History lists (15.4+).
  Then "add this to my favorites" works on whatever is on screen or selected.
- **Learning.** Donate `ResumeTitleIntent` / `ToggleFavoriteIntent` when the
  user does the same thing by hand, so suggestions reflect real habits. Only
  UI actions are donated, once per action.
- **Disambiguation.** The same show from two providers is common here; the
  display subtitle carries the provider name so Siri's choice list is readable.
- **Honest failures.** Locked, engine down, offline, provider removed — each
  has its own sentence. No "Done" for something that did not happen.
- **Offline.** Resuming a fully downloaded title must not need the provider;
  verify `LibraryStore.resume` falls back to the downloaded file.
- **Discoverability.** A "Siri & Shortcuts" row in Settings listing the phrases,
  plus a `SiriTipView` on Continue Watching until first use.

## 5. Privacy and security

- Indexing puts title names in the system index. Proposal: when App Lock is
  enabled, default `indexInSpotlight` off and explain why in Settings.
- Profile switch already has to clear and rebuild the index; verify this holds
  for `indexAppEntities` and add a test.
- Queries and intents are gated by `IntentGate`; no entity leaves a locked app.
- Provider URLs are part of the entity ID but are not a displayed or indexed
  property.
- No intent accepts a URL or repository string from Siri.

## 6. Phases

| Phase | Scope | Min OS for the feature |
|---|---|---|
| S0 | `Intents/` folder, `IntentGate`, dialogs + real errors on the two existing intents, engine-ready wait | 15.0 |
| S1 | `TitleEntity`, query, enums, `IndexedEntity`, `SpotlightIndexer` migration | 15.0 |
| S2 | Open / Play / Resume / Search intents, parameterised phrases, store ID-based mutations, library and query intents | 15.0 (schemas gated to 27) |
| S3 | On-screen annotations, donations, snippets, Settings row | 15.2 / 15.4 / 26 |
| S4 | `AppIntentsTesting` suite, lock/profile/isolation tests, manual Siri matrix in `qa-ui-checklist.md` | Xcode 27 |

Deployment target stays 15.0; newer pieces are `@available`-gated.

## 7. Verification

1. `AppIntentsTesting` unit tests per intent, including locked, isolated and
   empty-library cases.
2. Shortcuts app: every intent appears, parameters resolve, results chain.
3. Spotlight: titles appear, open the right page, disappear on profile switch
   and when indexing is turned off.
4. Siri, typed and spoken: the examples in §3.4 plus "add this to favorites" on
   a title page and on a selected library card.
5. Cold launch from Siri with the engine not yet running.

## 8. Open questions

1. CI: does `.github/workflows/macos.yml` build with Xcode 27? The schema macros
   and `AppIntentsTesting` need it.
2. Do schema-less `IndexedEntity` types get the full semantic-index treatment on
   27, or only keyword matching? Needs a device test in S1.
3. `_NowPlaying_AppIntents` (`MediaSessionRepresentable`) can attach entity
   identifiers to Now Playing. The sessions only show music content; check
   whether a video content type exists before planning on it.
4. Siri behaviour for an ad-hoc-signed build outside `/Applications` — confirm
   intents register from the packaged `dist/` app, not only from Xcode runs.
5. App Lock + Spotlight default (§5) — product decision.
