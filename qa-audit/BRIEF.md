# Adversarial QA Audit — Shared Brief

Repo: CloudStream for macOS (native Swift 6 client + headless Kotlin/JVM engine + Kotlin extension library).
Goal: find real defects — crashes, races, leaks, data corruption, hangs, silent failures, wrong results,
security/contract violations, and platform-specific breakage — with enough evidence that a maintainer can
confirm and fix each one. **Do not change any code.**

## Hard rules

1. **Read-only on source.** You may not edit, move, create, or delete anything outside `qa-audit/`.
   Your only writable file is your own report (`qa-audit/<NN>-<area>.md`) plus scratch files under
   `qa-audit/scratch/` (prefix them with your area name).
2. **Never run anything destructive or stateful.** Do NOT run: `make build`, `make package`, `make clean`,
   `scripts/clean.sh`, `scripts/package_app.sh`, `scripts/uninstall*`, `DeleteCloudStream`, the updater,
   the app itself, the daemon, or anything that writes to `~/.cloudstream-macos`, `~/Library`, dist/, or
   user downloads. Do not `git commit`, `git checkout`, `git stash`, or revert.
3. **Tests/builds are optional and must be time-boxed.** Do not run `make test` (shared DerivedData /
   long). If you want a compile or unit check, use a *unique* `-derivedDataPath` and prefer targeted
   `-only-testing:`; Gradle targeted tests are fine but note Gradle daemons may serialize. Never edit a
   test to make it pass. Most value comes from tracing code, not from running the suite.
4. **Do not report style nits, naming, comment typos, or "could add tests"** unless they cause a defect.
5. **No false positives.** Before writing a finding, re-read the surrounding code and the docs that
   define intended behavior. If the code already guards the case, drop it or move it to
   "Reviewed / non-issues". Label residual uncertainty honestly (Confidence: high/medium/low).

## Context to read first (cheap, prevents bogus findings)

- `docs/Architecture.md`, `docs/Rules.md`, `docs/Security.md`, `docs/ipc-api.md`, `docs/adr/`.
- `docs/Remaining-Work.md` "Known limits" and `CHANGELOG.md` "Fixed" — those are *known*, not new.
- Recent commits (`git log --oneline -20`) and the tests for your files: tests encode intended behavior.

## What counts as a bug (aim for these)

- Race conditions, actor reentrancy/ordering, unsynchronized shared mutable state, lost/duplicated events.
- Deadlocks: `DispatchQueue.sync` from its own queue, lock ordering, semaphore waits on the main thread,
  `withCheckedContinuation` never resumed / resumed twice.
- Resource leaks: file descriptors, `FileHandle`, sockets, processes, `Task` trees, observers, timers,
  Metal/`IOSurface`/C callbacks, mpv handles, URLSession sessions, keychain items.
- Data corruption / loss: non-atomic writes, partial writes, WAL/backup mistakes, migration re-entry,
  unordered merge, off-by-one in page/window slicing, truncation, encoding errors.
- Null/undefined/force-unwrap paths, unchecked array indices and ranges, integer overflow/underflow,
  division by zero, NaN/Inf propagation into UI or math, empty-collection edges.
- Broken error handling: errors swallowed, wrong error mapping, retry storms, infinite retry, retry budget
  bypass, cancellation treated as failure (or vice versa).
- Timing: timeouts vs. long polls, clock jumps (monotonic vs. wall clock), debounce/throttle misuse,
  races between cancellation and completion, task resurrection after `deinit`.
- Performance/pathological behavior: unbounded caches/queues/collections, O(n²) on large libraries,
  blocking I/O on MainActor, main-thread SwiftData fetches, per-frame allocations.
- UI/UX failures reachable from unusual inputs/sequences (double-click, rapid tab switching, window close
  mid-operation, profile switch mid-download, engine restart mid-playback).
- Platform/env: macOS 15 vs 26 APIs, Apple Silicon assumptions, sandbox/hardened-runtime entitlements,
  case-insensitive filesystems, paths with spaces/non-ASCII, locale/number/date formatting, JVM 17 vs 21.
- Security boundary violations of the project's own invariants (loopback-only, bearer auth, URL
  sanitization, plugin hash verification, filesystem confinement).

## How to work

1. Inventory your scope; read the largest/riskiest files end-to-end, then trace call paths into and out of
   them (grep for callers/callees). Do not rely solely on pattern grep.
2. For each candidate, construct a concrete trigger: inputs, user sequence, or interleaving; follow it
   line-by-line through the real code (including error paths and cancellation). Note what actually happens.
3. Check whether an existing guard, test, or documented limitation already covers it.
4. Rank by real-world impact, not by weirdness.
5. Write findings as you go; keep the report self-contained.

## Report format (`qa-audit/<NN>-<area>.md`)

Top: one-paragraph scope (files reviewed, what you traced, what you ran).

Then findings in descending severity, each as:

```
### F-<area>-<n>: <one-line title>
- **Severity**: Critical | High | Medium | Low
- **Confidence**: high | medium | low
- **Type**: race | leak | corruption | crash | hang | logic | security | ux | perf | platform
- **Location**: `path:line` (and any other implicated lines)
- **Trigger**: concrete inputs / user sequence / interleaving
- **Trace**: the actual execution path and what goes wrong, step by step
- **Impact**: observable consequence for a user/maintainer
- **Evidence**: code quotes or test observations
- **Recommended fix**: specific, minimal, and where to apply it
- **Guards considered**: existing checks/tests/docs that might already cover it, and why they don't
```

End with: `## Reviewed / non-issues` (candidates you cleared and why), `## Areas not covered` (honest gaps).

Aim for 8–20 solid findings per area. Quality and evidence beat volume.

## Finish

- `send_message` to `lead` with: report path, count by severity, and the top 5 findings as
  `severity | title | file:line | 1-line impact`. Keep it under ~40 lines.
- If you find something Critical, message the Lead immediately rather than waiting until the end.
