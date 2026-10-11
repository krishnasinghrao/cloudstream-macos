# Extensions & Repositories — Remediation Plan

Status: in progress — P0–P6 implemented, P7–P8 largely implemented, P9 open. Fact-checked against the code on 2026-09-30 (see "Status and corrections" below). Owner: macOS team.
Inputs:
- `audit/extensions-repository/REPORT.md` (F01–F37)
- `audit/extensions-repository/fact-check/FACT-CHECK.md` (C01–C04, N01–N10)
- `audit/extensions-repository/second-fact-check/FACT-CHECK-2.md` (G01–G07)
- `audit/extensions-repository/android-comparison/COMPARISON.md`

**Goal:** a macOS extensions system that is clean, secure, robust, production-ready and enterprise-grade. It should match Android's functionality while keeping the macOS design advantages (authenticated catalogs, mandatory digests, transactional state and staged publication), and fix the areas where macOS is weaker (updates, revocation, safe mode, compatibility, OS isolation, UI).

`REMEDIATION.md` remains the status ledger. This document is the plan it tracks. Every ledger row must name the task(s) below and the passing test(s) that prove it.

**Runtime follow-up, 2026-10-01:** the [Extensions Runtime Implementation Plan](Extensions-Runtime-Implementation-Plan.md) covers the fifteen newly verified runtime/Android compatibility findings. Its RT tasks extend the implemented lifecycle/isolation work and propose replacing the mandatory-publisher-digest and blanket resource-rejection decisions for broader compatibility. The status below describes the earlier remediation scope; it does not certify community playback or complete Android host compatibility.

---

## Status and corrections (fact-check, 2026-09-30)

Verified by reading the code and running the suites (latest): daemon **239 tests, 0 failures, 2 live tests skipped**; client unit tests **277, 0 failures, 23 skipped**; UI tests `ExtensionsUITests` and `SidebarNavigationUITests` passing. "Done" below means the daemon enforces it and a normal-suite test asserts it; ground rule 1(d) (UI tests) is met only where T9.2 lists coverage.

Where the implementation deliberately differs from the task text, the task text below the table is **superseded by this table**.

