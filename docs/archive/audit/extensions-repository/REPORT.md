# Extensions and repository system audit

**Assessment: the macOS implementation is not ready to be called enterprise grade.** The separation between native UI and scraper daemon is useful, but repository ownership, installation state, runtime identity, authenticity, and lifecycle transactions are not consistently modeled. These are systemic issues; cosmetic cleanup or more exception handling will not resolve them.

Reviewed on 2026-09-30 against this working tree. Android baseline: local `app/` and shared `library/`, Git HEAD `643f78c1f51a11d5b6ff746d7d10a13df79fa9cd`. The macOS tree is largely untracked and the workspace contains pre-existing edits. This is a comparison with the checked-out Android implementation, not a claim about a newer upstream release.

Production source was not changed. Added this report and opt-in diagnostic probes only. A finite audit cannot establish that every possible bug has been found.

## Evidence and validation

- The existing daemon suite ran successfully: **73 passed, 3 skipped**. The three skipped tests require live repositories/plugins.
- **19 isolated characterization probes passed**, meaning each probe reproduced the undesirable behavior it was designed to expose. Passing these probes is evidence of defects, not a clean bill of health.
- All probe HTTP responses were intercepted; no community plugin was downloaded or executed. Files were isolated under `macos/daemon/build/tmp/extensions-audit-home`.
- Loader probes use harmless synthetic archives and a deliberately warmed JAR cache resolving a test-classpath plugin. They exercise lifecycle/cache handling, not dex translator correctness or compatibility with every real extension.
- Client findings are source-level traces. No SwiftUI automation, live-provider compatibility matrix, Android device run, destructive exhaustion test, or hostile-code execution was performed.
- The normal Gradle test configuration was restored after the opt-in run.

Evidence labels below: **Probe** = executable reproduction; **Code** = direct source/data-flow evidence; **Risk** = an architectural failure mode whose load/environment threshold was not measured. P1 means fix before the stated reliability/security target; P2 means important correctness or compatibility work; P3 means lower-impact polish/interoperability.

[Probe source](macos/docs/audit/extensions-repository/ExtensionsRepositoryAuditProbe.kt), [probe results](macos/docs/audit/extensions-repository/probe-results.json), [normal-suite results](macos/docs/audit/extensions-repository/baseline-results.json), and [source fingerprints](macos/docs/audit/extensions-repository/reviewed-source-sha256.json) accompany this report.

## Architecture compared with Android

| Concern | Android in this checkout | macOS in this checkout | Assessment |
|---|---|---|---|
| Execution | Android process, `PathClassLoader`, native DEX/runtime/resources | SwiftUI → authenticated loopback Ktor → dex2jar → JVM `URLClassLoader` | Good UI/process separation, substantially different plugin ABI and failure boundary |
| Repository state | `RepositoryData` persisted through app storage | `DaemonState.repos` plus separate Swift `repositoryURLs` | Two competing authorities break visible add/remove/offline behavior |
| Installation identity | `PluginData` records internal name, URL, repository-derived file path, installed version | Content hash map plus current catalog/name guesses/cache existence | Missing durable installation and ownership records |
| Repository collisions | Repository URL participates in plugin path; update matching validates that path | Global first name match; repository argument ignored during catalog selection | Cross-repository installation/update/removal errors |
| Updates | Compare installed version; `-1` means always update; remote-down handling | Hash comparison only, no normal UI update action, bulk load bypasses replacement | Significant regression |
| Artifact publication | Stream to temporary file, check optional hash, atomic move preferred | Buffer entire response, write final file directly, reuse equal-length files | Integrity and concurrency regression |
| Trust | Optional artifact hash; no equivalent signed-root chain in reviewed manager | Optional hash plus custom Ed25519/TOFU root | Added security intention, but downgrade and detached-list gaps defeat its guarantees |
| Offline startup | Load installed records, safe-mode mechanisms | Load latest catalog hashes, then scan every cached source | Cache doubles as installation authority, including rejected/orphan files |
| Provider execution | Shared provider engine, Android APIRepository behavior | Shared engine, custom ProviderExecutor and IPC DTOs | Name identity and homepage semantics diverge |
| Provider configuration | Android context/resources/settings support | Partial stubs, ephemeral settings, config endpoint with no restore application | Compatibility and persistence failures |
| Concurrency | Some mutexes/map synchronization, still incomplete lifecycle transactions | Atomic JSON update and concurrent descriptor map, but no lifecycle coordinator | Thread-safe containers do not make install/update/remove atomic |

Key Android references: [installation records](upstream/app/src/main/java/com/lagradost/cloudstream3/plugins/PluginManager.kt:79), [repository-qualified paths](upstream/app/src/main/java/com/lagradost/cloudstream3/plugins/PluginManager.kt:747), [update selection](upstream/app/src/main/java/com/lagradost/cloudstream3/plugins/PluginManager.kt:225), [download publication](upstream/app/src/main/java/com/lagradost/cloudstream3/plugins/RepositoryManager.kt:193), [resource loading](upstream/app/src/main/java/com/lagradost/cloudstream3/plugins/PluginManager.kt:611), [homepage semantics](upstream/app/src/main/java/com/lagradost/cloudstream3/ui/APIRepository.kt:156).

Strengths worth retaining: loopback binding, bearer authentication, token delivery through stdin, explicit IPC versioning, ordinary supplied-hash mismatch rejection, atomic replacement of state JSON, structured logs, and a separate daemon process. These do not compensate for the defects below.

## Findings

