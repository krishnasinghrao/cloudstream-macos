# ADR-0016: one sandboxed worker process per extension

**Status:** Accepted. 2026-09-30. Supersedes the process layout of ADR-0015.
**Plan:** Extensions-Remediation-Plan T5.2–T5.7 (D3); findings F18, F19, F30.

## Context

ADR-0015 confined the whole engine, so extension code could not read user
files. All extensions still shared one JVM: a blocking or memory-hungry
extension stalled or killed every other extension and the IPC server, and any
extension could read another's data and the engine's trust state.

A sandboxed macOS process cannot apply a further sandbox to its children
(`sandbox_apply: Operation not permitted`, verified), so per-extension profiles
require an unsandboxed parent.

## Decision

The engine becomes a **control plane** that runs no extension code: state,
catalogs, trust, receipts, routes, caches, solver bridge and built-in providers.
Each installed extension runs in its own **worker** JVM
(`daemon.jar --worker`), launched by the control plane through `sandbox-exec`
with a per-worker profile:

- read: the bundled runtime, the daemon jar, the one verified artifact file,
  system TLS/DNS configuration;
- read/write: only the worker home `workers/<installationId>/` (its translation
  cache, its `Context` storage, its temp directory);
- network: outbound only. No listening sockets; the worker talks to the control
  plane over its stdin/stdout pipes.

The control plane no longer runs inside `sandbox-exec` itself.

**Protocol.** Length-prefixed JSON frames (4-byte big-endian length, ≤ 16 MiB)
on the worker's stdin/stdout, multiplexed by request ID: `init`, `search`,
`home`, `details`, `links` (streamed `event` frames, then `result`), `extract`,
`verify`, `configure`, `cancel`, `shutdown`; worker-initiated `solve` for
anti-bot challenges. Worker `System.out` is redirected to stderr so extension
output cannot corrupt the protocol; stderr is logged, truncated and
rate-limited.