| Task | Status | Evidence / correction |
|---|---|---|
| T0.1 | Done (partial by necessity) | Annotated tag `extensions-audit-baseline` (in the original CloudStream fork, not this repository) archives the pre-remediation copy; `verify_audit_baseline.py` there confirms it reproduces **21/29** reviewed files. The reviewed versions of the other 8 (six client files, daemon `Main.kt`, `Security.md`) were never committed or captured and cannot be rebuilt |
| T0.2, T0.5, T0.6, T0.7 | Done | `FakeRuntime`, route harness in `ExtensionRoutesTest`, d8-built fixtures (`fixture`, `multidex`, `failing`, `resources.cs3`) |
| T0.3 | Done | Live test uses consent; nightly `live-repositories` CI job opens an issue on failure |
| T0.4 | Superseded | Probes stay historical evidence under `docs/audit` and are not compiled; they are expected to fail where behavior was fixed |
| T0.8 | Done | Ledger rewritten against this table |
| T1.1–T1.2 | Done, design changed | Consent is per repository URL with its source (`user`/`migration`); it is **not** bound to a catalog digest. Instead every community receipt's proof stores the exact list bytes it was installed from. Route is `POST /repos/consent {repoUrl, allow}`. Withdrawing consent blocks new installs and updates; installed community extensions keep running until uninstalled |
| T1.3–T1.7 | Done | `CatalogTrustTest`, `InstallationLifecycleTest` (community, hashless, migration), `RepositoryMigrationTest`; docs updated |
| T2.1–T2.4, T2.6, T2.8–T2.10 | Done | Route tests in `ExtensionRoutesTest`; CI grep guard for deleted APIs; IPC v4 |
| T2.5 | Done, codes changed | Codes are those in `ipc-api.md` (`untrusted` covers digest/signature failures, `operation_conflict` replaces `operation_in_progress` because operations on one installation wait rather than being rejected, T3.1) |
| T2.7 | Done | `Main.kt` 245 lines; routes in `ExtensionRoutes.kt` and `MediaRoutes.kt` |
| T3.1–T3.7, T3.10–T3.13, T3.15, T3.17, T3.18, T3.20–T3.22 | Done | `InstallationLifecycleTest`, `ArtifactIntegrityTest`, `VerifierJobsTest`, `PluginBridgeTest`. T3.6/T3.7: repository removal now removes the repository before uninstalling so a racing install cannot survive (`FactCheckRegressionTest`) |
| T3.8 | Done | A same-version artifact with a different digest is offered as a normal update (no separate "republished" flag) |
| T3.9 | Done, shape changed | No `GET /updates`: update state is on `/plugins` (`updateAvailable`) and `/repos/plugins` (`updateState`). `BackgroundRefresh` syncs top-level repositories 30 s after start and every 6 h, then auto-updates when enabled; the client polls every 30 min and posts one notification per refresh that updated something |
| T3.14 | Done | JAR cache key is `sha256(sourceDigest + TRANSLATION_PROFILE)`; the profile string carries the stub ABI version. dex2jar output is not byte-reproducible for some methods (verified), so the receipt records the digest of the translation actually produced |
| T3.16 | Done, simplified | A cached JAR whose digest differs from the receipt is rebuilt from the verified source every time; no quarantine is needed because the source bytes are verified on each load |
| T3.19 | Done, amended | Leases drain for at most 30 s, then `beforeUnload` runs. Retirement marks the generation first; a lease taken afterwards (including through a stale provider reference) is refused, so no call runs on a retired generation (`ProviderIdentityTest`). There is no `classLoader.close()`: `VerifiedClassLoader` holds only in-memory bytes; in worker mode the worker process is stopped |
| T4.1, T4.3, T4.5 | Done | T4.3 is covered by a unit test that leaves a loading marker; a subprocess kill test belongs to T9.4 |
| T4.2 | Done | Worker mode: restore registers stubs without running extension code; loads happen in workers with a 60 s init deadline and kill. In-process mode keeps the 20 s soft deadline |
| T4.4 | Done, amended | Safe mode: hold ⌥ at launch, Settings → Advanced → Restart in Safe Mode, managed `ExtensionsSafeModeOnly`, or two engine crashes within 60 s. No `--safe-mode` flag or marker file |
| T4.6 | Done | Polling starts before bootstrap (verified in `AppState`); `ChallengePathTest` drives a Cloudflare-style challenge against a local HTTPS server through the in-process path and the worker → engine path |
| S5.0, T5.1 | Replaced | Superseded twice: ADR-0015 confined the whole engine; ADR-0016 moves every extension into its own sandboxed worker. Nested sandboxing is impossible on macOS (verified), so the engine (first-party code only) is not sandboxed. Whole-app App Sandbox was not spiked. `allow-dyld-environment-variables` removed from `java.entitlements` |
| T5.2–T5.7 | Done | ADR-0016. T5.2 design; T5.3 `WorkerExtensionRuntime` behind the existing `ExtensionRuntime` seam, `RemoteProvider` stubs, lazy start from receipt descriptors, 8-worker cap, 10-minute idle stop; T5.4 hard deadlines (budget + 2 s, cancel, kill after 3 s); T5.5 256 MB heap, exit on OOM, 2 processors, 3-crashes-per-hour quarantine; T5.6 per-worker sandbox (own home, one artifact, outbound network only); T5.7 solver, configuration and network settings over the channel. `WorkerIsolationTest` (real JVMs; stable over repeated runs) and a live end-to-end run with two community extensions (install, search, details, links, restart with lazy restore). Packaging self-test boots a sandboxed worker on the bundled runtime |
| T6.1–T6.5 | Done | Saved library/download items migrate lazily: each gains a `providerID` when its details next load; until then a bare name resolves only when exactly one provider has it (`ProviderIdentityTest`). Provider IDs on all DTOs; provider-level enable; URL overrides persist, credentials are memory-only (Keychain on the client) and are accepted before an extension finishes loading; per-installation `Context`/preferences; `AndroidStubConformanceTest` |
| T6.7 | Done | The d8-built fixture declares main-page requests; `PluginBridgeTest` and `WorkerIsolationTest` verify them in-process and in a worker |
| T6.6 | Done | `VideoClickAction` registration is accepted and reported as an unsupported feature |
| T7.1–T7.5 | Implemented, untested UI | Status chips, tier badges, catalog search/type/language filters, details, repository status, Sync All, consent, re-trust with fingerprints, Update All, auto-update, notification. Catalog sort by name or catalog order. Store logic has XCTests; no UI tests (T9.2) |
| T7.6 | Implemented, untested UI | Onboarding offers Choose Extensions and Set Up Later |
| T7.7 | Partial | Trust-tier, consent, safe-mode and sandbox-fallback copy checked against behavior; no full copy review |
| T7.8 | Done (manual pass pending) | Decorative icons hidden from VoiceOver; icon-only controls labeled; `performAccessibilityAudit` gate in `ExtensionsUITests` fails on any unexplained issue (ignored: SwiftUI-generated containers, the borderless `Menu` "action missing" report, and app-wide sidebar contrast, which is outside the extension screens); checklist in `qa-ui-checklist.md` for the manual VoiceOver pass |
| T8.1 | Done, transport changed | Policy travels in the launch-options stdin line (not a `/policy` route), is fixed for the process, and fails closed when missing, malformed or of the wrong type. Keys are prefixed `Extensions` (see `Security.md`); `ExtensionsRequireSandbox` and `ExtensionsAllowDeveloperExtensions` added |
| T8.2 | Done | Hash-chained `AuditLog`; `GET /extensions/audit`; exported from Settings → Advanced → Export Diagnostics… with its chain-verification result (T8.5) |
| T8.3 | Done | `tools/RepositorySigner` (`keygen`, `sign`) verified by the production verifier; `RepositorySignerTest` |
| T8.4 | Done | `:engine:sbom` (CycloneDX, purl + SHA-256 per dependency), CI artifact, and `tools/sbom.cdx.json` in the app including the bundled runtime. Gradle dependency verification metadata is not enabled (it applies to the whole multi-module build) |
| T8.5 | Done | `GET /diagnostics/export` + Settings → Advanced → Export Diagnostics…; redacts URL userinfo/query, auth headers, key=value secrets and sensitive keys (`DiagnosticsExportTest`) |
| T9.1 | Done | Every acceptance gate is mapped to its tests in `REMEDIATION.md` → Acceptance gates; gates that need external systems are marked as such |
| T9.2 | Done (repository flows external) | `ExtensionsUITests` (isolated data root, real engine and sandboxed worker, no network): Extensions sections and Add Repository sheet; install (via the Debug-only developer-import hook), enable, disable and uninstall; safe mode entered from Settings and left from the banner; automated accessibility audit gate. Found and fixed: safe mode pushed the whole UI off-screen; developer rows claimed "repository removed"; version -1 shown as "v-1". Browsing and installing from a live HTTPS repository in the UI remains external (the engine rejects local repository hosts by design) |
| T9.3 | Done (engine) | `PerformanceBudgetTest` with 100 installed: `/plugins` 4 ms (was 114 ms before per-request catalog memoization), catalog 5 ms, `/health` 1 ms during a slow restore; worker cold search 2.0 s end to end. UI rendering budgets belong to T9.2 |
| T9.4 | Done (state) | `StateCrashConsistencyTest` SIGKILLs a writer mid-commit 20 times: state always loads, never goes backwards; interrupted temp files are cleaned on load (verified to fail without the fix). Duplicate daemon: `DataRootLock` test. Network partitions are covered by transport tests |
| T9.5 | Partial | `ParserFuzzTest` (repository JSON, signed manifests, catalog lists, worker frames); found and fixed acceptance of unknown `signature` members. Threat-model update done in `Security.md`; external review not done |
| T9.6 | Partial | Packaging self-test boots a sandboxed worker on the bundled runtime. **Upgrade verified** with the real pre-remediation daemon built from `extensions-audit-baseline` (v1.1.0, IPC v2): it installed a live community extension; the new daemon on that data root migrated state v1 → v2, recorded the cached artifact as legacy, adopted it on the first repository sync (consent recorded as `migration`) and ran it in a sandboxed worker with identical search results. Remaining: notarized DMG (needs release credentials) |
| T9.7 | Done (review pending) | `Architecture.md`, `ipc-api.md` v4, `Security.md`, `repository-signing.md`, ADR-0015, user help page `docs/help/extensions.md` |
| D5 | Done | Developer tier: Settings → Advanced toggle (off by default), Install from File…, imports start disabled, unload when developer mode is turned off, `ExtensionsAllowDeveloperExtensions` policy key and repository allow-lists block it (`DeveloperExtensionTest`, `ExtensionsStoreTests`) |

