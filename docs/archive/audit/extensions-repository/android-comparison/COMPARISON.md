# Extensions/repositories: macOS vs. Android comparison

Reviewed 2026-09-30 against the current working tree:
- Android: `app/.../plugins/PluginManager.kt`, `RepositoryManager.kt`, `Plugin.kt`, `ui/settings/extensions/*`, shared `library/`.
- macOS: daemon `RepositoryService`, `InstallationManager`, `InstallationProofStore`, `CatalogTrust`, `RepositoryTransport`, `StateRepository`, `PluginBridge`, `Main.kt` routes, Android stubs; client `ExtensionsStore`, `ExtensionsView`, entitlements.

The analysis is source-level and backed by the daemon suite (166 tests: 162 passed, 1 failed, 3 skipped) and the seven `current-review` probes (see `../second-fact-check/FACT-CHECK-2.md`). No Android device, live extension or packaged-app run was performed.

## Verdict

**The macOS system is not production-ready or enterprise-grade today.** Its core *design* is now stronger than Android's in trust, integrity, persistence and lifecycle transactions. The *product* is weaker, for three reasons:

1. It cannot install any extension from existing repositories (signed-catalog-only policy).
2. The HTTP routes the client uses still run on the pre-receipt model, so the installed list and the enable toggle are broken.
3. Plugins run with the user's full macOS privileges. They are less confined than on Android, where they at least inherit the app's OS sandbox.

| Goal | Status | Main reasons |
|---|---|---|
| Clean | Partial | Two coexisting models (hash-keyed legacy + receipt-based), dead APIs, route handlers carrying business logic in an 848-line `Main.kt`, test seam in a production object |
| Secure | Design good, deployment weak | Authenticated catalog chain and mandatory digests exceed Android. But: no App Sandbox, weakened hardened runtime on the JVM, unauthenticated JAR cache, cleartext provider credentials |
| Robust | Partial | Atomic/fsynced state and staged publication are good. Missing: safe mode, revocation, garbage collection, hard deadlines. Classloader retire can break in-flight requests |
| Production-ready | No | Red test suite, broken routes, no installable ecosystem, lifecycle untested, no migration of existing installs |
| Enterprise-grade | No | No managed policy (MDM), no per-plugin isolation, no install audit trail, no secret storage, no update management |

## 1. Architecture side by side

| Layer | Android | macOS |
|---|---|---|
| Process model | Plugins run inside the app process via `PathClassLoader` over native DEX | SwiftUI app → loopback Ktor daemon (bearer token via stdin) → dex2jar → `URLClassLoader` in one shared JVM |
| OS confinement | Android app sandbox (per-UID). Plugins share the app's private storage, not other apps' data | **None.** Neither the app nor the JVM declares `com.apple.security.app-sandbox`. The daemon, and every plugin, can read anything the user can (e.g. `~/.ssh`, browser profiles) |
| Repository registry | `REPOSITORIES_KEY` in preferences, guarded by a `Mutex` | Daemon `state.json` via `StateRepository` (atomic + fsync, backup, recovery mode, data-root lock). Swift store reads it |
| Installation identity | File path `filesDir/Extensions/<sanitized repo URL>.<hashCode>/<sanitized internalName>.<hashCode>.cs3`, recorded in `PLUGINS_KEY` (`PluginData`: internalName, url, filePath, version) | `InstalledExtension` receipt keyed by `sha256(len:repoUrl + internalName)`, with artifact digest, generation, signed-proof hash, metadata, enabled flag |
| Artifact storage | One file per installation path, replaced in place | Content-addressed `cs3/<sha256>.cs3` + `plugins/<sha256>[_n].jar` + `installation-proofs/<sha256>.json` |
| Trust | Optional `fileHash`. No manifest authentication | Ed25519 TOFU root → signed `pluginListHashes` → mandatory artifact SHA-256, with `catalogVersion` rollback protection and ≤30-day `expiresAt` |
| Update | Startup pass: load everything, fetch catalogs, re-download if `version` increased or is `-1`, notify. Manual "update all" | Catalog shows "new version available"; no update action, no automatic update. Downgrade rejected at install |
| Remote disable | Status `0` → `unloadPlugin` during the update pass (after it was already loaded) | Status `0` blocks new installs only. Committed installs keep loading (`revokedReason` never set) |
| Safe mode | `Cloudstream3/safe` file or `lastError` suppresses extension loading | None. All receipts load before `/health` is served |
| Local/dev extensions | Load from shared external storage `Cloudstream3/plugins`, hot reload via adb | Not supported |