### F01 — P1 — Repository add/remove uses incompatible sources of truth [Code]

[Add/remove actions](macos/client/Sources/UI/Extensions/ExtensionsView.swift:513) mutate the daemon, then [bootstrap](macos/client/Sources/ViewModels/AppState.swift:173) replaces the visible repositories with the results of [syncing Swift preferences](macos/client/Sources/Services/UserPreferences.swift:123). Neither action updates `repositoryURLs`; the client’s `repos()` accessor has no caller.

**Trigger/result:** add a non-default repository: daemon persists it but the refresh hides it. Remove a preference-listed/default repository: the next bootstrap sync recreates it. Offline sync failures erase visible rows even though cached repository state exists. HTML-discovered child repositories are likewise invisible.

**Remedy:** make the daemon’s persisted repository registry authoritative. Refresh UI with read-only `/repos` and `/plugins`; migrate the old preference list once. Separate add, remove, refresh, and remote sync operations.

### F02 — P1 — Installation lookup ignores repository identity [Probe]

[installPlugin](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:587) searches all catalogs by internal name, display name, or URL and chooses the first match. It does not constrain the lookup by `repoUrl`, then overwrites that entry’s URL with the caller’s URL. [Loaded lookup](macos/daemon/src/main/kotlin/com/lagradost/macos/PluginBridge.kt:218) further uses substring matching against a hash-based filesystem path and manifest display names.

**Trigger/result:** repositories A and B both publish `Same`. Installing B downloads B’s URL using A’s hash/metadata; the probe gets a hash rejection naming A’s digest. With missing hashes, the wrong ownership/metadata can be accepted. Update/uninstall lookup can target a same-name extension from another repository. An empty name matches every filename.

**Remedy:** immutable `PluginKey(repositoryID, internalName)`; exact lookup only. The daemon should derive URL/hash from that catalog key rather than accept an independent caller-supplied tuple. Retain content hashes only as artifact identities.

### F03 — P1 — Provider names are treated as globally unique IDs [Code]

[Provider lookup](macos/daemon/src/main/kotlin/com/lagradost/macos/PluginBridge.kt:242), [enable state](macos/daemon/src/main/kotlin/com/lagradost/macos/DaemonState.kt:104), [configuration](macos/daemon/src/main/kotlin/com/lagradost/macos/Main.kt:294), [link-cache keys](macos/daemon/src/main/kotlin/com/lagradost/macos/ProviderExecutor.kt:216), and [Swift result identity](macos/client/Sources/Models/Dtos.swift:89) all depend on display names. A plugin hash also resolves only its first provider.

**Trigger/result:** two extensions or clones register `Movies`. Detail/playback routes select the first, disabling one affects both, and identical episode data can reuse the other provider’s cached links. Plugin update/configuration changes leave old cache entries valid for up to three minutes. Saved library coordinates lack sufficient identity to disambiguate future duplicates.

**Remedy:** carry stable provider IDs through IPC, preferences, library, downloads, metrics, and caches. Include plugin generation/configuration revision in cache keys. Support multiple independently configured instances explicitly.

### F04 — P1 — Updates have no working normal UI path [Code]

[Update detection](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:540) requires a hash and matches a loaded descriptor by name. [Catalog UI](macos/client/Sources/UI/Extensions/ExtensionsView.swift:486) ignores `isUpdateAvailable` and only shows “Installed.” Normal [sync](macos/client/Sources/Services/DaemonClient.swift:109) defaults `installAll=false`; it updates metadata, not installed plugins. Installed versions are not separately retained.

**Trigger/result:** a working plugin becomes stale after its repository publishes a fix; syncing does not update it and the UI offers no Update button. Hashless repositories never show an update, and Android’s [version/-1 policy](upstream/app/src/main/java/com/lagradost/cloudstream3/plugins/PluginManager.kt:229) is absent. The API’s [bulk install path](macos/daemon/src/main/kotlin/com/lagradost/macos/Main.kt:165) loads new hashes without unloading older generations, so using that as an updater creates duplicate versions.

**Remedy:** persist installed version/digest independently of the catalog. Implement one update coordinator used by single/bulk/automatic updates and expose update/retry/rollback states. Define downgrade and always-update policies.

### F05 — P1 — Remote status handling hides usable plugins and fails to revoke loaded ones [Probe]

[Catalog persistence](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:483) retains only status `1`. Android documents `0=down`, `1=OK`, `2=slow`, `3=beta` and [explicitly unloads remote-down plugins](upstream/app/src/main/java/com/lagradost/cloudstream3/plugins/PluginManager.kt:305).

**Trigger/result:** status `2` disappears despite being usable. A status `0` plugin disappears from the catalog but remains registered and searchable. The fallback startup scan can reload its cached source. The probe confirms the catalog becomes empty while the revoked provider remains available.

**Remedy:** persist all statuses; separate discovery visibility, channel compatibility, install eligibility, and runtime revocation. Reconcile revocations against installed records and enforce them before startup/load.

### F06 — P1 — Failed updates destroy the working runtime before validating replacement [Probe]

[Replacement](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:608) removes the old plugin before translating/instantiating/loading the new one. Removal marks the old hash as user-removed. There is no rollback transaction.

**Trigger/result:** new version has a missing class or fails in `load()`. The update reports failure, the working provider disappears, and its old cached version is suppressed on restart. The probe confirms the old descriptor is gone and its hash is tombstoned.

