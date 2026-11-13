# Client Persistence, Security, Backup, and Download Audit

This audit evaluates the persistence, security, backup, and download subsystems of CloudStream macOS (`client/Sources/Services/Persistence/`, `client/Sources/Services/Backup/`, `client/Sources/Services/Security/`, `client/Sources/Services/Downloads/`, `client/Sources/Models/`, `client/Sources/Services/LibraryStore.swift`, `client/Sources/Services/DownloadService.swift`, and associated test suites). We traced real-world execution paths: SwiftData concurrency and background transactions, SQLite WAL snapshotting and pre-migration backup integrity, v1-to-v2 provider identity schema migration, database deletion and cleanup, Android and macOS backup validation and merging, Keychain access controls and fallback behavior under system lock, WebKit network isolation, and download queue state machine transitions.

---

### F-PERSIST-01: Identity Migration Fails to Update `mergedIntoID`, Splitting Unified Titles
- **Severity**: High
- **Confidence**: high
- **Type**: corruption
- **Location**: `client/Sources/Services/LibraryStore.swift:1772-1806`
- **Trigger**: User runs v1-to-v2 library identity migration on a library containing merged/unified titles (ADR-0020 title unification).
- **Trace**:
  1. Title unification links secondary sources to a primary title via `StoredMediaItem.mergedIntoID`.
  2. When `LibraryStore.performIdentityMigration(report:assignments:)` runs, it creates `map = [oldID: newID]` for all rekeyed items (lines 1772-1773).
  3. It rekeys `EpisodeProgress.itemID` (line 1782), `TitlePlaybackPrefs.itemID` (line 1792), and `LibraryPageEntry.itemID` (line 1803).
  4. It loops over `StoredMediaItem` to update `item.id`, `item.providerID`, `item.identityVersion`, and `item.legacyItemID` (lines 1774-1780).
  5. It **never** inspects or updates `item.mergedIntoID`.
  6. If a unified title's primary ID was rekeyed from a legacy `Provider|URL` key to `remote-v2:<hash>`, all secondary items still hold the old legacy ID in `mergedIntoID`.
  7. When `LibraryStore.details(for:)` or `items(matching:)` resolves merged titles, `existingItems[item.mergedIntoID]` evaluates to `nil`.
- **Impact**: All merged titles are silently separated back into duplicate standalone entries. User progress and playback settings previously unified across providers are fragmented.
- **Evidence**:
  ```swift
  // client/Sources/Services/LibraryStore.swift:1774-1780
  for item in try transaction.fetch(FetchDescriptor<StoredMediaItem>()) {
      if let newID = map[item.id] {
          item.id = newID
          item.providerID = report.changes.first { $0.oldID == item.id || $0.newID == newID }?.providerID ?? item.providerID
          item.identityVersion = LibraryIdentity.version
          item.identityResolution = "migrated"
      }
      // Note: item.mergedIntoID is completely untouched
  }
  ```
- **Recommended fix**: In `LibraryStore.swift:1774-1780`, add remapping for `item.mergedIntoID`:
  ```swift
  if let currentMerge = item.mergedIntoID, let updatedTarget = map[currentMerge] {
      item.mergedIntoID = updatedTarget
  }
  ```
- **Guards considered**: `IdentityMigrationTests.swift` tests migrating standard titles, downloads, and progress, but test fixtures do not establish any merged titles prior to running migration (`mergedIntoID` is always nil in the test assertions).

---

### F-PERSIST-02: Missing `LibraryPageEntry` Collision Check in `identityPlan` Causes Fatal Migration Abort
- **Severity**: High
- **Confidence**: high
- **Type**: crash
- **Location**: `client/Sources/Services/LibraryStore.swift:1604-1628` & `1801-1806`
- **Trigger**: User has custom library pages containing entries for items whose identities are rekeyed or merged during migration.
- **Trace**:
  1. `LibraryPageEntry` has a unique constraint: `@Attribute(.unique) var id: String`, where `id` is computed as `LibraryPagePolicy.entryKey(pageID: entry.pageID, itemID: newID, episodeData: entry.episodeData)`.
  2. Before executing identity migration, `LibraryStore.identityPlan` pre-validates collisions on `EpisodeProgress` (lines 1604-1616) and `TitlePlaybackPrefs` (lines 1618-1628).
  3. `identityPlan` completely omits validation for `LibraryPageEntry`.
  4. In `performIdentityMigration`, lines 1801-1806 rekey page entries:
     ```swift
     for entry in try transaction.fetch(FetchDescriptor<LibraryPageEntry>()) {
         if let newID = map[entry.itemID] {
             entry.itemID = newID
             entry.id = LibraryPagePolicy.entryKey(pageID: entry.pageID, itemID: newID, episodeData: entry.episodeData)
         }
     }
     ```
  5. If an entry for the target `newID` already exists on that page (or if two rekeyed items on the same page produce identical keys), `entry.id` collides.
  6. `try transaction.save()` throws an unhandled unique constraint error.
  7. The transaction rolls back and throws `MigrationFailure.aborted`, leaving the user trapped on the legacy schema.
