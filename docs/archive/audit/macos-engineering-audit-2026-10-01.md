# CloudStream macOS engineering audit

**Reviewed 1 October 2026. No application, test, build-script, or project changes were made.** This report evaluates the current working tree at commit `3389a7b095accb9eb2a673605ddafc402b0cef09`, including the pre-existing changes in `project.pbxproj` and `scripts/clean.sh`. Generated test output and audit probes are separate from source changes.

## Assessment

The codebase has a credible architecture and significant engineering investment: native SwiftUI/AppKit presentation, an authenticated loopback engine, extension workers, durable extension provenance, bounded parsers, atomic daemon state publication, and real regression tests. The extension trust implementation is substantially stronger than a simple downloader/class loader. Those strengths do not make the complete application release-ready. The most consequential defects concern data integrity, isolation boundaries, concurrency during teardown, recovery, and whether CI actually verifies the shipped product.

The highest priorities are the reproducible corrupted-download completion (A02), invalid-backup crash (A10), native-player input boundary (A01), player teardown races (A03), lock bypass (A04), incomplete provider identity propagation (A05), silent persistence failures (A06), and build/CI defects (A07–A09). There is no demonstrated P0 remote-code-execution finding in this audit. A01 establishes an unsafe handoff to a privileged process; it does not establish an end-to-end exfiltration exploit.

**Findings:** 53 total — 11 P1, 36 P2, 6 P3. The design/debt observations below are separate from this count.

**Priorities:** P1 = address before release because ordinary use can lose data/crash, an intended security boundary is bypassed, or build verification is invalid. P2 = important reliability, correctness, capacity, privacy, or distribution issue; schedule after P1 unless it blocks your immediate workflow. P3 = smaller correctness or engineering-quality issue. These are remediation priorities, not CVSS scores.

**Evidence labels:** Reproduced = exercised with unchanged relevant production source or actual test/runtime tooling. Code path = directly evidenced in source, with the stated trigger; not exercised end-to-end in the app. Engineering risk = a demonstrated design/build gap whose production manifestation depends on deployment or workload.

## Scope and method

The audit covered all production areas under `macos/`: 67 Swift source files (22,586 lines), 101 Kotlin production files (12,557 lines), the C/libmpv bridge and vendored headers, Xcode/XcodeGen settings, Gradle dependencies, build/package/runtime/media scripts, tests, API/security/architecture documentation, and the associated GitHub workflow. The review traced entry points and state across the application, daemon, extension worker, WebKit bridge, player, downloader, SwiftData, profiles, backups, and system integrations. Detailed tracing focused on ownership, cancellation, failure handling, persistence boundaries, and recovery. This is an engineering audit, not a proof of every possible behavior or a dependency vulnerability certification.

Existing audit documents were treated as background and their applicable claims checked against current source. Their conclusions were not assumed to remain current. The intended macOS 15 minimum and arm64-only product are accepted constraints; absence of newer macOS visual APIs is not classified as a defect.

A source inventory with SHA-256 digests accompanies this report in [source-inventory.json](~/.audit-artifacts/visualizations/2026/10/01/01a0f5b2-6de7-7a41-bc8b-e9cb1bc54535/macos-audit/source-inventory.json). All finding references below point to the reviewed working-tree files, not an older audit snapshot.

## Architecture and data flow

| Area | Current responsibility and flow | Assessment |
| --- | --- | --- |
| Application composition | `CloudStreamMacApp`/`AppDelegate` → singleton `AppState`, `DaemonSupervisor`, `LibraryStore`, player/download services | Practical for one window, but window lifecycle and application lifecycle are mixed; async ownership is insufficiently explicit. |
| Engine transport | Swift `DaemonClient` actor → authenticated loopback Ktor routes → executor/runtime | Actor transport and typed DTOs are useful. Health, endpoint publication, provider restoration, and readiness are represented by separate, racing signals. |
| Extensions | Repository transport/trust → installation proof/artifact/state → translated extension → isolated worker → bounded IPC | Strong provenance and parser controls. Admission, blocking writes, and privileged consumers of worker output need further hardening. |
| Search/discovery | Swift tasks → streaming/batch search or homepage API → provider workers → UI collections | Cancellation exists, but bounds and generations are inconsistent between routes and pagination. |
| Playback | Details/episode → progressively resolved links → player state machine → libmpv events/render queue → Metal/AppKit window | Sophisticated playback support. Unsafe shared state and missing failure/identity contracts remain in the bridge. |
| Downloads | Persistent queue → link resolution → direct HTTP or ffmpeg → rename/sidecars → record/library update | Good policy extraction, structured failures, cancellation and progress ownership. Resume and completion invariants are incomplete. |
| User data | Active-profile SwiftData library/history/playback stores; shared download records; UserDefaults preferences; Keychain credentials | Intended scope separation is clear. Error propagation, stable identity, cross-profile async work, and backup semantics do not consistently honor it. |
| Distribution | Gradle fat jar + jlink image + native media stack → Xcode app → nested signing → DMG/notarization | Too many mutable staging/publishing paths. Clean-checkout CI and packaged-runtime verification are incomplete. |

## P1 findings

### A01 — Worker-provided URLs are not restricted before native playback

**Evidence — code path:** [WorkerRuntime.kt:353](macos/daemon/src/main/kotlin/com/lagradost/macos/worker/WorkerRuntime.kt:353) (`RemoteProvider.cleanLink`), [Sanitizer.kt:80](macos/daemon/src/main/kotlin/com/lagradost/macos/Sanitizer.kt:80) (`sanitizeWith`), [PlayerViewModel.swift:597](macos/client/Sources/ViewModels/PlayerViewModel.swift:597) (`loadPlan`), [MetalVideoView.swift:348](macos/client/Sources/UI/Player/MetalVideoView.swift:348) (`load`).

The “untrusted output” cleanup strips tracking parameters but returns every non-HTTP(S) string unchanged. Video, playlist segments, audio, and subtitle URLs then reach libmpv in the unsandboxed client. A sandboxed extension can supply a `file://` URL or another mpv-supported protocol rather than an ordinary remote stream, asking the client to open resources the worker itself cannot read. Local playback is already a distinct, legitimate path and can remain supported through explicit provenance.

Headers also pass through `splitHeaders` without the CR/LF and header-name policy applied by the downloader. External-player handoffs share the same URL trust issue; passing an argv array prevents shell expansion but does not establish a URL/protocol boundary. This is a concrete isolation-boundary gap, not a demonstrated remote exfiltration exploit. mpv's protocol-capable input behavior is documented in the [mpv manual](https://mpv.io/manual/stable/).

**Recommendation:** Validate every remotely supplied media resource at the native consumer boundary, including nested playlist/audio/subtitle resources and redirects. Distinguish authorized local files from provider output. Centralize remote URL and header policy; generate EDL only from validated component URLs.

### A02 — A mismatched HTTP 206 response is saved as a complete video

**Evidence — reproduced:** [DirectFileJob.swift:225](macos/client/Sources/Services/Downloads/DirectFileJob.swift:225) (`didReceive response`), [DirectFileJob.swift:343](macos/client/Sources/Services/Downloads/DirectFileJob.swift:343) (`restartFromZero`).

When a resume response has the wrong range start or total, the downloader truncates the existing partial file and accepts the **same partial response body** as a fresh full download. It also treats unsolicited 206 responses as full bodies. The new expected length becomes the partial response's `Content-Length`, so normal completion checks accept the fragment.

An isolated probe compiled the unchanged `DirectFileJob` and requested `Range: bytes=524288-`. The fixture returned `Content-Range: bytes 1048576-2097151/2097152`, with a 1 MiB tail. The result was `completed(bytes: 1048576)`; the original prefix was gone and the 2 MiB file was incomplete. [Probe log](~/.audit-artifacts/visualizations/2026/10/01/01a0f5b2-6de7-7a41-bc8b-e9cb1bc54535/macos-audit/range-probe.log) and [probe harness](~/.audit-artifacts/visualizations/2026/10/01/01a0f5b2-6de7-7a41-bc8b-e9cb1bc54535/macos-audit/range_probe.py).

**Recommendation:** Reject an invalid partial response and issue a new request without `Range`, or fail/retry explicitly. Never reinterpret a nonzero-range body as a complete entity. Validate start/end/total/body length and both requested and unsolicited 206 cases.

### A03 — Native-player teardown contains two unsynchronized shared-state races

**Evidence — code path:** [MetalVideoView.swift:701](macos/client/Sources/UI/Player/MetalVideoView.swift:701) (`renderFrame`), [MetalVideoView.swift:838](macos/client/Sources/UI/Player/MetalVideoView.swift:838) (`makePixelBuffer`), [MetalVideoView.swift:1062](macos/client/Sources/UI/Player/MetalVideoView.swift:1062) (`performShutdown`), [MetalVideoView.swift:1393](macos/client/Sources/UI/Player/MetalVideoView.swift:1393) (`MpvCore.stop`), [MetalVideoView.swift:1519](macos/client/Sources/UI/Player/MetalVideoView.swift:1519) (`MpvEventSink`).