---

## 0. Ground rules (apply to every task)

1. **Definition of done.** A task is done only when all of these hold:
   - (a) The invariant is enforced in the daemon, not only in the UI.
   - (b) A normal-suite test asserts the *correct* behavior.
   - (c) The route/IPC contract is covered by a route test.
   - (d) The client path is covered by an XCTest or UI test where the user can reach it.
   - (e) `docs/ipc-api.md`, `docs/Security.md` or `docs/repository-signing.md` are updated where affected.
   - (f) The ledger row cites the test names.

   A characterization probe that "passes" is never evidence of a fix.
2. **CI stays green.** The daemon suite and Swift tests must pass on every merge. Skipped live tests must not hide broken expectations (see T0.3).
3. **One model.** New work goes through `InstallationManager` / receipts. No new callers of the legacy hash-keyed APIs. Those APIs are deleted in T2.6.
4. **Fail closed, recover visibly.** Every security or integrity failure produces a persisted, user-visible state (with retry, uninstall or quarantine), never a silent disappearance.
5. **No plugin callback under a registry lock.** No plugin code runs inside `ExtensionLifecycle.locked`, and no network I/O either.
6. **Size key:** S ≤ 1 day, M ≤ 3 days, L ≤ 2 weeks, XL > 2 weeks (one engineer).

---

## Phase overview

| Phase | Theme | Outcome | Depends on | Size |
|---|---|---|---|---|
| P0 | Baseline & guardrails | Green CI, reproducible evidence, test harnesses | — | M |
| P1 | Trust policy & ecosystem access | Existing repositories usable under an explicit policy; legacy installs migrated | P0, **decision D1** | L |
| P2 | Route/client wiring & cleanup | Installed list, toggle, uninstall, errors and update action work end to end; legacy code removed | P0 | M |
| P3 | Lifecycle correctness | Updates, revocation, key rotation, removal, GC, bytecode integrity, concurrency edge cases | P2 | L |
| P4 | Startup resilience | Health first, background restore, safe mode, quarantine | P3 | M |
| P5 | Isolation & resource governance | Sandboxed daemon, then isolated killable plugin workers with budgets | P4, spike S5.0 | XL |
| P6 | Identity, configuration & compatibility | Stable provider IDs, Keychain secrets, durable prefs, ABI conformance | P2 (P5 for the final worker shape) | L |
| P7 | UX parity & polish | Catalog filters, details, notifications, re-trust UX, repository status, onboarding | P2, P3 | M |
| P8 | Enterprise controls | Managed policy (MDM), audit log, publisher tooling, SBOM | P1, P3 | L |
| P9 | Release verification | Packaged/notarized, UI automation, scale, security review, docs | all | M |

P0–P2 are the critical path to a usable product. P5 is the critical path to any "secure" or "enterprise" claim. P6 and P7 can run in parallel with P3–P5 once P2 lands.

---

## Decisions required before P1

| ID | Decision | Options | Recommendation |
|---|---|---|---|
| **D1** | Trust policy for unsigned community repositories (G01) | (a) Signed-only (current). (b) Two tiers: signed = *Verified*; unsigned = *Community*, allowed only after explicit per-repository consent, digest mandatory, badged, blockable by policy. (c) App-operated signed mirror of vetted extensions | **(b)**, with (c) as a later option. It matches REPORT F15's remedy and Android parity without weakening the verified tier. (a) only for a curated/enterprise build, selectable by policy (P8) |
| D2 | Legacy install migration | (a) Auto-convert cached pre-receipt artifacts that match a current catalog digest. (b) Notify and offer one-click reinstall | **(a) then (b)** for anything that cannot be matched |
| D3 | Isolation granularity | One sandboxed daemon · one worker per trust tier · one worker per extension | Sandbox the daemon first (P5.1), then **one worker per extension** with pooling limits (P5.3) |
| D4 | Resource-dependent extensions (`requiresResources`) | Support via packaged resource extraction · reject with a clear message | Reject explicitly now (P6.5); revisit after P5 |
| D5 | Local/developer extension import | None · developer mode only · general | Developer mode only, behind a setting, Community tier, never auto-enabled |

---

## P0 — Baseline & guardrails