**Remedy:** stage and validate a candidate in an isolated runtime; publish a new registry generation only after successful initialization and durable commit. Distinguish retirement during update from user uninstall. Keep a last-known-good generation.

### F07 — P1 — Partial plugin load leaves untracked executable providers [Probe]

[Registration](macos/daemon/src/main/kotlin/com/lagradost/macos/PluginBridge.kt:150) directly mutates shared registries during `load()`; the descriptor is only inserted afterward. The [outer exception barrier](macos/daemon/src/main/kotlin/com/lagradost/macos/PluginBridge.kt:56) logs and returns null without undoing registration or closing the candidate classloader.

**Trigger/result:** plugin registers a provider/extractor, then throws. It is absent from `/plugins` but its provider remains searchable. Retry can add more copies. The probe reproduces a visible runtime provider with no loaded descriptor.

**Remedy:** transactional registration scope with complete rollback of providers, extractors, API mappings, and resources. Close candidate classloaders on all unsuccessful paths. A failed install must not become an implicit next-boot retry.

### F08 — P1 — Simultaneous loads are not idempotent; cache publication is racy [Probe + Code]

[Bridge check-then-load](macos/daemon/src/main/kotlin/com/lagradost/macos/PluginBridge.kt:74) and final map insertion are separate operations. ConcurrentHashMap does not serialize the intervening translation, registration, and classloader creation. [CS3 writes](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:758) and [JAR translation](macos/daemon/src/main/kotlin/com/lagradost/macos/PluginBridge.kt:114) also target final paths directly.

**Trigger/result:** the probe starts two loads of the same artifact and obtains two registered providers but one descriptor. Concurrent writers/readers can see partial CS3/JAR files; failed conversion cleanup can delete a competing operation’s output. Uninstall can race an install that later re-registers the extension.

**Remedy:** keyed lifecycle serialization, artifact-level single-flight work, temporary files plus atomic publication, and cancellation/generation checks before commit. Uninstall must cancel or wait for in-flight operations.

### F09 — P1 — Sync can resurrect removed repositories or overwrite trust/state from stale work [Code]

[Sync](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:351) performs network work and reads trust outside the final [state update](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:486). [Removal](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:672) has no shared operation lock or generation/tombstone. The JSON mutex only protects each individual update.

**Interleaving:** sync begins → removal succeeds → sync completes and appends the repository again. Two first-use syncs can both observe no key and validate different keys; the later commit wins. An older catalog request can overwrite a newer result.

**Remedy:** repository-scoped operation coordinator and revision-checked commit. Revalidate the pinned key inside commit; persist removal generations so cancelled/stale syncs cannot recreate a removed repository.

### F10 — P1 — Download verification can return different bytes from those verified [Probe]

[fetchVerifiedCs3](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:735) hashes the downloaded bytes but [reuses an existing file of the same size](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:759) without checking that file’s content.

**Trigger/result:** cached content is corrupt or replaced with equal-length content. A fresh correct download verifies successfully, but the method returns the corrupt cached file. PluginBridge recomputes its hash and loads it without comparing it to the expected digest. The probe verifies “good” but returns “evil.”

**Remedy:** hash the exact file being published/loaded. Replace mismatched cached content atomically, even if size matches. Never use size as proof of content identity.

### F11 — P1 — Startup’s fallback scan bypasses explicit hash rejection [Probe]

The [first boot pass](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:697) detects mismatches. The [second pass](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:715) recomputes content hashes but does not require them to match the filename or catalog expectation; it loads the same rejected file under its actual digest.

**Trigger/result:** a cached file under expected hash H contains another valid plugin. The first pass rejects it; the fallback loads it. The probe reproduces that sequence. Orphaned and previously failed-install artifacts are also eligible simply because they are in the source cache.

**Remedy:** boot only committed installation records with verified digests. Quarantine mismatches; never retry them through a permissive scan. Treat a cache as disposable storage, not permission to execute.

### F12 — P1 — Translated JARs are trusted solely by filename and nonzero size [Code]

[Bytecode cache](macos/daemon/src/main/kotlin/com/lagradost/macos/PluginBridge.kt:113) accepts any existing nonempty `<source-hash>.jar`. It does not validate archive completeness, bind the output to a trusted conversion receipt, or include dex2jar/runtime/bridge ABI version in the cache key. Conversion failures in secondary DEX entries are silently omitted if another JAR remains.

**Trigger/result:** interrupted/corrupt conversion persists across restarts; repaired source download does not repair a nonempty bad JAR. A changed writable JAR executes despite a correct source digest. Engine/translator upgrades reuse stale conversion products, and partially translated plugins fail later during use.

**Remedy:** atomic validated conversion outputs keyed by source digest plus toolchain/ABI version; reject incomplete multidex conversion. Protect/cache-check receipts and rebuild suspect outputs. This mitigates cache corruption/tampering; it does not create a sandbox against already-running arbitrary plugins.

### F13 — P1 — Catalog fileHash permits filesystem traversal during removal [Probe]

[uninstallPlugin](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:656) can take `fileHash` from a catalog without validating it as a digest, then uses it as a filename in two cache directories. [Installed checks](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:573) also resolve that unvalidated path.

**Trigger/result:** a catalog supplies `../audit-victim` and a corresponding `.cs3` file exists outside `cache/sources`. Removing the repository deletes that file. The probe demonstrates this through `removeRepository(..., true)` using a harmless file under the isolated test root. More traversal segments escape the intended cache directories; the suffixes constrain targets to `.cs3` and `.jar`, but do not confine their parent path.