## 2. Concern-by-concern comparison

**Legend:** ▲ macOS better · ▼ Android better · = equivalent weakness

| # | Concern | Android | macOS | |
|---|---|---|---|---|
| 1 | Artifact integrity | Hash optional; stream to temp file, verify if present, atomic move | Hash mandatory and validated as 64 hex; bounded HTTPS transport checks every redirect, status and size; verified bytes published atomically | ▲ |
| 2 | Catalog authenticity | None; also rewrites GitHub URLs through a jsDelivr proxy when enabled | Signed chain with rollback/replay/expiry rules | ▲ design / ▼ usability (no publisher uses it) |
| 3 | Transport policy | `http://` repos accepted by `parseRepoUrl`; no size limits | HTTPS everywhere, byte limits, destination policy | ▲ |
| 4 | Install identity | Repo-qualified path; delete-by-URL and `filePath.contains(repoPath)` are loose | Exact repo-qualified ID, catalog-derived URL/hash, caller cannot substitute | ▲ |
| 5 | Load transaction | Registers in maps *before* `load()`; catch doesn't roll back; unloads old before new proves itself | `StagedRegistration` collects registrations; publish swaps generations under one lock and rolls back registries; state rollback on publish failure | ▲ (but no normal tests) |
| 6 | Unload completeness | Removes APIs, extractors, `VideoClickAction`s, mappings | Removes providers, extractors, mappings. `registerVideoClickAction` is a no-op (feature silently unsupported). Host verifier jobs not cancelled. Classloader closed while calls may be in flight | = |
| 7 | Updates | Version-based, `-1` always-update, auto on launch, manual update-all, notifications | No update path in UI; detection is digest-only | ▼ |
| 8 | Remote status | Down plugins unloaded; slow/beta kept | Down blocks install only; slow kept; aggregate path still drops slow | ▼ |
| 9 | Persistence | SharedPreferences JSON blobs, separate keys updated independently | Atomic, fsynced, versioned, backup + explicit recovery mode, single-owner lock | ▲ |
| 10 | Concurrency | Data writes under `Mutex`; loads parallel via `amap`; check/load/unload not serialized | Lifecycle lock + per-installation operation token + revision checks. But enable/uninstall silently cancel in-flight updates, and routes bypass the manager | ▲ design |
| 11 | Runtime compatibility | Native DEX, real Android `Context`, resources, SharedPreferences, settings UI | dex2jar + stubs. Resources unsupported, preferences lose values, `Uri`/`Base64`/`Pair` diverge, JAR cache trusted by size | ▼ |
| 12 | Provider identity | Display name | Display name (details/links cache keys, disable list, config) | = |
| 13 | Provider configuration | Per-plugin SharedPreferences + `openSettings` | Overrides persisted in cleartext `state.json`, never re-applied on load | ▼ |
| 14 | Isolation | App sandbox; plugins share app privileges | Full user privileges; JVM entitlements add `disable-library-validation` and `allow-dyld-environment-variables` (library injection into the scraper process) | ▼ |
| 15 | Startup resilience | Safe-mode file, crash marker, loads in parallel | Sequential restore before server start, 20 s supervisor deadline, no quarantine | ▼ |
| 16 | Observability | Logcat, toasts, notifications | Structured `DaemonLog`, metrics, `/diagnostics` | ▲ |
| 17 | UI capability | Search, TV-type and language filters, download-all per repo, plugin details, voting, update notifications, local plugins | Text filter, install, uninstall; toggle is a no-op; installed list shows version 0/unverified | ▼ |
| 18 | Tests | Few | 166 daemon tests, but 1 failing and no direct `InstallationManager` tests | ▲ quantity, not yet quality |

**Do not copy these Android behaviors:**
- Unverified loading from world-readable shared storage (`/Cloudstream3/plugins`).
- Optional hashes.
- Loading remote-down plugins *before* checking status.
- Pre-`load()` registration without rollback.
- Destroying the old version before the new one is proven.

## 3. What blocks each goal