- **Impact**: Identity migration unconditionally fails and aborts for any user with custom library pages containing entries related to migrated items.
- **Evidence**:
  ```swift
  // client/Sources/Services/LibraryStore.swift:1801-1806
  for entry in try transaction.fetch(FetchDescriptor<LibraryPageEntry>()) {
      if let newID = map[entry.itemID] {
          entry.itemID = newID
          entry.id = LibraryPagePolicy.entryKey(pageID: entry.pageID, itemID: newID, episodeData: entry.episodeData)
      }
  }
  ```
  `identityPlan` (lines 1590-1640) validates `EpisodeProgress` and `TitlePlaybackPrefs`, but has no check for `LibraryPageEntry`.
- **Recommended fix**: In `LibraryStore.identityPlan`, scan `LibraryPageEntry` objects and either report collisions in the plan or deduplicate colliding page entries before updating their `id`.
- **Guards considered**: `IdentityMigrationTests.testIdentityMigrationPlanDetectsConflicts` only injects duplicate episode progress entries, never custom library pages.

---

### F-PERSIST-03: Backup Restore / Android Import Fails to Match Migrated `remote-v2` Items, Inducing Permanent Migration Conflict
- **Severity**: High
- **Confidence**: high
- **Type**: corruption
- **Location**: `client/Sources/Services/LibraryStore.swift:2404-2415` & `client/Sources/Services/Persistence/LibraryIdentityMigration.swift:56-59`
- **Trigger**: User imports an Android backup (`AndroidBackupImporter`) or legacy v1 macOS backup with `.merge` mode into a library whose titles have already migrated to `remote-v2`.
- **Trace**:
  1. In Android backups and v1 macOS backups, items lack `providerID` (`entry.providerID == nil`) and are identified by legacy keys (`ProviderName|URL`).
  2. In `LibraryStore.applySnapshot`, lines 2405-2407 attempt to find matching existing items:
     ```swift
     let stableMatch = entry.providerID.flatMap {
         existingStableItems[LibraryIdentity.remote(providerID: $0, url: entry.providerURL)]
     }
     ```
  3. Because `entry.providerID` is `nil`, `stableMatch` is `nil`.
  4. Line 2410 falls back to `var targetID = stableMatch?.id ?? entry.id` (`"ProviderName|URL"`).
  5. The existing local item was already migrated to `remote-v2:<hash>`, so `existingItems[targetID]` is `nil`.
  6. The importer enters the `else` branch (lines 2475-2512) and inserts a **new duplicate** `StoredMediaItem` with legacy ID `"ProviderName|URL"`.
  7. When `migrateProviderIdentities` subsequently runs, both the original migrated item and the newly imported item resolve to the exact same `remote-v2:<hash>`.
  8. `LibraryIdentityMigration.plan` detects that two stored items resolve to the same ID:
     ```swift
     if let owner = owners[newID], owner != item.id {
         report.conflicts.append("Two stored titles resolve to the same provider identity.")
     }
     ```
  9. `canApply` becomes `false`. The user's library is now permanently blocked from identity migration and cannot resolve provider updates.
- **Impact**: Importing an Android backup duplicates titles in the library and locks up future identity migrations with unresolvable conflicts.
- **Evidence**:
  `AndroidBackupImporter.swift:159` generates `id = "\(bookmark.apiName)|\(bookmark.url)"` with `providerID = nil`. `LibraryStore.swift:2405-2415` requires `entry.providerID != nil` to look up `existingStableItems`.