**Remedy:** validate exactly 64 ASCII hex digits after an explicitly permitted prefix at deserialization; never use untrusted catalog strings for deletion paths. Derive paths from validated installed artifact records and enforce canonical containment/symlink policy.

### F14 — P1 — A pinned signed repository can downgrade to unsigned or HTML [Probe + Code]

[RepoSignature.verify](macos/daemon/src/main/kotlin/com/lagradost/macos/RepoSignature.kt:63) returns null if the signature member is missing, even with a pin. [sync](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:450) accepts that result. The [HTML path](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:369) runs before signature verification and replaces the repository with null pins.

**Trigger/result:** previously signed repository serves an unsigned manifest: accepted and persisted. HTML can also erase its pin. Key pinning therefore does not enforce continuing signed publication.

**Remedy:** if a pin exists, require a valid signature before any content-type branch. Trust reset must be an explicit, separately authorized operation; reject signature removal and HTML substitution.

### F15 — P1 — A valid root signature does not authenticate plugin lists or artifacts [Probe]

[Signature verification](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:452) covers the root document. [pluginLists](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:465) are subsequently fetched from URLs, but their content digests/signatures are not bound into the signed root. Artifact hashes themselves come from those unbound lists and may be absent.

**Trigger/result:** keep the signed root unchanged and replace its external plugin list. Both syncs report verified; a new unsigned list can select different bytes or omit the digest. The probe changes a plugin entry without the signing key and retains `verified=true`. This requires control of the list response/origin, not merely unauthenticated access to the local IPC port.

**Remedy:** establish a complete chain: trusted root → signed catalog or catalog digest → required artifact digest. Add expiry/version/rollback rules. Keep compatibility repositories usable only under an accurately labeled lower-trust policy.

### F16 — P1 — HTTPS enforcement stops at the initial repository string [Probe + Code]

[sync](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:353) checks the root string. [Nested lists](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:465), [artifact downloads](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:735), and the direct install API do not apply an equivalent policy. [fetchUrlBytes](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:269) uses the common client and does not enforce destination/redirect restrictions or reject non-success HTTP status before consuming the body.

**Trigger/result:** an HTTPS manifest includes an HTTP plugin list; the probe confirms the HTTP fetch is accepted. A list can choose an HTTP artifact, including one with no hash. Supplied URLs can also target local/private services; redirect destinations are not explicitly checked here.

**Remedy:** dedicated repository transport validates every hop, requires HTTPS for executable metadata/artifacts, checks status and bounded content length, and applies an explicit local/private-host policy. Private enterprise repositories can be supported through intentional allowlisting rather than accidental unrestricted access.

### F17 — P2 — Failed re-trust destroys the previous trust pin [Probe]

[reTrust](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:523) clears the pin before fetching/verifying the replacement.

**Trigger/result:** network or JSON failure leaves the repository unpinned. The probe observes null after a failed call, so a later ordinary sync can accept a different key. The client has no implemented fingerprint review/re-trust interaction even though the error says re-trust is required.

**Remedy:** fetch a candidate, present old/new fingerprints, validate it, then atomically replace the pin. Failure must retain the old pin. Add a concrete client recovery flow if key rotation is supported.

### F18 — P1 — Plugin execution has daemon/user privileges; exceptions are not isolation [Code / architectural gap]

[URLClassLoader and reflective execution](macos/daemon/src/main/kotlin/com/lagradost/macos/PluginBridge.kt:133) run arbitrary plugin code in the shared JVM. [CloudDirs](macos/daemon/src/main/kotlin/com/lagradost/macos/CloudDirs.kt:9) is a path convention, not an access-control boundary. App/JRE entitlements do not enable App Sandbox. The loader’s “hostile plugin can never crash” comment is stronger than the implementation.

**Impact:** a malicious plugin can access files available to the daemon, mutate shared clients/registries, spawn work, terminate the JVM, or interfere with other providers. A separate Swift process limits some UI crash impact but does not provide per-plugin security. Security.md acknowledges arbitrary code as a residual risk while also presenting filesystem/integrity claims as enforced.

**Remedy:** for untrusted multi-provider operation, use supervised worker processes with an actual OS-enforced permission boundary, resource limits, explicit network/storage capabilities, and per-plugin or deliberate trust-group isolation. A classloader or separate unsandboxed process alone is insufficient. Android also executes plugins with app privileges; copying that trust model is not an enterprise security solution.

### F19 — P1 — Unbounded ingestion and startup loading can take the entire engine down [Risk]

[Downloads](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:298) buffer entire bodies; [DEX extraction](macos/daemon/src/main/kotlin/com/lagradost/macos/PluginBridge.kt:100) expands all entries in memory; [HTML discovery](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:377) fans out without entry/depth/visited limits. [Startup](macos/daemon/src/main/kotlin/com/lagradost/macos/Main.kt:100) loads cached plugins before serving health, with no load timeout or safe-mode quarantine. The [supervisor](macos/client/Sources/App/DaemonSupervisor.swift:264) has a 192 MB heap and exits on OOM; [health startup](macos/client/Sources/App/DaemonSupervisor.swift:347) stops waiting after 20 seconds.

**Trigger/result:** a large archive, compression bomb, broad/cyclic catalog, expensive translation, or blocking `load()` can starve/kill the daemon or make it miss readiness. A cached offending plugin is retried on restart. Timeouts around recursive sync do not impose a byte/memory/concurrency limit.

