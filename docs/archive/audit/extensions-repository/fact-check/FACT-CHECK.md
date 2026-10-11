# Independent fact-check of the Extensions/Repository audit

Reviewed 2026-09-30. **The audit's central conclusion is supported: the current repository, trust, and plugin lifecycle implementation has serious correctness and security defects. All 19 original characterization probes reproduced. However, F33 contains an unsupported status-bypass claim, several client descriptions are stale, and important first-run, compatibility, startup, and background-job failures were omitted.**

The current Swift sources also fail type-checking because an incomplete Extensions UI rewrite references missing types. This is a current-tree finding, not evidence that the original audited snapshot failed to compile.

## Evidence and scope

| Check | Result |
|---|---|
| Original source fingerprints | 22 of 29 matched; 7 changed before this review's initial comparison |
| Original opt-in probes | 19 executed, 19 reproduced their documented adverse behavior |
| Additional fact-check probes | 12 executed, 12 matched their characterization assertions; one specifically contradicts part of F33 |
| Current normal daemon suite | 79 tests: **76 passed, 3 skipped**, no failures/errors |
| Original normal-suite snapshot | 76 tests: **73 passed, 3 skipped**; the arithmetic is correct. Three current `VerifierJobsTest` tests explain the difference |
| Swift source type-check | Failed with missing `ExtensionsStore` and `RepositoryCatalogStore`; diagnostics saved |
| Live extensions / translation | No community code executed; no fresh real DEX translation or compatibility certification |
| UI execution | Source traces and compiler check, not a running SwiftUI/onboarding test |

The seven changed fingerprinted files were `DaemonSupervisor.swift`, Swift `Dtos.swift`, `DaemonClient.swift`, `UserPreferences.swift`, `ExtensionsView.swift`, `AppState.swift`, and daemon `Main.kt`. The core `RepositoryService`, `PluginBridge`, `DaemonState`, `ProviderExecutor`, and `RepoSignature` fingerprints matched. The original fingerprints do not preserve old source contents, so exact historical client behavior cannot be reconstructed from them alone.

Other work is occurring in this shared checkout: the end-of-review manifest records source changes during this review. Findings below refer to the inspected files and saved fingerprints; unrelated edits are not attributed to this review. Only this `fact-check/` directory was authored for the review. Original audit artifacts and production sources were preserved.

At the final comparison, Security.md had also changed, bringing original-fingerprint mismatches to eight. Its added download-security paragraph does not alter the repository-integrity, secret-storage, or memory-only cookie claims discussed here. DownloadService, LibraryStore, and DownloadsView also changed during the review; their new behavior is outside this fact-check's scope.

Evidence: [additional probes](macos/docs/audit/extensions-repository/fact-check/FactCheckProbe.kt), [probe results](macos/docs/audit/extensions-repository/fact-check/probe-results.json), [current baseline](macos/docs/audit/extensions-repository/fact-check/baseline-results.json), [Swift diagnostics](macos/docs/audit/extensions-repository/fact-check/client-typecheck.log), [source capture](macos/docs/audit/extensions-repository/fact-check/source-start.json), and [final source comparison](macos/docs/audit/extensions-repository/fact-check/source-end.json).

## Corrections to the existing audit

### C01 — F33's claimed remote-down installation bypass is not reachable through ordinary aggregation

The report correctly spots that the aggregate branch returns `distinctPlugins` while persisting `enabledPlugins`. But those arrays do not actually differ in status on the inspected path:

1. Ordinary JSON sync filters to `status == 1` before returning `SyncOutcome.plugins`.
2. HTML sync adds only each child `SyncOutcome.plugins` to its composite list.
3. Nested HTML sync follows the same rule recursively.

Consequently, successfully returned entries are already status 1. The additional probe provides an HTML root with a child catalog containing OK, down, and slow entries; the aggregate returns only OK. This is also established by the full data flow, not just that fixture.

