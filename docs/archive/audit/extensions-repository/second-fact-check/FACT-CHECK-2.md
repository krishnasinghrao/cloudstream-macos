# Second fact-check of the Extensions/Repository audit package

Reviewed 2026-09-30, ~17:45 IST, against the working tree at that time (HEAD `0c2f3a93` plus uncommitted edits; no source changes in the preceding 20 minutes). Scope: `REPORT.md`, `fact-check/FACT-CHECK.md`, `REMEDIATION.md`, `current-review/`, and the current daemon/client sources they describe. No production source, original audit artifact, or earlier evidence was modified.

**Bottom line.** The original REPORT is accurate for the code it audited, and the first fact-check's corrections still hold. The audit *package* no longer describes the product accurately, though. The REMEDIATION ledger is stale in both directions and misstates the test status. The newest lifecycle code (`InstallationManager`) is not wired into the HTTP routes the client uses. The new trust policy also means that no existing community repository can install anything. None of these points appears in any audit document as a blocker.

## Evidence

| Check | Result |
|---|---|
| REPORT line anchors vs. audited source | The pre-edit backup (`/var/folders/.../cloudstream-extensions-baseline-gtvfazpf`) matches the audit fingerprints for 11/11 core daemon files. ~45 cited anchors (RepositoryService, PluginBridge, DaemonState, RepoSignature, ProviderExecutor) point to the described code. No inaccuracy found |
| Normal daemon suite, now | **166 tests: 162 passed, 1 failed, 3 skipped**. Failure: `ReviewFixRegressionTest.getRepoPlugins flags update when loaded hash differs from pinned hash` (line 130). REMEDIATION reports 0 failures |
| `current-review/CurrentReviewProbe.kt` as committed | **Cannot run.** JUnit rejects the class: `restore publishes even when trust anchor changes during preparation()` returns a value (`assertFails`) instead of `void` |
| Same probe with one added `Unit` line (run from a scratch copy) | **7/7 reproduced** their characterized defects |
| Unit-test coverage of `InstallationManager` | None. No normal test constructs it. Only the unsigned-rejection path and a skipped live test reach it through `RepositoryService.installPlugin` |
| Default repository (`recloudstream/extensions` repo.json, fetched live) | Unsigned. No `signature`, `catalogVersion`, `expiresAt` or `pluginListHashes` |

The normal suite was re-run last to restore ordinary test outputs.

## 1. Verdict on the original REPORT and first fact-check

- REPORT's historical claims are well sourced. Spot-checked examples: F10's size-only reuse (`cs3File.length() != body.size`), F14's `root["signature"] ?: return null`, F05's `status == 1` filter, F02's cross-catalog `firstOrNull` name match, and F32's lowercase-substring lookup. Each is at the cited line.
- FACT-CHECK's corrections (C01 withdrawal of F33's status bypass, C03 double legacy call, the N01–N10 additions) remain valid for their snapshot. I found nothing to retract.
- **Reproducibility risk.** The only exact copy of the audited core sources is a temp directory under `/var/folders`, which macOS may purge. It does not contain the audited client files, entitlements, `build.gradle.kts` or `Security.md`. Commit `0c2f3a93` was made mid-remediation: 13 of 29 fingerprinted files already differ from the audited versions. Once the temp directory is gone, REPORT's line references cannot be checked. Archive the baseline, for example as a tag or branch built from the backup.

## 2. The REMEDIATION ledger misstates current status

