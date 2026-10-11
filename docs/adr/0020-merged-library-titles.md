# ADR-0020: one library title, several sources

**Status:** Accepted. 2026-10-08.
**Plan:** Compatibility-Fix-Plan U3 (decision: merge copies into one entry).

## Context

A library entry's identity is its provider and URL (`StoredMediaItem.id`,
ADR-0013/IPC v4). The same show saved from two providers is therefore two
entries, shown twice in every collection. Each entry's resume pointer and
per-episode progress are keyed by that provider's own episode data, which
another provider cannot interpret.

## Decision

A title keeps one row per source. A source that has been merged into another
row records it in `StoredMediaItem.mergedIntoID` (optional, SwiftData
lightweight migration). The row it points to is the title's **primary**.

- **Visibility.** Merging clears the secondary's own status and favourite
  (`watchTypeRaw = -1`, `isFavorite = false`), so every existing query,
  count, badge, shelf and Spotlight index shows only the primary without
  changing them. A secondary is also left out of Continue Watching.
- **Progress stays with its source.** A secondary keeps its resume pointer,
  per-episode progress, playback preferences and history rows; nothing is
  re-keyed or translated between providers.
- **The source last played fronts the title.** Recording progress on a
  secondary promotes it: it takes the title's status, favourite, rating,
  note and custom order, and the other sources point at it. Continue Watching
  then resumes exactly where the user stopped.
- **Edits go to the title.** Status, favourite, rating and note set from any
  source's details page apply to the primary.
- **Merging.** Automatic only on a strong match: the same normalised title,
  the same media type and the same known release year, among titles in the
  library. Anything weaker is the user's choice (Library ▸ select ▸ Merge).
  Conflicts resolve to: the most active status (Watching > On Hold >
  Plan to Watch > Completed > Dropped, by most recent change), favourite if
  any source is, the most recently changed rating, both notes.
- **Separating** a source clears its `mergedIntoID` and gives it a copy of
  the title's status, so it reappears where the title is.
- **Backups** carry `mergedIntoID`; older apps ignore it and show both
  sources as before. Android imports run the same automatic merge.

## Consequences

- No source's history is ever lost or reinterpreted; a merge is reversible.
- Two sources can still disagree on the next episode; the details page shows
  the title's sources so the user can open either.
- Automatic merging misses titles whose provider reports no year; those are
  merged by hand.