### Clean
- Delete the legacy hash-keyed surface once routes are migrated: `PluginBridge.getAllPlugins`, `findLoadedByInternalNameOrManifest`, `isLoaded`, `loadPluginFromCs3`, `loadedPluginsSha256OverrideForTest`, `RepositoryService.pluginMetadataFor`, `isArtifactAuthorizedToLoad`, `removedPluginHashes` and its helpers.
- Move route logic out of `Main.kt` into thin handlers over `RepositoryService`/`InstallationManager`. Today `/plugins`, `/plugins/setEnabled` and `/plugins/config` hold their own (outdated) domain logic.
- One provider-identity type used by executor caches, enable state, config and IPC DTOs.
- Track the shared-library change (`BasePlugin.registrationTarget`) and build/test the Android app against it.

### Secure
1. **Decide the trust policy (blocking).** Options:
   - (a) Signed-only (current). Secure, but no ecosystem; needs publisher tooling and outreach.
   - (b) Two tiers. Signed = trusted; unsigned = explicit per-repository user consent, hash still mandatory, clearly badged, and optionally disabled by managed policy.
   - (c) An app-operated signed mirror/index of vetted extensions.

   (b) matches the original audit's F15 remedy and Android parity; (a) is appropriate only for a curated deployment.
2. **Confine plugin code.** Run plugins in a separate sandboxed helper (an XPC service or helper tool with `app-sandbox`, network-client only, container-scoped files), ideally one worker per extension or trust group, supervised and killable. Remove `allow-dyld-environment-variables` and, if possible, `disable-library-validation` from the JVM.
3. Authenticate translated JARs: key the cache by source digest + translator/ABI version, publish atomically, record the JAR digest in the receipt and verify it before loading.
4. Store provider credentials in the Keychain (or a Keychain-wrapped key), not in `state.json`.
5. Enforce revocation: a signed status `0` for an installed artifact should set `revokedReason`, unload it, and block restore.

### Robust
- Safe mode: a persistent "loading" marker per installation, automatic quarantine after a crash or timeout during load, a user-visible recovery screen, and an option to start with zero extensions.
- Serve `/health` before restoring extensions; restore in the background with per-extension deadlines.
- Retire generations only after in-flight calls drain (reference-count calls per generation, then close the classloader). Cancel host jobs owned by the generation.
- Garbage-collect unreferenced CS3/JAR/proof blobs.
- Single-flight translation per artifact digest.
- Fix `InstallationManager` edge cases: idempotent enable, uninstall cancelling or waiting for an in-flight first install, anchor recheck in `restore`, an explicit re-proof on key rotation.

### Production-ready
- Wire routes to receipts: `/plugins` → `installedPlugins()`, `/plugins/setEnabled` → `setEnabled(installationId)`, and show `lastError` with retry/uninstall for unloaded receipts.
- Update UX: an Update button (the store already labels it "Updating…"), update-all, optional automatic updates with a version policy that includes Android's `-1` semantics.
- Migrate existing (pre-receipt) installations, or clearly notify the user and offer reinstall.
- Green suite: remove the stale `ReviewFixRegressionTest` case, fix `CurrentReviewProbe`, and add normal tests for install, update, rollback, cancel, revoke, rotate, restore and route contracts.
- Signed-fixture end-to-end test running a real Android-compiled `.cs3` through dex2jar.
- Packaged-app verification: notarized build, first-run onboarding, offline boot, daemon restart during mutation.

### Enterprise-grade (beyond parity)
- **Managed configuration:** allowed/blocked repositories and keys, "disallow adding repositories", "signed only", auto-update policy — read from a configuration profile (`UserDefaults` managed domain) and enforced in the daemon, not only the UI.
- **Audit trail:** durable, append-only log of add/remove repository, trust/re-trust, install/update/uninstall/enable with digest, key fingerprint and actor.
- **Supply-chain documentation:** a published signing profile and publisher tooling, key rotation and revocation procedure, SBOM for the bundled JRE/dex2jar.
- **Resource governance:** per-worker memory/CPU/network budgets and concurrency limits, measured cold/warm boot with N extensions.
- **Support tooling:** export of diagnostics that redacts credentials and cookies.

## 4. Recommended order

1. Trust-policy decision + route wiring + green suite. *Makes the product usable and honest; small code.*
2. Revocation, update UX, migration of existing installs. *Reaches Android functional parity.*
3. Safe mode, background restore, drained generation retirement, GC, JAR authentication. *Robustness.*
4. Sandboxed plugin workers and entitlement hardening. *The largest item; required before any "secure" or "enterprise" claim.*
5. Provider identity/config/Keychain, ABI conformance fixtures. *Compatibility.*
6. Managed policy, audit log, resource budgets, packaged/scale verification. *Enterprise.*