| Ledger claim | Actual state |
|---|---|
| "Latest normal daemon suite … 0 failures" and "166 … 163 passed" | 1 failure. The failing test asserts the pre-receipt, loaded-hash update logic that was replaced. The test is stale, but the suite is red. `current-review/daemon-tests.log` already recorded this failure |
| F05: down entries "are blocked from new installation/**loading**" | Loading is not blocked. `InstallationManager.restore` never consults current catalog status, and `revokedReason` is never written anywhere. Probe: *signed remote down revision does not revoke old committed receipt* |
| F06, F07, F20, F21, F22: "Open" | Their mechanisms now exist. Receipts plus the keep-old-until-publish order address F06/F20. `StagedRegistration` addresses F07. `detach`/`publish` call `removePluginMapping` (F21). `allProviders()` snapshots under the lock (F22). They should read "Implemented; untested", not "Open" and not "Verified" |
| N03: "Downloaded cache bytes alone no longer mean Installed" | True, but the same dead end now has a new cause (see G02) |
| F11: "cached loading reconstructs signed … evidence and the loader rechecks source authorization" | Boot now uses receipts (`bootFromCache` → `restore`). `isArtifactAuthorizedToLoad` has no production caller. The text describes a superseded path |
| `docs/repository-signing.md` final paragraph: cache loading "still needs migration to committed installation records" | Already done for boot. The document is stale |

**Recommendation:** every ledger status should cite a test in the normal suite that currently passes. Most "Verified" rows already do. The lifecycle rows cannot yet.

## 3. Gaps not covered by any audit document

### G01 — P1 — No existing repository can install extensions, and prior installations vanish on upgrade [Source + live fetch]

Installation now requires a macOS-specific signed catalog: an Ed25519 root with `catalogVersion`, an `expiresAt` no more than 30 days ahead, and a `pluginListHashes` binding. The Android client and repository tooling in this checkout do not produce that format. The default official repository was fetched and is unsigned, so every catalog row renders "Unavailable". The built-in shortcodes point to ordinary community catalogs; only the default was fetched, but none is expected to use this macOS-only format. `repository-signing.md` states this deliberately ("There is no unsigned execution compatibility bypass").

REPORT F15's remedy asked for compatibility repositories under an *accurately labeled lower-trust policy*. The remediation instead removed the capability without any finding, ledger row or release gate recording the product impact. Related consequences:

- `bootFromCache` loads only receipts. Extensions installed before this change are silently not loaded after upgrade; nothing migrates or reports them. REMEDIATION mentions "cache migration remain[s] open" only under F11.
- Publishers would need to re-sign at least every 30 days to allow new installs.
- The skipped live test `RepositoryServiceTest` (`CS_LIVE_REPO_TESTS=1`) asserts a successful SoraStream install from a real unsigned repository. It would now fail, and the skip hides that.
- Onboarding's "Choose Extensions" (N02 fix) leads to a catalog in which nothing is installable.

**Needed:** an explicit, documented product decision (compatibility tier, publisher migration plan, or accepted loss of function), a migration or notice for existing installs, and a release gate for it.

### G02 — P1 — HTTP routes bypass the installation model; the installed list and enable toggle are broken [Probe + source]

The client's installed-extensions list and toggles go through routes still written for the old hash-keyed loader (`Main.kt`, last edited before the lifecycle code):

- **`GET /plugins`** builds from `PluginBridge.getAllPlugins()` and calls `pluginMetadataFor(dto.id)`. `dto.id` is now the installation ID, not an artifact hash, so the metadata is always null. Every installed extension reports version 0, `verified=false`, no description or authors, and `internalName` = the absolute local `.cs3` path. `RepositoryService.installedPlugins()`, the correct receipt-based projection with a retry message, has no caller.
- **Unloaded receipts are invisible.** If `restore` fails, the receipt exists, so the catalog shows "Installed" with no Install button. `/plugins` omits it, so there is no row to uninstall or retry. Re-installing the same version returns the old record early without loading it. This is N03's dead end in a new form.
- **`POST /plugins/setEnabled` is a silent no-op.** `ExtensionsStore.setEnabled` sends `plugin.id` (the installation ID). The route matches only artifact hash, filename substring, manifest name or provider name. None match, so it adds the ID string to `disabledProviders` and returns `ok`. The provider stays enabled, and the durable `InstalledExtension.enabled` flag, which controls boot loading, is never changed. `InstallationManager.setEnabled` / `RepositoryService.setInstallationEnabled` have no caller.