Remove the claim that aggregate `installAll` loads remote-down entries. Keep F33's valid findings about lost repository provenance, duplicate-name collapse, independent child commits, partial failure, and ownership. F05 remains valid: **already loaded** down providers are not revoked. These are different mechanisms. [Child collection](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:384), [ordinary filter](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:483), [ordinary return](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:516).

### C02 — Do not describe the old Extensions UI as the current implementation, or close its findings prematurely

The new view has separate row activity dictionaries, an update-available message, catalog filtering, a sheet-local catalog store, and `.task(id:)`. It hides enable toggles for extractor-only extensions. Therefore these specific audit assertions are outdated:

- F04: the UI no longer completely ignores `isUpdateAvailable`; it displays a message. **There is still no Update action**: installed entries take the Installed branch.
- F26: the current view no longer uses a single `isToggling` string or visibly toggles extractor-only plugins.
- F34: the specific shared `browsePlugins`/A→B overwrite implementation is gone.
- The final “versatility gaps” list should no longer claim catalog search is absent; text filtering now exists. Dedicated type/language filters and the other listed features remain separate questions.

These are source changes, not verified completed repairs. Both new store types are missing, `AppState.extensions` is absent, and `RepoPluginDto.catalogID` is referenced but undefined. The unchanged bootstrap still synchronizes preferences, so F01/F37's state-authority and refresh concerns remain in that path. Do not infer correct store cancellation, refresh, or mutation behavior from a view that references an unimplemented store. [New catalog UI](macos/client/Sources/UI/Extensions/ExtensionsView.swift:325), [installed/update branch](macos/client/Sources/UI/Extensions/ExtensionsView.swift:402), [bootstrap](macos/client/Sources/ViewModels/AppState.swift:183).

### C03 — F31 is valid, but the fallback explanation misses the actual shared API contract

`ProviderExecutor` comments say both base search methods throw. In this checkout, **modern `MainAPI.search(query, page)` already delegates to legacy `search(query)`**. If legacy search returns null, the executor calls it again and turns the second null into empty success. The added counter probe observes two calls. If a provider explicitly implements modern search returning null and legacy search returning an empty list, the executor also converts the modern failure into success.

The original F31 remedy mentions not falling back on arbitrary failure, but should explicitly account for the shared implementation. Preserve modern null as failure and avoid the redundant legacy call. Do not add a second compatibility fallback without inspecting the engine ABI. [Shared default](upstream/library/src/commonMain/kotlin/com/lagradost/cloudstream3/MainAPI.kt:640), [executor fallback](macos/daemon/src/main/kotlin/com/lagradost/macos/ProviderExecutor.kt:122).

### C04 — Clarify security preconditions and prioritize trust persistence consistently

F10–F12 are genuine integrity failures. Their cache-tampering scenarios require corrupt/replaced cache bytes or another path to write them; they do not by themselves demonstrate an unauthenticated loopback attacker installing code. F13 requires attacker-controlled catalog data and an applicable removal operation; targets are constrained by the appended `.cs3`/`.jar` suffix. F15 requires control over an external list response/origin, as the report already notes. Public signatures from an arbitrary first-use key do not establish independently verified publisher identity: that is TOFU.

The report's repair order puts F17 in the final UI/interoperability stage even though it destroys a trust pin on failure. Move F17 beside F14/F15. Likewise, the trust-policy loss portion of F23 belongs in the early fail-closed/security work, even if ordinary persistence reporting remains P2. F18 should remain an explicit trust-model decision tied to the intended deployment, not an implication that a classloader or merely a second process would provide isolation. Apple documents actual App Sandbox capability boundaries and child-process behavior separately. [Apple sandbox guidance](https://developer.apple.com/documentation/security/discovering-and-diagnosing-app-sandbox-violations?changes=_7).

## Additional findings and missing consequences

Priorities use the original report's conventions. “Probe” means a synthetic characterization of the stated mechanism, not a full production exploit or UI test.