- **Recommended fix**: In `LibraryStore.applySnapshot`, when `entry.providerID` is nil, attempt to match existing items by `(providerName, providerURL)` or look up `existingStableItems` using catalog providers matching `entry.providerName`.
- **Guards considered**: `BackupProfileTests.swift` tests importing into an empty store, never into a store that has already migrated to v2 provider identities.

---

### F-PERSIST-04: `SQLiteRecoverySnapshot.copyDatabase` Omits Busy Timeout and Retries, Aborting Pre-Migration Snapshots
- **Severity**: High
- **Confidence**: high
- **Type**: crash
- **Location**: `client/Sources/Services/Persistence/SQLiteRecoverySnapshot.swift:164-180`
- **Trigger**: Pre-migration snapshot creation (`preservePreMigrationSchema`) is triggered while a background thread or SwiftData write transaction holds an SQLite read/write lock.
- **Trace**:
  1. `needsSchemaRecovery`, `storeIdentifier`, and `verify` all invoke `sqlite3_busy_timeout(database, 1000)` on opened connections.
  2. `copyDatabase(source:destination:)` opens `input` and `output` connections but **never** sets a busy timeout.
  3. It calls `sqlite3_backup_step(backup, -1)`.
  4. Per SQLite documentation: if `sqlite3_backup_step` encounters a lock on the source database, it immediately returns `SQLITE_BUSY` **without** invoking the busy handler callback. The caller is required to sleep and retry.
  5. `copyDatabase` performs no retry loop:
     ```swift
     let result = sqlite3_backup_step(backup, -1)
     let finished = sqlite3_backup_finish(backup)
     guard result == SQLITE_DONE, finished == SQLITE_OK else {
         throw Failure(detail: "The database is busy or its snapshot could not be written. Retry when current work finishes.")
     }
     ```
  6. Any transient database write or WAL checkpoint causes `preservePreMigrationSchema` to throw `Failure`, which causes `LibraryStore.activateProfileStore` to fail and triggers startup store suspension.
- **Impact**: Transient background database activity causes store initialization and schema migration to fail with a hard crash/suspension alert.
- **Evidence**:
  ```swift
  // client/Sources/Services/Persistence/SQLiteRecoverySnapshot.swift:164-178
  guard sqlite3_open_v2(source.path, &input, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
        sqlite3_open_v2(destination.path, &output, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { ... }
  // No sqlite3_busy_timeout call on input or output
  guard let backup = sqlite3_backup_init(output, "main", input, "main") else { ... }
  let result = sqlite3_backup_step(backup, -1) // Single step call
  let finished = sqlite3_backup_finish(backup)
  guard result == SQLITE_DONE, finished == SQLITE_OK else { ... }
  ```
- **Recommended fix**: Wrap `sqlite3_backup_step(backup, pages)` in a retry loop with short exponential backoff/sleep (up to 1-2 seconds) before failing, and set `sqlite3_busy_timeout(input, 1000)` and `sqlite3_busy_timeout(output, 1000)`.
- **Guards considered**: `IdentityMigrationTests.swift` runs on idle, newly opened test stores where no concurrent read/write transactions exist.

---

