# ADR-0009: Library observation via store version counter

**Status:** Accepted (2026-09-29) · **Decides:** UI-Remediation-Plan DP-2

## Context

`LibraryStore` was `@Observable`, but its only tracked stored property
(`container`) never changes; views fetched SwiftData manually inside
`body`, so mutations never invalidated anything. The tree papered over
this with `.id(revision)` identity nukes (destroying scroll position and
re-firing every poster load), a 5-second polling `Timer` in Downloads,
and `onAppear` state snapshots that went stale.

## Decision

Every committed `LibraryStore` mutation funnels through `save()`, which bumps
`private(set) var version: UInt64`. Screens read
`LibraryStore.shared.version` once per `body` — that read is an
observation registration, so any mutation invalidates exactly the views
that care. `@Query` adoption (modelContainer in the environment) remains
the north star and may replace this wholesale in a later workstream.

## Consequences

* Zero `.id()` refresh hacks, zero polling timers; scroll position and
  in-flight poster loads survive updates.
* Mutation protocol is uniform: forget to call `save()` and the UI
  (correctly) won't update — easy to review for.
* `@Observable` on the store is now doing real work.
* Cross-object granularity is coarse (any mutation re-runs the affected
  screen's query) — fine at library scale; `@Query` narrows it later.

## Audit remediation clarification (2026-10-01)

Library and shared-download writes own separate contexts with autosave disabled.
Read/save errors throw and roll back only the failing transaction; an unsuccessful
commit never publishes a version. Restore uses its own context and refreshes the
facade context only after its transaction commits. Periodic playback writes may
suppress display notifications; retained failed writes can be explicitly flushed
with notification enabled. A profile activation also publishes a version once
the replacement context and backfill are usable.

Views handle throwing reads through the named `readForDisplay` presentation
policy, which records errors after the current render pass. That unavailable
fallback is accompanied by a persistent recovery action and must not be treated
by services as successful empty data. Services and API actions handle the actual
throwing result directly.