### N01 — P1 — The current Extensions rewrite is incomplete and prevents Swift compilation [Compiler + source]

`ExtensionsView` requires `ExtensionsStore` at line 19 and `RepositoryCatalogStore` at line 330. Neither exists under client Sources. It also expects `AppState.extensions` and `RepoPluginDto.catalogID`, neither of which is defined. An all-source Swift 6 type-check, using the project's mpv bridging header, fails on the missing store types. The first sandboxed attempt could not launch Observation macros; rerunning with that restriction lifted produced the actual source errors saved in the diagnostics.

This is an immediate current-tree delivery blocker and a reason not to claim F01/F26/F34/F37 fixed based solely on new view code. Complete the store/model wiring, then run the generated project's normal build and integration tests. A successful daemon suite does not validate the native client. [Missing store reference](macos/client/Sources/UI/Extensions/ExtensionsView.swift:19), [missing catalog store](macos/client/Sources/UI/Extensions/ExtensionsView.swift:330), [catalog model](macos/client/Sources/Models/Dtos.swift:31).

### N02 — P1 — Fresh-install onboarding has no path from a catalog to an installed provider [Source]

With an empty source cache, Get Started calls `syncRepositories()`, whose client `syncRepo` defaults to `installAll=false`. `/plugins` consequently remains empty even when catalog sync succeeds. Onboarding then advances to `pickProvider`; only a provider button can move to Done. There is no install/browse action, retry, skip, or cancel on that step, and the presenting sheet disables interactive dismissal. The “No providers loaded” condition only fires if every sync failed, so a successful catalog fetch can produce a blank picker without even that explanation.

This blocks first use independently of update support. Offer an explicit extension-selection/install step or a recoverable route to Extensions and a skip option; handle the engine-not-ready case too. Do not silently install an entire repository merely to make the picker populate. Verify with empty preferences/cache and both successful and failed syncs. This is a source-proven navigation dead end, not a UI run against the presently uncompilable client. [Sync/default flow](macos/client/Sources/UI/Components/OnboardingView.swift:102), [picker transition](macos/client/Sources/UI/Components/OnboardingView.swift:76), [dismissal restriction](macos/client/Sources/UI/Navigation/RootView.swift:53).

### N03 — P2 — Failed installation can lock the catalog into a false Installed state [Probe + source; extends F07/F25]

`isPluginInstalled` returns true for an existing expected-hash `.cs3`, even when no runtime descriptor exists. The probe creates a cached archive with a missing entry class, confirms loader failure, then observes `isPluginInstalled == true`. A normal failed install also leaves its downloaded artifact in this location.

`GET /plugins` has no descriptor to display, while the catalog's Installed branch suppresses Install. Thus the user can have neither a working extension nor a retry/uninstall entry in the installed list. F07 discusses leaked registrations and next-boot retry, but not this immediate recovery dead end; a missing-class failure needs no leaked provider at all.

Represent downloaded, staged, failed, installed, and loaded states separately. Catalog actions should use committed installation state and expose retry/cleanup for failed artifacts. [Cache-as-install check](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:569), [UI branch](macos/client/Sources/UI/Extensions/ExtensionsView.swift:410).

### N04 — P1 — Ordinary filesystem failures can abort all offline startup outside the loader barrier [Probe; extends F19]

`bootFromCache` calls `sha256(cs3)` outside a per-file exception handler in both passes. Its fallback filter tests only the `.cs3` extension, not `isFile`. A directory named `bad.cs3` makes `bootFromCache` throw `IOException`; the added probe reproduces this without large files, native code, or hostile plugins. Unreadable files and removal between existence check and hashing are related source-level failure paths.

`main` calls boot before starting the server, so this can prevent `/health` from ever existing. F19 focuses on resource exhaustion and blocking callbacks; this simpler crash path deserves its own regression. Validate file type, guard each read/hash/load, quarantine/report the offending entry, and continue with healthy committed installations. [Startup order](macos/daemon/src/main/kotlin/com/lagradost/macos/Main.kt:103), [fallback/hash](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:715).