| Task | Work | Files | Acceptance |
|---|---|---|---|
| T0.1 Archive audited baseline | Copy `/var/folders/.../cloudstream-extensions-baseline-gtvfazpf` into a tag or branch `audit/extensions-baseline`, including the client files recovered from the original fingerprints where available | git | Tag exists; `reviewed-source-sha256.json` hashes verified against it by a script |
| T0.2 Green suite | Delete or rewrite `ReviewFixRegressionTest."getRepoPlugins flags update when loaded hash differs from pinned hash"` to assert receipt-based `isUpdateAvailable`. Remove `PluginBridge.loadedPluginsSha256OverrideForTest` | `ReviewFixRegressionTest.kt`, `PluginBridge.kt` | `./gradlew :engine:test` passes; CI `macos.yml` green |
| T0.3 Honest live tests | Rewrite the skipped `RepositoryServiceTest` live install to match the D1 policy (Community tier consent), and run it in a nightly job with `CS_LIVE_REPO_TESTS=1` | `RepositoryServiceTest.kt`, `.github/workflows/macos.yml` | Nightly job exists; failures open an issue |
| T0.4 Fix probes | Add `Unit` to `CurrentReviewProbe` (JUnit void rule). Document that probes are expected to *fail* once fixed | `current-review/CurrentReviewProbe.kt` | Probe class runs |
| T0.5 Lifecycle test harness | A `FakeRuntime` (prepare/publish/discard/remove counters, injectable failures and latches) and a `SignedCatalogFixture`-based receipt builder in the normal test tree (promote from the probe) | `src/test/.../LifecycleFixtures.kt` | Used by all P3 tests |
| T0.6 Route test harness | Reusable embedded-Netty test app with a bearer token and JSON helpers (promote from the probe) | `src/test/.../RouteHarness.kt` | Used by all P2 route tests |
| T0.7 Real-DEX fixture | Build a tiny Android-compiled `.cs3` (one `MainAPI`, one extractor, multi-DEX variant) once and commit it under `src/test/resources`, signed with a test key | test resources, a script in `scripts/` | Test loads it through real dex2jar |
| T0.8 Ledger hygiene | Rewrite `REMEDIATION.md` statuses per `FACT-CHECK-2.md` §2. Each row links to plan tasks and tests | `REMEDIATION.md` | Reviewed |

---

## P1 — Trust policy & ecosystem access (G01, F15 remedy, D1, D2)

**Target model:**

```
Repository.trustTier = VERIFIED | COMMUNITY
VERIFIED  : signed chain (current CatalogTrust); installs require fresh evidence
COMMUNITY : unsigned catalog; user consent recorded per repository URL + first-seen catalog digest;
            artifact SHA-256 still mandatory; HTTPS transport rules unchanged;
            receipts carry tier; UI badge "Community — not verified by a publisher key"
Policy (P8) may disable COMMUNITY entirely.
```

| Task | Work | Acceptance tests |
|---|---|---|
| T1.1 Tier model | Add `trustTier` and `consent` (`consentedAt`, `catalogDigestAtConsent`) to `PersistedRepository`. Add `tier` to `InstalledExtension` and `InstallationProofStore.Proof` (unsigned proof = exact list bytes + URL + consent record, content-addressed). Bump the state schema version with a migration | State migration test (v1 → v2) round-trips; unknown future version enters recovery |
| T1.2 Consent flow | New `POST /repos/consent {repoUrl, catalogDigest}`. Install of a Community extension requires existing consent. A pinned (Verified) repository can never drop to Community (keep the F14 guarantees) | Route tests: install without consent → 403; with consent → OK; signed→unsigned still rejected |
| T1.3 Community install path | `InstallationManager.install` accepts a Community catalog: entry must have a valid `fileHash`; entries without one are shown but not installable | Hashless entry → blocked reason; hash mismatch → rejected, nothing committed |
| T1.4 Catalog projection | `getRepoPlugins` returns `trustTier`; `installationBlockedReason` distinguishes "needs consent", "no digest", "publisher disabled" and "stale signed catalog" | Unit tests per reason |
| T1.5 Client | Consent sheet (repository URL, tier explanation, extension count). Badges in repository and installed lists. Onboarding "Choose Extensions" leads to installable entries | XCTest on `ExtensionsStore` consent state; UI test T9.2 |
| T1.6 Legacy migration (D2) | One-time `migration: cache-to-receipts-v1`. For each `cs3/<hash>.cs3` without a receipt: if exactly one current catalog entry (any tier, consent implied for repositories the user already had) has that digest, create a receipt (tier from the repository). Otherwise record it in `unmatchedLegacyArtifacts` and surface "Reinstall N extensions" | Migration tests: match, ambiguous match (two repositories), no match; idempotent re-run; runs offline |
| T1.7 Docs | `repository-signing.md`: tiers, consent, publisher guidance. `Security.md`: accurate claims | Doc review |

---

## P2 — Route/client wiring & cleanup (G02, F25, F26 wiring, N03, F01, F37, F34)

| Task | Work | Acceptance tests |
|---|---|---|
| T2.1 `GET /plugins` | Return `RepositoryService.installedPlugins()`: receipt metadata (installed version, tier, verified from proof), `loaded` state, `lastError`, providers from the receipt, `mainUrl` from the live generation. Never expose filesystem paths | Route test: installed, not-loaded, disabled and revoked records all listed with correct fields; no `/` in `internalName` |
| T2.2 Enable/disable | `POST /plugins/setEnabled {installationId, enabled}` → `InstallationManager.setEnabled`. Unknown ID → 404. Remove the name-based fallback that writes arbitrary strings into `disabledProviders`. Provider-level disable moves to T6.1 | Route test: disable unloads and persists `enabled=false`; restart does not load; enable loads once |
| T2.3 Uninstall/retry | `POST /plugins/uninstall {installationId}` only. New `POST /plugins/retry {installationId}` → `restore` with error capture | Route tests; unloaded receipt can be retried or uninstalled |
| T2.4 Update action | `POST /plugins/update {installationId}` → install of the latest catalog entry for the same key. Client shows an **Update** button when `isUpdateAvailable`, in both catalog and installed lists | Route test; XCTest for button state |
| T2.5 Error model | Typed error codes (`consent_required`, `digest_mismatch`, `revoked`, `operation_in_progress`, `recovery_required`, …) instead of free text; HTTP statuses consistent (409 for in-progress, 403 for policy/security, 404 unknown) | Contract tests; Swift decodes all codes |
| T2.6 Delete legacy surface | Remove `PluginBridge.getAllPlugins`, `findLoadedByInternalNameOrManifest`, `isLoaded`, `loadPluginFromCs3`, `RepositoryService.pluginMetadataFor`, `isArtifactAuthorizedToLoad`, `catalogPluginForInstall`, `allKnownPlugins` (if unused), `removedPluginHashes` + `DaemonState.markPluginRemoved/unmark/isPluginRemoved` (state migration drops the field) | Compiles; no references; grep check added to CI |
| T2.7 Thin routes | Move handler logic from `Main.kt` into `ExtensionRoutes.kt` / `RepositoryRoutes.kt` that only validate, call services and map errors | `Main.kt` < 300 lines; route tests unchanged |
| T2.8 Client store | `ExtensionsStore` uses installation IDs everywhere; per-target operation state instead of the single global `mutation` gate (independent rows can operate concurrently; the daemon serializes per ID); reconcile via refresh after every mutation (already present) | XCTests: concurrent toggles on two rows; stale response rejection; daemon restart mid-mutation |
| T2.9 Remove Swift preference authority (F01) | Confirm no remaining reads of `UserPreferences.repositoryURLs` outside the one-time import; delete the property after migration | Grep check; XCTest for import idempotence |
| T2.10 IPC contract | `ipc-api.md` → Contract v4, with the changes listed; bump `HealthDto.IPC_VERSION`; client refuses mismatched daemons with a clear message | Version-mismatch test |

