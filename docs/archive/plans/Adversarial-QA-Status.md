# Adversarial QA audit status (4 October 2026)

Tracks the 17 defects in the [adversarial QA audit](../audit/macos-adversarial-qa-audit-2026-10-04.md).
As with the [engineering audit](Audit-Remediation-Status.md), a defect is not
closed by an edit: each row stays open until the packaged app has been checked
on a supported machine. "Fixed locally" means the code is changed and the test
suites below pass on this Mac.

Suites on 4 October 2026 (Asia/Kolkata), with every fix below applied: engine
343 tests, 0 failures, 3 live tests skipped; app unit tests 503, 0 failures,
35 gated tests skipped.

| Defect | Severity | Status | Fix | Evidence / remaining gate |
| --- | --- | --- | --- | --- |
| CRIT-01 | Critical | Fixed locally | `SIGPIPE` is ignored from the app delegate's and app's initializers and again in `setupSignalHandlers`, so a write to an exited engine's pipe returns `EPIPE` instead of killing the app. | No dedicated test (needs a process that exits mid-write). Remaining: kill the engine while the app writes to it, in the packaged app. |
| CRIT-02 | Critical | Fixed locally | Relay idle lifetime 15 min (was 6 h). A full relay evicts the least recently used session that has been idle for at least 60 s. A session with an open stream is never expired or evicted; its idle time starts when its last stream ends. The upstream response is closed if the reply fails. | `MediaRelayTest`: `sessions are bounded and expire when idle`, `a session with an open stream neither expires nor is evicted`. Remaining: long split-audio playback with a pause and a seek, in the packaged app. |
| CRIT-03 | Critical | Fixed locally | `SolveInterceptor` does not park plain-HTTP challenges (the solver needs an HTTPS origin); the challenge page goes back to the provider. | Engine suite. Remaining: a live plain-HTTP challenge. |
| HIGH-01 | High | Fixed locally | Navigation is cleared before the store switch, and the detail view's note save is bound to the profile store the draft was loaded from (`LibraryStore.owns`). Clearing navigation alone did not hold: the view's `onDisappear` save runs after `select()` has switched stores. | No dedicated UI test. Remaining: edit a note, switch profile, and check that neither profile gains the other's note. |
| HIGH-02 | High | Fixed locally | Deep links, Spotlight results and Handoff are ignored while locked. Leaving a locked profile needs authentication. A locked profile is never indexed in Spotlight, and its entries are removed. | Remaining: interactive checks while locked (deep link, Spotlight, Handoff, profile menu). |
| HIGH-03 | High | Fixed locally | `/links/stream` runs under `withConnectionCancellation`, so a disconnected client cancels the worker scrape. Write failures after a disconnect are ignored instead of being reported as provider failures. | Engine suite. Remaining: cancel a link search mid-stream in the packaged app. |
| HIGH-04 | High | Fixed locally | A `Last-Modified` date is accepted as a resume validator when the response has no `Date`, or a `Date` no earlier than it; the 60-second separation is no longer required. | App suite. Trade-off: a file replaced within the same second as its `Last-Modified` date could resume onto different bytes. Remaining: resume a large download from a server without an ETag. |
| HIGH-05 | High | Fixed locally | The worker's sandbox profile allows reading the shared class-data archive the engine was started with. | Engine suite (sandboxed workers). Remaining: the packaged build with its archive. |
| HIGH-06 | High | Fixed locally | A failed episode check still records `lastEpisodeCheck`, so a dead title moves to the back of the queue. | App suite. Remaining: none beyond the packaged gate. |
| HIGH-07 | High | Fixed locally | Backups fall back to a move when the filesystem refuses hard links (exFAT, SMB), still refusing to replace an existing file. | No dedicated test (needs an exFAT or SMB volume). Remaining: a backup to such a volume. |
| MED-01 | Medium | Fixed locally | Now Playing skips artwork whose image has a zero dimension. | No dedicated test. |
| MED-02 | Medium | Fixed locally | Clearance cookie headers ignore empty parts (a trailing `;`) but still need at least one valid pair. | `ChallengePathTest`: `clearance cookie headers tolerate empty parts but need one valid pair`. |
| MED-03 | Medium | Fixed locally | VLC and QuickTime are not offered for multi-part (EDL) links. | App suite. |
| MED-04 | Medium | Fixed locally | A waiter cancelled while queued leaves the queue and throws `CancellationError` without running, so cancelled image work neither blocks others nor runs outside the limit. | `BoundedResourceTests` limiter tests. Remaining: fast scrolling through a large library, with memory measured. |
| MED-05 | Medium | Fixed locally | A failed frame render still reports the swap to libmpv. | No dedicated test (needs a failing render). |
| MED-06 | Medium | Fixed locally | Plain-HTTP challenges are never parked (CRIT-03); the app also skips pending targets it cannot solve and logs only their host. | Engine and app suites. |
| MED-07 | Medium | Fixed locally | Safety backups are pruned to the newest 5 per profile. | No dedicated test. |

## Review follow-ups (4 October 2026)

A review of the uncommitted changes found problems in the first pass; all are
fixed above or below:

- The engine's app-lock state (SEC-08, from the [remediation plan](Remediation-Plan.md))
  blocked downloads and cleared relay sessions on lock. Downloads now keep
  `/links`, `/links/verify/*` and the relay routes while locked; other routes
  answer 423.
- Lock and unlock requests to the engine are sent in order, each with the
  state current at send time, with two retries.
- A challenge cancelled by the lock now ends as unsolved instead of throwing
  into OkHttp.
- External players are not offered streams that need `Cookie` or
  `Authorization` headers, which are never placed on a command line.

## Not in this change

- `engine/advisory-triage.json` and `Dependency-Review.md` re-triage the ten
  Jackson advisories as `mitigated-by-isolation`. That is the owner's open
  decision, so those edits are left uncommitted.
- `client/Resources/media-manifest.json` is local build output with absolute
  paths and is not committed.
- The entitlements comment and the Xcode build-phase setting
  (`basedOnDependencyAnalysis: false`, `alwaysOutOfDate`) are unrelated to this
  audit and stay uncommitted for the owner to review.