### N05 — P2 — Host-owned verifier jobs continue after disable/uninstall [Probe; extends F21/F26/F30]

`VerifierJobs.start` captures a provider in a global coroutine scope. Its map stores only job ID → Job; neither disable nor `PluginBridge.removePlugin` cancels matching jobs. The probe starts a cooperatively suspended verifier, disables its provider, unloads the plugin, and confirms the verifier remains active until explicitly stopped.

Unlike an arbitrary plugin-created thread, this work is owned by the host and can be tracked/cancelled reliably. It can retain retired provider/classloader state and keep making network calls until the client stops it or the six-hour cooperative lifetime expires. Track jobs by installation/generation and cancel/join them during disable, uninstall, update, and engine teardown. Also define what happens to in-flight search, detail, link, and download work; closing a classloader is not cancellation. [Verifier scope and capture](macos/daemon/src/main/kotlin/com/lagradost/macos/VerifierJobs.kt:27), [unload](macos/daemon/src/main/kotlin/com/lagradost/macos/PluginBridge.kt:262).

### N06 — P2 — The Android compatibility gap includes common value/encoding APIs [Three probes; extends F27]

The original audit focuses on Context, Resources, and preferences. Additional concrete failures are:

| API | Observed macOS behavior | Android contract / consequence |
|---|---|---|
| `android.util.Pair.first/second` | Kotlin `val` properties compile to private fields plus getters; reflection confirms no public fields | Android exposes public final fields. Translated Android field-access bytecode can fail access/linkage checks; matching property names in Kotlin is insufficient |
| `Uri.getQueryParameter` | `q=a%2Fb` returns `a%2Fb` | Decoded parameter should be `a/b` |
| `Uri.encode` | Space becomes `+` | Android URI component encoding percent-escapes it |
| `Uri.Builder.appendQueryParameter` | `q` value `a&admin=1` produces `?q=a&admin=1` | Value must be escaped; current output changes query structure |
| `Base64.decode(DEFAULT)` | Embedded newline throws | Android decoding accepts wrapped input; stub also ignores encoding line-wrap/CRLF semantics |