---

## P3 — Lifecycle correctness

### 3A. InstallationManager semantics (G04, F06, F07, F09, F20)

| Task | Work | Acceptance tests (all using T0.5) |
|---|---|---|
| T3.1 Per-ID operation queue | Replace the `active` map token with a per-installation serialized queue (`Mutex` per ID held for the duration of the operation, *not* the global lifecycle lock). Operations: install/update, enable, disable, uninstall, restore, revoke. Later operations wait or are rejected with `operation_in_progress` (no silent cancellation) | Toggle during update → update completes, toggle applies after. Uninstall during first install → install is cancelled before commit **or** uninstall runs after commit; never "lost" |
| T3.2 Idempotent enable | `setEnabled(true)` on a loaded, current generation is a no-op | Prepare count stays 0 |
| T3.3 Re-install of committed-but-unloaded | Same version + not loaded → restore instead of early return | Probe scenario now loads |
| T3.4 Restore rechecks | Inside the publish lock, recheck record, anchor/consent and revocation | Anchor change during prepare → not published |
| T3.5 Failure-path tests | Publish throws → old generation still serving and state rolled back. Prepare throws → nothing committed. Commit write fails → recovery mode and no publish | Tests for each branch |
| T3.6 Repository removal | `removeRepository(keepInstallations)` explicit in the API/UI ("Remove repository and its N extensions" vs. "keep installed"); kept installations retain provenance and show "repository removed" | Route + UI tests |
| T3.7 Sync vs. remove/install (F09) | Sync commits check a per-repository revision counter; removal bumps it; removal of a repository with in-flight installs waits on T3.1 queues | Interleaving tests with latches |

### 3B. Updates (F04, Android parity)

| Task | Work | Acceptance |
|---|---|---|
| T3.8 Version policy | `isUpdateAvailable` when catalog `version > installed.version`, or `version == -1` with a different digest, or same version with a different digest (flag as "republished"). Downgrades rejected unless the user explicitly chooses "Install older version" | Unit matrix |
| T3.9 Update all / auto-update | Daemon job: after a successful sync, compute updates; if the user setting (or policy) allows, update sequentially with per-extension results. `GET /updates` for the UI. Notification via the client (`UNUserNotificationCenter`) | Integration test with two catalogs and revisions |
| T3.10 Last-known-good | Keep the previous generation's artifact and receipt as `previous` for one-click rollback | Rollback test |

### 3C. Revocation & key rotation (G03, F05, F15 lifecycle, G04 rotation)

| Task | Work | Acceptance |
|---|---|---|
| T3.11 Remote-down revocation | On every successful sync, for each receipt from that repository: if the catalog marks its internal name `status == 0`, or the entry vanished and the policy says to revoke, set `revokedReason`, unload, and block restore. Clear it when the status returns to 1/2 (the user re-enables) | Signed and Community tests; restart keeps it revoked |
| T3.12 Key rotation re-proof | Successful `reTrust` re-validates each receipt against the new catalog: same digest → issue a new proof under the new key; digest differs → mark `needs_update`; missing → mark `revoked: removed from catalog` | Tests; no silent disappearance |
| T3.13 Status consistency | HTML aggregate keeps statuses 1 and 2 like the direct path (G07) | Unit test |

### 3D. Artifacts & bytecode (F08, F12, G05)

| Task | Work | Acceptance |
|---|---|---|
| T3.14 Translation cache key | JAR path = `sha256(sourceDigest + translatorVersion + stubAbiVersion)`; stub ABI version is a constant bumped whenever `android/*` stubs change | Changing the constant forces retranslation |
| T3.15 Atomic, single-flight translation | Translate into a unique temp file, then `AtomicFiles` move. A per-digest mutex so concurrent prepares share one translation; never delete a published file on failure | Concurrency test with two prepares |
| T3.16 JAR authentication | Record each JAR's SHA-256 in the receipt (list for multi-DEX) at prepare time; verify before building the classloader; on mismatch, retranslate once, then quarantine | Tampered/empty/truncated JAR → rebuilt; persistent mismatch → error state |
| T3.17 Garbage collection | Mark-and-sweep of `cs3/`, `plugins/` and `installation-proofs/` from receipts + `previous` + in-flight operations, run after uninstall/update and at boot (in the background) | Blobs removed after uninstall; shared blobs kept while referenced |
| T3.18 Multi-DEX completeness | All `classesN.dex` translated or the install fails (already enforced); cleanup covers every suffix | Test with a 2-DEX fixture (T0.7) |

### 3E. Runtime retirement & host jobs (G06, N05, F21, F22)

