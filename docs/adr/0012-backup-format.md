# ADR-0012: Backup format — versioned JSON, merge by recency, Android import

**Status:** Accepted (2026-09-30) · **Decides:** Offline-Features-Plan Phase 7.1

## Context

The library, watch history and per-show settings live only in a local
SwiftData store. Users need to move them between Macs, recover from a bad
profile, and bring their library over from CloudStream on Android.

## Decision

A single UTF-8 JSON document (`BackupDocument`):

* Header `{"format": "cloudstream-macos-backup", "version": 2}` — sniffed
  before full decoding. A newer `version` is refused with an "update the
  app" message; unknown fields are ignored so minor additions stay compatible.
  Version 1 remains readable; its missing provider identity and playback
  timestamps remain unknown rather than being inferred from import time.
* Body: `items` (library/favorites/continue-watching), `episodes`
  (ADR-0011 rows), `playback` (per-show audio/subtitle memory),
  `preferences` (allow-listed keys only), `repositories`, `disabledProviders`.
  No credentials, tokens, cookies or download files.
* Dates are ISO 8601 with milliseconds, written through one formatter, so
  export → import → export is byte-stable.
* Hard limits before decoding: 64 MB file, 200 000 records.
* **Merge** (default) keeps whichever side has the newer `lastUpdated` /
  `updatedAt`; **Replace** wipes the active profile first. Both write a
  safety backup of a non-empty library before touching data; if that
  write fails, Replace is refused (nothing changes) while Merge — which
  never deletes — continues and logs it. Writes are atomic (temp + replace).
* Automatic daily backup to Application Support, keeping the newest 7.
* Android backups (`BackupUtils.BackupFile`) are detected by shape and
  mapped: bookmarks + watch status, favorites, and title-level resume
  position. Per-episode Android history is skipped (unmappable ids).

## Consequences

* Human-readable, diffable, and testable with plain fixtures.
* Merging by timestamp is last-writer-wins per record; concurrent edits on
  two Macs to the same title keep only the later one. Acceptable: there is
  no sync, backups are manual moves.
* Identity changes require a format version and an explicit legacy reader.

## Provider identity foundation (2026-10-01)

New identified remote titles use a length-framed SHA-256 key containing the
stable provider ID and exact original URL bytes. Display names are presentation
metadata, so two installations with the same name and URL remain separate.
Items carry optional provider ID, identity version/resolution and legacy-key
metadata; playback snapshots carry optional `updatedAt`. Export writes v2 so
older clients reject identities they cannot safely interpret. No credentials,
cookies or download paths are added.

Existing known-provider legacy rows migrate through a verified recovery gate.
Before opening an older schema, the store preserves its original SQLite schema
and committed WAL contents; before durable rekey, it creates another verified
copy of the current graph. The transaction moves title keys, dependent episode
keys and playback settings together and commits a migration record containing
legacy-key aliases and recovery paths. Repeating migration is idempotent. Legacy
system activities resolve through persisted aliases after rekey or restoration.

Provider restoration supplies a catalog for unknown legacy owners. Only one
distinct installed provider ID matching the saved name permits automatic
resolution; ambiguous and unavailable owners remain unchanged and inspectable.
Existing stable IDs do not require network/provider availability to migrate.
Conflicting titles or dependents fail recoverably instead of merging. Merge
adapts incoming stable identities and history/prefs to the local key; backup
import itself never performs an uncontrolled rekey.

Explicit legacy-provider reassignment is available for unknown remote owners
from Library and History. It changes only the selected row through the same
snapshot-backed rekey transaction, rejects collisions and unavailable selection,
and preserves legacy aliases/history/settings. Interactive reassignment,
minimum-OS acceptance and the remaining restore/scheduling phases are still
remediation work. Per-field metadata and chronological merge have local
regression and old-schema compatibility evidence. Process-kill migration acceptance now
covers both default and named old-schema stores at four transaction boundaries.
An older binary must use the original pre-schema recovery copy, never the newly
migrated store. Recovery requires closing the application and preserving the
current store plus its WAL/SHM files together in a separate recovery directory
before restoring a compatible copy under the original store name. Never leave
the current store's WAL/SHM beside the restored standalone snapshot; they belong
to the preserved current database, not the restored copy. This is
operator recovery, not an automatic downgrade or a JSON import of downloads.

The frozen old-schema fixture is compiled separately as module `CloudStream`.
Run `bash scripts/tests/run_identity_migration_tests.sh /absolute/private/DerivedData`
to execute its upgrade/recovery, WAL, transaction-failure, profile-rollback
and separate-process kill/reopen checks. Ordinary unit selection explicitly skips the external fixture when its
tool is absent; the compatibility command must execute it without a skip.