These are useful, small conformance fixtures for the ABI matrix. Do not infer that every extension uses these methods, or that the fixture covers dex2jar correctness. Test actual Android-compiled field/method descriptors as well as Kotlin source calls. [Pair stub](macos/daemon/src/main/kotlin/android/util/Pair.kt:7), [URI stub](macos/daemon/src/main/kotlin/android/net/Uri.kt:75), [Base64 stub](macos/daemon/src/main/kotlin/android/util/Base64.kt:36). Contract references: [Android Pair](https://developer.android.com/reference/android/util/Pair), [Android Uri](https://developer.android.com/reference/android/net/Uri), [Android Uri.Builder](https://developer.android.com/reference/android/net/Uri.Builder), and [AOSP Base64 implementation](https://raw.githubusercontent.com/aosp-mirror/platform_frameworks_base/master/core/java/android/util/Base64.java).

### N07 — P2 — Context filesystem stubs ignore the configured isolated data root [Probe]

`CloudDirs` respects `cs.cloudstream.home`; `Context.getFilesDir/getCacheDir` directly use `user.home/.cloudstream-macos`. Therefore an otherwise correctly isolated plugin test can still write the real application directory when it calls these common stubs. The new probe temporarily redirects `user.home` to a directory inside the isolated audit root and confirms the divergence safely.

The original probes do not call these filesystem methods, so this does **not** invalidate their recorded isolation or imply they touched real user data. It does invalidate a general claim that setting the test data-root property isolates all stub-mediated writes. Route all host-controlled stub directories through the same injected root and give plugins their own namespaces. This is ordinary host correctness in addition to F18's acknowledged inability to confine malicious arbitrary code. [Context paths](macos/daemon/src/main/kotlin/android/content/Context.kt:24), [CloudDirs](macos/daemon/src/main/kotlin/com/lagradost/macos/CloudDirs.kt:12).

### N08 — P2 — Solved-cookie lookup receives the wrong input type [Probe + source]

`SolveInterceptor` passes `request.url.host` and `prepared.url.host` to `cookieHeaderFor`. That helper parses its argument as a URI and uses `.host`; for a bare hostname, `.host` is null. A probe stores cookies for an HTTPS URL, gets them back using the URL, and gets null using the same bare hostname.

The immediate retry can still work through `solution.cookies`, so “the solver never works” would overstate this. The helper-based pre-injection and cached fallback do fail, causing avoidable challenges/timeouts for later repository and provider requests unless another cookie mechanism supplies them. Give the helper an explicitly host-based interface or pass a full URL consistently, then test interception end-to-end. [Caller](macos/daemon/src/main/kotlin/com/lagradost/macos/SolveInterceptor.kt:31), [helper](macos/daemon/src/main/kotlin/com/lagradost/macos/SolveBridge.kt:85).

### N09 — P2 — Initial repository bootstrap can wait for a solver that has not started [Source; unmeasured timing]

On first endpoint publication, `AppState.observeEngine` awaits bootstrap before calling `startSolvePolling`. Bootstrap performs repository requests through the shared HTTP client, and startup installs `SolveInterceptor` on that client. If a root or list request hits a supported challenge, the daemon parks it waiting for the Swift solver, but the initial Swift polling loop has not started. The solve wait is bounded at 90 seconds; this is a dependency cycle until timeout/failure, not necessarily a permanent deadlock. A previous polling loop after a restart may change the behavior.

Start challenge servicing once the endpoint is verified, independently of repository sync; avoid startup requiring provider `load()` network operations before the IPC service is available. Add a first-launch challenged-repository integration test. [Bootstrap-before-poll order](macos/client/Sources/ViewModels/AppState.swift:145), [interceptor install](macos/daemon/src/main/kotlin/com/lagradost/macos/NetworkSetup.kt:15), [park](macos/daemon/src/main/kotlin/com/lagradost/macos/SolveInterceptor.kt:49).

### N10 — P2 — Security claims are also wrong in product copy and the WebKit storage path [Source + platform documentation]

Onboarding promises that extensions are signature- and hash-verified before execution. The daemon permits unsigned roots and missing/blank artifact hashes; this is inaccurate even before considering F10–F15's bypasses. Fix the user-facing statement, not just Security.md or badges.

Security.md's memory-only cookie description also omits the Swift solver's explicit `WKWebsiteDataStore.default()`. Apple documents that this default store persists website data to disk; a nonpersistent store is a separate API. This is the app's WebKit store, not evidence of access to Safari's browser profile. The solver additionally falls back to submitting all matching-domain cookies when its clearance-name filter is empty. Document the actual retention policy, choose persistent versus nonpersistent storage intentionally, and avoid returning unrelated cookies to the shared plugin runtime. [Onboarding promise](macos/client/Sources/UI/Components/OnboardingView.swift:33), [WebKit store](macos/client/Sources/Services/WebViewSolverService.swift:32), [cookie selection](macos/client/Sources/Services/WebViewSolverService.swift:75), [Apple WKWebsiteDataStore](https://developer.apple.com/documentation/webkit/wkwebsitedatastore?changes=la_5).

## Stronger evidence for already-mentioned risks

**Signed rollback/replay is accepted.** A new probe signs revision 2 and revision 1 with the same real Ed25519 key, syncs 2, then replays 1. Both return verified and revision 1 replaces the repository. This is not a signature forgery. F15's remedy and the original acceptance gates already mention rollback; promote it into an explicit reproducible trust requirement rather than count it as a wholly new vulnerability. A future protocol needs authenticated monotonic catalog revisions and a defined freshness/offline policy; `manifestVersion` is a format version, not automatically a release counter. [Signature verification](macos/daemon/src/main/kotlin/com/lagradost/macos/RepoSignature.kt:51), [unconditional replacement](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:486).

**F30's cooperative-timeout warning is correct.** Kotlin explicitly states timeout cancellation is cooperative; synchronous blocking work is not forcibly terminated. Existing suspension-based timeout tests cannot prove a hard wall-clock bound. Do not turn this into a measured starvation or denial-of-service claim without a process-isolated blocking fixture. [Kotlin withTimeout contract](https://kotlinlang.org/api/kotlinx.coroutines/kotlinx-coroutines-core/kotlinx.coroutines/with-timeout.html).

**The read-only repository endpoint needs richer status before replacing bootstrap sync.** `listRepositories()` always returns `status="ok"`, `error=null`, description/icon null, and manifestVersion 1. Merely swapping the client to GET `/repos` fixes one authority problem but will not expose freshness, degraded catalogs, or preserved metadata correctly. Persist and return last successful sync and last attempt/error separately. [Repository projection](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:72).

**Redirect handling needs both policy and correct resolution bases.** `fetchUrlBytes` discards response URL/provenance, while sync resolves relative lists against the requested root and artifacts against the requested list. If redirects change directories, relative references can resolve to the wrong location. This is a source-level interoperability risk requiring a redirect fixture, in addition to F16's transport-policy concerns. Do not claim an actual public repository currently fails without checking it. [Fetch return](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:298), [relative references](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:465).

## Disposition of all 37 original findings

“Supported” means the stated mechanism is present in inspected source; it does not mean every example, scale threshold, or UI sequence was executed. “Reproduced” applies to the original probe's scope only.

| Finding | Disposition |
|---|---|
| F01 | Underlying bootstrap/preferences split remains. Historical add/remove UI trace is stale and replacement store is missing; do not mark fixed |
| F02 | Reproduced; repository-scoped lookup absent |
| F03 | Supported; provider names remain global identity and cache keys |
| F04 | Supported lack of update action/version policy; correct the obsolete “ignores update flag” statement |
| F05 | Reproduced; slow dropped, loaded down provider retained. “Down” is an operational status, not necessarily a cryptographic security revocation |
| F06 | Reproduced; working generation removed before candidate instantiation |
| F07 | Reproduced; rollback and classloader cleanup missing; add N03 |
| F08 | Reproduced duplicate registration; direct-final cache publication races supported by source |
| F09 | Supported interleavings; JSON mutex is not a lifecycle transaction. No dedicated stale-sync interleaving probe was run |
| F10 | Reproduced equal-size corrupt-cache return; distinguish verified download bytes from returned file bytes |
| F11 | Reproduced fallback bypass; no genuine hostile plugin used |
| F12 | Supported nonempty-JAR trust, incomplete translation, and absent toolchain versioning; no real multidex translation executed |
| F13 | Reproduced isolated traversal deletion; suffix and user-removal preconditions matter |
| F14 | Unsigned downgrade reproduced. Unsigned JSON preserves the stored pin but bypasses its enforcement; HTML can erase it |
| F15 | Reproduced detached-list gap; strengthen with replay fixture and explicit TOFU meaning |
| F16 | HTTP list fetch reproduced; other destinations/redirects are source-level policy gaps, not individually tested exploits |
| F17 | Reproduced pin loss; move earlier in remediation order |
| F18 | Supported architecture/trust limitation, not an executed hostile-code exploit |
| F19 | Supported resource/startup risk; numeric exhaustion thresholds unmeasured; add deterministic N04 |
| F20 | Reproduced orphan survival; shared ownership and multidex cleanup supported by source |
| F21 | Reproduced shared API mapping retention; add host-job lifecycle ownership |
| F22 | Supported unlocked registry traversal. `AtomicList.filter` itself locks; `firstOrNull`/`toList` and cross-registry snapshots remain unsafe |
| F23 | Reproduced write failure reporting success; corruption resets policy in source. Atomic replacement does not prove power-loss durability or multi-process safety |
| F24 | Reproduced saved override ignored; partial replacement, success reporting, and plaintext credentials remain supported |
| F25 | Supported latest-catalog reconstruction, absent DTO provenance, and publisher-controlled ownership claim |
| F26 | Backend semantics remain deficient. Current route also matches plugin hashes/descriptors then writes provider-name state; it is not exclusively a direct provider-name lookup. Old UI details are stale |
| F27 | Supported ABI/resource mismatch; extend to Pair/URI/Base64 with N06 |
| F28 | Reproduced preferences reset/remove/clear failures; durable namespaced storage still absent |
| F29 | Reproduced loss of declared homepage request structure |
| F30 | Supported cooperative cancellation/resource-boundary warning; do not claim a measured hard timeout or worker-exhaustion threshold |
| F31 | Reproduced; shared modern API already delegates to legacy, causing duplicate legacy calls on null |
| F32 | Supported whole-URL lowercasing/substring matching |
| F33 | Partly supported; **withdraw remote-down aggregate install claim**; retain identity/provenance/partial-commit findings |
| F34 | Specific old view race is stale; sheet/task design changed but stores are missing. Bootstrap still lacks engine/request generation validation |
| F35 | Supported parser inconsistencies. Explicit unknown shortener's first request preserves case; lowercased fallback/bare-code handling still changes identity |
| F36 | Supported unescaped remaining JSON controls and unspecified external canonicalization protocol; not demonstrated as a signature forgery |
| F37 | Bootstrap still network-syncs and replaces failures with empty/missing state; current view refresh/mutation paths depend on missing store code |

The Android comparison is generally accurate for the checked-out implementation: repository-qualified paths, version/-1 handling, streaming temporary-file publication, remote-down unloading, and homepage request iteration are present. It is right to warn that Android's own load/unload paths are not transactional. Do not treat comparison to Android as a security certification or a promise of full Android ABI compatibility.

## Missing verification and revised repair priorities

1. **Establish a buildable client and recoverable first-run flow.** Complete the new store/model integration, run a clean build, then test empty-install onboarding. These are immediate delivery gates alongside the security blockers.
2. **Repair authenticity and fail-closed policy together.** F10–F17, the security-policy part of F23, authenticated catalog/artifact ownership, and replay/freshness rules. Define compatibility versus trusted-repository policy and match user-facing copy to it.
3. **Introduce committed installations and coordinated lifecycle generations.** Preserve working versions; handle failed installation/retry, shared artifacts, tombstones, status changes, persistence failures, active jobs, and startup quarantine in one model. UI-only serialization cannot protect against independent IPC requests or startup paths.
4. **Restore supported provider semantics and binary compatibility.** Exercise Android-compiled fixtures through actual DEX translation, including common stub methods, settings/resources, multi-provider and extractor-only plugins. Run real signed/unsigned repository fixtures separately from live internet tests.
5. **Separate startup, local refresh, remote sync, and challenge servicing.** Keep cached data visible, make operations observable/reconcilable, fix the cookie helper contract, and ensure the solver is available before work depends on it.
6. **Measure containment and scale with disposable processes.** Blocking load/unload/search, memory pressure, cyclic discovery, filesystem failures, daemon death during commit, and signed release entitlements need their own evidence. Avoid running deliberately unbounded hostile fixtures in the normal test JVM.

The original acceptance-gate list is a strong starting point. Add explicit gates for: native compilation; clean first-run onboarding; cache-present/descriptor-absent recovery; per-file boot I/O failure; disable/uninstall with active host jobs; stub ABI and encoding conformance; data-root isolation across Context; challenged bootstrap and repeated cookie reuse; and persistent WebKit data policy. Test repository transport with actual redirect/status behavior rather than only application interceptors returning HTTP 200.

No finite review establishes the absence of other defects. The added evidence supports specific corrections and additional failure mechanisms; it does not justify either discarding the original audit or treating its passing characterization probes as a release approval.