**Remedy:** streaming limits, maximum manifest/list/plugin/expanded sizes, bounded discovery/download/conversion queues, visited/depth budgets, worker deadlines, persistent loading markers, automatic quarantine, and a safe-mode startup path. Measure multi-provider cold/warm boot under representative load.

### F20 — P1 — Repository removal cannot reliably identify what it owns [Probe + Code]

[removeRepository](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:672) enumerates the *latest catalog*, not committed installations. Hashes/name guesses provide neither stable ownership nor reference counts.

**Trigger/result:** installed extension disappears from a later catalog, is remote-disabled, or loses matching metadata; removing its repository leaves it loaded and cached. The probe shows an installed plugin survives removing a now-empty repository. Conversely, shared/same-name artifacts across catalogs can be removed on another repository’s behalf. Multidex uninstall deletes only the primary `<hash>.jar`, leaving secondary outputs behind.

**Remedy:** installation ownership records independent of catalog availability; reference-count shared artifacts; deterministic cleanup of every generation/output. Keep “remove repository but retain installed extensions” an explicit supported state with retained provenance.

### F21 — P2 — Unload leaves shared provider mappings alive [Probe]

[macOS removal](macos/daemon/src/main/kotlin/com/lagradost/macos/PluginBridge.kt:281) removes `allProviders` and extractors but omits `APIHolder.removePluginMapping`. [BasePlugin registration](upstream/library/src/commonMain/kotlin/com/lagradost/cloudstream3/plugins/BasePlugin.kt:21) populates that mapping. [Android unload](upstream/app/src/main/java/com/lagradost/cloudstream3/plugins/PluginManager.kt:703) attempts to remove it.

**Trigger/result:** after uninstall, shared `APIHolder.getApiFromNameNull` still resolves the removed provider. The probe confirms this. Metaproviders can retain access to obsolete instances; references prevent clean classloader retirement.

**Remedy:** one registry transaction must remove every mapping and cached handle belonging to the retired generation; add an unload/reload test through both direct daemon lookup and shared engine lookup.

### F22 — P2 — Registry readers iterate without the required lock [Code]

[allProviders().toList / firstOrNull](macos/daemon/src/main/kotlin/com/lagradost/macos/PluginBridge.kt:249) iterate `AtomicList` without `withLock`. [AtomicList](upstream/library/src/commonMain/kotlin/com/lagradost/cloudstream3/utils/AtomicList.kt:27) explicitly leaves iterators unsynchronized. Locking removal alone does not protect an unlocked reader.

**Trigger/result:** install/remove while search, health, or `/plugins` snapshots the registry can yield inconsistent snapshots or collection-modification failures. Descriptor/provider lists can also be observed from different lifecycle generations.

**Remedy:** snapshot registries under their locks or publish immutable registry generations. Never hold registry locks while executing untrusted plugin callbacks. Android’s mutable registries also require scrutiny.

### F23 — P2 — Persistence failure is reported as successful mutation; corruption loses policy [Probe + Code]

[DaemonState.update](macos/daemon/src/main/kotlin/com/lagradost/macos/DaemonState.kt:75) assigns `current` before disk persistence, catches write failure, and returns normally. [load](macos/daemon/src/main/kotlin/com/lagradost/macos/DaemonState.kt:61) treats any decoding/read failure as an empty state.

**Trigger/result:** a disk-full/permission/path failure makes an action appear successful but it disappears on restart. The probe forces a temp-file write failure and observes exactly that. Corrupt state removes disabled-provider settings, removal marks, and trust pins; permissive cache scanning can then reactivate content. Atomic rename does not address these failure paths or concurrent independent daemon processes.

**Remedy:** explicit commit result, preserve the last committed snapshot, maintain recoverable/versioned backup state, and enter a safe recovery state rather than silently using empty policy. Lock a data-root to one daemon. Validate supported state schema versions.

### F24 — P2 — Provider configuration is saved but not restored or safely merged [Probe + Code]

[config endpoint](macos/daemon/src/main/kotlin/com/lagradost/macos/Main.kt:294) stores `ProviderOverride`; [overrideFor](macos/daemon/src/main/kotlin/com/lagradost/macos/DaemonState.kt:114) has no production caller. Loader does not apply overrides. Partial updates merge into live fields but persist only fields supplied in the current request.

**Trigger/result:** configured host/credentials disappear after reload/restart. The probe confirms a persisted URL override is ignored on load. A credentials-only update can discard the previously persisted URL. Providers that refuse overrides still receive a success response. Credentials are serialized as cleartext in [state.json](macos/daemon/src/main/kotlin/com/lagradost/macos/DaemonState.kt:21), contrary to the documentation’s claim that the daemon holds no user secrets.

**Remedy:** stable instance-keyed configuration, patch semantics with explicit reset, apply before publishing a provider, report unsupported overrides, invalidate caches on revision changes, and use protected secret storage/references rather than cleartext JSON.

### F25 — P2 — Installed metadata and trust are reconstructed from mutable/untrusted catalog claims [Code]

[pluginMetadataFor](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:765) joins by latest catalog hash, so hashless installs or old installed versions lose provenance/version metadata. [GET /plugins](macos/daemon/src/main/kotlin/com/lagradost/macos/Main.kt:241) does not populate `repositoryUrl` or `sha256` in its copy; default nulls remain. It derives `verified` from `meta.repositoryUrl`, which is supplied by the publisher rather than authoritative catalog ownership.

**Trigger/result:** installed version becomes `0`, internal name becomes a cache path, trust/origin disappears after a catalog update, and a catalog can claim another configured signed repository’s URL to influence the badge. A plugin hash shared across repositories gets the first matching metadata.