`renderFrame` releases `renderLock` before `makePixelBuffer` reads/replaces the `pixelBufferPool`. `performShutdown` clears that pool under the lock on a different calling thread, before ordered queue cleanup. The reader does not take that lock, so the lock on the writer does not provide synchronization.

Separately, `MpvCore.stop` clears the sink's mutable closure fields on the drain queue while previously enqueued `deliver` closures read them on the main queue. The sink's `@unchecked Sendable` comment explicitly describes this split, but there is no synchronization or main-actor ownership for those fields. Both races involve Swift reference lifetime/state and are eligible for crashes or undefined behavior during close/replacement, rather than merely harmless duplicate UI updates.

**Recommendation:** Keep render-only mutable resources on the render queue and release them only in its ordered teardown. Make sink handlers main-actor owned and clear them there in FIFO order; use an explicit stopped/generation gate for queued events. Add a sanitizer-backed close/reopen stress scenario.

### A04 — File-menu backup commands bypass the application lock

**Evidence — code path:** [CloudStreamMacApp.swift:151](macos/client/Sources/App/CloudStreamMacApp.swift:151) (Import/Export commands), [BackupService.swift:193](macos/client/Sources/Services/Backup/BackupService.swift:193) (`exportInteractively`), [BackupService.swift:210](macos/client/Sources/Services/Backup/BackupService.swift:210) (`importInteractively`).

The root/settings surfaces and deep-link dispatch account for the lock, but the global File-menu commands do not disable or authenticate backup operations. While a profile is locked, the commands can expose its library, notes, history and preferences through export, or open a destructive restore flow. The lock being non-encrypting is explicitly disclosed; bypassing its in-app access gate is a separate issue.

**Recommendation:** Guard sensitive service entry points with the same lock/authentication policy and reflect it in command enabled state. Test keyboard shortcuts and menu invocation while locked, including locking after a panel has opened.

### A05 — Stable provider identity is lost in the library and backup pipeline

**Evidence — code path:** [LibraryStore.swift:235](macos/client/Sources/Services/LibraryStore.swift:235) (`upsertLibraryEntry`), [LibraryStore.swift:316](macos/client/Sources/Services/LibraryStore.swift:316) (`recordProgress`), [LibraryStore.swift:373](macos/client/Sources/Services/LibraryStore.swift:373) and [LibraryStore.swift:397](macos/client/Sources/Services/LibraryStore.swift:397) (`detailsPreview` overloads), [LibraryStore.swift:784](macos/client/Sources/Services/LibraryStore.swift:784) (`itemID`), [BackupDocument.swift:27](macos/client/Sources/Services/Backup/BackupDocument.swift:27) (`Item`), [LibraryStore.swift:1062](macos/client/Sources/Services/LibraryStore.swift:1062) (restore construction).

The engine disambiguates providers with stable installation/provider IDs, but persisted item keys still use display name plus URL. Two installations exposing the same provider name and content URL collide in the library/history. Both preview DTO constructors omit the available provider ID, so filing a search/browse item into the library can lose identity even without a backup. The backup format has no provider-ID field and restore does not restore it. Later resume/details calls fall back to names, which the daemon deliberately accepts only when unambiguous.

**Recommendation:** Carry provider ID through every DTO conversion, persisted key, system activity, download linkage and backup record. Provide a migration for legacy name-based keys and an explicit ambiguous/unavailable-provider recovery flow; do not silently merge installations.

### A06 — SwiftData failures are converted into empty data or apparently successful mutations

**Evidence — code path:** [LibraryStore.swift:29](macos/client/Sources/Services/LibraryStore.swift:29) (container initialization), [LibraryStore.swift:218](macos/client/Sources/Services/LibraryStore.swift:218) (`save`), [LibraryStore.swift:1023](macos/client/Sources/Services/LibraryStore.swift:1023) (`importSnapshot`).

If the container cannot open, the store logs and keeps `container = nil`; many operations then silently return. Save failures are logged without rollback or propagation, while callers can continue as though a favorite, progress update, deletion or download record was persisted. Fetch failures throughout the store become `[]`/`nil`, conflating database failure with a genuinely empty library.

This also weakens backup guarantees: an unreadable store can produce an empty safety snapshot, and replace/merge restore suppresses fetch errors used to decide what exists or must be deleted. A successful final save alone cannot establish that the intended replacement occurred. `importSnapshot` uses the shared main context, so a failed restore's rollback can discard unrelated pending changes.

**Recommendation:** Expose store health, distinguish empty results from failed fetches, and return mutation failures to callers. Use a dedicated transaction context for restore; validate its reads before mutation. Treat snapshot-read failure as a failed safety backup, and persist downloads with an explicit result.

### A07 — The bundled JRE cannot support APIs used by the Android shims, and CI rejects those references

**Evidence — reproduced runtime inventory/code path:** [bundle_runtime.sh:24](macos/scripts/bundle_runtime.sh:24) (`REQUIRED_MODULES`), [Handler.kt:122](macos/daemon/src/main/kotlin/android/os/Handler.kt:122) (`SystemClock.currentThreadTimeMillis`), [ActivityManager.kt:18](macos/daemon/src/main/kotlin/android/app/ActivityManager.kt:18) (`getMemoryInfo`), [macos.yml:35](upstream/.github/workflows/macos.yml:35) (module gate).

The jlink list omits `java.management` and `jdk.management`. The current staged runtime's actual `--list-modules` output confirms both are absent ([module inventory](~/.audit-artifacts/visualizations/2026/10/01/01a0f5b2-6de7-7a41-bc8b-e9cb1bc54535/macos-audit/runtime-modules.txt)). The shims call `java.lang.management.ManagementFactory`; `ActivityManager` additionally references `com.sun.management.OperatingSystemMXBean`. A provider exercising those methods can fail with missing classes on the packaged runtime even though tests pass on a full JDK. The current CI grep explicitly rejects `java.lang.management`, so these current source references also fail the daemon job before its tests run.

**Recommendation:** Choose whether the shim implementation should avoid these modules or the packaged runtime should include them, then make source policy and jlink agree. Run shim/ABI and worker tests on the exact jlink runtime; the translation-only self-test is insufficient.

### A08 — Runtime packaging starts an engine against the developer's real data in in-process mode

**Evidence — code path:** [bundle_runtime.sh:63](macos/scripts/bundle_runtime.sh:63) (AppCDS recording run), [CloudDirs.kt:11](macos/daemon/src/main/kotlin/com/lagradost/macos/CloudDirs.kt:11) (default root), [ExtensionPolicy.kt:79](macos/daemon/src/main/kotlin/com/lagradost/macos/ExtensionPolicy.kt:79) (`LaunchOptions` defaults), [Main.kt:108](macos/daemon/src/main/kotlin/com/lagradost/macos/Main.kt:108) and [Main.kt:135](macos/daemon/src/main/kotlin/com/lagradost/macos/Main.kt:135) (state/restore startup).

The AppCDS recording run uses a throwaway port/token but provides neither an isolated `cs.cloudstream.home` nor launch options that prevent normal restoration. The default root is the user's `~/.cloudstream-macos`; default non-stdin launch options use in-process extension hosting. If the root is unlocked, ordinary build/package work can therefore migrate or update real state and load installed extension code inside the recording daemon, outside the production worker boundary. If another app owns the lock, the recording run instead fails; this is not isolation.

**Recommendation:** Record CDS with an explicit temporary data root, deterministic fixtures and safe launch options, and clean that root after exit. All build-time self-tests/smoke runs should have explicit data-root and extension-isolation contracts.

### A09 — CI and `make test-client` can report success after `xcodebuild` fails

**Evidence — code path:** [macos.yml:63](upstream/.github/workflows/macos.yml:63) and [macos.yml:73](upstream/.github/workflows/macos.yml:73) (client build/tests), [Makefile:41](macos/Makefile:41) (`test-client`).

