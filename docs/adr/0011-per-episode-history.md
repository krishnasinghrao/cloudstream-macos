# ADR-0011: Per-episode watch history beside the title resume pointer

**Status:** Accepted (2026-09-30) · **Decides:** Offline-Features-Plan Phase 1

## Context

`StoredMediaItem` held one resume position per title. The detail page
could not show which episodes were watched, "Play" could not pick the next
unwatched episode, and marking a season watched had nowhere to go.
Android keeps this per episode (`video_pos_dur`, `result_watch_state`).
Episode identity on the Mac is the provider's `data` string, which can be
several KB of JSON.

## Decision

Add a separate SwiftData model, `EpisodeProgress`, keyed by
`"<itemID>|sha256(episodeData)"` (unique), with position, duration,
`watched` and `updatedAt`. Keep the denormalised title-level pointer on
`StoredMediaItem` so Continue Watching stays a single fetch.

* An episode counts as watched past 90 % or within the credits tail
  (`WatchProgressPolicy`); explicit marks override it.
* Reads fetch every row of a title in one query (`episodeProgress(itemID:)`);
  the detail page caches the map and refreshes on `LibraryStore.version`.
* Bulk marks (season, "all previous") fetch once and upsert in memory.
* Schema change is additive (ADR-0006 rule): the new model and every new
  field has a default, so existing stores migrate lightweight.
* Library status auto-promotes (Plan to Watch → Watching → Completed) only
  for titles the user filed, behind a setting.

## Consequences

* Ticks, progress bars, "Resume / Start Over" and next-unwatched selection
  are all local and work offline.
* Two sources of truth for "where am I": the pointer is derived and
  rewritten on every progress save, so drift is bounded to one save.
* Keys depend on provider `data`; a provider that changes its episode
  encoding orphans old rows (they stay harmless, and are removed with the title).
* Android per-episode history cannot be imported — Android ids are
  app-internal hashes (see ADR-0012).
