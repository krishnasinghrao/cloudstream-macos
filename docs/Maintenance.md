# Maintaining the macOS implementation

## Code boundaries

- `client/Sources/App/` owns launch, engine supervision, environment isolation
  and application shutdown. Completion callbacks for application shutdown run
  on the main actor.
- `client/Sources/Models/IPC/` contains JSON values by domain: engine health and
  errors, extensions, media, diagnostics, networking and WebView bridges. Keep
  these free of transport methods and UI imports. Preserve coding keys,
  optional-field defaults, identity generation and IPC version compatibility.
  The engine mirrors these domains in
  `engine/src/main/kotlin/com/lagradost/macos/models/`; moving a DTO must preserve
  its package, serializer, fields and defaults. `EngineDtos.kt` owns the daemon
  version used by the SBOM task.
- `client/Sources/Services/DaemonClient.swift` owns authenticated loopback
  requests, endpoint wrappers and NDJSON streams. All streams share completion,
  cancellation and line decoding. Only unsupported link-stream endpoints
  (404/405) fall back to batch extraction; authorization errors propagate.
- `client/Sources/Services/EngineDemand.swift` owns bridge-poll activity.
  Health and bridge polls are passive. Provider diagnostics retain their
  existing passive accounting.
- `client/Sources/Models/WatchType.swift` and `LibraryViewOptions.swift` contain
  library values used by preferences, persistence and UI. They do not require
  constructing a view or a SwiftData container.
- `client/Sources/Models/MediaPresentation.swift` owns media categories and
  display formatting without SwiftUI. `DesignSystem.swift` contains palette,
  button styling and loading UI; detail components live beside `MediaDetailView`.
- `client/Sources/Services/Contracts/LibraryPagePolicy.swift` owns page name
  normalization and entry identity shared by SwiftData and backup validation.
  Portable backup validation must not depend on constructing persistence models.
- `BoundedHTTPResourceLoader.swift`, `AsyncLimiter.swift` and
  `BoundedImageDecoder.swift` separate bounded network bodies, concurrency
  admission and artwork decoding. Keep their resource limits and cancellation
  contracts when changing any one component.
- `ViewerProfile` is a model value; `ProfileStore` owns observable profile
  operations and `ProfileLockSecurity` owns secure lock records.
  `ProviderCredentialStore` owns credentials and `ProviderConfiguration` owns
  coordination with the running engine. Both secure stores share
  `Services/Security/GenericPasswordKeychain.swift`, preserving their service
  and account keys, accessibility policy, and isolated in-memory test storage.
- `client/Sources/Services/Downloads/DownloadQueueItem.swift` contains queue
  state and transfer metrics. `DownloadService` owns execution, retries,
  finalization and durable queue reconciliation. Internal task handles,
  callbacks and lookup caches are excluded from Observation; UI state remains
  observable.
- `engine/src/main/kotlin/com/lagradost/macos/ArtifactDigest.kt` owns artifact
  SHA-256 identity. File hashing streams through a bounded buffer and both
  overloads emit lowercase hexadecimal. RepositoryService retains deprecated
  forwarding entry points because frozen audit probes call them.

## Compatibility constraints

The engine's `android.*`, `androidx.*` and `com.lagradost.cloudstream3.*` shims
are an extension ABI. An entry point can be necessary even when repository
source has no caller: downloaded bytecode, service discovery and reflection
also call them. Use the descriptor, fixture and worker tests before removing
or changing a shim. Preserve legacy durable keys and backup readers for the
same reason.

Engine dependencies are locked in `engine/gradle.lockfile`; media versions
are pinned in `scripts/build_media_stack.sh`. Review an upgrade against
[Dependency-Review.md](Dependency-Review.md), extension ABI tests, the runtime
module closure and the packaged application. A cleanup alone is not a reason
to change these versions or the minimum macOS release.

`client/project.yml` is the Xcode project source of truth. Regenerate with
`xcodegen generate --spec client/project.yml` from the repository root
when adding sources or changing settings. Build settings and generated project
files must agree. Xcode does not publish releases; the verified artifact
publisher is the only writer of `dist/`.
Both development builds and packaging regenerate the project before compiling.

## Releasing

The app version is `MARKETING_VERSION` in `client/project.yml` (shown in
About and written to `BUILD_INFO.json`); `CURRENT_PROJECT_VERSION` is the build
number and increases with every release. The engine reports its own component
version, `HealthDto.DAEMON_VERSION`, which feeds the engine SBOM and is
versioned independently.

To release:

1. Set `MARKETING_VERSION` (and raise `CURRENT_PROJECT_VERSION`) in
   `client/project.yml`, and merge it to `main` with a passing CI run.
2. Run the `ci` workflow once on `main` with **Build and package DMG artifact**
   ticked, and open the resulting DMG.
3. Tag that commit `vX.Y.Z` (or `vX.Y.Z-beta.N`, `-rc.N`, `-alpha.N` for a
   prerelease) and push the tag. The tag starts the same workflow, which
   publishes the GitHub Release with the DMG and its SHA-256.

The first job of a tag run fails when the tag does not match
`MARKETING_VERSION`, so a mismatched tag never builds or publishes. Never move
or reuse a published tag; if a release is wrong, delete it and ship the next
version.

Audit reports and source snapshots under `docs/archive/audit/` describe the recorded
revision. Preserve them; correct current reference documentation and add a new
record for changed decisions. Historical line numbers and paths can differ
from today's layout.

## Local checks

From the repository root:

```sh
make test-core       # isolated Swift extension and backup tests
make test-scripts    # build, staging, publication and smoke tooling
make test-library    # extension library tests and ABI check (api/library.api)
make test-engine     # engine, ABI, worker and repository tests
make test-client     # app-hosted XCTest and GUI tests (builds the engine jar its end-to-end tests launch)
make test-live-player # live libmpv rendering tests; generates /tmp fixtures (scripts/make_player_fixtures.sh)
shellcheck -S warning *.sh scripts/*.sh scripts/tests/*.sh
```

`make test` includes scripts, library, engine and client suites. The isolated
Swift harness is shared by the existing `test_extensions_core.sh` and
`test_backup_core.sh` entry points; update its source lists when introducing
new dependencies. It creates and removes its own temporary package and caches.

Full client checks need Xcode, staged native libraries/runtime and permission
to run compiler macro plugins. GUI tests need a logged-in desktop and testing
accessibility permission. Test hosts use isolated data and preferences; never
point a test at the production library or engine data root.

Fixture-dependent player tests and network-dependent tests explicitly skip
unless provisioned: `CS_MPV_ENGINE_TESTS=1` (via `make test-live-player`),
`CS_LARGE_LIBRARY_TESTS=1`, `CS_LIVE_REPO_TESTS=1` for the engine's live
repository syncs, the identity script below, and the player benchmarks
(`CS_MPV_BENCH`, `CS_YT_DIR`; `make test-player-bench` provisions them).
Live extension playback (`CS_LIVE_PLAYBACK_TESTS`) plays links exported to
`/tmp/cs_live_links.json`. `make test-client-full`
(`scripts/run_full_client_tests.sh`) provisions every tier: fixtures, the
local CDN, links from the `local-media` fixture extension in a sandboxed
worker (`LocalMediaLinksTest`), and the identity tool. It then runs every
client and UI test in one pass and fails on any skip. `make test` uses it.
To rerun part of it with the same provisioning, set `CS_FULL_ONLY_TESTING`
(space-separated `Target/Class[/test]`). When a live engine fails to start, the
failure includes its stderr, a thread dump and the tail of its `daemon.log`.
A pending macOS permission prompt blocks the process that triggered it, so
answer prompts during a long run. Pass
these to app-hosted tests as `TEST_RUNNER_<NAME>=1` on the `xcodebuild`
command line. A successful default suite does not certify these skipped
paths or macOS 15 behavior. For a built candidate, run
`scripts/smoke_launch.sh /absolute/path/CloudStream.app` to verify isolated engine
startup, prerequisites and bounded shutdown. Use
`scripts/tests/run_identity_migration_tests.sh /absolute/private/DerivedData`
for the independently compiled legacy-store and process-kill fixtures.

## Durability

The engine's atomic writes call `FileChannel.force` and then
`fcntl(F_FULLFSYNC)` through the JDK 17 foreign-function API
(`FullFsync.java`), so a committed write survives power loss, not only a
crash. The engine (and the workers, which share its AppCDS archive) run with
`--add-modules=jdk.incubator.foreign --enable-native-access=ALL-UNNAMED`; the
bundled runtime includes that module. If the call is unavailable the engine
logs `storage.fullfsync_unavailable` once and keeps the `fsync` guarantee.

## Player benchmarks

`make test-player-bench` (`scripts/run_player_benchmarks.sh`) generates
media into `/tmp/cs-bench`, serves it from two local CDN simulators (with and
without range support, `scripts/bench_cdn.py`) and runs
`PlayerStartupBenchmarkTests` against them, including the split-track
YouTube-style inputs. The servers are stopped on exit.