The workflow pipes `xcodebuild` through `xcpretty` and checks only the pipeline's final status; it does not specify `shell: bash` or enable `pipefail`. GitHub's unspecified non-Windows shell uses `bash -e`, whereas explicitly selecting bash adds `-o pipefail`, as described in [GitHub's workflow syntax documentation](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax). A formatter that succeeds can mask a compiler/test failure, making `|| exit 1` ineffective. The Makefile's `| tail -25` has the same problem.

**Recommendation:** Set a shell with `pipefail`, retain the raw log and XCTest result bundle, and prove failure propagation with an intentionally failing command/test. Passing client CI currently cannot be treated as reliable build/test evidence.

### A10 — A syntactically valid backup preference can trap the application after library restore

**Evidence — reproduced:** [UserPreferences.swift:341](macos/client/Sources/Services/UserPreferences.swift:341) (`applyBackupValues` integer conversion), [BackupDocument.swift:171](macos/client/Sources/Services/Backup/BackupDocument.swift:171) (`BackupValue` decoding), [BackupService.swift:108](macos/client/Sources/Services/Backup/BackupService.swift:108) (restore ordering).

`BackupValue` accepts an out-of-Int-range number as `Double`; `applyBackupValues` executes `Int(v)` before any property-specific clamp. For example, `{"maxConcurrentDownloads":1e100}` decodes successfully and traps rather than throwing a recoverable validation error. The isolated probe used the unchanged preference/backup source and exited with signal 5: “Double value cannot be converted to Int … greater than Int.max.” [Probe log](~/.audit-artifacts/visualizations/2026/10/01/01a0f5b2-6de7-7a41-bc8b-e9cb1bc54535/macos-audit/preference-probe.log). Its unrelated policy/DTO dependencies were minimal stubs; the decoder and conversion were real source.

The restore service commits the library before applying preferences, so this can leave a partially applied restore and abrupt application termination. Swift's conversion range checks are also visible in its [standard-library integer implementation](https://github.com/swiftlang/swift/blob/main/stdlib/public/core/Integers.swift).

**Recommendation:** Validate every numeric backup field for finiteness, type and supported range before committing any data. Use a checked exact/range conversion and return validation warnings/errors. Extend validation beyond record count and file size.

### A11 — Worker IPC writes can block before deadlines and before forced shutdown are armed

**Evidence — code path:** [WorkerClient.kt:93](macos/daemon/src/main/kotlin/com/lagradost/macos/worker/WorkerClient.kt:93) (`call`), [WorkerClient.kt:113](macos/daemon/src/main/kotlin/com/lagradost/macos/worker/WorkerClient.kt:113) (`abandon`), [WorkerClient.kt:130](macos/daemon/src/main/kotlin/com/lagradost/macos/worker/WorkerClient.kt:130) (`stop`), [WorkerClient.kt:138](macos/daemon/src/main/kotlin/com/lagradost/macos/worker/WorkerClient.kt:138) (`send`).

`send` synchronously writes/flushed framed data under a monitor. `call` starts its await timeout only after this write returns. Cancellation writes another frame before scheduling its grace-period kill; shutdown similarly writes and closes the stream before scheduling its forced wait. If a worker stops reading stdin and the pipe fills, the code advertised as bounded can block in the write, preventing those later recovery steps from being armed. This matters precisely for hostile or hung workers, which isolation is intended to contain.

**Recommendation:** Bound outbound buffering and own writes on a dedicated writer path. Arm monotonic call and termination deadlines before attempting IO; timeout enforcement must be able to kill a process without acquiring the writer lock or writing another frame. Test a worker that never reads stdin with payloads large enough to fill the pipe.

## P2 findings

### A12 — Worker startup reservations and streaming-search bounds are ineffective

**Evidence — code path:** [WorkerRuntime.kt:204](macos/daemon/src/main/kotlin/com/lagradost/macos/worker/WorkerRuntime.kt:204) (`WorkerPool.admit`), [WorkerRuntime.kt:103](macos/daemon/src/main/kotlin/com/lagradost/macos/worker/WorkerRuntime.kt:103) (`WorkerHandle` publication), [MediaRoutes.kt:116](macos/daemon/src/main/kotlin/com/lagradost/macos/MediaRoutes.kt:116) (`/search/stream`), [ProviderExecutor.kt:73](macos/daemon/src/main/kotlin/com/lagradost/macos/ProviderExecutor.kt:73) (`searchPermits`).

Admission counts only `running` handles, but a new handle publishes its client only after initialization completes. Concurrent cold starts are admitted without a reserved slot, so the configured worker limit/overflow is not a bound during startup. The UI's streaming search starts one async job per provider and calls `searchOne` directly; only the batch search uses the eight-permit semaphore. A normal large-provider search is therefore a practical trigger for the startup race and CPU/memory spikes.

**Recommendation:** Reserve capacity across starting/running/stopping states, release on all failures, and apply one concurrency policy to every search route. Include cold-start and nested extractor workloads in admission tests.

### A13 — Restart spawns the replacement before the previous engine releases its data lock

**Evidence — code path:** [DaemonSupervisor.swift:128](macos/client/Sources/App/DaemonSupervisor.swift:128) (`restart`), [AtomicFiles.kt:51](macos/daemon/src/main/kotlin/com/lagradost/macos/AtomicFiles.kt:51) (`DataRootLock.acquire`), [Main.kt:108](macos/daemon/src/main/kotlin/com/lagradost/macos/Main.kt:108) (startup lock).

`restart` requests termination, removes the process from tracking and immediately calls `spawn`. Termination is asynchronous; the old engine can still own the exclusive root lock. The replacement may fail startup solely because the old engine is still shutting down, feeding the crash/restart path. This is especially likely for slow extension/server shutdown.

**Recommendation:** Make restart an ordered operation with a generation: stop, wait or force within a bounded grace period, verify exit, then spawn. Keep the terminating process owned until it exits.

### A14 — Crash recovery has no backoff and can turn safe mode off on the next crash

**Evidence — code path:** [DaemonSupervisor.swift:352](macos/client/Sources/App/DaemonSupervisor.swift:352) (termination handler), [DaemonSupervisor.swift:393](macos/client/Sources/App/DaemonSupervisor.swift:393) (safe-mode launch handling).

Unexpected exits immediately restart with no delay, retry ceiling or stable terminal state. A persistently invalid jar/runtime/root can cause repeated JVM launches. Once safe mode is selected, `safeModeRequested` is cleared at spawn; an exit while `safeModeActive` is true does not request it again. Unless policy forces safe mode, the next restart goes back to loading extensions. Thus crash recovery can alternate between safe and ordinary launches rather than keeping the protective state latched.

**Recommendation:** Persist safe-mode intent until an explicit user action clears it. Add exponential backoff, a retry budget and actionable recovery diagnostics; distinguish process-start failures from extension-induced crashes.

### A15 — A live engine that misses the startup deadline is left permanently unmanaged for health recovery

**Evidence — code path:** [DaemonSupervisor.swift:412](macos/client/Sources/App/DaemonSupervisor.swift:412) (`awaitHealthy`).

If the process is still alive after the 20-second startup deadline, the supervisor sets an error and stops polling. The regular heartbeat starts only after initial health success. A hung engine is not restarted, and a slow engine that becomes healthy later is never connected automatically.

**Recommendation:** Define a bounded startup recovery policy, with retry/backoff or a continuing recoverable health state. Ensure cancellation/stop cannot publish a late error or readiness event for a superseded generation.

### A16 — “Ready” and “bootstrapped” can become true before the client or providers are usable

**Evidence — code path:** [DaemonSupervisor.swift:417](macos/client/Sources/App/DaemonSupervisor.swift:417) (ready before endpoint event), [AppState.swift:144](macos/client/Sources/ViewModels/AppState.swift:144) (`observeEngine`), [AppState.swift:249](macos/client/Sources/ViewModels/AppState.swift:249) (`watchExtensionRestore`), [AppState.swift:279](macos/client/Sources/ViewModels/AppState.swift:279) (`bootstrap`), [DownloadService.swift:1173](macos/client/Sources/Services/DownloadService.swift:1173) (`classifyResolutionError`).

The state stream can mark `AppState` ready before the endpoint task updates/verifies `DaemonClient`. Bootstrap marks providers bootstrapped after an extension-list refresh even when health reports `extensions.phase == "restoring"`. Restored downloads then resolve against unavailable providers; 400/422 responses are classified as provider-missing failures. The extension-restore watcher also exits on one transient health failure and never repairs that watcher automatically.

**Recommendation:** Publish one generation-bound connection state containing endpoint, verified IPC health and provider-restoration phase. Gate provider work on restoration completion, and retry transient health polling failures without falsely publishing readiness.

### A17 — Opening another main window can break the singleton engine observation

**Evidence — code path, with stream cancellation behavior reproduced:** [CloudStreamMacApp.swift:133](macos/client/Sources/App/CloudStreamMacApp.swift:133) (`WindowGroup.task`), [AppState.swift:144](macos/client/Sources/ViewModels/AppState.swift:144) (`observeEngine`), [DaemonSupervisor.swift:55](macos/client/Sources/App/DaemonSupervisor.swift:55) (single stored streams).

Every main window invokes `observeEngine` on the same `AppState`, cancelling the previous endpoint/state consumer and iterating the same stored `AsyncStream` objects again. These are not replayable broadcast subscriptions. In particular, cancellation of a waiting iterator can terminate stream iteration; an already-ready engine does not republish its endpoint for the replacement observer. Shared navigation/selection also makes multiple windows operate on one navigation state.

A standalone Swift probe confirmed that cancelling the first consumer causes a later yield to return `terminated` and a replacement consumer to receive zero values. [Probe log](~/.audit-artifacts/visualizations/2026/10/01/01a0f5b2-6de7-7a41-bc8b-e9cb1bc54535/macos-audit/stream-probe.log). The multiwindow application scenario itself was not run.

**Recommendation:** Start application-scoped observation exactly once in composition/lifecycle code. Use replayable current state plus explicit subscriptions if multiple consumers are needed, and give windows their own navigation state or enforce a single-main-window design.

### A18 — Profile switches do not cancel or fence profile-specific asynchronous work

**Evidence — code path:** [AppLock.swift:81](macos/client/Sources/Services/AppLock.swift:81) (`switchProfile`), [LibraryStore.swift:558](macos/client/Sources/Services/LibraryStore.swift:558) (`resume`), [EpisodeUpdateChecker.swift:42](macos/client/Sources/Services/EpisodeUpdateChecker.swift:42) (`runOnce`), [DownloadService.swift:1537](macos/client/Sources/Services/DownloadService.swift:1537) (`autoAddToLibraryIfEnabled`).

Closing the current player does not cancel a library resume that is still awaiting details. Its completion can start profile A's title after profile B is selected, and subsequent progress goes to B's active store. The episode checker similarly obtains A's due items, awaits the daemon, then writes through the currently active `LibraryStore`; if B contains the same item key, A's check changes B. Download completion adds to whichever profile is active at completion rather than an explicitly chosen owner.

Shared downloads/extensions/settings are intentional; this finding concerns writes and playback attributed to private profile libraries. **Recommendation:** Capture profile ID/generation and owned store at operation start, cancel on switch, and revalidate ownership after every await. Specify which profile receives shared-download library entries.

### A19 — Backup repository restore calls an API that intentionally stops working after one migration

**Evidence — code path:** [BackupService.swift:125](macos/client/Sources/Services/Backup/BackupService.swift:125) (`restore`), [AppState.swift:283](macos/client/Sources/ViewModels/AppState.swift:283) (initial migration), [RepositoryService.kt:136](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:136) (`importLegacyRepositories`).

Backup restore sends missing repositories through the one-time `swift-repositories-v1` migration API. After ordinary bootstrap marks that migration completed, it returns successfully without adding anything. Restore can therefore report no warning while leaving backed-up repositories absent. Disabled-provider restores also use `try?`, hiding unavailable IDs or rejected operations.

**Recommendation:** Use a normal idempotent user-authorized repository-add/import operation for backups, with an applied/skipped/failed result. Keep migration APIs limited to migrations and report per-provider warnings.

### A20 — Safety backups overwrite each other within the same minute

**Evidence — code path:** [BackupService.swift:59](macos/client/Sources/Services/Backup/BackupService.swift:59) (`defaultFileName`), [BackupService.swift:157](macos/client/Sources/Services/Backup/BackupService.swift:157) (`writeAutoBackup`).

Automatic filenames have minute precision plus a reason; there is no unique suffix or profile identifier. Two `before-restore` backups in one minute write the same path atomically, replacing the first safety copy. Repeated restores can erase the original recovery point that justified allowing replacement. Profiles also share filenames and one retention pool.

**Recommendation:** Use collision-free snapshot IDs and profile ownership in metadata/path. Keep pre-restore safety snapshots distinct from rolling daily retention and never overwrite an existing recovery point.

### A21 — “Automatically every day” means only “when the engine bootstraps,” with one clock for all profiles

**Evidence — code path:** [BackupService.swift:140](macos/client/Sources/Services/Backup/BackupService.swift:140) (`runAutoBackupIfDue`), [AppState.swift:314](macos/client/Sources/ViewModels/AppState.swift:314) (call site), [UserPreferences.swift:417](macos/client/Sources/Services/UserPreferences.swift:417) (`lastAutoBackup`).

There is no daily scheduler or profile-switch trigger. An application left running for days can go without another automatic backup. A backup of profile A updates a global timestamp, suppressing profile B's backup for the next interval even though B has never been backed up. Global retention can then remove the only backup of a less active profile.

**Recommendation:** Schedule due checks over application lifetime and profile activation, record backup success per profile, and retain a minimum recovery history per profile. The UI should describe actual backup coverage.

### A22 — Movie playback is omitted from history and watch statistics

**Evidence — code path:** [LibraryStore.swift:356](macos/client/Sources/Services/LibraryStore.swift:356) (`recordProgress`), [LibraryStore.swift:728](macos/client/Sources/Services/LibraryStore.swift:728) (`watchHistory`), [LibraryStore.swift:772](macos/client/Sources/Services/LibraryStore.swift:772) (`watchStats`).

Only non-nil episodes create history rows. Movies play with `episode == nil`, so their title-level progress can appear in Continue Watching but contributes no history or statistics. Privacy/settings controls based on an empty episode history can consequently be unavailable even with movie resume data present.

**Recommendation:** Represent movie playback in the same history domain using a stable movie playback key, or query a unified playback-history model. Test movie-only libraries and privacy clearing.

### A23 — Deleted history can reappear, and its Continue Watching position is retained

**Evidence — code path:** [LibraryStore.swift:744](macos/client/Sources/Services/LibraryStore.swift:744) (`deleteHistoryEntry`), [LibraryStore.swift:813](macos/client/Sources/Services/LibraryStore.swift:813) (`backfillEpisodeProgressIfNeeded`).

Deleting a history row does not update its title's last-episode pointer or resume position. Continue Watching can still expose the removed entry. If deletion leaves no episode rows, startup/profile activation runs the “legacy” backfill again and reconstructs history from those retained title fields. Emptiness is being used as a migration marker, so explicit deletion is indistinguishable from an unmigrated store.

**Recommendation:** Persist a one-time migration/version marker and define consistent row deletion/resume clearing semantics. Test deletion of the last row followed by reopening the store.

### A24 — Continue Watching can resume the wrong episode

**Evidence — code path:** [LibraryStore.swift:572](macos/client/Sources/Services/LibraryStore.swift:572) (`resume`).

The first candidate satisfying either matching data or matching optional season/episode wins. A candidate with nil season/episode matches a stored nil/nil pair even when the exact saved data appears later. Sub/dub alternatives can also share season/episode values. This can apply an old resume position to a different episode or audio variant. Failure to match any series episode falls through to a nil episode instead of reporting/reconciling an unavailable episode.

**Recommendation:** Match exact episode identity first, then use a separate non-nil coordinate fallback constrained by audio/edition. Report an unavailable match rather than loading a movie path for a series.

### A25 — Backup merge does not implement consistent “newer wins” semantics

**Evidence — code path:** [LibraryStore.swift:928](macos/client/Sources/Services/LibraryStore.swift:928) (`setUserNote`), [LibraryStore.swift:936](macos/client/Sources/Services/LibraryStore.swift:936) (`setUserRating`), [LibraryStore.swift:1039](macos/client/Sources/Services/LibraryStore.swift:1039) (item merge), [LibraryStore.swift:1113](macos/client/Sources/Services/LibraryStore.swift:1113) (playback merge), [BackupDocument.swift:59](macos/client/Sources/Services/Backup/BackupDocument.swift:59) (`Playback`).

Notes/ratings are changed without advancing `lastUpdated`, although merge uses that timestamp. Incoming nil notes and zero ratings cannot clear existing values; favorites use OR regardless of recency, so an unfavorite cannot be represented by the merge. Per-title playback records lack update timestamps and restore overwrites local speed/delay/subtitles-off even from an older backup.

**Recommendation:** Specify field merge policy, timestamps and explicit clearing/tombstones. Either support chronological synchronization or present merge as a deliberately additive import; the existing mixed behavior surprises users in both directions.

### A26 — Deleting library items leaves unowned history and playback-preference records

**Evidence — code path:** [LibraryStore.swift:267](macos/client/Sources/Services/LibraryStore.swift:267) (`setWatchType`), [LibraryStore.swift:945](macos/client/Sources/Services/LibraryStore.swift:945) (bulk mutation), [EpisodeProgress.swift:1](macos/client/Sources/Models/EpisodeProgress.swift:1), [TitlePlaybackPrefs.swift:1](macos/client/Sources/Models/TitlePlaybackPrefs.swift:1).

The models relate through string IDs rather than SwiftData relationships or a centralized deletion policy. Item-deletion branches do not remove dependent episode/preference records. Playback preferences can exist even for a title removed with no current resume position, and imported snapshots can include orphan episode IDs. History rendering and statistics/snapshot export use different filters, so hidden rows can still affect stats or backup data.

**Recommendation:** Define whether title removal retains history intentionally, then enforce it consistently through relationships/cascade rules or an explicit aggregate operation. Validate referential integrity during import and add cleanup/reconciliation for existing data.

### A27 — Direct resume without a validator can splice different files of identical length

**Evidence — code path:** [DirectFileJob.swift:117](macos/client/Sources/Services/Downloads/DirectFileJob.swift:117) (resume admission/If-Range).

When no strong ETag or Last-Modified exists, matching mirror key and total length are accepted as proof of identical content. Mirror identity is not a byte-content identity; refreshed signed links can refer to different files of the same size. A matching 206 start/total will then append one file's suffix to another file's prefix.

**Recommendation:** Resume only with an adequate validator or verified content identity; otherwise restart. Persist the actual representation identity and test equal-length changed content. This is separate from A02's mishandling of an explicitly mismatched range.

### A28 — Direct video downloads omit separate audio tracks

**Evidence — code path:** [DownloadPolicy.swift:163](macos/client/Sources/Services/Downloads/DownloadPolicy.swift:163) (`isDirectFile`), [DownloadService.swift:1248](macos/client/Sources/Services/DownloadService.swift:1248) (`attempt`), [PlayerViewModel.swift:597](macos/client/Sources/ViewModels/PlayerViewModel.swift:597) (split-stream playback support).

A `VIDEO` link without a playlist extension is sent to the direct downloader even when `audioTracks` is nonempty. Successful direct download returns only the video URL's bytes and never combines the separate audio. Split extractor output can therefore be marked complete as a silent video, despite playback handling it as split media.

**Recommendation:** Route split media through the remux path, or explicitly download/mux all selected tracks. Add a video-only direct URL plus separate-audio regression case.

### A29 — Resuming frozen ffmpeg jobs bypasses concurrency and offline admission

**Evidence — code path:** [DownloadService.swift:664](macos/client/Sources/Services/DownloadService.swift:664) (`pause`), [DownloadService.swift:681](macos/client/Sources/Services/DownloadService.swift:681) (`resume`), [DownloadService.swift:704](macos/client/Sources/Services/DownloadService.swift:704) (`suspendForNetworkLoss`).

Paused jobs free queue slots, allowing queued jobs to start. Resuming a retained ffmpeg job directly sends resume/SIGCONT and marks it downloading without reacquiring global/per-provider capacity or checking the network hold. Pause three jobs, start three replacements, then resume the original three: the configured limit of three can become six. Resolution already in flight is also not paused by the network-loss filter, which only handles `.downloading` items.

**Recommendation:** Route every transition into active transfer through one admission function, including retained-process resume and completion of link resolution. Preserve user-pause versus network-pause intent independently of scheduler state.

### A30 — Download completion is not crash-consistent across rename, subtitles and database state

**Evidence — code path:** [DownloadService.swift:1374](macos/client/Sources/Services/DownloadService.swift:1374) (`finalize`).

The video is moved to its final path and partial metadata removed before awaiting subtitle downloads and persisting `.completed`. A crash/quit in that interval leaves a final video with a record still describing an active transfer and potentially the prior destination. Restart recovery can requeue/redownload it, leave an unindexed file, or choose a duplicate destination.

**Recommendation:** Introduce a durable finalizing state or commit/reconcile the completed video before optional sidecars. Reconcile final and partial paths during queue restoration, and inject a crash at each boundary in a recovery test.

### A31 — Failed file deletion still removes the download's records

**Evidence — code path:** [DownloadService.swift:817](macos/client/Sources/Services/DownloadService.swift:817) (`deleteCompleted`).

File/sidecar removals suppress errors; the library entry and download record are then removed unconditionally. On an unplugged volume or denied permission, the video remains while the application loses its index and reports the logical deletion. Users cannot distinguish “forgot record” from “deleted file.”

**Recommendation:** Return a deletion result, preserve recoverable records on IO failure and surface the failed path/reason. Offer forgetting a missing file as an explicit action rather than an implicit fallback.

### A32 — Poster and subtitle downloads buffer unbounded remote bodies in the main process

**Evidence — code path:** [PosterImage.swift:152](macos/client/Sources/UI/Components/PosterImage.swift:152) (`ImageCache.image`), [DownloadService.swift:1574](macos/client/Sources/Services/DownloadService.swift:1574) (`downloadSubtitles`).

Both paths use `URLSession.data(for:)`, which collects the full body. Subtitle size is checked only afterward; images have neither a response-byte limit nor a decode-dimension budget before `NSImage` creation. A faulty or malicious provider host can serve very large data, causing client memory pressure or termination even though worker IPC and the worker heap are bounded. An NSCache cost limit after decode does not bound peak memory.

**Recommendation:** Stream with a hard byte budget and reject oversized declared/observed lengths; bound image pixels during decoding/downsampling, response status/type, outstanding requests and disk storage. Test oversized/chunked bodies, not just small valid images.

### A33 — Clearing provider credentials does not clear credentials in an already running provider

**Evidence — code path:** [ProviderOverrides.kt:34](macos/daemon/src/main/kotlin/com/lagradost/macos/ProviderOverrides.kt:34) (`configure`), [ProviderOverrides.kt:19](macos/daemon/src/main/kotlin/com/lagradost/macos/ProviderOverrides.kt:19) (`apply`), [WorkerMain.kt:202](macos/daemon/src/main/kotlin/com/lagradost/macos/worker/WorkerMain.kt:202) (`configure`), [ExtensionsView.swift:851](macos/client/Sources/UI/Extensions/ExtensionsView.swift:851) (`ProviderSettingsSheet.apply`).

A blank credential removes the override map entry, but applying the resulting nil uses `provider.storedCredentials` as the fallback; the worker uses the same fallback. The running extension therefore keeps using the old secret after the Keychain entry is deleted and the UI says saved. The client also changes Keychain state before the engine request succeeds, allowing configuration drift on IPC failure. Empty URLs are rejected by validation before the later branch intended to clear a URL can execute.

**Recommendation:** Model unchanged/set/clear explicitly, apply clears to live instances or restart them, and report the actual remote result. Coordinate Keychain persistence with engine acknowledgement and support a real URL-clear operation.

### A34 — Native next/previous and autoplay do not use the selected episode order

**Evidence — code path:** [MediaDetailView.swift:219](macos/client/Sources/UI/Details/MediaDetailView.swift:219) (`playbackOrder`), [PlayerViewModel.swift:1250](macos/client/Sources/ViewModels/PlayerViewModel.swift:1250) (`currentEpisodeIndex`/neighbors).

The details screen sorts episodes by season/number and filters anime by sub/dub preference, while the player indexes the raw `details.episodes` array. Next/previous, prefetch and autoplay can consequently switch editions, repeat an episode, or follow provider collection order instead of the order the user selected.

**Recommendation:** Resolve and pass an explicit playback sequence/edition into the session, using the same episode identity/order policy across details, resume, controls and autoplay.

### A35 — Split-stream playback discards per-audio request headers

**Evidence — code path:** [PlayerViewModel.swift:597](macos/client/Sources/ViewModels/PlayerViewModel.swift:597) (`loadPlan`), [PlayerViewModel.swift:628](macos/client/Sources/ViewModels/PlayerViewModel.swift:628) (`mergedSplitURL`), [PlayerViewModel.swift:572](macos/client/Sources/ViewModels/PlayerViewModel.swift:572) (`StreamLoadRequest`).

The split path builds an EDL from video/audio URLs and returns no separate audio-track objects. Only the main video's headers are passed to libmpv; each audio track's headers are discarded. Audio hosted behind a different Referer, Cookie or other authorization requirement can fail while video succeeds. A single header set can also send a video's credentials to a different audio origin.

**Recommendation:** Preserve per-resource header/origin contracts in the transport plan. If the chosen EDL path cannot express them safely, use an alternative supported transport or report an unsupported split-header configuration.

### A36 — Player initialization and asynchronous command failures do not reliably reach the player state machine

**Evidence — code path:** [MetalVideoView.swift:445](macos/client/Sources/UI/Player/MetalVideoView.swift:445) (`createRenderContext`), [MetalVideoView.swift:514](macos/client/Sources/UI/Player/MetalVideoView.swift:514) (shader failure), [MetalVideoView.swift:1449](macos/client/Sources/UI/Player/MetalVideoView.swift:1449) (command replies), [PlayerViewModel.swift:580](macos/client/Sources/ViewModels/PlayerViewModel.swift:580) (loading state).

Render-context/device/pipeline failures return false or log. Failed asynchronous commands/properties are logged without a typed event/request association delivered to the view model. The UI can stay loading or announce an operation that never happened; `takeScreenshot` announces “saved” immediately even if no live view or successful mpv reply exists. A rejected seek can also leave its pending-position reconciliation waiting for a position that never arrives.

**Recommendation:** Send initialization/command outcomes into one typed player event channel keyed by session/request generation. Define loading deadlines and recoverable mirror/engine failure transitions; announce success after acknowledgement/file verification.

### A37 — Discover pagination can append stale results after refresh or provider clearing

**Evidence — code path:** [DiscoverStore.swift:62](macos/client/Sources/ViewModels/DiscoverStore.swift:62) (`load`), [DiscoverStore.swift:104](macos/client/Sources/ViewModels/DiscoverStore.swift:104) (`loadMore`).

Page-one loads have a stored task, but pagination uses an unowned task and only compares provider strings. A page-two request started before force-refresh of the same provider can append into the new page-one result and change its page counter. Clearing the provider returns before cancelling the previous page-one task, which can later repopulate cleared rows.

**Recommendation:** Own both tasks under a load generation and reject responses unless provider, generation and expected page all match. Clearing selection and engine replacement must cancel/invalidate every load.

### A38 — Cached details survive provider/engine configuration changes indefinitely

**Evidence — code path:** [AppState.swift:72](macos/client/Sources/ViewModels/AppState.swift:72) (`loadedDetails`), [AppState.swift:484](macos/client/Sources/ViewModels/AppState.swift:484) (`loadDetails`), [AppState.swift:144](macos/client/Sources/ViewModels/AppState.swift:144) (engine replacement).

Details are reused without a TTL or engine/provider generation in the key. Engine restart, extension replacement and credential/clone-URL changes do not invalidate this dictionary. The daemon's own invalidation cannot repair a hit served from the client cache, leaving stale episode data or inaccessible streams until explicit refresh/eviction. Trimming by dictionary iteration is also arbitrary rather than a meaningful freshness/LRU policy.

**Recommendation:** Associate entries with provider generation/configuration and freshness, invalidate on relevant lifecycle events, and distinguish offline snapshots from authoritative playable details.

### A39 — Spotlight can retain stale profile items and suppress retries after failure

**Evidence — code path:** [SpotlightIndexer.swift:28](macos/client/Sources/Services/System/SpotlightIndexer.swift:28) (`reindex`), [SpotlightIndexer.swift:42](macos/client/Sources/Services/System/SpotlightIndexer.swift:42) (`removeAll`).

The version is marked indexed before the asynchronous deletion/insertion succeeds. Failure then suppresses another attempt for the same version. Cancellation is checked before `reindex` starts, but not after its awaits: an in-flight old-profile reindex can insert old items after a profile switch, disable/remove action or newer reindex. This is especially sensitive for profile metadata visible in system search. The product already discloses non-encrypted libraries; the issue is stale indexing after an explicit state change.

**Recommendation:** Fence operations by profile/index generation and enabled state after each await. Advance success version only after completion, serialize deletion/indexing and retry recoverable failures.

### A40 — The fresh-checkout client CI job does not stage its required native dependencies

**Evidence — engineering risk/code path:** [macos.yml:52](upstream/.github/workflows/macos.yml:52) (client job), [project.yml:41](macos/client/project.yml:41) (resource declarations), [project.yml:73](macos/client/project.yml:73) (`-lmpv`), [project.yml:110](macos/client/project.yml:110) (Gradle prebuild).

The client job installs XcodeGen but does not build/stage/download the media stack. Binaries, frameworks, runtime and tools are ignored/untracked generated resources, while linking requires `Resources/Binaries/libmpv`. The jar artifact from the daemon job is not consumed and the Xcode prebuild instead invokes Gradle without the client job explicitly provisioning the required JDK/tooling. A developer's populated Resources directory masks this clean-checkout gap; A09 can additionally hide failures.

**Recommendation:** Give client CI an explicit staged dependency artifact with architecture/minimum-OS provenance, or build that artifact before XcodeGen/build. Provision the JDK and avoid hidden build-time Gradle work. Validate on a clean checkout without Homebrew fallback libraries.

### A41 — Release publication points to the wrong DMG and does not provision signing credentials

**Evidence — code path:** [macos.yml:147](upstream/.github/workflows/macos.yml:147) (package/release), [package_app.sh:18](macos/scripts/package_app.sh:18) (destination), [package_app.sh:111](macos/scripts/package_app.sh:111) and [package_app.sh:147](macos/scripts/package_app.sh:147) (optional signing/notarization).

The workflow publishes `macos/client/build/Release/CloudStream.dmg`; the packaging script produces `macos/dist/CloudStream.dmg`. The intended asset is absent at the configured publication path. The workflow passes an identity string/profile name but has no certificate/private-key import or notary-profile setup on its fresh hosted runner. When secrets are absent the script deliberately succeeds with unsigned/non-notarized output despite the job's signed/notarized description.

**Recommendation:** Consume the packaging script's declared artifact path and fail if it is absent. Provision an ephemeral signing keychain and notarization credentials, then require signature/notarization verification in release mode; retain an explicitly separate development packaging mode.

### A42 — Media staging does not prove dependency closure and accepts stale resources

**Evidence — engineering risk/code path:** [bundle_media.sh:59](macos/scripts/bundle_media.sh:59) and [bundle_media.sh:78](macos/scripts/bundle_media.sh:78) (relative load-path skips), [bundle_media.sh:139](macos/scripts/bundle_media.sh:139) (verification), [build_dev.sh:44](macos/scripts/build_dev.sh:44) (staging condition).

The recursive copier skips existing `@rpath`/`@loader_path` dependencies and suppresses rewrite errors. Its final check inspects a few ffmpeg load-path lines, not whether every dependency of libmpv/ffmpeg and nested libraries actually resolves; unresolved paths warn rather than fail. Relative dependencies from a supported external prefix can remain unstaged. Development staging is skipped whenever ffmpeg exists, even if libmpv or its closure is missing/stale or source pins changed.

**Recommendation:** Resolve relative paths using each binary's loader/rpaths, verify the complete closure and architectures/deployment targets, and fail unresolved rewrites. Key staged resources by a manifest of pins/hashes rather than one executable's existence. Add an isolated no-Homebrew launch check.

### A43 — Multiple build paths publish a mutable distribution app before final verification

**Evidence — code path:** [project.yml:120](macos/client/project.yml:120) (postbuild distribution sync), [build_dev.sh:97](macos/scripts/build_dev.sh:97) (second publisher), [package_app.sh:130](macos/scripts/package_app.sh:130) (third copy).

A Release Xcode build copies to `dist` during a run-script phase that explicitly precedes final Xcode signing, then signs that copy ad hoc. Other scripts independently delete/copy the same canonical app later. Publication is `rm` plus `cp`, not an atomic swap, and a failed build/signing/packaging operation can leave an absent, partial or prematurely published app. Concurrent builds can contend for both source Resources staging and distribution paths.

**Recommendation:** Have one explicit publisher consume a finalized, verified build artifact. Stage to a unique directory and atomically replace the canonical artifact after verification; keep generated dependency staging outside the source tree where practical.

### A44 — The isolated Swift test harness is broken and the key integration boundaries lack demonstrated coverage

**Evidence — reproduced/code path:** [test_extensions_core.sh:9](macos/scripts/test_extensions_core.sh:9) (copied source set), [DaemonClient.swift:517](macos/client/Sources/Services/DaemonClient.swift:517) and [DaemonClient.swift:533](macos/client/Sources/Services/DaemonClient.swift:533) (protocol conformances).

The script fails compilation because it does not copy `MediaResolveClient` and `ExtensionPreferencesClient` definitions. The latter contract is declared in a SwiftUI sheet file, making a transport client's build depend on UI-owned source. [Failure log](~/.audit-artifacts/visualizations/2026/10/01/01a0f5b2-6de7-7a41-bc8b-e9cb1bc54535/macos-audit/swift-isolated-tests.log). This removes the intended lightweight, safe client-test path.

The suite has substantial policy/feature coverage; the reproduced range and preference defects demonstrate specific gaps, rather than an absence of tests. Important missing or unverified acceptance cases include mismatched 206 bodies, numeric extremes, same-name provider collisions through backup, profile switches during awaits, closed pipes, worker cold-start reservations, multiwindow observation, database fetch/save failure, and crash windows around completed downloads. Current CI does not establish that the actual packaged runtime/player/UI behavior passes.

**Recommendation:** Put transport protocols in a lower-level contracts module/source set and repair harness dependency selection. Add focused boundary regressions and separate fast policy tests, native engine tests and packaged-app acceptance tests with visible prerequisites/skips.

### A45 — Download resolution ignores the daemon's typed retryable failures

**Evidence — code path:** [DaemonClient.swift:503](macos/client/Sources/Services/DaemonClient.swift:503) (`validate`), [DownloadService.swift:1173](macos/client/Sources/Services/DownloadService.swift:1173) (`classifyResolutionError`), [OperationFailure.kt:68](macos/daemon/src/main/kotlin/com/lagradost/macos/OperationFailure.kt:68) (retryability), [MediaRoutes.kt:239](macos/daemon/src/main/kotlin/com/lagradost/macos/MediaRoutes.kt:239) (links failure response).

The daemon explicitly returns structured operation failures with `retryable` for capacity, worker termination, timeout and network errors. `DaemonClient` decodes those into `.operationFailure`, but download classification handles only `.notReady` and `.http`, treating the typed case as fatal. A structured 503 capacity response therefore bypasses the retry behavior an unstructured HTTP 503 would receive. Restored or cold-start workloads can fail immediately on the condition they should back off for.

**Recommendation:** Classify the typed operation failure first, preserving retryability/code/remote status and respecting the same bounded retry budget. Test actual encoded route responses through the client, not just manually created HTTP errors.

### A46 — Anti-bot retries replace the provider's login cookies

**Evidence — code path:** [SolveInterceptor.kt:31](macos/daemon/src/main/kotlin/com/lagradost/macos/SolveInterceptor.kt:31) (pre-injection), [SolveInterceptor.kt:54](macos/daemon/src/main/kotlin/com/lagradost/macos/SolveInterceptor.kt:54) (retry request).

Cached clearance is injected only if there is no Cookie header. After solving a challenge, the retry unconditionally replaces that header with the WebKit solver's cookie string. A provider request carrying a login/session cookie loses it, unless the ephemeral solver coincidentally obtained the same cookie. Authenticated sites can thus pass the anti-bot challenge but lose authentication on the retry; subsequent requests carrying login cookies still do not receive cached clearance.

**Recommendation:** Merge cookies by name and scope, preserving provider authentication while replacing the relevant clearance cookies. Use a deliberate shared cookie/UA contract where a site's challenge requires it, rather than discarding unrelated session state. Test requests containing both login and anti-bot cookies.

### A47 — Playback never starts the implemented extractor keepalive verifier

**Evidence — code path/conditional compatibility risk:** [VerifierJobs.kt:14](macos/daemon/src/main/kotlin/com/lagradost/macos/VerifierJobs.kt:14) (verifier contract), [DaemonClient.swift:318](macos/client/Sources/Services/DaemonClient.swift:318) (`startExtractorVerifier`), [DownloadService.swift:1369](macos/client/Sources/Services/DownloadService.swift:1369) (only client start call), [PlayerViewModel.swift:227](macos/client/Sources/ViewModels/PlayerViewModel.swift:227) (playback flow).

The API and daemon implementation support `extractorVerifierJob`, which some providers use to keep an extracted link alive. Downloads start/stop it, but there is no player caller for links carrying `extractorData`. For a provider that requires this polling while its link is in use, playback can expire mid-session while a download of the same link works. This is a source-level capability gap; no such live host was exercised during this audit.

**Recommendation:** Own the verifier with the active playback link/session, stop it on mirror switch/close/replacement, and fence completion by generation. Add a deterministic fixture whose stream remains valid only while verifier polling runs.

## P3 findings and smaller engineering issues

### A48 — Now Playing artwork can be applied to the wrong session

**Evidence — code path:** [NowPlayingService.swift:163](macos/client/Sources/Services/NowPlayingService.swift:163) (artwork task).

A single artwork task captures one URL, then inserts its result into whatever `nowPlayingInfo` is current when it completes. It does not compare the current title/session/URL or check cancellation after the image await. Switching titles can briefly show the previous title's artwork; clearing playback can be followed by a late task restoring an artwork-only dictionary. The old task's deferred cleanup can also clear ownership of a newer task.

**Recommendation:** Key task ownership and completion by session/artwork generation and check cancellation before mutation; clear only the task that completed.

### A49 — Search suggestions incorrectly encode query parameter values

**Evidence — code path:** [SearchSuggestionService.swift:35](macos/client/Sources/Services/SearchSuggestionService.swift:35) (URL construction).

`.urlQueryAllowed` is suitable for a broader query component, not an individual query value, and permits separators such as `&`. Interpolating “Tom & Jerry” or text containing `&page=` changes parameter boundaries instead of preserving the search text.

**Recommendation:** Construct the URL with `URLComponents`/`URLQueryItem` and test reserved characters, Unicode, plus signs and literal percent escapes.

### A50 — Discover's existing-shelf merge does not deduplicate within the incoming page

**Evidence — code path:** [DiscoverStore.swift:119](macos/client/Sources/ViewModels/DiscoverStore.swift:119) (`merge`).

When appending to an existing shelf, `seen` is fixed and never updated as incoming items pass the filter. Two identical items not already in the shelf both survive. The new-shelf branch correctly uses `seen.insert`, so behavior differs depending on whether a shelf already exists. Duplicate SwiftUI identities can make rendering/selection unpredictable.

**Recommendation:** Use an incrementally updated set in both branches and add a page containing duplicate provider+URL IDs.

### A51 — Android backup import drops account identity before resolving conflicts

**Evidence — code path:** [AndroidBackupImporter.swift:84](macos/client/Sources/Services/Backup/AndroidBackupImporter.swift:84) (folder grouping).

The importer intentionally merges Android profiles, but groups `<account>/<folder>/<id>` only by folder/id. The same numeric ID in two accounts overwrites one value during dictionary iteration before chronological merge can occur. This can lose statuses/resume values and makes the chosen result dependent on iteration order. “Merge all accounts” should not mean discard account identity before examining the records.

**Recommendation:** Preserve account+ID through parsing, then apply an explicit conflict policy or let the user select an account/destination profile. Add same-ID conflicting-account fixtures.

### A52 — The development smoke check reports failures without failing

**Evidence — code path:** [build_dev.sh:134](macos/scripts/build_dev.sh:134) (`--launch` smoke sequence).

A dead app, absent readiness marker and surviving daemon are printed but do not produce a failure result. The readiness marker can come from an earlier log; `pgrep` can select an unrelated daemon/worker rather than the launched app's engine. Thus the script's “verify the engine” promise is stronger than its evidence.

**Recommendation:** Track the launched app and its actual engine generation/endpoint, use a fresh isolated log/root, require live authenticated health and bounded shutdown, and exit nonzero on failed criteria.

### A53 — Supervisor logs overwrite old prefixes and can retain misleading stale tails

**Evidence — code path:** [DaemonSupervisor.swift:347](macos/client/Sources/App/DaemonSupervisor.swift:347) (stdout/stderr handles).

Opening existing log files for writing starts at offset zero; neither append seeking nor truncation/rotation is performed. Each restart can overwrite the beginning while retaining a previous process's longer tail. This damages chronological diagnostics and makes historical readiness strings unreliable for smoke checks. This finding does not assume a file-descriptor leak.

**Recommendation:** Use append/rotation with a clear process-generation marker, or distinct bounded files per launch. Export logs with generation and timestamps.

## Cross-cutting maintainability and engineering opportunities

These are design/debt observations, not additional proven production failures.

| Area | Evidence and why it matters | Improvement direction |
| --- | --- | --- |
| Oversized responsibility owners | [DownloadService.swift:1](macos/client/Sources/Services/DownloadService.swift:1) (1,715 lines), [MetalVideoView.swift:1](macos/client/Sources/UI/Player/MetalVideoView.swift:1) (1,645), [PlayerViewModel.swift:1](macos/client/Sources/ViewModels/PlayerViewModel.swift:1) (1,482), [LibraryStore.swift:1](macos/client/Sources/Services/LibraryStore.swift:1) (1,130), [RepositoryService.kt:1](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:1) (741). Size alone is not a defect; these owners combine policy, transport, persistence, lifecycle, scheduling and UI effects, making invariants hard to enforce locally. | Extract queue admission/completion persistence, playback sequence/session ownership, render/event isolation, and profile repository transactions. Preserve already useful pure policy types instead of replacing them with a generic framework. |
| Composition and dependency direction | Many services directly use `.shared`, while useful injectable protocols exist for media resolution/preferences. A client protocol residing in a UI sheet contributed to A44. | Create an application composition root, inject narrow transport/store/clock/process boundaries, and place contracts below UI. Keep per-window state separate from application-scoped services. |
| Inconsistent failure contracts | Daemon operation failures are structured, but frontend `try?`, nil stores, log-only mpv replies and best-effort restore operations erase actionable state. | Establish explicit success/failure/partial-success results at persistence and cross-process boundaries. Preserve retryability, operation identity and user-facing recovery action through the client. |
| Dependency consistency and reproducibility | [build.gradle.kts:38](macos/daemon/build.gradle.kts:38) declares OkHttp 4.12.0 next to DoH 5.3.2. The generated runtime-classpath listing inspected here resolves `okhttp-jvm` and DoH to **5.3.2**, so the 4.12.0 declaration is misleading rather than evidence of a mixed-version runtime. Media build tooling installs unpinned Python tooling in CI. Several media-building entry points have different pin/target assumptions. | Align a single dependency catalog/BOM, inspect the resolved graph and lock release dependencies/tooling. No OkHttp ABI failure or CVE is claimed; resolution was inspected, but a vulnerability scan was not performed. |
| Native-process entitlements | [CloudStreamMac.entitlements:7](macos/client/CloudStreamMac.entitlements:7) grants the Swift client JIT, unsigned executable memory and disabled library validation; the separate Java process also has its own entitlement file. The native client remains a privileged consumer of provider media and WebKit output. | Review which exemptions the Swift executable actually requires, scope JVM-specific permissions to the JVM executable, and verify final nested signatures/entitlements. Process separation should also reduce privilege at the native consumer boundary. |
| Shipped SBOM coverage | [bundle_runtime.sh:116](macos/scripts/bundle_runtime.sh:116) appends the JRE to the daemon's SBOM, but the shown process does not inventory the bundled libmpv/ffmpeg and native transitive media components. | Include native component versions/commits, licenses, hashes and build provenance in the shipped inventory; scan the actual artifact, not just JVM declarations. No comprehensive license or vulnerability scan was run. |
| Idle energy and responsiveness | [DaemonSupervisor.swift:86](macos/client/Sources/App/DaemonSupervisor.swift:86) prevents App Nap with a lifetime latency-critical activity. [AppState.swift:351](macos/client/Sources/ViewModels/AppState.swift:351) polls solve work every 2 seconds and media work every 500 ms, even idle. Large synchronous SwiftData snapshot/import operations run on the main actor; the backup permits up to 200,000 records. | Scope power assertions to active work; use pending-work events/adaptive polling. Move bulk decoding and transactional imports to owned worker contexts and measure main-thread stalls with realistic libraries. |
| Query/read amplification | Library/history UI reads repeatedly use singleton computed queries, and history/title lookups issue additional per-item fetches. A global version counter triggers broad invalidation. | Fetch coherent read models once per version/profile, batch related lookups, and measure before introducing more caches. Ensure cache invalidation follows durable commits rather than attempted writes. |
| Renderer fidelity and performance tradeoff | [MetalVideoView.swift:122](macos/client/Sources/UI/Player/MetalVideoView.swift:122) caps rendering at 1920 pixels; CPU `bgr0` rendering is uploaded into BGRA8 Metal textures. This is a deliberate software-render fallback, but 2160p selection does not imply a native 4K/HDR output pipeline. | Document the actual rendering contract and measure frame times/copy cost on target Macs. Plan higher-fidelity/EDR rendering only if required; avoid treating framework novelty as correctness. |
| Geometry/accessibility edge cases | [PlayerWindowController.swift:74](macos/client/Sources/UI/Player/PlayerWindowController.swift:74) derives a minimum size from aspect ratio, and [PlayerWindowController.swift:110](macos/client/Sources/UI/Player/PlayerWindowController.swift:110) can enforce it beyond the usable screen for extreme panoramic/vertical ratios. HUD accessibility labels/adjustable actions are present, but full VoiceOver/reduced-motion/keyboard UI validation was not performed. | Bound aspect/size to actual screen constraints; add extreme-ratio/small-display tests and manual accessibility acceptance cases. |
| Shutdown consistency | [CloudStreamMacApp.swift:23](macos/client/Sources/App/CloudStreamMacApp.swift:23) and [CloudStreamMacApp.swift:37](macos/client/Sources/App/CloudStreamMacApp.swift:37) signal exits stop downloads/daemon without the `player.close()` used by ordinary termination. | Use one idempotent shutdown coordinator that persists player state before stopping owned processes, irrespective of termination entry point. |
| Documentation and legacy surface | Architecture/security ADRs are valuable, but current assertions such as safe/bounded shutdown, daily backups, complete media closure and CI verification exceed several implementation paths. Older audit/remediation documents coexist with new code and probes. | Keep one current acceptance checklist tied to test/build evidence and mark superseded audit claims explicitly. Identify obsolete build scripts and compatibility shims from actual callers/ABI usage before removal. Compatibility shims are not unnecessary simply because they appear unused by host source. |

## Validation results and limits

| Validation | Result | Meaning |
| --- | --- | --- |
| Daemon test retry | **55 suites; 298 tests declared; 295 passed; 3 skipped; 0 failures/errors.** `./gradlew :macos:daemon:test --offline --no-daemon --max-workers=2 --console=plain` | Strong evidence for the exercised daemon behavior on this machine/full JDK; does not validate the jlink runtime or native UI. [Run log](~/.audit-artifacts/visualizations/2026/10/01/01a0f5b2-6de7-7a41-bc8b-e9cb1bc54535/macos-audit/daemon-tests.log). |
| Initial daemon test run | Gradle daemon disappeared before completion | An incomplete infrastructure run, not a passing suite and not assigned a product root cause. The successful retry is reported separately. |
| Three skipped daemon cases | Live StreamPlay installation, website-catalog aggregation, Hexated/Codeberg sync | Live-provider/network compatibility was not established. Their names and suite totals are in [test-results-summary.json](~/.audit-artifacts/visualizations/2026/10/01/01a0f5b2-6de7-7a41-bc8b-e9cb1bc54535/macos-audit/test-results-summary.json). |
| Existing isolated Swift harness | **Compilation failed**: missing `MediaResolveClient` and `ExtensionPreferencesClient` | Reproduced A44. It is not a passing client suite. |
| Direct download probe | **Corrupt partial file reported completed** | Reproduced A02 from unchanged production implementation, with unrelated policy/UA dependencies stubbed. Local fixture only; no provider traffic. |
| Backup preference probe | **Signal 5 / out-of-range Double-to-Int trap** | Reproduced A10 from unchanged decoding/preferences source, with unrelated policy/DTO types stubbed. |
| Engine stream cancellation probe | First consumer cancellation terminates subsequent yields; replacement receives no values | Confirms the underlying A17 API behavior, without claiming an app UI reproduction. |
| Resolved dependency/service inventory | OkHttp JVM/DoH 5.3.2; no duplicate `META-INF/services` resources in the inspected runtime classpath | No service-provider loss was demonstrated; the fat jar's exclusion strategy was reviewed against actual jars. [Inventory](~/.audit-artifacts/visualizations/2026/10/01/01a0f5b2-6de7-7a41-bc8b-e9cb1bc54535/macos-audit/dependency-inspection.json). |
| Staged jlink module inventory | `java.management` and `jdk.management` absent | Confirms the current packaged-runtime mismatch in A07. Runtime inventory did not rebuild/stage resources. |
| Source-change verification | Only the original two tracked modifications remain | No proposed fix was applied. |

There are 23 Swift unit-test source files and three UI-test source files. Their existence is not counted as successful execution. The full Xcode unit/UI suite, Thread Sanitizer run, signed/notarized release, clean-checkout build, minimum-macOS launch, live repositories and network challenge flows were **not run** as part of this audit. A normal Xcode/package build here writes staging resources and can start the engine against real user state (A08), so it was not used as a supposedly read-only verification. Existing build/test artifacts were not attributed to this run.

The audit did not perform a comprehensive dependency advisory scan, cryptographic implementation proof, fuzzing campaign, visual/accessibility inspection of the running application, or an end-to-end exploit of A01. Code-path findings state their actual conditions; platform-dependent or workload-dependent opportunities are labeled as risks rather than reported as reproduced failures.

## Recommended remediation sequence

1. **Protect data and native boundaries:** A01–A06 and A10. Establish strict remote-resource policy, correct 206 behavior, safe render/event ownership, lock-gated service operations, stable provider keys, and throwing/transactional persistence/restore.
2. **Make build evidence trustworthy:** A07–A09 and A40–A44. Isolate build-time runtime probes, repair the runtime/module policy and Swift harness, stage clean dependencies, propagate failures, and produce one verified release artifact.
3. **Make lifetime/capacity explicit:** A11–A18. Own process/worker reservations and deadlines, serialize restarts, retain safe-mode intent, publish generation-bound readiness, start observers once and fence profile operations.
4. **Repair user-facing recovery semantics:** A19–A39 and A45–A47. Separate migration from restore, preserve unique/per-profile backups, reconcile history/resume and merge policy, journal download completion, use one transfer-admission gate and invalidate stale async/cache results.
5. **Consolidate contracts and observability:** A48–A53 and the design table. Fix smaller state/encoding/import defects, enforce smoke checks, preserve chronological logs and update acceptance documentation.

## Regression cases that should gate the resulting fixes

| Boundary | Required scenario and assertion |
| --- | --- |
| Worker → native player | Reject remote `file://`, nested unsafe playlist/audio/subtitle URLs and invalid headers; explicitly authorized local download still plays. |
| Direct HTTP resume | Wrong range start, wrong total, unsolicited 206, missing/weak validator and same-size changed representation; completed bytes must match the intended entity. |
| Player teardown | Repeated close/reopen, mirror switch, queued events and in-flight render during shutdown under sanitizer; no race or stale callback. |
| Lock/profile | Menu/shortcut import/export while locked; resume and episode-check awaits completing after profile switch; no access or writes attributed to the wrong profile. |
| Identity | Two installations with equal provider display name and equal content URL; search filing, history, backup round-trip, Spotlight and resume remain distinct. |
| Persistence/restore | Container unavailable, fetch failure, save failure, concurrent pending changes, numeric extremes, repeated safety backup in one minute and failed repository restore; truthful result and preserved recovery point. |
| Worker lifetime | Concurrent cold starts beyond capacity, stalled stdin writer, nested extractor request, cancellation and process exit; hard resource/deadline bounds hold. |
| Supervisor | Slow lock release, never-healthy live process, repeated crash in safe mode, endpoint replacement and a second window; exactly one usable, correctly configured current connection. |
| Downloads | Pause/replacement/resume at capacity, network loss during resolution, split video/audio, crash after final rename, failed deletion on removed/read-only volume; no silent media loss or inaccurate record. |
| Distribution | Empty clean checkout, no Homebrew libraries, exact jlink runtime, complete native closure, intentional compiler/test failure, missing release secrets and final DMG path; checks fail honestly and shipped assets match verified artifacts. |

This audit recommends targeted invariant repairs and acceptance tests. It does not recommend a broad rewrite: the existing policy types, provenance model, process separation, and regression fixtures are useful foundations.
