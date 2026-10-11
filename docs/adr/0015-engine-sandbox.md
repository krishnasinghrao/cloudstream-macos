# ADR-0015: extension engine confinement via a helper sandbox profile

**Status:** Superseded by ADR-0016 (per-extension sandboxed workers). 2026-09-30.
**Plan:** Extensions-Remediation-Plan P5 (S5.0, T5.1), finding F18.

## Context

Extension code is third-party bytecode executed inside the engine JVM. The
plan's first choice (T5.1) was to adopt App Sandbox for the whole app and let
the JVM inherit it, moving the data root into the container. Spike S5.0 was
meant to decide between that and the plan's stated fallback, "a helper tool
with its own sandbox profile".

App Sandbox for the whole app was **not spiked**. It would also confine the
native client, which reads and writes user-chosen download folders, runs
ffmpeg and libmpv, and stores its library outside a container; each of those
needs security-scoped bookmarks or entitlements and a data migration. None of
that protects user files from extensions any better than confining the engine
alone, which is the process that runs extension code.

## Decision

Launch the engine JVM through `sandbox-exec` with a deny-by-default SBPL
profile embedded in the signed app binary (`EngineSandbox.profile`, passed
with `-p`, so it cannot be edited on disk). Inside it the engine can:

- read only its bundled runtime and daemon jar directory, plus the system
  configuration needed for TLS, DNS and time zones;
- read and write only its data root and its temp directory;
- connect outbound, and bind/accept only on loopback.

All profile parameters are resolved with `realpath` before launch, because
sandbox rules match resolved paths (`/private/var`, not `/var`).

When `sandbox-exec` is missing or the sandboxed engine fails to start, the
supervisor restarts it unsandboxed and shows a persistent warning; the managed
preference `ExtensionsRequireSandbox` turns that fallback into a refusal.

## Consequences

- User documents, SSH keys, keychains, browser profiles and other apps' data
  are unreadable by extension code (`EngineSandboxTests`).
- `sandbox-exec` is deprecated by Apple. It is present on all supported macOS
  versions; its absence is detected and surfaced. If it is removed, the
  replacement is App Sandbox for a separate engine helper (not the whole app).
- Extensions still share one process: a hostile extension can interfere with
  other extensions and read their in-memory data. Per-extension workers
  (T5.2–T5.7) remain the plan's path to cross-extension isolation, hard
  deadlines and memory budgets.
- The whole-app App Sandbox (T5.1 as written) remains unevaluated; it is no
  longer on the critical path for protecting user files.
- Notarization with the helper profile is unaffected (no new entitlements).