| Task | Work | Acceptance |
|---|---|---|
| T3.19 Generation leases | Every provider call acquires a lease on the generation (ref-count). `retire` waits for the count to reach 0 (bounded, e.g. 30 s) before `beforeUnload` + `classLoader.close()`. New calls route to the new generation immediately | Test: slow call in flight during update completes successfully; the classloader closes afterwards |
| T3.20 Host job ownership | `VerifierJobs` and any executor-owned background work are keyed by installation + generation and cancelled/joined on disable, uninstall, update and revoke | N05 scenario test |
| T3.21 Cache invalidation per generation | Details/links cache keys include `installationId + generation` (full identity in T6.1) | Update invalidates only that extension's entries |
| T3.22 Global context | Stop assigning `CloudStreamApp.context` per prepare; provide a per-installation context (T6.4) | — |

---

## P4 — Startup resilience (F19, N04, N09, Android safe mode)

| Task | Work | Acceptance |
|---|---|---|
| T4.1 Health before restore | `main` starts the server first; `/health` reports `extensions: {state: restoring|ready, restored, failed, quarantined}`; restore runs on a background dispatcher | Daemon ready in < 2 s with 50 slow fixtures |
| T4.2 Per-extension deadline | Each restore/prepare has a deadline (in-process soft deadline now, hard kill in P5) | A blocking `load()` does not block the others |
| T4.3 Loading markers & quarantine | Persist `loading:<id>:<generation>` before prepare and clear it after. At boot, a marker left behind means that generation crashed or hung the daemon → mark `quarantined` and skip it. The user can retry or uninstall | Kill-during-load test (subprocess) |
| T4.4 Safe mode | Launch option (hold ⌥ at launch, Settings toggle, or `--safe-mode` / marker file in the data root) → no extension loads; UI banner with "Exit safe mode". Also entered automatically after two consecutive daemon crashes within 60 s (supervisor counter) | UI test; supervisor test |
| T4.5 Supervisor | Readiness no longer depends on extension restore; restart backoff with jitter; crash-loop detection feeds T4.4 | XCTest with a fake daemon |
| T4.6 Solver ordering (N09) | Verify the challenge poller starts before any bootstrap network activity; add a first-launch challenged-repository integration test | Test |

---

## P5 — Isolation & resource governance (F18, F30, F19, comparison #14)

**S5.0 Spike (M):** prove the bundled JVM (with JIT) runs under App Sandbox with `com.apple.security.inherit` as a child of a sandboxed app; measure startup and throughput; confirm the loopback server works with `network.server`. Exit criteria: go/no-go and a measured overhead report. On no-go, fall back to an XPC service or a helper tool with its own sandbox profile.

| Task | Work | Acceptance |
|---|---|---|
| T5.1 Sandbox the whole stack | Add `com.apple.security.app-sandbox` to the app; the JVM gets `app-sandbox` + `inherit`. Move the data root into the container, with a one-time migration from `~/.cloudstream-macos`. Remove `allow-dyld-environment-variables`; keep `disable-library-validation` only if the spike proves it necessary (document why) | Plugin fixture cannot read `~/.ssh/known_hosts` (test in the packaged app); notarization passes |
| T5.2 Control/worker split design | ADR: the daemon becomes a **control plane** (no plugin code): state, catalogs, trust, receipts, routes. **Workers** host plugin generations. Protocol: length-prefixed JSON over a Unix domain socket in the container, with versioned messages (`prepare`, `publish`, `call{search,home,details,links,extract}`, `cancel`, `retire`, `health`). The existing `ExtensionRuntime` interface is the seam | ADR merged |
| T5.3 Worker runtime | `WorkerExtensionRuntime` implements `ExtensionRuntime`; `ProviderExecutor` calls go through a `ProviderGateway` (in-process implementation for tests, worker implementation in production). One worker process per extension (D3), launched lazily, pooled with an LRU cap (e.g. 8 hot workers) | All provider route tests pass against both gateways |
| T5.4 Hard deadlines & cancellation | Per-call deadline → cancel message → kill the worker after a grace period; the executor returns a `timeout` error distinct from provider errors (F30). Search fan-out gets a concurrency budget | Blocking fixture killed within deadline + grace; other providers unaffected |
| T5.5 Resource budgets | Worker JVM flags (`-Xmx`, thread caps), per-worker concurrent-call limit, response size limits on the worker channel, restart budget per extension (auto-quarantine after N crashes/hour) | Memory-hog fixture killed; daemon stays healthy |
| T5.6 Capability policy | Workers get network client access only and a private per-extension directory (T6.4); no access to the control-plane state, tokens or other extensions' data | Cross-extension read attempt fails in a test |
| T5.7 Host APIs over the channel | Solver cookies, settings, logging and metrics are proxied to workers through explicit messages | Solver integration test through a worker |

---

## P6 — Identity, configuration & compatibility (F03, F24, F26, F27, F28, N06, N07, D4)

| Task | Work | Acceptance |
|---|---|---|
| T6.1 Provider identity | `ProviderKey = installationId + provider index/name` exposed as `providerId` in all IPC DTOs (search results, details, links, home, `/providers`), library items, downloads, metrics and caches. Name lookup is kept only as a legacy input for saved data, with a migration that maps existing library entries by (name → unique provider) and flags ambiguities | Two extensions both registering `Movies` work independently; the library migration test |
| T6.2 Provider enable | Provider-level disable keyed by `ProviderKey`; extension-level disable (T2.2) takes precedence; extractor-only extensions have extension-level state only | Tests for multi-provider and extractor-only |
| T6.3 Configuration | Overrides keyed by `ProviderKey`; applied before publish on every restore; patch semantics with explicit reset; "unsupported" response when the provider refuses; credentials stored in the Keychain (reference ID in state), never in `state.json` or logs | Restart retains the override; `state.json` has no secrets (test greps it) |
| T6.4 Context & storage | `Context` per installation: `filesDir`/`cacheDir` under `CloudDirs.extensionData/<id>/` (respecting `cs.cloudstream.home`, N07); `getSharedPreferences` returns a durable, namespaced store with Android editor semantics (remove, clear, apply/commit, listeners) persisted atomically (F28) | Conformance tests ported from AOSP semantics |
| T6.5 ABI conformance | Build the stub ABI matrix: `Pair` public fields, `Uri` encode/decode/builder, `Base64` flags and line wrapping, `TextUtils`, `Log`, `Context` method descriptors matching Android (return types!), `Plugin.resources` type (F27). Every stub gets a descriptor test compiled against the Android API jar. Unsupported capabilities (`requiresResources`, D4) fail before registration with a clear message | ABI test suite green; the T0.7 fixture exercises it |
| T6.6 VideoClickAction | Decide: support (register and expose to the client) or reject with a warning at load time. It is currently silently ignored | Test for the chosen behavior |
| T6.7 Homepage semantics (F29) | Validate with the real-DEX fixture that declares `mainPage` requests | Fixture test |

