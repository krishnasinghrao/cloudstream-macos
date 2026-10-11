# Extensions remediation and release evidence

Goal: implement and verify all supported findings in the repository audit and independent fact-check; deliver a production-ready native Extensions/Repository system. Status: **in progress; not release approved** (P0–P6 done; release verification open).

The original reports are immutable historical evidence. This ledger records current fixes; a passing characterization test is not acceptance. No issue closes until its intended invariant and relevant integration path are verified. Runtime isolation, resource budgets, native build/UI flows, migration, artifact integrity, trust, and release verification remain in scope.

## Execution order

1. Durable state and filesystem primitives; explicit recovery; process ownership.
2. Native authoritative repository store, onboarding and compile gate.
3. Validated identities, installation records, transport and signed catalog chain.
4. Transactional generation lifecycle, rollback, update/revocation and safe boot.
5. Supervised isolated plugin execution, deadlines and resource budgets.
6. ABI, settings, provider semantics, stable provider IDs/configuration and jobs.
7. Route/UI integration, migration, failure/scale/security fixtures, packaged runtime and release evidence.

## Findings

Statuses re-verified against the code on 2026-09-30 (see the plan's "Status and corrections"). **Done** = enforced in the daemon and asserted by a normal-suite test; UI-test evidence (plan T9.2) is outstanding for every client-facing row.

| ID | Requirement | Status | Evidence (plan task → tests) |
|---|---|---|---|
| F01 | Repository add/remove sources of truth | Done | T2.9: daemon registry is authoritative; Swift list read only by one-time import. `RepositoryMigrationTest`, `ExtensionsStoreTests` |
| F02 | Installation lookup ignores repository identity | Done | T2.x: installation ID = SHA-256 of length-prefixed repository URL + internal name. `RepositoryIdentityTest`, `InstallationLifecycleTest` |
| F03 | Provider names treated as global IDs | Done | T6.1: `<installationId>:<name>` on every DTO, cache key and toggle; bare names only when unambiguous. `ProviderIdentityTest`, `PluginBridgeTest` |
| F04 | No working update path | Done | T2.4, T3.8–T3.10: update, update-all, rollback, auto-update, background refresh. `InstallationLifecycleTest`, `FactCheckRegressionTest` |
| F05 | Remote status hides/does not revoke | Done | T3.11: status 0 revokes, unloads, survives restart and lifts when re-enabled. `InstallationLifecycleTest` |
| F06 | Failed update destroys working runtime | Done | T3.5: commit-then-publish with rollback. `InstallationLifecycleTest` |
| F07 | Partial load leaves providers | Done | Staged registration sealed before publication. `PluginBridgeTest` (failing load publishes nothing) |
| F08 | Loads not idempotent; racy cache | Done | T3.1, T3.2, T3.15: per-installation queue, idempotent enable, locked atomic translation. `InstallationLifecycleTest` |
| F09 | Sync resurrects/overwrites | Done | T3.7: snapshot checks at commit; removal removes the repository before uninstalling. `RepositoryMigrationTest`, `FactCheckRegressionTest` |
| F10 | Download returns unverified bytes | Done | `ArtifactIntegrityTest` |
| F11 | Startup fallback scan bypasses rejection | Done | Receipts are the only execution authority; no cache scan. `ArtifactIntegrityTest`, `InstallationLifecycleTest` |
| F12 | JARs trusted by filename | Done | T3.16: JAR digests in the receipt; mismatch rebuilds from verified source; in-memory `VerifiedClassLoader`. `PluginBridgeTest` |
| F13 | fileHash traversal on removal | Done | `ArtifactIntegrityTest` |
| F14 | Signed → unsigned/HTML downgrade | Done | `RepositoryTrustTest`; policy-pinned keys matched after URL normalization (`FactCheckRegressionTest`) |
| F15 | Root signature does not bind lists/artifacts | Done | `CatalogTrustTest`, `RepositorySignerTest` |
| F16 | HTTPS stops at initial URL | Done (packaged gate open) | `RepositoryTransportTest`, `RepositoryFetchIntegrationTest` |
| F17 | Failed re-trust destroys pin | Done | T3.12, T7.4: candidate key must deliver a valid catalog; UI shows fingerprints. `RepositoryTrustTest`, `InstallationLifecycleTest` |
| F18 | Plugins run with user privileges | Done | ADR-0016: one sandboxed worker per extension; cannot read user files, engine state or other extensions (`WorkerIsolationTest`) |
| F19 | Unbounded ingestion/startup | Done | Bounded transport/JSON; restore runs no extension code; worker heap and crash budgets; worker cap (`WorkerIsolationTest`) |
| F20 | Removal cannot identify ownership | Done | Receipts carry repository provenance; removal keeps or removes explicitly. `InstallationLifecycleTest` |
| F21 | Unload leaves mappings | Done | Detach removes providers, extractors and mappings under lock. `PluginBridgeTest` |
| F22 | Registry readers without lock | Done | Readers copy under `allProviders.withLock`; publication swaps under the lifecycle lock |
| F23 | Persistence failures reported as success | Done (crash-phase gate open) | `StateRepositoryTest`; subprocess kill tests are T9.4 |
| F24 | Provider configuration not restored | Done | T6.3: URL persists by provider ID and applies before publication; credentials memory-only, re-sent from the Keychain, accepted before load. `ExtensionRoutesTest`, `FactCheckRegressionTest` |
| F25 | Installed metadata from mutable catalogs | Done | Receipts + content-addressed proofs re-verified on every load. `InstallationLifecycleTest` |
| F26 | Enable/disable model | Done | T2.2 extension-level, T6.2 provider-level. `ExtensionRoutesTest`, `ProviderIdentityTest` |
| F27 | Android stubs not binary compatible | Done | T6.5: d8-compiled fixture + `AndroidStubConformanceTest` |
| F28 | Settings stubs lose values | Done | T6.4: durable namespaced preferences; uninstall evicts cached stores. `AndroidStubConformanceTest`, `FactCheckRegressionTest` |
| F29 | Homepage request structure | Done | Real d8-built fixture declares main-page requests (`PluginBridgeTest`, `WorkerIsolationTest`) |
| F30 | Timeouts do not contain blocking plugins | Done | Hard deadline kills a blocking worker; other extensions unaffected (`WorkerIsolationTest`) |
| F31 | Legacy null search reported as success | Done | `ProviderExecutorTest` |
| F32 | Repository lookup conflates URLs | Done | `RepositoryIdentityTest` |
| F33 | HTML aggregation provenance/status | Done | T3.13: child-repository provenance per entry, statuses 1 and 2 kept, 0 dropped, same names from different children both kept. `AggregateCatalogTest` |
| F34 | Overlapping UI tasks | Done (UI stress open) | `ExtensionsStoreTests` (generations, cancellation, reconnect) |
| F35 | URL normalization too broad | Done (live compatibility nightly) | `RepositoryServiceTest`, nightly live job |
| F36 | Canonicalization control characters | Done | `RepoSignatureTest`, strict `RepositoryJson` |
| F37 | Refresh performs network sync | Done | Refresh is read-only; `ExtensionsStoreTests` |
| N01 | Rewrite prevented compilation | Done | Client builds; CI runs unit tests |
| N02 | Onboarding had no path to a provider | Implemented (UI test open) | Choose Extensions / Set Up Later |
| N03 | Failed install shows Installed | Done | Installed state comes only from receipts. `ExtensionRoutesTest` |
| N04 | Filesystem failures abort startup | Done | `ArtifactIntegrityTest` |
| N05 | Verifier jobs outlive disable/uninstall | Done | T3.20: jobs owned by installation + generation, cancelled on retire. `ProviderIdentityTest` |
| N06 | Common value/encoding API gaps | Done | `AndroidStubConformanceTest` |
| N07 | Context ignores data root | Done | `AndroidStubConformanceTest` (context storage follows the configured root) |
| N08 | Solved-cookie lookup type | Done | Interceptor regression test |
| N09 | Bootstrap waits for solver | Done | Poller starts before bootstrap; `ChallengePathTest` covers the in-process and worker challenge paths |
| N10 | Security claims in product copy | Done | Copy reflects tiers and sandbox state; false sandbox/entitlement claims in `Security.md` corrected 2026-09-30 |

## Acceptance gates

Mapped to evidence on 2026-09-30 (plan T9.1). "External" means the gate needs systems outside the test suites.

| Gate | Status | Evidence |
|---|---|---|
| Repository UI: add/remove/default removal, offline catalogs, aggregate children | Done (UI partial) | `ExtensionsStoreTests`, `RepositoryMigrationTest`, `AggregateCatalogTest`; `ExtensionsUITests` covers the screen and sheet; add/browse against a live HTTPS repository is external |
| Identity: duplicate names, shared artifacts, independent configuration, migrated saved media | Done | `ProviderIdentityTest`, `RepositoryIdentityTest`, `ExtensionRoutesTest`; saved media migrate lazily (plan T6.1) |
| Install/update: single-flight, failed candidate keeps old generation, reconciliation after timeout/cancel | Done | `InstallationLifecycleTest`, `FactCheckRegressionTest`, `WorkerIsolationTest` |
| Removal: sync/install races, catalog omission, shared ownership, multidex outputs, mappings, host jobs | Done | `InstallationLifecycleTest`, `FactCheckRegressionTest`, `PluginBridgeTest`, `ProviderIdentityTest` (verifier jobs, leases) |
| Integrity: equal-size corruption, source/filename mismatch, altered JAR, interrupted publication, toolchain invalidation | Done | `ArtifactIntegrityTest`, `PluginBridgeTest`, `StateCrashConsistencyTest`; translation profile bump |
| Trust: stripping/HTML downgrade, detached lists, rotation failure, replay/freshness, missing digest, forged provenance | Done | `RepositoryTrustTest`, `CatalogTrustTest`, `RepoSignatureTest`, `ParserFuzzTest`, `RepositorySignerTest` |
| Transport: redirects/destinations, HTTP rejection, private hosts, status, byte/decompression limits | Done | `RepositoryTransportTest`, `RepositoryFetchIntegrationTest`, `ChallengePathTest` |
| Runtime: partial registration, blocking callbacks, OOM, restart/safe mode, OS isolation, cross-plugin interference | Done | `PluginBridgeTest`, `WorkerIsolationTest` (real JVMs and sandbox), `InstallationLifecycleTest`, `ExtensionsUITests` |
| Persistence: write failure, corrupt/future schema, crash recovery, one owner per root, protected secrets | Done | `StateRepositoryTest`, `StateCrashConsistencyTest`, `ExtensionRoutesTest` (no secrets in state) |
| Compatibility: Android-compiled DEX, resources, settings, multidex, extractor-only, multi-provider, homepage, utility APIs | Done | d8 fixtures in `PluginBridgeTest` and `WorkerIsolationTest`, `AndroidStubConformanceTest`; live community extensions nightly (external) |
| Client: build, first-run flow, task generations, simultaneous actions, restart, safe-mode presentation | Done | `ExtensionsStoreTests`, `ExtensionsUITests` (install/enable/disable/uninstall, safe mode, accessibility audit), `SidebarNavigationUITests`; onboarding is dismissed through Set Up Later in every UI test |
| Scale: boot, UI and cancellation latency, memory/network/concurrency limits | Done (engine) | `PerformanceBudgetTest`, `WorkerIsolationTest`, end-to-end worker run (cold search 2.0 s, ~110 MB per worker) |
| Release: packaged app, compatibility/trust contract, signing/notarization, budgets | Partial / external | Packaging self-test boots a sandboxed worker; SBOM; docs; upgrade from the real pre-remediation daemon verified end to end. The notarized DMG needs release credentials |

## Work log

- Remediation started from current working-tree sources; unrelated work preserved. Pre-edit source backup: `/var/folders/ks/8_87xt0s2b56vcmknv178kjc0000gn/T/cloudstream-extensions-baseline-gtvfazpf`.

### Verified implementation checkpoint — 2026-09-30

- Durable state: atomic replacement + fsync, private files/directories, process root lock, explicit recovery instead of silent trust-policy reset. Migration retries cannot resurrect removed repositories.
- Native store: source-of-truth wiring, stale-response/cancellation guards, offline refresh, recoverable onboarding. Native `build-for-testing` succeeded after WebKit lifecycle changes; this is compilation of app and test bundles, not executed UI tests or release signing.
- Trust: no unsigned/HTML downgrade of a pinned root, transactional re-trust failure, stale-sync commit rejection. Root canonicalization has an explicit constrained protocol in `../../repository-signing.md`. Detached-list authentication, replay protection and strict bounded ingestion remain open.
- Artifacts: mandatory valid matching digest, size mismatch rejection, verified-byte atomic publication, validated deletion paths, no orphan execution scan and per-file boot barriers. This does not yet supply a committed installation ledger or authenticate translated JARs.
- Provider semantics: exactly-once legacy search delegation, null failure and caller cancellation, declared homepage requests with bounded parallelism/sequential order and partial completed results.
- Solver: full-URL cookie lookup; callbacks bound to original target; HTTPS origin/port isolation, bounded task/cookie caches, 5-minute in-memory daemon cookie lifetime, cleanup on cancellation; fresh nonpersistent WebKit storage per attempt and engine reset.
- Remaining architecture work: dedicated bounded transport; authenticated list/artifact chain and freshness; stable installation/provider identities; transactional generation lifecycle and rollback; OS-isolated workers; protected credentials/Android binary compatibility; actual packaged-runtime, UI, load and release verification.

Evidence logs for this checkpoint are copied into `verification/`; original audit and fact-check probes remain historical characterizations and intentionally fail when an adverse behavior has been repaired. Do not run them as passing acceptance tests.

At this checkpoint the normal daemon suite had **111 tests; 108 passed, 3 skipped, 0 failures, 0 errors**. The three opt-in live/community-plugin tests remain skipped. See `verification/checkpoint.json` for per-suite counts and source hashes.

### Transport and authenticated-catalog checkpoint — 2026-09-30

- Dedicated HTTP transport and strict ingestion now replace provider-global networking. Real HTTPS fixtures exercise redirect/status/size/cancellation/cookie/TLS/DNS behavior. Final effective URLs are retained for relative links; shortcode/migration parsing preserves identity.
- Signed roots now bind every list's exact bytes and each artifact digest, require monotonic `catalogVersion` and a bounded `expiresAt`, and atomically persist original list evidence plus durable key/revision anchors. Removing a catalog cannot erase that history. Synthetic Ed25519 fixtures verify replay, expiry, revision reuse, stripped binding, modified lists, forged display metadata and offline proof behavior.
- Installation requires fresh signed evidence. Cached loading requires reconstructed signed evidence and source-digest authorization, including direct loader calls. Unsigned/legacy catalogs remain browseable with a clear installation restriction; the Swift store also refuses missing/denied policy.
- Repository read projections retain metadata and derive trust from evidence. Loader negative tests first establish a valid signed chain so their archive-validation assertions still exercise the intended path.
- The temporary automatic-approval usage-limit failure cleared after work resumed. All pending transport edits were subsequently included in successful daemon verification.
- Full production readiness is still unproven. Next: committed installation receipts independent of latest catalogs, transactional runtime generations/rollback, translated-bytecode integrity, host job cancellation, and isolated workers; then ABI, packaged stress, UI and release gates.

Checkpoint result: **166 daemon tests: 163 passed, 3 skipped, 0 failures, 0 errors**; **7 Swift Extensions tests passed**; native app and test bundles built successfully. Other ongoing work adds tests to the total; see `verification/transport-trust-checkpoint.json` for exact suite counts and source hashes. Native UI execution and signed release verification remain open.

### Fact-check checkpoint — 2026-09-30

Every plan task was re-checked against the code (plan: "Status and corrections"). Defects found and fixed, each with a regression test (`FactCheckRegressionTest`, `ProviderIdentityTest`, `ExtensionsStoreTests`, `EngineSandboxTests`):

- Launch options: a missing policy line silently applied no organization policy; it now fails closed. Misconfigured managed preferences (wrong type) and client encoding failures also fail closed.
- Policy-pinned keys matched URLs exactly while allow/block lists normalized them; both now normalize.
- Keychain credentials re-sent while extensions were still restoring were dropped ("Unknown provider"); they are now held until the extension loads, and the client re-sends after restore.
- Configuring or toggling a built-in provider did not invalidate its cached responses.
- Repository removal with its extensions could leave an extension installed by a concurrent install.
- Uninstall left an extension's preferences cached in memory; a reinstall resurrected them.
- Automatic updates only ran on a manual sync; `BackgroundRefresh` now syncs every 6 h and the client notifies.
- Sandbox paths under `/var` were denied (symlink); profile parameters are now resolved.
- `java.entitlements` still granted `allow-dyld-environment-variables` although `Security.md` said it was removed; removed.
- CI never ran Swift tests, had no legacy-API guard or nightly live job, and granted `contents: write` to every job; fixed.
- Added: Sync All, catalog sort, Settings → Restart in Safe Mode, ADR-0015, `verify_audit_baseline.py` and the `extensions-audit-baseline` tag (21/29 reviewed files reproducible), `Main.kt` split (245 lines).

Suites: **daemon 214 tests, 0 failures, 2 live tests skipped**; **client unit tests 275, 0 failures, 23 skipped** (fixtures that need packaged media resources).

### Worker isolation checkpoint — 2026-09-30

- ADR-0016: every extension runs in its own sandboxed worker JVM; the engine runs no extension code. Verified with real worker processes (deadline kill, OOM containment, crash-budget quarantine, sandbox denial of engine state and another extension's data) and a live end-to-end run with two community extensions: install, search (52 results from two workers), details, links (batch and streamed), and restart with lazy restore (0 workers until first call; cold search 2.0 s). Workers use about 105–115 MB each.
- Found by the end-to-end run: the launcher used `java.management`, which the bundled runtime lacks. Fixed, the packaging self-test now boots a sandboxed worker on the bundled runtime, and CI rejects daemon code that uses modules outside the bundle.
- Found by the fixture rebuild: dex2jar output is not byte-reproducible for some methods. Integrity already relied on verified source and receipt-bound cache digests; tests and docs no longer assume reproducibility.
- Also: T8.4 SBOM, T8.5 redacted diagnostics export, T6.7 real homepage fixture, T7.8 accessibility pass.

### Hardening checkpoint — 2026-09-30

- T9.4: `StateCrashConsistencyTest` kills a real writer process mid-commit 20 times; state always loads complete and monotonic. Found: interrupted commits left temp files forever; now removed on load.
- T9.5: `ParserFuzzTest` mutation-fuzzes repository JSON, signed manifests, catalog lists and worker frames. Found: unknown members inside the `signature` object were accepted; the verifier now rejects them (strict profile, documented).
- T9.3: `PerformanceBudgetTest` with 100 installed. Found: `/plugins` re-verified the repository catalog for every extension (114 ms); memoized per request (4 ms). Same fix for update detection.
- Suites: daemon 231 passed (2 live skipped).

### Safe-mode layout, challenge path and developer mode — 2026-09-30

- Found by a new UI test (and reported by the user): in safe mode the Extensions screen demanded more height than the window, which with `.contentMinSize` pushed the entire UI off-screen. Fixed at the screen and at the root; `ExtensionsUITests` asserts the header, banner and sidebar stay on-screen.
- Network errors reach users as plain language instead of Java exception text.
- T4.6/N09: `ChallengePathTest` (local HTTPS server, in-process and worker paths).
- D5: developer tier with policy control (`DeveloperExtensionTest`).

### UI lifecycle, accessibility audit and upgrade — 2026-09-30

- `ExtensionsUITests` drives install (Debug-only developer-import hook, isolated data root), enable (starts a sandboxed worker), disable and uninstall with no network, plus an automated accessibility audit gate. Found and fixed: developer rows said "repository removed"; version -1 displayed as "v-1".
- Upgrade: the real pre-remediation daemon (built from `extensions-audit-baseline`) installed a live community extension; the new daemon migrated the data root (schema v1 → v2, legacy artifact adopted on first sync with `migration` consent) and ran it in a sandboxed worker with identical results.
- Worker stderr no longer floods the log with macOS "CFPrefsPlistSource" denials (the sandbox blocks those reads by design).