Probe: *actual plugin routes lose metadata ignore stable ID disable and hide unloaded receipts*.

### G03 — P1 — Remote-down and publisher revocation still do not affect committed installations [Probe]

This is F05's second half, which the ledger now describes as fixed. A signed catalog that marks an installed extension `status: 0` blocks new installs, but `restore` republishes the old receipt at every boot. No code path sets `revokedReason`.

### G04 — P2 — `InstallationManager` edge cases [Probes + source]

- `setEnabled(true)` on an enabled, running extension runs the plugin's `load()` again and republishes (probe: 2 prepares, 2 publishes).
- `setEnabled` and `uninstall` clear `active[id]`. Toggling an extension while its update is downloading therefore aborts the update ("Installation was cancelled").
- Conversely, `uninstall` during a *first* install returns "unknown plugin", and the install then commits. The user's uninstall is lost (probe).
- `restore` re-checks the installation record under the lock but not the trust anchor, so it can publish after the anchor was removed mid-preparation (probe).
- Key rotation via `reTrust` changes the anchor's public key, and `InstallationProofStore.verify` requires it to equal the proof's key. Every installed extension from that repository then stops loading at the next restore, with no re-proof step and no surfaced error (the `lastError` projection is unused; see G02).

### G05 — P2 — Artifact store is never collected; the unauthenticated JAR cache outlives uninstall [Source + probe]

`uninstall` notes that "Collection is separate", but no collector exists. CS3 sources, translated JARs and proof files accumulate indefinitely. Because F12 is still open (a `<hash>.jar` is trusted if it exists and is non-empty), a corrupted or replaced JAR survives uninstall and is reused on reinstall. Probe: *direct loader runs disabled receipt using unauthenticated warm jar*. That probe also shows `loadPluginFromCs3` ignores the receipt's `enabled` flag. It currently has no production caller, but it is public API and should be removed or gated.

Two install or restore operations preparing the same artifact still translate into the same final JAR path non-atomically. The failure path deletes that shared file (F08 remainder).

### G06 — P2 — Retiring a generation closes its classloader while calls may still be running [Source / Risk]

`publish` swaps generations and then closes the old `URLClassLoader` via `retire`. Search, links or verifier work already running on the old generation can then fail with `NoClassDefFoundError` when it lazily loads a class. Updates under load can therefore fail active requests. This extends FACT-CHECK N05 ("closing a classloader is not cancellation") from host jobs to ordinary requests. Also, each `prepare` overwrites the global `CloudStreamApp.context`, including for candidates that are later discarded.

### G07 — P3 — Smaller inconsistencies

- The HTML aggregate path still keeps only `status == 1` (it drops "slow", status 2), while the normal path keeps 1 and 2. The F05 fix was applied inconsistently. Aggregate children are still committed as standalone repositories (F33).
- The shared `library/` `BasePlugin` gained `registrationTarget`. The addition is binary-compatible, but it changes code the Android app ships, and no ledger row or Android verification covers it.
- Leftover pre-receipt code: `removedPluginHashes`/`markPluginRemoved` and `findLoadedByInternalNameOrManifest` (substring match) are unused. The test seam `loadedPluginsSha256OverrideForTest` is in the production object. `isArtifactAuthorizedToLoad` is unused.

## 4. Suggested next steps

1. Decide G01 explicitly. It determines whether the app is usable at all.
2. Wire `/plugins`, `/plugins/setEnabled` and uninstall to `installedPlugins()` / `setEnabled(id)`. Add route-level tests using the (fixed) current-review probe as the template (G02).
3. Fix `CurrentReviewProbe` (add `Unit` after the final `assertFails`). Delete or rewrite the stale `ReviewFixRegressionTest` case so the suite is green, then correct the REMEDIATION totals and statuses (section 2).
4. Add normal-suite tests for `InstallationManager`: rollback on publish failure, cancellation, update-while-toggle, revocation, key rotation.
5. Archive the audited baseline sources before the temp directory disappears.