---

## P7 — UX parity & polish (F04 UI, F17 UX, F37, N02, N10, Android UI features)

| Task | Work | Acceptance |
|---|---|---|
| T7.1 Installed list | Status chips (Running, Disabled, Needs update, Revoked, Quarantined, Failed + reason), tier badge, installed vs. available version, Retry/Update/Uninstall/Rollback actions | UI test |
| T7.2 Catalog | Search + TV-type + language filters, sort, extension details sheet (authors, description, size, digest, repository, tier), Install/Update/Installed states | UI test |
| T7.3 Repository list | Per-repository last successful sync, last error, tier, key fingerprint, extension counts; Sync, Sync all, Remove (with keep/remove installs choice) | UI test |
| T7.4 Re-trust UX (F17) | Key-change error shows old/new fingerprints and requires explicit confirmation; shows which installations will be re-proofed or flagged (T3.12) | UI test |
| T7.5 Updates UX | Update-all, auto-update setting, notification summary | UI test |
| T7.6 Onboarding (N02) | Verify the fresh install → choose repository → consent → install → provider picker flow, plus skip and offline variants | UI test |
| T7.7 Copy accuracy (N10) | All security wording reflects the tiers and current isolation state | Copy review checklist |
| T7.8 Accessibility | VoiceOver labels, keyboard navigation for all extension actions | `qa-ui-checklist.md` updated |

---

## P8 — Enterprise controls

