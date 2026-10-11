# Audit traceability

Every finding and planned change in the three October 2026 documents, with
where it is implemented and the test that proves it. Precedence where the
documents overlap: [Security audit](../audit/macos-security-audit-2026-10.md) >
[Audit-Fix Plan](Audit-Fix-Plan.md) > [Remediation Plan](Remediation-Plan-2026-10.md).

How to verify all of it:

- `./gradlew test` with `CS_LIVE_REPO_TESTS=1` (engine, library).
- `make test-core` and `make test-scripts`.
- `make test-client-full` (`scripts/run_full_client_tests.sh`): every client
  and UI test, with every gated tier provisioned. A skipped test fails the run.
- `make build`, then `scripts/smoke_launch.sh --launch "$PWD/dist/CloudStream.app"`.

Status values:

- **Done:** implemented as written.
- **Done (stricter):** implemented in a form the higher-precedence document
  requires; the reason is given.
- **Superseded:** replaced by a stricter item in a higher-precedence document.

Paths are relative to the repository root. Engine tests are under
`engine/src/test/kotlin/com/lagradost/macos/`; client tests are under `client/Tests/`.

## Gates and commits

| Gate | Commit | Contents |
|---|---|---|
| 0: baseline | `67cb745`, `bd8e564` | Uncommitted refactor checkpointed. Audit-Fix Q5 (#6) and M5 (#9) were fixed in the modified engine files before the refactor was committed. |
| 1: worker sandbox, engine trust | `aff62b6` | H1, M2, M4, M5, L1–L6; Audit-Fix Q2–Q4, Q7, M4 |
| 2: IPC and relay | `bee7ab9` | M1, M3; Audit-Fix A1, A2, M1–M3, M6, M7 |
| 3: rendering, persistence | `bee7ab9`, `05bd12f` | Remediation Phases 1–4; Audit-Fix Q1, Q6, Q8, Q9, M8 |
| 4: verification | `05bd12f`, `dfbcb42`, and the commit adding this file | Live tests unskipped and provisioned; LAN egress, external players, `F_FULLFSYNC`, 3.3, RT-17 |

## Security audit

| ID | Status | Implementation | Proof |
|---|---|---|---|
| H1 sandbox escape | Done | `WorkerLauncher.kt` profile denies all TCP/UDP except the egress proxy's loopback port, and denies Unix sockets except mDNSResponder. `WorkerClient.kt` calls `environment().clear()`. `DaemonSupervisor.engineEnvironment` sets an explicit engine environment. LAN: `WorkerEgressProxy.kt` (SOCKS5, public addresses only). | `WorkerIsolationTest`: Unix sockets (H1), loopback (H1), "only through the engine's egress proxy (H1, LAN)", "inherit none of the engine's environment (H1)". `WorkerEgressProxyTest` (3 tests). |
| M1 port squatting | Done | Engine on port `0` announces its port on stdout (`EnginePortAnnouncement`). `/health` answers a nonce with `HMAC(token, nonce)`, so the token is never sent to it (`Main.kt` `proof`). The listener must belong to the child PID (`EngineSocketOwnership`). Credentials are resent only after the proof (`AppState`, `resendAll`). | `EngineHandshakeTest` (5 tests, including a real engine on port 0). `EngineHandshakeTests` (proof, announcement, socket ownership). |
| M2 argv and file probing | Done | sysctl allowlist; `process-info*` limited to self; `file-read-metadata` limited to listed paths. Credentialed downloads go through `MediaRelay`. | `WorkerIsolationTest` "cannot read other processes' command lines or probe for files (M2)"; profile test. `DownloadReliabilityTests.testCredentialedLinksNeverPutHeadersInFFmpegArgv` |
| M3 on-disk cache | Done | `EngineTransport.ipcSession` and `healthSession` (ephemeral, `urlCache = nil`, no proxy). Engine sends `Cache-Control: no-store` (`Main.kt`). `purgeLegacyResponseCache` deletes the old cache at launch. | `EngineHandshakeTest` "every engine response is marked no-store (M3)". `DaemonClientTests.testEngineSessionsAreEphemeralCachelessAndProxyFree` |
| M4 "Verified" is only TOFU | Done | Tiers are "verified" (policy-pinned key), "signed" (key fingerprint shown) and community. Every non-pinned repository needs consent. A signed-only policy needs a pinned key or an allowlist. | `CatalogTrustTest` (3 tests tagged M4) |
| M5 blocklist bypass | Done | URLs are canonicalized with `HttpUrl`; the blocklist matches on host, and policy is checked again at every redirect hop. | `ExtensionPolicyTest` (2 tests tagged M5) |
| L1 secrets in logs | Done | Worker stderr is counted, not stored, unless verbose logging is on. Values are redacted when the log is written; the redactor catches prefixed, JSON-quoted and path-embedded secrets. | `DiagnosticsExportTest` (3 tests), `WorkerPipeTest` stderr test |
| L2 relay and the system proxy | Done | The relay client uses `Proxy.NO_PROXY`; so do the worker egress proxy's connections. | `MediaRelayTest` "never goes through the system proxy (L2)" |
| L3 solved cookies shared | Done | A worker's solved cookies go only to that worker (`SolveBridge.kt`, `task.shared`). | `SolveBridgeTest` "(L3)" |
| L4 Spotlight while locked | Done | `SpotlightIndexer` stops indexing when `requireUnlock` is on. | `SystemIntegrationTests.testGlobalAppLockRemovesAndSuppressesSpotlightIndex` |
| L5 legacy keychain | Done | Items go to the data protection keychain. The file-keychain fallback deletes and re-adds; it never updates an item in place. | `KeychainOwnershipTests.testAPreCreatedItemIsReplacedNotWrittenInto` (real keychain) |
| L6 `requireSandbox` default | Done | Sandbox required unless an organization turns it off. Without an explicit opt-out, an unsandboxed worker never starts. | `ExtensionPolicyTest` "(L6)"; `WorkerIsolationTest` "(L6)" |
| Note: owner-only engine files | Done | `CloudDirs` creates 0700 folders and 0600 files; the audit log is 0600. | `DiagnosticsExportTest` "owner-only" |
| Note: documentation drift | Done | `Security.md` gives the 15-minute relay idle time; `ipc-api.md` describes manifests as rewritten, with 415 only for inexpressible ones. | — |
| Note: dev builds lack the hardened runtime | Done | `lib_artifact.sh sign_bundle` signs every build with `--options runtime`; Developer ID builds also get a timestamp. | `make build` + smoke launch |
| Note: TMDB key; `NSAllowsArbitraryLoads` | Documented | Both are accepted exposures, with reasons, in `Security.md` (Accepted exposures). | — |

## Audit-Fix Plan

| ID | Status | Implementation | Proof |
|---|---|---|---|
| Q1 failover | Done | `failover` returns whether the load was issued; `skipUnloadable` passes that through. | `MediaResourcePolicyTests.testFailoverReportsWhetherTheLoadWasIssuedAndKeepsALastMirrorsFailure`; `PlayerFeatureTests.testBufferingWhileLoadingIsNotAStallAndFailoverIsAnnounced` |
| Q2 recovery gate | Done | `/lock` and download routes are exempt from the recovery gate. | `DaemonLockTest` "…not the lock or download routes (Q2)" |
| Q3 HEAD on a manifest | Done | Answers 200 with the manifest type. | `MediaRelayTest` "(Q3)" |
| Q4 ResourceTable bounds | Done | Bounds are checked; a malformed table throws `IllegalArgumentException`. | `ResourceTableTest` "(Q4)" |
| Q5 icon URL fails a sync | Done | Never resolves a host name; only strict literals count; failures are per entry. | `CatalogEntriesTest` (3 tests) |
| Q6 DASH labelled as a file | Done | `dash+xml` MIME type and an `<MPD` sniff in the first 512 bytes hand the link to ffmpeg. | `DownloadReliabilityTests.testDASHManifestsLabelledAsFilesAreNotDownloadedDirectly`, `testDASHManifestServedAsFileIsHandedToFFmpeg` |
| Q7 admission busy loop | Done | `delay` instead of `yield` while waiting for admission. | `WorkerAdmissionTest` "a start is refused only after waiting…" |
| Q8 repeated import banner | Done | `OncePerGeneration` (`Services/Contracts/OncePerGeneration.swift`), used by `AppState`. | `SystemIntegrationTests.testLegacyImportFailureIsShownOncePerEngineGeneration` |
| Q9 progress-save banner spam | Done | Periodic failures are logged; the error is shown once per session. | `PlayerFeatureTests.testPeriodicProgressFailuresAreReportedOncePerSession` |
| M1 streams without `done` | Done | `consumeEvents` reports `done`; a stream that ends without it throws `streamEnded`. | `DaemonClientTests` (3 tests) |
| M2 failed final rename | Done | `finalizeFailed` keeps the part file and persists the item as `finalizing`; Retry and relaunch complete the rename. | `DownloadReliabilityTests.testFailedFinalRenameKeepsThePartAndRetryCompletesIt`, `testFailedFinalRenameIsReconciledAtTheNextLaunch` |
| M3 cross-origin redirects | Done | Credentials are stripped when a redirect changes origin; Range is kept. | `DownloadReliabilityTests.testCrossOriginRedirectsDropCredentialsButKeepRangeHeaders` |
| M4 worker exit race | Done | Checks `exited` after registering a call; the exit handler drains a snapshot of pending calls. | `WorkerPipeTest` "(M4)" |
| M5 capacity wait | Done | `waitForCapacity`; nested extraction is refused at once; default wait is 10 s. | `WorkerAdmissionTest` (2 tests) |
| M6 relay session leaks | Done | Shielded registration; stale sessions are revoked; a never-read session is evicted after 10 s. | `MediaRelayTest` "(M6)"; `MediaResourcePolicyTests.testRapidRelayedMirrorSwitchesLeaveAtMostOneLiveSession` |
| M7 keep-alive after an engine restart | Done | `engineReconnected` restarts the verifier. | `PlayerFeatureTests.testEngineRestartRestartsTheKeepAliveWithoutStoppingTheOldJob` |
| M8 Keychain on the main actor | Done | `resendAll` reads in `Task.detached(priority: .utility)`. | `SystemIntegrationTests.testCredentialResendReadsTheKeychainOffTheMainActor` |
| M9 random port unchecked | Superseded (Security M1) | Port `0` plus the stdout handshake replaces picking a free port. | as M1 |
| A1 dedicated IPC pools | Done | `ipcSession` (24 connections) and `healthSession` (2 connections, 5 s timeout); slow probes logged as `daemon.health_slow`. | `DaemonClientTests.testEngineSessionsAreEphemeralCachelessAndProxyFree` |
| A2 credentialed manifests | Done (stricter) | Any link with credential headers goes through the relay, for downloads and for playback (decision 2 settled by Security M2). Fails closed with `relayUnavailable`. `MAX_SESSIONS` is 12. | `DownloadReliabilityTests.testCredentialedHLSDownloadsThroughTheRelayWithoutCredentialsInArgv`, `testCredentialedDownloadFailsClosedWhenTheRelayIsUnavailable` |
| Deferred #22 `F_FULLFSYNC` | Done | `FullFsync.java` uses the JDK 17 foreign-function API; `AtomicFiles` calls it after every commit. | `FullFsyncTest` |
| Deferred #21, minor items | Deferred as the plan says | No caller passes `plugins` today. | — |

## Remediation Plan

| Item | Status | Implementation | Proof |
|---|---|---|---|
| Phase 0 baseline | Done | See Gate 0 above. | — |
| 1.1 shimmer CPU burn | Done | `SkeletonShelves` pulses only while on screen in an active window, and stops after `maximumPulses`. | Code review: `HomeView.swift` `SkeletonShelves` |
| 1.2 full-screen insets | Done | Safe-area handling only in `RootView`; the duplicate in `MediaDetailView` was removed. | UI suite: `SidebarNavigationUITests` |
| 1.3 hero placeholder | Done | `MediaDetailView.HeroArtwork`: backdrop 580 pt, lone poster over a blurred copy, no artwork collapses to a 260 pt gradient. | `DetailsHeroTests` |
| 1.4 stale lock | Done | `StaleEngineReaper`: `kill(pid, 0)`, then SIGTERM, then SIGKILL. | `EngineLifecycleTests.testAnOrphanedEngineHoldingTheLockIsStoppedOnceThenTheEngineStarts`, `testOrphanReapIsAttemptedOnlyOncePerStart` |
| 2.1 single-source ticks | Done | Display-link ticks render only when `frameAvailable` is set; immediate dispatch only when the link is paused. | `PlayerEngineLiveTests` (24–40 frames/s presented for a 30 fps source); benchmarks |
| 2.2 non-blocking fences | Done | `gl_surface.c` polls the previous frame's fence with a zero timeout and uses `glFlush`; `BLOCK_FOR_TARGET_TIME = 0`. | `PlayerEngineLiveTests.testRenderTeardownAndReplacementGenerationStayIndependent`; playback cost tests |
| 3.1 absolute DASH URLs | Done | `ManifestRewriter` relays absolute segment URLs and templates. | `MediaRelayTest` "(Remediation 3_1)" |
| 3.2 `data` protocol | Done | `ffmpegProtocolWhitelist` includes `data`. | `DownloadReliabilityTests.testWhitelistRefusesLocalFileInput`; DASH live test |
| 3.3 headers to sub-demuxers | Done | Each file gets `demuxer-lavf-o` with a length-prefixed `headers=` value (`MetalVideoView.demuxerOptions(headers:…)`). Credential headers never reach it because those streams are relayed (Security M2). | `MediaResourcePolicyTests.testRequestHeadersBecomeALengthPrefixedPerFileDemuxerOption`; `PlayerEngineLiveTests` HLS and DASH: every header on every request, none repeated |
| 4.1 merged sources in queries | Done | `mergedIntoID == nil` in `items(withWatchType:)` and `counts()`. | `MergedTitlesTests.testAMergedSourceThatKeepsItsOwnStatusIsNeverShownOrCountedTwice` |
| 4.2 canonical title dedup | Done (stricter) | Merged in storage rather than grouped in the view. `LibraryStore.strongMatchKey` (normalized title, year, type) merges at every launch and save; the most recent source is the primary; the others are listed in the details source switcher (`titleSources`). In-memory grouping could not fill that switcher. | `MergedTitlesTests.testStrongMatchesMergeIntoOneTitleAndShowOnce`, `testWeakMatchesAreNeverMergedAutomatically` |
| 4.3 legacy duplicates | Done | Unresolved records are marked `legacy_unresolved`. A legacy twin with the same provider URL is bound when it is used through its only provider. | `IdentityMigrationTests.testALegacyTitleUsedThroughItsOnlyProviderIsBoundInsteadOfDuplicated`, `testALegacyTitleIsNotBoundWhenTheNameIsAmbiguousOrAnotherProviderIsUsed` |
| 5.1 response body leaks | Done | `ResponseTracker` interceptor reclaims bodies left open when an operation ends; pool of 5 idle connections, 30 s keep-alive. | `ResponseTrackerTest`; engine suite shows 0 "connection leaked" warnings |
| 5.2 worker recycling | Done | Idle workers over 256 MB resident memory, or idle for 5 minutes, are retired; a busy one never is. | `WorkerAdmissionTest` "(Remediation 5_2)" |
| 6.1 live tests in make | Done | `make test-live-player`, `make test-player-bench`, and `make test-client-full`, which `make test` uses. | — |
| 6.2 regression tests | Done | The absolute-URL DASH manifest test and the `mergedIntoID` query test above. | — |

## Live tiers provisioned by `make test-client-full`

| Tier | Provisioning |
|---|---|
| `CS_MPV_ENGINE_TESTS` | `scripts/make_player_fixtures.sh` (media in `/tmp`) |
| `CS_LARGE_LIBRARY_TESTS` | none needed |
| `CS_MPV_BENCH`, `CS_BENCH_BASE(_NORANGE)`, `CS_YT_DIR` | `scripts/lib_bench_media.sh`: media in `/tmp/cs-bench`, two local CDN simulators |
| `CS_LIVE_PLAYBACK_TESTS` (RT-17) | `LocalMediaLinksTest`: the Android-compiled `local-media.cs3` extension runs in a sandboxed worker and its links are exported to `/tmp/cs_live_links.json`. Every exported link must play. |
| Identity compatibility | `scripts/tests/build_legacy_identity_fixture.sh` and a separate debug app process |
| UI tests | the `CloudStreamMacUITests` bundle in the same run |