### F-PERSIST-05: `GenericPasswordKeychain.read` Conflates `errSecInteractionNotAllowed` with `.missing`, Bypassing Profile Locks
- **Severity**: High
- **Confidence**: high
- **Type**: security
- **Location**: `client/Sources/Services/Security/GenericPasswordKeychain.swift:82-91` & `client/Sources/Services/ProfileLockSecurity.swift:19-26`
- **Trigger**: App launches or reads keychain items while the device screen is locked, in power nap/sleep, or running in a context where keychain interaction is disallowed.
- **Trace**:
  1. `ProfileLockSecurity` uses `GenericPasswordKeychain` with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` to store profile lock enforcement state (`SEC-04` defense against plist tampering).
  2. When the keychain is locked, `SecItemCopyMatching` returns `errSecInteractionNotAllowed` (-25308).
  3. In `GenericPasswordKeychain.copyData`:
     ```swift
     let status = SecItemCopyMatching(query as CFDictionary, &result)
     if status == errSecMissingEntitlement { return .unavailable }
     guard status == errSecSuccess, let data = result as? Data else { return .missing }
     return .found(data)
     ```
  4. `errSecInteractionNotAllowed` is mapped to `.missing`.
  5. In `ProfileLockSecurity.readLocked()`:
     ```swift
     guard let data = GenericPasswordKeychain.read(service: service, account: account),
           let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
     ```
     It receives `nil` and returns an empty set `[]`.
  6. In `ProfileStore.init`:
     ```swift
     let keychainLocked = ProfileLockSecurity.readLocked()
     for i in loaded.indices {
         if keychainLocked.contains(loaded[i].id) {
             loaded[i].requiresUnlock = true
         }
     }
     ```
     `keychainLocked` is empty, so if `UserDefaults` was modified or corrupted, `requiresUnlock` is NOT enforced.
  7. Furthermore, in `GenericPasswordKeychain.read`, when `.dataProtection` returns `.missing`, it falls back to `copyData(.file)` and calls `save(data, ...)`, which can resurrect obsolete or revoked credentials from the legacy file keychain and overwrite the data protection keychain.
- **Impact**: Bypasses profile lock verification when launched under locked keychain conditions. Can resurrect stale credentials from legacy file keychain.
- **Evidence**:
  ```swift
  // client/Sources/Services/Security/GenericPasswordKeychain.swift:87-90
  let status = SecItemCopyMatching(query as CFDictionary, &result)
  if status == errSecMissingEntitlement { return .unavailable }
  guard status == errSecSuccess, let data = result as? Data else { return .missing }
  return .found(data)
  ```
- **Recommended fix**: Distinguish `errSecItemNotFound` from `errSecInteractionNotAllowed` and `errSecAuthFailed` in `Lookup`. Return an explicit `.locked` or `.authFailed` error, and do not fall back to `.file` or return empty lock sets when access is restricted.
- **Guards considered**: `KeychainOwnershipTests.swift` tests unlocked scenarios and missing entitlement fallbacks, but does not simulate locked keychain status (`errSecInteractionNotAllowed`).

---

### F-PERSIST-06: `LibraryStore.deleteProfileStore` Targets Default Directory Instead of `storeDirectory`, Leaking Files
- **Severity**: Medium
- **Confidence**: high
- **Type**: leak
- **Location**: `client/Sources/Services/LibraryStore.swift:345-351`
- **Trigger**: Deleting a profile when `LibraryStore` was configured with a custom `storeDirectory` (e.g. sandboxed paths, containerized storage, or test environments).
- **Trace**:
  1. `LibraryStore.init` takes an optional `storeDirectory: URL?`, which it stores in `private let storeDirectory: URL?`.
  2. When constructing store URLs in `configuration(named:schema:)` (lines 188-200), it uses `storeDirectory.appendingPathComponent(name + ".store")`.
  3. However, `deleteProfileStore(named:)` is a static method:
     ```swift
     nonisolated static func deleteProfileStore(named storeName: String) {
         guard storeName != defaultStoreName, !AppEnvironment.isIsolated() else { return }
         let url = ModelConfiguration(storeName).url
         for suffix in ["", "-wal", "-shm"] {
             try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
         }
     }
     ```
  4. `ModelConfiguration(storeName).url` resolves to the default system `~/Library/Application Support/` location, completely unaware of `storeDirectory`.
  5. The `removeItem` calls attempt to delete files at the non-existent default path, silently failing (`try?`).
  6. The actual `.store`, `-wal`, and `-shm` database files in `storeDirectory` remain untouched on disk.
- **Impact**: Deleted profile databases, WAL journals, and shared memory files are orphaned on disk, leaking storage and sensitive metadata.
- **Evidence**:
  ```swift
  // client/Sources/Services/LibraryStore.swift:347-350
  let url = ModelConfiguration(storeName).url
  for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
  }
  ```
- **Recommended fix**: Pass `storeDirectory` or query `LibraryStore.shared.storeDirectory` (or accept the target directory as a parameter) rather than instantiating a default `ModelConfiguration`.
- **Guards considered**: `PersistenceBoundaryTests.swift` tests isolation in-memory, where `AppEnvironment.isIsolated()` returns `true` and skips file deletion entirely.

---

### F-PERSIST-07: `DownloadService.pause(_:)` Silently Drops Pause on Resolving or Queued Items
- **Severity**: Medium
- **Confidence**: high
- **Type**: ux
- **Location**: `client/Sources/Services/DownloadService.swift:449`
- **Trigger**: User clicks "Pause" on a download that is currently in `.resolving` or `.queued` state.
- **Trace**:
  1. Resolving stream links can take 5–15 seconds during slow provider scraping or web solver challenges.
  2. `DownloadService.pause(_:)` enforces:
     ```swift
     func pause(_ id: UUID) {
         guard let item = items.first(where: { $0.id == id }) else { return }
         guard item.state == .downloading, let run = runs[item.id], let job = run.job else { return }
         ...
     ```
  3. When `item.state == .resolving` or `item.state == .queued`, the guard condition fails and `pause` exits immediately without doing anything.
  4. The UI button press has no effect.
  5. Once link resolution finishes, `runItem` proceeds to transition the item to `.downloading` and starts network streaming, ignoring the user's intent to pause.
- **Impact**: User cannot pause waiting or resolving downloads; bandwidth is consumed against the user's explicit action.
- **Evidence**:
  ```swift
  // client/Sources/Services/DownloadService.swift:448-450
  func pause(_ id: UUID) {
      guard let item = items.first(where: { $0.id == id }) else { return }
      guard item.state == .downloading, let run = runs[item.id], let job = run.job else { return }
  ```
- **Recommended fix**: Allow `pause(_:)` to set `item.state = .paused` when `item.state == .queued` or `.resolving`, and check for `.paused` in `runItem` before starting `attempt(...)`.
- **Guards considered**: `DownloadReliabilityTests.swift` only tests pausing items that are actively streaming bytes (`.downloading`).

---

### F-PERSIST-08: `DownloadService.reconcileFinalizing` Omits `drainQueue()`, Starving Concurrency Slots
- **Severity**: Medium
- **Confidence**: high
- **Type**: logic
- **Location**: `client/Sources/Services/DownloadService.swift:571-574` & `1541-1565`
- **Trigger**: A download that previously failed with `.finalizeFailed` is retried and successfully completes finalization.
- **Trace**:
  1. In `DownloadService.retry(_:)`:
     ```swift
     if case .finalizeFailed = item.failureReason {
         reconcileFinalizing(item)
         return
     }
     ```
  2. `reconcileFinalizing` renames the finished `.part` file to the destination URL, updates records, and transitions `item.state = .completed`.
  3. `reconcileFinalizing` then returns. It does **not** call `drainQueue()`.
  4. Notice that normal `retry(_:)` paths call `drainQueue()` at line 592, and normal `runItem` executions call `drainQueue()` in their `defer` block.
  5. Because the finalize retry returned early at line 573, waiting downloads in `.queued` state remain blocked, starving the queue until an unrelated action (like adding a new download) triggers draining.
- **Impact**: Download queue hangs in an idle state despite having available concurrent slots and waiting queued items.
- **Evidence**:
  ```swift
  // client/Sources/Services/DownloadService.swift:571-574
  if case .finalizeFailed = item.failureReason {
      reconcileFinalizing(item)
      return // drainQueue() at line 592 is skipped
  }
  ```
- **Recommended fix**: Add `drainQueue()` call before `return` in `DownloadService.swift:573`, or at the end of `reconcileFinalizing(item)`.
- **Guards considered**: Test suites test initial download finalization, but do not assert queue progression following a `.finalizeFailed` retry.

---

### F-PERSIST-09: `BackupService.pendingExternalRestore` Kept in Volatile Memory, Discarded on Quit
- **Severity**: Medium
- **Confidence**: high
- **Type**: logic
- **Location**: `client/Sources/Services/Backup/BackupService.swift:199, 251-258, 270-274`
- **Trigger**: User restores a backup while the extension engine daemon is still starting or unreachable, and quits the application before clicking "Finish Restoring Extensions".
- **Trace**:
  1. When restoring a backup, `BackupService.applyExternalPhases` applies repositories and disabled provider configurations to the engine.
  2. If the engine is not ready, line 271 stores the document:
     ```swift
     pendingExternalRestore = document
     result.externalPhasesPending = true
     result.warnings.append("Your library was restored, but the extension setup wasn’t: \(reason) Use Finish Restoring Extensions in Settings to try again.")
     ```
  3. `pendingExternalRestore` is an in-memory property: `private(set) var pendingExternalRestore: BackupDocument?`.
  4. It is never serialized to disk or saved in `UserDefaults`.
  5. If the user quits or restarts CloudStream macOS, `pendingExternalRestore` resets to `nil`.
  6. On subsequent launch, "Finish Restoring Extensions" is unavailable, and the user's extension repositories and disabled provider settings from the backup are permanently lost unless the user performs a full library restore again.
- **Impact**: Restored extension settings (repositories and provider configurations) are lost permanently if the app is closed before manual retry.
- **Evidence**:
  ```swift
  // client/Sources/Services/Backup/BackupService.swift:199
  private(set) var pendingExternalRestore: BackupDocument?
  ```
- **Recommended fix**: Persist `pendingExternalRestore` as a temporary JSON file in the application support directory and reload it on startup if external phases were left incomplete.
- **Guards considered**: `BackupValidationTests.swift` tests in-memory retries within a single test execution, not across application lifecycle restarts.

---

### F-PERSIST-10: `ProviderCredentialStore.resendAll` Silently Discards Stored Credentials When Keychain Is Inaccessible
- **Severity**: Medium
- **Confidence**: high
- **Type**: security
- **Location**: `client/Sources/Services/ProviderCredentialStore.swift:48-67`
- **Trigger**: Engine restarts or re-authenticates providers while Keychain access is restricted (e.g., locked session or background startup).
- **Trace**:
  1. `ProviderCredentialStore.resendAll` iterates over `storedProviderIds()`.
  2. For each provider, it calls:
     ```swift
     guard let credential = await Task.detached(priority: .utility, operation: { credential(for: providerId) }).value else { continue }
     ```
  3. If Keychain returns `errSecInteractionNotAllowed`, `GenericPasswordKeychain.read` returns `nil` (see F-PERSIST-05).
  4. The `guard let credential` fails, and the loop executes `continue`.
  5. No failure is recorded in `failures[providerId]`.
  6. `resendAll` returns an empty failure dictionary, signalling success to caller `AppState`.
  7. The engine is left with unauthenticated providers, causing subsequent media scrapes and provider operations to fail unexpectedly without an informative user alert.
- **Impact**: Daemon runs with missing provider credentials without raising any user-facing error or retry prompt.
- **Evidence**:
  ```swift
  // client/Sources/Services/ProviderCredentialStore.swift:56-57
  guard let credential = await Task.detached(priority: .utility, operation: { credential(for: providerId) }).value else { continue }
  ```
- **Recommended fix**: Check whether `credential(for:)` failed due to an inaccessible keychain versus a truly missing item, and record an error in `failures` or schedule a retry upon keychain unlock.
- **Guards considered**: `KeychainOwnershipTests.swift` tests valid credential transmission when keychain is unlocked.

---

## Reviewed / non-issues

1. **SQLite WAL Checkpointing during normal operation**: Checked whether `LibraryStore` leaves uncommitted WAL data that could be lost on abrupt termination. `LibraryStore` sets `autosaveEnabled = false` and explicitly calls `context.save()` with `persistenceFault` boundaries; SQLite WAL mode ensures crash durability across unexpected exits.
2. **WebKit Local Network Isolation**: Audited `WebContentNetworkPolicy.swift` against DNS rebinding, loopback variations (`0x7f.1`, `::ffff:127.0.0.1`), and link-local ranges. The combination of SOCKS5 egress enforcement, WebKit Content Rule List regex matching, and navigation delegate pre-flight checks cleanly blocks access to local destinations.
3. **Download Path Traversal and Sanitization**: Audited `DownloadPolicy.uniqueDestination` and `MediaResourcePolicy.remoteURL`. Path components with `../` or non-printable ASCII characters are strictly rejected, and reserved base names prevent filesystem collision and overwriting.
4. **DirectFileJob Resume Byte Validation**: Audited `DirectFileJob.swift` resume metadata validation (`If-Range`, `ETag`, `Last-Modified`, content length). Partial resumes are rejected if validators do not match, preventing file splicing across different streams.

---

## Areas not covered

1. **APFS Sparse File Allocation**: Did not execute physical disk-level tests for sparse allocation or filesystem clone behavior (`clonefile`) when copying large download parts across APFS volume boundaries.
2. **Hardware Keychain / Secure Enclave Enrolment**: Did not test biometric Touch ID prompts backed by the Secure Enclave on real physical hardware (audited software Keychain SecItem API contracts only).

---

## Pass 2 & Fact-Checking Results

### Fact-Checking Verdicts (Pass 1 Findings F-PERSIST-01 through F-PERSIST-10)

| ID | Title | Verified Location | Verdict | Evidence / Status |
|---|---|---|---|---|
| **F-PERSIST-01** | Identity Migration Fails to Update `mergedIntoID` | `client/Sources/Services/LibraryStore.swift:1775-1791` | **[CONFIRMED]** | Traced lines 1775–1806; `mapping` updates `EpisodeProgress`, `TitlePlaybackPrefs`, and `LibraryPageEntry`, but `row.mergedIntoID` is untouched. Unification queries in `titleEntry` fail to resolve primary titles. |
| **F-PERSIST-02** | Missing `LibraryPageEntry` Collision Check in `identityPlan` | `client/Sources/Services/LibraryStore.swift:1604-1628, 1801-1806` | **[CONFIRMED]** | `identityPlan` checks progress and playback preferences but omits `LibraryPageEntry`. Unique constraint `@Attribute(.unique) var id` crashes `transaction.save()` on collision. |
| **F-PERSIST-03** | Backup Restore / Android Import Fails to Match Migrated `remote-v2` Items | `client/Sources/Services/LibraryStore.swift:2404-2415`, `LibraryIdentityMigration.swift:56-59` | **[CONFIRMED]** | `entry.providerID == nil` in Android/v1 backups prevents matching `existingStableItems`, inserting duplicate rows with legacy keys. Subsequent migrations conflict permanently. |
| **F-PERSIST-04** | `SQLiteRecoverySnapshot.copyDatabase` Omits Busy Timeout and Retries | `client/Sources/Services/Persistence/SQLiteRecoverySnapshot.swift:164-180` | **[CONFIRMED]** | Lines 164–180 open input/output with zero busy timeout; `sqlite3_backup_step(backup, -1)` returns `SQLITE_BUSY` immediately without calling busy handler, throwing `Failure` on concurrent WAL writes. |
| **F-PERSIST-05** | `GenericPasswordKeychain.read` Conflates `errSecInteractionNotAllowed` with `.missing` | `client/Sources/Services/Security/GenericPasswordKeychain.swift:82-91`, `ProfileLockSecurity.swift:19-26` | **[CONFIRMED]** | Line 89 maps all non-success/non-entitlement codes to `.missing`. `ProfileLockSecurity.readLocked()` receives `[]`, bypassing profile unlock verification on launch; also triggers fallback to legacy file keychain. |
| **F-PERSIST-06** | `LibraryStore.deleteProfileStore` Targets Default Directory Instead of `storeDirectory` | `client/Sources/Services/LibraryStore.swift:345-351` | **[CONFIRMED]** | Static method instantiates `ModelConfiguration(storeName).url` pointing to `~/Library/Application Support/`, ignoring the store's configured `storeDirectory` and silently failing `removeItem`. |
| **F-PERSIST-07** | `DownloadService.pause(_:)` Silently Drops Pause on Resolving or Queued Items | `client/Sources/Services/DownloadService.swift:449` | **[CONFIRMED]** | Line 449 guards `item.state == .downloading`. Calling `pause` while an item is in `.resolving` or `.queued` returns immediately without effect, continuing link resolution and downloading. |
| **F-PERSIST-08** | `DownloadService.reconcileFinalizing` Omits `drainQueue()`, Starving Concurrency Slots | `client/Sources/Services/DownloadService.swift:571-574, 1541-1565` | **[CONFIRMED]** | Retrying `.finalizeFailed` calls `reconcileFinalizing(item)` and returns at line 573, skipping `drainQueue()` at line 592 and stalling waiting downloads. |
| **F-PERSIST-09** | `BackupService.pendingExternalRestore` Kept in Volatile Memory, Discarded on Quit | `client/Sources/Services/Backup/BackupService.swift:199, 251-258, 270-274` | **[CONFIRMED]** | Line 199 defines `pendingExternalRestore` solely as an in-memory property. Closing the app permanently discards postponed extension configuration. |
| **F-PERSIST-10** | `ProviderCredentialStore.resendAll` Silently Discards Stored Credentials When Keychain Inaccessible | `client/Sources/Services/ProviderCredentialStore.swift:48-67` | **[CONFIRMED]** | Line 56 silently skips providers whose credentials return `nil` without logging an error in `failures[providerId]`, falsely signaling success while providers remain unauthenticated. |

---

### Pass 2 Deep-Audit Findings

### F-PERSIST-11: `FFmpegJob.terminate()` Asynchronous Escalation Races Child PID Recycling TOCTOU
- **Severity**: Medium
- **Confidence**: high
- **Type**: platform
- **Location**: `client/Sources/Services/Downloads/FFmpegJob.swift:163-168`
- **Trigger**: User cancels, pauses, or stops an active remux download where ffmpeg exits during the 3-second grace period.
- **Trace**:
  1. `FFmpegJob.terminate()` issues `process.terminate()` (SIGTERM) at line 162.
  2. Line 164 schedules a delayed fallback block:
     ```swift
     let process = self.process
     DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
         if process.isRunning {
             kill(process.processIdentifier, SIGKILL)
         }
     }
     ```
  3. If ffmpeg exits after 2.9 seconds and the process is reaped by the operating system, the kernel is free to reassign the newly freed PID to an unrelated user process.
  4. When the delayed block fires on the global queue, `process.isRunning` can be evaluated concurrently with `Process` internal state updates, or the process may exit immediately between the check `if process.isRunning` and the subsequent `kill(...)` call (a classic TOCTOU window).
  5. The raw POSIX call `kill(process.processIdentifier, SIGKILL)` executes with the reallocated PID, sending `SIGKILL` to an arbitrary, completely unrelated process.
- **Impact**: Arbitrary process termination on macOS due to PID recycling in asynchronous kill escalation.
- **Evidence**:
  ```swift
  // client/Sources/Services/Downloads/FFmpegJob.swift:163-168
  let process = self.process
  DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
      if process.isRunning {
          kill(process.processIdentifier, SIGKILL)
      }
  }
  ```
- **Recommended fix**: Avoid naked `kill(process.processIdentifier, SIGKILL)` in an unchecked delayed dispatch block. Cancel the delayed task inside `process.terminationHandler` once the process has exited, or rely on `Process` APIs rather than raw POSIX PID signaling.
- **Guards considered**: `DownloadReliabilityTests.swift` tests process shutdown under controlled single-process conditions without rapid PID reallocation.

---

### F-PERSIST-12: `GenericPasswordKeychain.delete` Silently Fails Under Inaccessible Keychain Conditions
- **Severity**: Medium
- **Confidence**: high
- **Type**: security
- **Location**: `client/Sources/Services/Security/GenericPasswordKeychain.swift:97-100` & `client/Sources/Services/ProviderCredentialStore.swift:30-36`
- **Trigger**: User deletes a provider credential, signs out, or removes a profile while the device screen is locked or Keychain interaction is disallowed.
- **Trace**:
  1. `GenericPasswordKeychain.delete` is defined as:
     ```swift
     static func delete(service: String, account: String) {
         SecItemDelete(query(.dataProtection, service: service, account: account) as CFDictionary)
         removeFileItem(service: service, account: account)
     }
     ```
  2. Notice that `delete` discards the `OSStatus` return values of both `SecItemDelete` calls.
  3. When Keychain interaction is disallowed (`errSecInteractionNotAllowed`), `SecItemDelete` fails and does **not** remove the generic password item from Keychain storage.
  4. The caller (`ProviderCredentialStore.delete(for:)` or profile management) assumes the secret has been purged and updates local UI state.
  5. Upon the next device unlock or subsequent launch, `GenericPasswordKeychain.read` finds the supposedly deleted credentials still intact in the Keychain.
- **Impact**: Deleted credentials and security records survive deletion attempts made while Keychain access is restricted.
- **Evidence**:
  ```swift
  // client/Sources/Services/Security/GenericPasswordKeychain.swift:97-100
  static func delete(service: String, account: String) {
      SecItemDelete(query(.dataProtection, service: service, account: account) as CFDictionary)
      removeFileItem(service: service, account: account)
  }
  ```
- **Recommended fix**: Return `OSStatus` or throw an error from `GenericPasswordKeychain.delete`, and ensure callers handle or defer deletion if the Keychain is temporarily locked.
- **Guards considered**: `KeychainOwnershipTests.swift` tests deletion only when the Keychain is unlocked.