| Task | Work | Acceptance |
|---|---|---|
| T8.1 Managed policy | Read the managed `UserDefaults` domain (configuration profile). Keys: `AllowedRepositories`, `BlockedRepositories`, `PinnedRepositoryKeys`, `AllowCommunityTier`, `AllowUserRepositories`, `AutoUpdate`, `AllowDeveloperExtensions`, `SafeModeOnly`. The client passes the policy to the daemon on startup through an authenticated `/policy` call; the **daemon enforces it** on every route; the UI shows "Managed by your organization" | Policy tests per key (daemon and UI) |
| T8.2 Audit log | Append-only JSON-lines log in the data root (rotated, integrity-chained with the previous entry's hash): repository add/remove/sync outcome, consent, trust/re-trust, install/update/rollback/uninstall/enable/disable/revoke/quarantine with digest, tier, key fingerprint and source (user/auto/policy). Export from Settings | Tests; tamper detection test |
| T8.3 Publisher tooling | `scripts/sign-repository` (or a Gradle task) producing `catalogVersion`, `expiresAt`, `pluginListHashes` and signatures per `repository-signing.md`; test vectors shared with the verifier | Round-trip test in CI |
| T8.4 Supply chain | SBOM (CycloneDX) for the daemon jar, JRE and dex2jar; dependency pinning and checksum verification in Gradle; reproducible-build notes | CI artifact |
| T8.5 Diagnostics export | Redacts credentials, cookies, tokens and URL query secrets; includes extension states and recent audit entries | Redaction test |

---

## P9 — Release verification

| Task | Work | Acceptance |
|---|---|---|
| T9.1 Acceptance-gate suite | Implement the REPORT §"Acceptance gates" table plus the FACT-CHECK additions as automated tests: identity collisions, duplicate requests, failed replacement, removal races, integrity corruption, trust downgrade/replay/rotation, transport redirects/limits, runtime blocking/OOM, persistence failures, compatibility fixtures, UI concurrency | All green; mapped in the ledger |
| T9.2 UI automation | XCUITest flows: onboarding, add repository (Verified and Community), install, update, disable, uninstall, remove repository, safe mode, re-trust, offline launch | Green on CI (macOS runner) |
| T9.3 Scale & performance | Budgets: daemon ready < 2 s; UI refresh < 200 ms with 100 installed; cold restore of 50 extensions < 30 s in the background; worker memory ≤ budget; search p95 with 20 providers | Benchmarks recorded in CI |
| T9.4 Fault injection | Disk full, permission denied, kill -9 at each commit phase, corrupted `state.json`/backup, duplicate daemon, network partitions | Tests using subprocess daemons |
| T9.5 Security review | Threat model update (malicious extension, malicious repository, network attacker, local unprivileged process vs. loopback API); external review of P1/P5; fuzz `RepositoryJson`, `CatalogTrust` and the worker protocol | Findings closed or accepted with owners |
| T9.6 Packaged verification | Notarized DMG from CI: sandbox active, entitlements minimal, first-run migration from an older version's data, upgrade with pre-receipt installs (T1.6) | Checklist signed off |
| T9.7 Documentation | `Architecture.md`, `Security.md`, `ipc-api.md` v4, `repository-signing.md`, the ADRs from P5 and a user help page on tiers and safe mode | Reviewed |

---

## Traceability matrix

| Issue | Current state | Plan tasks |
|---|---|---|
| F01 repository authority | Partial | T2.8, T2.9, T7.3 |
| F02 repository-scoped install | Verified selection | T3.1 (lifecycle), T9.1 |
| F03 provider names as IDs | Open | T6.1, T6.2, T3.21 |
| F04 no update path | Open | T2.4, T3.8–T3.10, T7.5 |
| F05 status handling / revocation | Partial (G03) | T3.11, T3.13 |
| F06 failed update destroys runtime | Implemented, untested | T3.5, T3.10 |
| F07 partial load leaks providers | Implemented, untested | T3.5 |
| F08 concurrent loads / racy publication | Partial | T3.1, T3.15 |
| F09 sync resurrects / stale commits | Partial | T3.7 |
| F10 verified-vs-returned bytes | Verified | T9.1 regression |
| F11 fallback boot bypass | Superseded by receipts | T1.6, T4.3 |
| F12 JAR trusted by size | Open | T3.14–T3.16 |
| F13 path traversal | Verified | T3.17 (GC must keep the validation), T9.5 fuzz |
| F14 signed→unsigned/HTML downgrade | Verified | T1.2 (preserve under tiers) |
| F15 detached lists | Verified chain | T1.1 (tier-aware proofs), T3.11 |
| F16 transport policy | Verified | T9.1, T9.3 max-size |
| F17 re-trust pin loss / UX | Partial | T3.12, T7.4 |
| F18 privileges / isolation | Open | S5.0, T5.1–T5.7 |
| F19 unbounded ingestion / startup | Partial | T4.1–T4.5, T5.4, T5.5 |
| F20 removal ownership | Implemented, untested | T3.6, T3.17 |
| F21 API mapping leak | Implemented | T3.5, T3.19 |
| F22 unlocked registry readers | Implemented | T5.3 (removes shared registries from the control plane) |
| F23 persistence failures | Partial | T9.4 |
| F24 provider config | Open | T6.3 |
| F25 metadata from mutable catalog | Partial (G02) | T2.1 |
| F26 enable/disable semantics | Open | T2.2, T6.2 |
| F27 ABI mismatches | Open | T6.5 |
| F28 SharedPreferences stub | Open | T6.4 |
| F29 homepage requests | Implemented | T6.7 |
| F30 cancellation / hard timeouts | Partial | T5.4 |
| F31 legacy null search | Verified | T9.1 regression |
| F32 URL lookup conflation | Verified | T9.1 regression |
| F33 aggregate provenance | Open | T3.13; aggregate commit via T3.7 (children as candidates, one transaction) |
| F34 UI task races | Partial | T2.8, T9.2 |
| F35 URL normalization | Verified parser | T0.3 nightly live, T9.1 |
| F36 canonicalization | Verified | T8.3 shared vectors |
| F37 refresh performs network sync | Partial | T2.8, T7.3, T9.3 |
| N01 client compile | Verified | CI |
| N02 onboarding dead end | Implemented | T1.5, T7.6 |
| N03 false Installed state | Reappeared as G02 | T2.1, T2.3, T3.3 |
| N04 boot I/O failures | Verified | T4.3 |
| N05 host jobs survive unload | Open | T3.20 |
| N06 stub value/encoding APIs | Open | T6.5 |
| N07 Context ignores data root | Open | T6.4 |
| N08 cookie lookup | Verified | T5.7 (worker path) |
| N09 solver ordering | Partial | T4.6 |
| N10 product security copy | Implemented | T7.7 |
| G01 no installable ecosystem | Open | D1, P1 |
| G02 routes bypass receipts | Open | T2.1–T2.3, T2.6 |
| G03 no revocation of receipts | Open | T3.11 |
| G04 manager edge cases / rotation | Open | T3.1–T3.4, T3.12 |
| G05 no GC; JAR outlives uninstall | Open | T3.15–T3.17 |
| G06 classloader closed in flight | Open | T3.19 |
| G07 aggregate status, shared-lib change, dead code | Open | T3.13, T2.6, T0.2; Android build check in T9.6 |
| Comparison: no App Sandbox / weakened JVM entitlements | Open | T5.1 |
| Comparison: cleartext credentials | Open | T6.3 |
| Comparison: no safe mode | Open | T4.3–T4.5 |
| Comparison: VideoClickAction ignored | Open | T6.6 |
| Comparison: catalog UI features | Open | T7.2 |
| Comparison: MDM, audit, SBOM | Open | P8 |

---

## Risks & mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| JVM with JIT is incompatible with App Sandbox or notarization constraints | Blocks P5 as designed | S5.0 spike first; fallback to an XPC helper or a separately sandboxed helper tool; keep the `ProviderGateway` seam so the in-process runtime still works |
| Worker IPC adds latency to search/links | UX regression | Pooled warm workers, streaming responses, budgets measured in T9.3 before rollout; feature flag for the in-process gateway during migration |
| Community-tier consent weakens the security story | Perception, risk | Clear badges, per-repository consent, digest still mandatory, policy can disable it (T8.1), sandboxed workers (P5) bound the damage |
| Library provider-ID migration mis-maps saved items | Lost history/playback | Dry-run migration with an ambiguity report; keep the original name field; reversible |
| Shared `library/` changes break Android | Android regressions | Every `library/` change is additive; Android build in CI (`pull_request.yml`) required for such PRs |
| Scope creep in P6 ABI work | Endless compatibility chase | Drive it from a ranked list of top-used community extensions (top 30 by install count) and the conformance matrix; publish a supported-capability list |
| State schema migrations on user machines | Data loss | Versioned migrations with backup-before-migrate (StateRepository already keeps a backup), migration tests with real old `state.json` samples |

---

## Milestones

1. **M1 — Usable & honest (P0, P1, P2):** green CI, D1 implemented, existing repositories installable, installed list/toggle/uninstall/update working, legacy installs migrated, IPC v4.
2. **M2 — Correct lifecycle (P3, P4):** updates, revocation, rotation, GC, JAR integrity, safe mode, health-first startup, all lifecycle tests.
3. **M3 — Secure runtime (P5):** sandboxed stack and isolated, killable, budgeted workers.
4. **M4 — Compatible & complete (P6, P7):** stable provider IDs, Keychain secrets, durable prefs, ABI suite, full UI parity.
5. **M5 — Enterprise release (P8, P9):** managed policy, audit log, publisher tooling, SBOM, full acceptance/scale/security verification, notarized release.

Claims allowed at each milestone:
- M1: "functional parity for install/manage".
- M2: "robust lifecycle".
- M3: "extensions are sandboxed".
- M5: "enterprise-grade". No such claim before its milestone.
