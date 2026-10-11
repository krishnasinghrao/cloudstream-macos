# Dependency review of the engine (plan B02)

Reviewed 2 October 2026 against the inventory the build itself writes
(`./gradlew :engine:sbom` → `engine/build/sbom/daemon.cdx.json`, 99
components, locked by `engine/gradle.lockfile`). Rerun with:

```
./gradlew :engine:jar :engine:sbom
python3 scripts/dependency_report.py advisories engine/build/sbom/daemon.cdx.json --triage engine/advisory-triage.json
python3 scripts/dependency_report.py licenses engine/build/sbom/daemon.cdx.json
```

The advisory lookup sends package names and versions to OSV (osv.dev) and
nothing else. CI runs both; a new advisory without a recorded decision fails
the daemon job, and an unreachable service is reported as such, never as a
clean result.

## Advisories

The first lookup reported advisories against nine packed components.

| Component | Was | Now | Result |
|---|---|---|---|
| Netty (HTTP codec, handler, HTTP/2, compression, native transports) | 4.2.13.Final | 4.2.18.Final | All reported advisories fixed. Daemon-local BOM; Ktor stays 3.5.0. The engine serves HTTP/1.1 on loopback without TLS, HTTP/2, SPDY, WebSockets, CORS or compression, so most of them were not reachable; the HTTP decoder ones were, by any local process before authentication |
| jackson-databind, jackson-core, jackson-annotations | 2.13.1 | 2.13.5 | Fixes the three 2022 denial-of-service advisories fixed inside the 2.13 line. `jackson-module-kotlin` stays 2.13.1 (strict in the shared catalog) |
| jackson-databind, jackson-core | — | 2.13.5 | **Mitigated: 10 advisories** are fixed only in 2.15/2.18+. Triaged as `mitigated-by-isolation` (SEC-09): isolated worker sandboxes, call deadlines, memory limits, and non-reliance by the daemon control plane prevent denial-of-service escalation. |
| jackson-databind | — | 2.13.5 | 3 advisories not applicable: they concern polymorphic type validators / default typing, which engine code does not enable (checked by search) |
| jsoup | 1.22.2 | 1.22.2 | Not applicable: the advisory is in jsoup's `Cleaner`; neither the engine nor the shared library calls `Jsoup.clean`, `Cleaner` or `Safelist`. Fixed in 1.23.1, which belongs to the shared catalog |
| jsoup | 1.22.2 | 1.22.2 | **Mitigated** (GHSA-65r4-943x-97jj, reviewed 2026-10-09): memory exhaustion in jsoup's XML tree builder. The engine does not use jsoup and the shared library never selects the XML parser; only an extension parsing hostile XML itself can reach it, inside a memory-capped sandboxed worker. Fixed in 1.23.2, which belongs to the shared catalog |

After these changes the full daemon suite passed (337 tests, 3 skipped).

### Jackson Triage Decision (SEC-09: Mitigated by Isolation)

The Android app pins Jackson 2.13 because later versions do not run on its
oldest supported Android versions, and community extensions are compiled
against that version. The engine therefore stays on 2.13 so that extension
bytecode keeps linking. The ten remaining advisories are stack or resource
exhaustion on hostile JSON, eager DNS resolution or path handling when
deserializing particular types, and one about ignored properties. In this
product that input is what a provider's own site returns to its own
extension.

Under the SEC-09 architectural audit, these advisories are triaged as
`mitigated-by-isolation`:
1. The daemon IPC control plane does not use Jackson; it deserializes all
   client requests via `kotlinx.serialization.json`.
2. Extension parsing runs in an isolated, sandboxed child worker process
   (`com.lagradost.macos.MainKt --worker`).
3. Workers run under strict memory limits (`-Xmx256m`, `-Xss512k`) and call
   deadlines (`timeoutMs`). Any recursion crash fails only that specific
   call and is quarantined without impacting the daemon or native UI.

## Licences

The product is GPL-3.0. Of 99 components, 91 declare a permissive licence, 3
a weak-copyleft one (Rhino: MPL-2.0; juniversalchardet: MPL-1.1 / GPL-3.0 /
LGPL-3.0), and 3 are GPL-3.0 and compatible (the in-repository engine library,
NewPipeExtractor, NiceHttp). Two need a person:

| Component | Finding |
|---|---|
| `me.xdrop:fuzzywuzzy:1.4.0` | Its POM says "GPL 2" without "or later". GPL-2.0-only is not compatible with GPL-3.0. The Android app ships the same library; whether upstream permits "or later" has to be confirmed from its sources, or the library replaced |
| `com.github.TeamNewPipe:nanojson` (JitPack build) | Publishes no licence in its POM or jar. The upstream repository's licence has to be confirmed |

`org.json` (8 October 2026): NiceHttp's `org.json:json` (JSON-java,
"Public Domain") is excluded from the engine. Extensions are compiled
against Android's own `org.json`, which behaves differently (JSON-java throws
from `getString` on numbers, returns `""` from `optString` on null and loses
key order). The engine ships AOSP libcore's six `org.json` classes as source
(`engine/src/main/java/org/json`, Apache-2.0, commit `de876a01b29`), with only
Android-internal annotations removed; Apache-2.0 is GPL-3.0 compatible.
NiceHttp itself only calls `toString()` on `JSONObject`/`JSONArray`.

The media stack links FFmpeg against the libxml2 macOS ships
(`/usr/lib/libxml2.2.dylib`, MIT) for the DASH demuxer; no copy is bundled,
so it receives the operating system's security updates.

Licences are read from each module's own POM or its parents in the Gradle
cache; nothing is inferred. ffmpeg and libmpv record the licence and
configuration of the actual build in `media-provenance.json`
(`build_media_stack.sh`); no media stack has been built on the development
Mac, so that file has not been reviewed.

## Reproducibility

Measured on the development Mac (Gradle 9.4.1, Kotlin 2.3.0, Homebrew OpenJDK
17.0.20.1):

- Two clean builds of the same sources produce a byte-identical `daemon.jar`
  (19,493 entries) and SBOM.
- A jar from an incremental compile differs from a clean one in 20 class
  files (same entries, order and timestamps): Kotlin's incremental compiler
  emits equivalent but not identical bytecode. `package_app.sh --distribution`
  therefore runs `:engine:clean` first; a fresh CI checkout is clean by
  construction.
- A version that drifts from the lock fails the build (`gradle.lockfile`).

Not measured: the jlink runtime and the native media stack (not built here),
and builds on another machine or JDK vendor.
