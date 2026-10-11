# ADR-0013: Profiles as separate SwiftData stores

**Status:** Accepted (2026-09-30) · **Decides:** Offline-Features-Plan Phase 7.2

## Context

Several people share one Mac and want their own library, watch history and
Continue Watching (Android `AccountSelectActivity`). Downloads, extensions
and app settings belong to the Mac, not the viewer.

## Decision

Each profile gets its own SwiftData store file
(`CloudStreamMac-Profile-<uuid>`); the default profile keeps the original
store, so upgrading users see no migration. `LibraryStore` holds two
contexts: the **profile context** (library, `EpisodeProgress`,
`TitlePlaybackPrefs`) and the **shared context** on the original store
(`DownloadRecord`). Switching profiles swaps the profile container and
bumps `version` (ADR-0009), so every screen re-reads.

Profile metadata (name, symbol, lock flag) is a small JSON array in
`UserDefaults`; at most 8 profiles, names ≤ 32 characters. Deleting a
profile deletes its store; the default profile cannot be deleted.

## Consequences

* No `profileID` column on every model and no risk of one profile's query
  leaking another's rows — isolation is by file.
* Backups export the active profile only.
* Cross-profile features (e.g. "who watched this") are out of reach without
  opening several stores; none are planned.
* Switching closes the player first so progress lands in the right store.