**Remedy:** persist installation-time provenance and manifest version; keep source-code/homepage URL separate from owning repository ID; report actual installed metadata and verified artifact-chain status.

### F26 — P2 — Extension enable/disable cannot represent extractor-only or multi-provider state [Code]

[GET /plugins](macos/daemon/src/main/kotlin/com/lagradost/macos/Main.kt:260) computes enabled with `providers.any`. [setEnabled](macos/daemon/src/main/kotlin/com/lagradost/macos/Main.kt:273) acts on provider names only; [Swift](macos/client/Sources/UI/Extensions/ExtensionsView.swift:228) sends `internalName`, although loaded descriptors retain hash paths and manifest names rather than that internal identifier.

**Trigger/result:** an extractor-only plugin always appears disabled and the toggle has no effect. Disabling an ordinary plugin does not remove its extractors or prevent `load()` on restart. If catalog internal name differs from manifest/provider name, the UI can toggle an unused string and change nothing. Name collisions can toggle several extensions. One shared `isToggling` ID does not serialize different-row operations.

**Remedy:** define plugin-enabled and provider-enabled independently; address by stable IDs; expose partial state for multi-provider plugins. Implement disable semantics for extractors and initialization, and operation state per target.

### F27 — P2 — Android stubs are not binary-compatible with important plugin APIs [Code]

[macOS Plugin.resources](macos/daemon/src/main/kotlin/com/lagradost/cloudstream3/plugins/Plugin.kt:34) uses `Any?`, but [Android Plugin.resources](upstream/app/src/main/java/com/lagradost/cloudstream3/plugins/Plugin.kt:34) is `android.content.res.Resources?`. [Context](macos/daemon/src/main/kotlin/android/content/Context.kt:39) returns a nested stub SharedPreferences class instead of the Android interface and also exposes resources/assets/looper with different JVM descriptors. The translated JAR classpath omits original archive assets/resources.

**Trigger/result:** an extension compiled against those Android method descriptors can fail with linkage errors even though method names look similar. Resource-dependent plugins are not detected and rejected before load; `requiresResources` and declared API compatibility do not select a supported execution path.

**Remedy:** define and test a supported binary ABI/capability matrix. Match descriptors precisely where support is real; package supported resources; fail unsupported capabilities before registration with an actionable message. Do not promise generic Android extension compatibility from a few stubs.

### F28 — P2 — Settings stubs lose values and implement removal incorrectly [Probe]

[Context.getSharedPreferences](macos/daemon/src/main/kotlin/android/content/Context.kt:39) creates a new store every call. Its editor uses ConcurrentHashMap null values for removal, which throws; clear only clears pending operations. [CloudStreamApp storage](macos/daemon/src/main/kotlin/com/lagradost/cloudstream3/CloudStreamApp.kt:10) is process-memory-only and global.

**Trigger/result:** settings disappear even before restart, `remove` raises NullPointerException, `clear` leaves committed values intact, and plugin caches/settings can collide across extensions. The probe demonstrates the first three without network or real plugins.

**Remedy:** namespaced durable stores with Android-compatible editor semantics, deletion sentinels, complete API signatures, and explicit secret handling. Prevent provider instances from sharing settings accidentally.

### F29 — P2 — Homepage execution discards the provider’s declared request structure [Probe]

[loadHome](macos/daemon/src/main/kotlin/com/lagradost/macos/ProviderExecutor.kt:144) calls once with empty name/data. Android [iterates `mainPage`](upstream/app/src/main/java/com/lagradost/cloudstream3/ui/APIRepository.kt:156), passes each request’s data, and honors sequential delays.

**Trigger/result:** providers build URLs or choose categories from request data: macOS gets empty/wrong home content or fails. The probe declares Films and Shows and observes one empty request. This is a daemon API compatibility issue even though the current native Home screen primarily shows library shelves.

**Remedy:** preserve MainAPI request semantics, capabilities, sequential ordering/delays, page state, and per-shelf error handling.

### F30 — P2 — Cancellation and advertised hard timeouts do not contain blocking plugins [Code / Risk]

[ProviderExecutor](macos/daemon/src/main/kotlin/com/lagradost/macos/ProviderExecutor.kt:419), repository helpers, and [route handlers](macos/daemon/src/main/kotlin/com/lagradost/macos/Main.kt:188) broadly catch Throwable, including cancellation. `withTimeoutOrNull` does not interrupt arbitrary non-cooperative JVM computation/blocking calls; search creates work for every provider without a separate concurrency budget. Load/unload callbacks have no deadline at all.