Local download placeholders are intentionally outside portable backup identity.
Their new durable key is `local-download-v2:<shared DownloadRecord UUID>`;
legacy path keys are mapped only with unique shared-record evidence through the
same recovery-backed transaction and alias marker. No remote provider identity
is manufactured for a local file. Downloaded-file playback now passes the real
file path plus that UUID instead of using the provider name as a title URL.


The original-schema recovery pointer is rediscovered after a crash before the
identity marker commit. Manifests carry the source SQLite store UUID (optional
for earlier v1 manifests); selection requires the matching UUID and source name,
then hash/integrity/original-schema verification. Unpublished partial copies are
ignored. The newest published matching copy must verify; an older copy cannot
mask its corruption. Unrelated-profile damaged manifests do not disable this
profile. The original copy remains an operator recovery artifact; crash recovery
continues the current store and its idempotent transaction instead of replacing
it automatically.


V2 field ordering uses optional note/rating/favorite/list/resume dates. A known
newer date applies the complete value, including explicit nil/zero/false clears.
An equal timestamp preserves local and reports a conflict when values differ.
Missing dates on either side preserve existing values and report unresolved
ordering; legacy aggregate title recency cannot stand in for note/rating edits
that older apps never timestamped. New records receive their supplied values,
and Replace restores all supplied values. Version-1/Android imports retain their
source version through the restore plan and never acquire invented edit dates.
Legacy playback unknown time is stored using an internal sentinel and exported
as an absent timestamp. Strictly newer known playback restores the full settings
value, including language and intro removal.

List removal keeps its clear tombstone for subsequent backup merges. Clearing
history cannot erase independent notes/ratings/clear metadata or playback memory.
The full episode-history deletion/backfill/retention work is still D04. A backup
with a known installation cannot claim an unknown name-key owner; it remains a
separate canonical identity. An unidentified source colliding with an identified
legacy owner requires explicit resolution, and the restore transaction fails
without changing data. Portable input rejects download types/UUID namespaces.


## History kinds, edition, restore phases and scheduling (2026-10-02)

Additive v2 fields, all optional so earlier v2 and v1 files stay readable:

* `episodes[].kind` — `episode` (default when absent) or `movie`. A movie row
  uses the fixed `episodeData` value `cloudstream.movie-playback.v1`, so its
  identity does not depend on a rotating movie link; validation requires kind
  and that value to agree. `episodes[].audio` and `items[].lastAudio` carry the
  edition (sub/dub) a row or resume pointer was played in.
* `disabledProviderIDs` — stable provider IDs. `disabledProviders` keeps
  display names for older readers and is used on restore only when
  `disabledProviderIDs` is absent, and then only for a name exactly one
  installed provider has.
* `extensionSetupCapturedAt` — when the repository list and disabled
  providers were last read from the engine. Absent means they were not
  available: the file holds the library, not a complete extension setup.

History and playback settings of local downloads are no longer exported, and
input carrying a `local-download-v2:` owner in `episodes` or `playback` is
rejected like a local item. Entries whose title is in neither the backup nor
the library are kept and counted in the restore result rather than pruned.

Restore is reported phase by phase and is not all-or-nothing across stores:
the library is one transaction; preferences follow; then the extension setup
is applied through `/repos/register` and `/providers/setEnabled`. Both engine
operations are idempotent, so a failed or postponed extension phase is retried
on its own ("Finish Restoring Extensions") without replacing the library again
or writing another safety copy. Registration adds addresses only; it never
installs extensions, syncs, or grants community consent. A restore carries the
profile it was prepared for and is refused if another profile is selected.

Automatic backups are scheduled for the life of the app (launch, hourly, wake,
profile activation) and do not depend on the engine. Each profile has its own
last-success time and its own `Daily` folder with seven files; an inactive
profile is read through its own store without switching the visible profile.
Safety copies keep their separate folder and are never pruned by the rolling
retention.

Android import keeps the account number through parsing. All accounts are
imported by default, or one chosen account. A title present in several accounts
takes the more recently changed account's list status, and its resume position
as one unit; without usable dates the lowest-numbered account stays, favorites
are a union, and the titles are listed in the restore result.

Older application versions cannot read `kind: movie` rows as anything but an
episode with unfamiliar data and do not know the new fields; v2 was already
refused by v1 readers. No automatic downgrade is offered.