**The seam** is `ExtensionRuntime` (`WorkerExtensionRuntime`) and the provider
object: the control plane registers a `RemoteProvider` stub (a `MainAPI` with
the worker's metadata) so listing, IDs, enable/disable, caches, testers and
verifier jobs are unchanged. `ProviderExecutor` sends calls on stubs to the
worker, which runs the same executor code on the real provider and returns
DTOs. The control plane treats every DTO as untrusted: stream and subtitle URLs
are sanitized again, result counts are bounded and provider IDs are forced into
the extension's namespace.

**Deadlines and budgets.** Each call has a hard deadline; on expiry the control
plane sends `cancel`, waits a short grace period, then kills the worker, failing
only that extension's calls with a timeout. Workers run with a bounded heap
(`-Xmx`, exit on OOM), small stacks and a capped processor count. More than
three crashes or kills within an hour quarantine the extension (persisted,
audit-logged, user can Retry).

**Lifecycle.** Receipts cache each extension's provider descriptors, so
startup registers stubs without starting any JVM; a worker starts on its first
call and stops after 10 minutes idle. At most 8 workers run at once; the least
recently used idle worker is stopped to make room. Updates start the new
generation's worker; the old worker drains (≤ 30 s) and stops.

**Solver.** A worker's challenge is parked in the control plane's `SolveBridge`
like any other; the resulting cookies are returned only to that worker, which
caches them. Clearance cookies are never shared across extensions.

**Fallback.** When `sandbox-exec` is unavailable, workers run unsandboxed and
the UI warns; `ExtensionsRequireSandbox` turns that into a refusal. The
in-process runtime remains for tests and for `isolation = in-process`
development launches.

## Consequences

- A hung, crashing or memory-hungry extension affects only itself.
- Extensions cannot read each other's data or the engine's state and trust
  anchors.
- Extensions cannot call each other's code directly. Extractors registered by
  *other* extensions are reached through the control plane (see the 2026-10-01
  amendment); built-in library extractors and an extension's own extractors
  run locally as before.
- Each running worker costs a JVM (~60–120 MB); the running-worker cap bounds
  total memory. The first call to a cold extension pays JVM start and load time
  (≈1–2 s; the translation cache persists in the worker home).
- Extension data moves from `extension-data/<id>` to
  `workers/<id>/extension-data/<id>` (migrated once).

## Amendment — 2026-10-01: worker-initiated requests (runtime plan RT-10 to RT-15)

Isolation removed things Android gets from sharing one process. They are
restored as **requests a worker makes to the control plane**, never as direct
access between workers. Each uses a negative request ID on the existing
pipes, is answered asynchronously (the pipe reader never blocks on a worker),
and is bounded by the latest live call the control plane has outstanding to
that worker — a worker cannot start work that outlives every call that could
use its result.

| Request | Purpose | Bounds |
| --- | --- | --- |
| `solve` | Anti-bot challenge in the app's WebKit | ≤ 4 per worker; live-call deadline; cookies returned only to the requester |
| `extract` | A URL no local extractor claims is routed to the extension that registered a matching extractor (`ExtractorRouter`) | visited installations (the origin is always added, whatever the worker claims), 3 hops, caller's remaining budget sent as a duration, 3 candidates, 16 concurrent routes, 4 per worker; only loaded, non-retired generations; outputs sanitized and bounded |
| `resolve_media` | `WebViewResolver`: the app loads a page in WebKit and reports its requests (`MediaResolveBridge`) | ≤ 2 per worker, ≤ 8 pending; http(s) only; the control plane matches the extension's patterns with a per-match time budget; per-task ephemeral website data |

Control-plane requests added to the worker protocol: `prefs_get` / `prefs_set`
(an extension's own preferences, edited only for keys and types found in its
code) and extractor descriptors in the `init` result, persisted with the
receipt so stopped and extractor-only extensions are routable.

**Admission.** A pool-owned reservation covers preparation, process launch,
initialization, running and stopping. Startup is shared by callers and has an
independent deadline; cancelling one caller does not cancel that startup.
Preparation/launch failures release a slot; once a process exists, only its
confirmed-exit callback releases the slot. A stopped generation cannot clear a
replacement's reservation. Retirement cancels an unpublished startup and
prevents it from publishing or launching after preparation resumes.

Past the 8-worker soft cap, the least recently used idle worker is stopped and
admission waits for its confirmed exit. Callers awaiting startup are counted before obtaining a worker, and call
leases are acquired under the same pool lock as eviction. This closes the gap
between startup publication and sending the request. A provider waiting on routed extraction remains busy.
When all reservations are busy, starting or stopping, up to 4 overflow slots
are allowed. A further start waits up to 30 seconds for a worker to become
idle (it then replaces it) or to exit, and only then returns the typed,
retryable `capacity` failure; the bounded wait keeps nested extraction from
waiting forever on a pool full of waiting callers.
An idle-stop request does not instantly create a free process slot.

**Search admission.** Batch and progressive search both use `searchOne`'s
shared eight-permit operation boundary. Waiting does not occupy a permit;
cancellation releases an acquired permit in `finally`. Fast provider results
remain progressive. The streaming scope attaches to the Netty connection's
close future, cancelling unfinished work even when the text writer is idle;
the close listener is removed on completion. This is deliberately tied to the
daemon's existing Netty engine and must be revalidated on engine upgrades.

**Translation bound.** Translation runs in the worker's 256 MB heap. A method
whose size × register count exceeds a fixed bound is translated as a named
throwing stub (`TranslationGuard`) and reported on the extension's row, so one
oversized method — or a crafted DEX — cannot exhaust the worker.

**Residual.** A routed extractor runs with the *target* extension's network
identity and private data, not the caller's; the caller receives only
sanitized links and subtitles. Extensions still cannot read each other's files
or cookies.