**Trigger/result:** cancelled UI work can continue into catches, retries, or mutations; a blocking provider can exceed the five-second search promise and delay structured completion or exhaust workers. Existing timeout tests use cooperative suspension, so they do not prove hard containment. Kotlin documents that [coroutine cancellation is cooperative](https://kotlinlang.org/docs/cancellation-and-timeouts.html).

**Remedy:** rethrow cancellation, check cancellation before committing, limit concurrency and queue length, enforce I/O deadlines, and use killable worker boundaries where a true hard timeout is required. Distinguish timeout, cancellation, no-data, and provider errors.

### F31 — P2 — Legacy null search is incorrectly reported as success [Probe]

[Legacy fallback](macos/daemon/src/main/kotlin/com/lagradost/macos/ProviderExecutor.kt:122) converts `search(query)` null to `orEmpty()`. The earlier regression test only covers a modern-API null return with an unimplemented legacy method.

**Trigger/result:** a legacy provider returns null to indicate failure; it becomes a successful empty result and increments success metrics. The new probe confirms `error == null`.

**Remedy:** preserve null as failure; fall back only on unimplemented API, not arbitrary failure. Test both modern and legacy contracts and ensure diagnostic counters reflect each result.

### F32 — P2 — Repository lookup conflates unrelated URLs [Code]

[getRepoPlugins](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:532) lowercases the whole URL and accepts substring matches in either direction.

**Trigger/result:** case-sensitive path differences or a query-suffixed URL resolve the first unrelated matching repository. Duplicate slashes/aliases may also create distinct pins on add while collapsing during lookup. The returned DTO labels the plugins with the caller’s URL, further obscuring ownership.

**Remedy:** canonical repository ID with normalized scheme/host/default port and preserved path/query semantics; exact equality. Resolve aliases once at add time with retained provenance, and never use substring matching for identity.

### F33 — P2 — HTML aggregation loses provenance and has inconsistent status semantics [Code]

[Aggregate sync](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:377) commits child repositories independently, merges by internal name alone, persists only enabled plugins, but [returns `distinctPlugins`](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:444) including disabled entries.

**Trigger/result:** two repositories publish the same name: one arbitrarily disappears according to asynchronous completion order. A failed/timed-out aggregate operation can still leave child repos committed. Aggregate `installAll` can load entries excluded by the ordinary status filter, including remote-down content. Aggregate deletion treats the same child artifacts as independently owned.

**Remedy:** discovery returns candidate repositories with provenance; validate and select before commit. Preserve repository-qualified plugin keys, expose partial success, and make batch status/ownership rules identical to individual operations.

### F34 — P2 — Overlapping UI tasks can show one repository’s plugins under another [Code]

[Catalog load](macos/client/Sources/UI/Extensions/ExtensionsView.swift:550) writes shared `browsePlugins` after an unstructured Task without cancellation or a selected-repository check. [bootstrap](macos/client/Sources/ViewModels/AppState.swift:173) similarly has no generation guard.

**Interleaving:** open A, dismiss it, open B; B returns, then A returns and overwrites the visible B catalog. The install closure uses B’s repo URL with A’s entry. Overlapping mutation-triggered bootstraps can replace newer data with older results. `isSyncing` is a shared boolean, not operation ownership.

**Remedy:** keyed tasks/request generations, cancel superseded work, check identity before state publication, and keep catalog/operation state per repository. Reconcile mutations with the daemon’s authoritative snapshot.

### F35 — P2 — URL normalization rewrites identity too broadly and inconsistently [Code]

[Swift normalization](macos/client/Sources/Services/DaemonClient.swift:65) and [daemon normalization](macos/daemon/src/main/kotlin/com/lagradost/macos/RepositoryService.kt:141) have different case, query, fragment, and decoding rules. The daemon’s migration check replaces any URL containing `likdev2583`; shortcode lookup lowercases arbitrary unknown codes and overrides explicit shortener URLs by known slug.

**Trigger/result:** case-sensitive unknown short links can resolve incorrectly; query text containing a migration keyword silently selects a different repository; uppercase HTTPS gets a second prefix in Swift. Daemon `cs.repo` query extraction can include trailing query parameters in the target. Relative redirects from shorteners are not resolved against the original URL. These are reproducible source-level parser cases, not claims that any particular public preset is currently broken.

**Remedy:** one canonical parser contract with structured URL/query handling; exact migration host/path matches; preserve shortcode case; explicit migration notices; shared fixtures covering percent encoding, queries, whitespace, schemes, and redirect chains.

### F36 — P3 — Signature canonicalization leaves some JSON control characters unescaped [Code]

[canonicalize](macos/daemon/src/main/kotlin/com/lagradost/macos/RepoSignature.kt:123) escapes common controls but emits other U+0000–U+001F characters literally. This is not a fully specified interoperable canonical-JSON implementation; prior tests cover backspace/formfeed only.

**Trigger/result:** a valid JSON manifest with escaped controls can produce a non-JSON canonical body and disagree with an external signer that emits valid JSON escapes. Numeric/Unicode canonicalization rules are also not specified as a cross-language protocol.

**Remedy:** select a documented canonical format, use a validated serializer/canonicalizer, and test cross-language vectors including all controls, Unicode, nested objects, and numbers. Version the signing format.

### F37 — P2 — Every UI refresh performs network sync, causing latency and self-rate-limiting [Code]

[bootstrap](macos/client/Sources/ViewModels/AppState.swift:176) serially syncs every preference-listed repository even after a toggle, install, or uninstall. The [sync limiter](macos/daemon/src/main/kotlin/com/lagradost/macos/RateLimiter.kt:42) permits four initial requests and refills at 0.5/s. Failed syncs replace visible repositories with only successes; a failed `/plugins` becomes an empty list.

**Trigger/result:** rapid actions or several fast repositories exhaust the limiter; an unrelated offline repository delays all local state refreshes. Users see empty/missing state instead of retained last-known-good data. A mutation may have succeeded before the client’s request timeout, but there is no operation ID/status reconciliation. The defined write limiter is not applied to the plugin lifecycle routes.

**Remedy:** make local refresh read-only and immediate; sync explicitly/in the background with coalescing, bounded parallelism, retry-after/backoff, and per-repository status. Retain last-known-good data on transient failure; use operation IDs for long-running mutations.

## Android is a reference, not a security certification

Several Android behaviors should be carried over: repository-qualified installation identity, persisted installed versions, atomic artifact publication, version/-1 updates, remote-down reconciliation, safe-mode support, and correct MainAPI homepage requests. Android itself has limitations visible in this checkout:

- [Loader registration](upstream/app/src/main/java/com/lagradost/cloudstream3/plugins/PluginManager.kt:660) mutates maps before `load()` succeeds and does not roll them back in its catch; [replacement](upstream/app/src/main/java/com/lagradost/cloudstream3/plugins/PluginManager.kt:790) unloads before proving the new version works.
- Optional hashes and URL-based plugin lists in [RepositoryManager](upstream/app/src/main/java/com/lagradost/cloudstream3/plugins/RepositoryManager.kt:169) do not form an end-to-end authenticity chain.
- Synchronizing individual map writes does not serialize all check/load/unload operations, and shared provider-name identity remains ambiguous.
- [Online metadata deletion](upstream/app/src/main/java/com/lagradost/cloudstream3/plugins/PluginManager.kt:138) removes by download URL rather than the repository-qualified installation path, so identical URLs in multiple repositories can remove more metadata than intended.
- [Statistics matching](upstream/app/src/main/java/com/lagradost/cloudstream3/ui/settings/extensions/ExtensionsViewModel.kt:62) joins internal names without the repository-path validation used by the updater, potentially miscounting duplicate names.

These are source-level comparison findings; no Android device test was run. The proposed macOS architecture should improve on these weaknesses rather than port them unchanged.

## Target design and repair order

A clean model has four separate concepts:

| Record | Required identity and fields |
|---|---|
| Repository | Stable repository ID, canonical URL/aliases, trust policy, pinned key/history, signed catalog revision, last success/error |
| Catalog entry | Repository ID + internal name, advertised version/status/capabilities, artifact URL/digest, publisher metadata |
| Installation | Repository-qualified plugin key, installed version/digest, committed generation, enabled state, provenance, last-known-good version, lifecycle status |
| Provider instance | Installation key + provider key + instance ID, configuration revision, secret references, runtime generation |

Content-addressed CS3/JAR storage is an implementation detail underneath installations. It must not infer permission to load, user intent, ownership, or installed version. A lifecycle coordinator should stage → verify → instantiate in isolation → commit → publish → retire, with explicit rollback and operation results. Repository removal and updates must share that coordinator.

Recommended order:

1. **Stop security bypasses:** F10–F16; require exact hash types, preserve pins, close the signed metadata chain, enforce transport policy, and eliminate permissive cache boot.
2. **Fix state and identity:** F01–F03, F20, F25, F32; migrate existing installations conservatively and expose ambiguous/unowned artifacts for recovery instead of guessing.
3. **Make lifecycle operations transactional:** F06–F09, F12, F21–F23; add staged generations, rollback, cancellation, safe mode, and complete registry cleanup.
4. **Restore expected extension behavior:** F04–F05, F24, F26–F29, F31; then add reliable update/configuration/status UI.
5. **Enforce resource and privilege boundaries:** F18–F19, F30; define a compatibility mode versus an enterprise trust policy explicitly.
6. **Finish UI/network consistency and interoperability:** F17, F33–F37; expose actionable errors, progress, trust details, and last successful sync.

Versatility gaps to scope explicitly, rather than label accidental bugs: local extension import, catalog search/language/type filters, provider settings UI, independent clone instances, update-all controls, and capability-based compatibility explanations. Android supports more of these workflows; the current macOS UI does not expose them.

## Acceptance gates before an enterprise-grade claim

| Area | Required verification |
|---|---|
| Repository UI | Add/remove survives restart; default repo stays removed; persisted catalogs remain visible offline; aggregate children are accounted for |
| Identity | Same internal names in two repos; identical artifact reused by two repos; same display names in two providers; independent clone configs |
| Install/update | Simultaneous duplicate requests load once; failed replacement retains old generation; request timeout/cancel reconciles via operation status |
| Removal | Races with sync/install; latest catalog omits installed plugin; shared-artifact ownership; all multidex outputs cleaned; no ghost API mapping |
| Integrity | Equal-length corruption, source/filename mismatch, corrupt/replaced JAR, interrupted download/translation, toolchain cache invalidation |
| Trust | Signature stripping, HTML downgrade, changed list under signed root, key rotation failure, stale/replayed catalog, missing/malformed digest, foreign provenance claim |
| Transport | HTTP roots/lists/artifacts, redirect downgrade, relative redirects, private-host policy, non-2xx, size/decompression limits |
| Runtime | Throw before/after registration; blocking load/search/unload; OOM worker; daemon restart; safe mode; cross-plugin interference |
| Persistence | Disk-full/permission failures, invalid/truncated state, schema migration, duplicate daemon process, credentials never in plain JSON/logs |
| Compatibility | Representative modern/legacy/resource/settings/multidex/extractor-only/multi-provider plugins; real provider homepage semantics |
| UI concurrency | A→B catalog switching with inverted response order; concurrent toggles; daemon restart during mutation; stale bootstrap rejection |
| Scale | Measured cold/warm boot, UI refresh and cancellation latency, bounded memory/network/worker use with representative large installations |

Existing tests are useful unit checks but do not establish these lifecycle invariants. Convert each opt-in characterization probe into a normal regression test asserting corrected behavior as the corresponding fix lands. Add route-level and SwiftUI integration tests for the flows currently supported only by source traces.
