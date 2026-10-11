# macOS audit implementation status

The approved [implementation plan](Audit-Remediation-Implementation-Plan.md) covers all 53 findings in the [engineering audit](../audit/macos-engineering-audit-2026-10-01.md). AI-assisted implementation is in progress; no finding is closed merely by an edit. Code, regression evidence and packaged validation must satisfy the plan before closure.

Baseline: commit `3389a7b095accb9eb2a673605ddafc402b0cef09`; existing user edits in `client/CloudStreamMac.xcodeproj/project.pbxproj` and `scripts/clean.sh` are preserved. The prior audit's tests are historical baseline results, not verification of implementation.

## Coverage

| Finding | Priority | Package | Status | Evidence / remaining gate |
| --- | --- | --- | --- | --- |
| A01 | P1 | Q03 | In progress: native consumer/worker boundary verified locally | HTTP(S)-only provider resources, whole-request header rejection and typed remote/generated/authorized-local provenance now reach player, download and external-launch consumers. Worker/legacy output rejects unsafe resources with terminal redacted failures. Closed EDL builders validate every component and enforce matching playlist/audio bounds. Required libmpv recursive-protocol options fail closed. Six live checks passed for wire headers, valid HLS, generated playlist/split audio, local playback and malicious manifest/redirect rejection. External-player recursive confinement, complete signed-provider compatibility and final packaged/minimum-OS gates remain. |
| A02 | P1 | Q05 | Locally verified; packaged gate pending | Strict range bounds/total/length, streaming byte cap and exact final length. Invalid range cancels before one fresh response; the wrong 512 KiB resume/1 MiB tail fixture now completes byte-identically. Unsolicited partial responses, unknown totals, malformed/overflowing bounds and short/oversized bodies are rejected. Final artifact/minimum-OS gate remains. |
| A03 | P1 | R01 | Locally verified; packaged gate pending | Generation-owned render buffers clear on render queue; main-actor sink + locked invalidation. Two hosted lifetime tests and three real libmpv tests passed under Thread Sanitizer, including twelve render/resize/reload/shutdown/reuse cycles; no race report. Final packaged app/quit and supported-machine coverage remain. |
| A04 | P1 | Q03 | Hosted API verified; modal gate pending | Menu commands and export/read/restore service entry points check the lock, including after panels/awaits. Actual locked makeDocument/read/write/restore regression passed; interactive mid-panel locking still needs UI coverage. |
| A05 | P1 | D02 | In progress; migration and process recovery locally verified | Shared identity/preview/navigation/backup v2 paths and snapshot-backed atomic remote/local title/history/preferences rekey pass regressions. Actual old-schema upgrade and original-schema recovery pass with a frozen old model; unambiguous catalog resolution, durable aliases/idempotence, WAL/tamper/rollback and failed-profile restoration pass. Explicit reassignment is implemented in Library/History with collision checks, snapshot/transaction reuse and profile/lock guards; interactive/conflict and minimum-OS acceptance remain. Additive per-field metadata now has merge and old-schema/process recovery evidence; Catalogue reconciliation now also runs whenever the installed providers change (not only at engine start and unlock), so a legacy title whose only candidate was just installed is bound without a relaunch; a title whose recorded installation is gone is never rebound by name and can be reassigned explicitly from Library/History (offered only when the provider list is complete). Local-download UUID linkage and legacy local rekey have local regression evidence. Eight SIGKILL/reopen boundaries pass for default/named stores; origin-profile download journals remain T01 work. |
| A06 | P1 | D01 | In progress: read/write/reopen boundaries verified | Queries, snapshots and mutations throw; private non-autosaving library/download contexts save separately, rollback and publish only after commit. Restore owns its context. Failed playback writes retain/coalesce owned retry intent; profile activation/backup fence unsaved progress. Deferred UI errors and explicit retry preserve selected-profile ownership; failed startup never exposes or restores into default data. Real disk stores reopen with committed profile/download domains and failed-mutation/replace rollback intact. Progress played while the selected profile's store cannot open is kept in memory for that store, reported as unsaved, written when that store opens and never to another profile (lost if the app quits first). Restore now runs its transaction on a background context with the profile's library fenced against other writes, profile switches and identity changes until it commits; positions played meanwhile are saved afterwards; a failed restore changes nothing. Interactive recovery/quit and minimum-OS gates remain. |
| A07 | P1 | Q02 | Locally verified; packaged gate pending | Management modules added; compiled host jdeps closure verified; actual 53 MiB jlink image ran Android memory/CPU APIs and sandboxed offline extension fixture. B01/V01 final artifact gate remains. |
| A08 | P1 | Q02 | Locally verified; final integration pending | Private recording root, forced safe/worker policy, fresh actual-port log, stdin token, cleaned inherited JVM/engine settings and bounded kill. Producer and consumer now bind jar/modules/archive hashes; consumer fallback fixtures pass. Repeat reduced-runtime recording/replay on the final jar/artifact. |
| A09 | P1 | Q01 | Locally verified | Explicit bash/pipefail, shared raw-log wrapper, preserved xcresult/log artifacts. Seven script tests include real Swift type error and failed Make/xcodebuild substitute. |
| A10 | P1 | Q04 | Locally verified; integration gate pending | Pre-mutation document/preference validation, checked integer/timestamp conversions and field domains. Six isolated tests include 1e100, fractional/nonfinite integers, unsafe finite positions, atomic patch rejection and valid signed delay. |
| A11 | P1 | W01 | Locally verified; packaged gate pending | Dedicated FIFO byte-bounded writer, independent call/write/kill deadlines, ProcessHandle signals and lifecycle-scope cancellation. Six worker-pipe regressions and full daemon suite pass; rerun reduced-runtime/final artifact after latest worker changes. |
| A12 | P2 | W02 | Locally verified; packaged gate pending | Pool-owned reservations cover preparation/start/init/running/stopping; failed pre-launch paths release, live children release only at confirmed exit, and stale callbacks cannot remove a replacement slot. Independent shared startup deadlines preserve caller cancellation. Awaiting callers plus atomic call leases protect routed work from idle eviction. Batch/streaming search share eight operation permits; a real socket disconnect cancels unfinished provider jobs through the Netty close event. Eleven new regressions and the full 320-test daemon suite pass, including existing real nested extraction/isolation. Final reduced-runtime/packaged gates remain. |
| A13 | P2 | L01 | Locally verified; packaged gate pending | Real lock-owning children prove ordered exit before replacement, coalesced restarts, ignored-TERM escalation and preservation of independent transfers. |
| A14 | P2 | L01 | Locally verified; packaged gate pending | Finite capped monotonic backoff, safe-mode latch/explicit clear, and sustained-health budget reset pass process/policy tests. |
| A15 | P2 | L01 | Locally verified; packaged gate pending | Never-healthy live children and failed spawns exhaust a finite recovery budget; stale health and stopped preparation cannot publish ready. |
| A16 | P2 | L01 | In progress; integration gate pending | Generation-bound verified/restoring/usable state, completed restore phases, awaited credential resend, and cancellable download wait implemented. Policy/terminal queue regressions pass; actual provider-restore/credential failure integration remains. |
| A17 | P2 | L01 | Locally verified; minimum-OS gate pending | Observation has one application lifecycle owner. Each main window owns navigation/search/sheets; focused commands and weak external routing preserve window targets. Replay/cancellation and independent-window unit tests pass; actual two-window UI navigation, private sheets and post-close command routing pass on the current OS. |
| A18 | P2 | D03 | In progress: episode-check ownership verified locally | Episode batches use immutable candidates, captured store/context/profile generations, engine usability/generation and lock authorization epochs. Scheduled/manual checks are owned and cancellable; post-switch results and permission-delayed notifications cannot apply to the new profile. Four new regression tests cover away/back, engine/lock/cancellation, notification permission and single-batch/captured-title behavior. Continue Watching now captures value requests synchronously in Home/Dock/menu-bar/Shortcut paths, owns/cancels tasks and fences details responses/errors by profile/lock/engine/current resume state. Restore now carries the profile it was prepared for and is refused if another profile is selected; export and import recheck lock and ownership after their modal panels; external restore phases recheck lock and engine generation after each request. Shared downloads record the profile that queued them and file the optional library entry into that profile through an owned context (deleted profile: download kept, user told; legacy unowned: explicit Add to Library). Interactive switching and minimum-OS acceptance remain. |
| A19 | P2 | D05 | Locally verified; live-engine restore gate pending | New ordinary `/repos/register` operation: repeatable, no migration marker, records the address only (no sync/install/trust/consent), applies the user-initiated repository policy and returns applied/already_present/rejected per address. The one-time `/repos/import` migration is unchanged. Restore uses registration, exports disabled providers by stable ID (names are kept for older backups and matched only when exactly one provider has the name), reports rejections, uninstalled and ambiguous providers as warnings and never swallows a failed request. Daemon tests (5) and client restore tests pass; a restore against a real running engine has not been exercised. |
| A20 | P2 | Q04 | Locally verified; integration gate pending | Profile/reason/UUID names, exclusive atomic inode publication, separate Daily/Safety directories, daily-only pruning. Collision/no-overwrite/cleanup tests pass; service retention/profile backup tests pending isolated host. |
| A21 | P2 | D05 | Locally verified; long-running/wake product gate pending | `BackupService.startScheduling` runs at launch, hourly while the app runs, on wake and on profile activation, independent of the engine. Each profile has its own last-success time; inactive profiles are read through an owned context without switching the visible profile; a failed or empty profile stays due. Backups carry the last extension setup the engine reported with its capture time, or none, and say so. Retention stays per profile (7 daily; safety copies separate). Disk-backed test covers three profiles, clocks, disable and read failure. The hourly timer and wake notification themselves were not exercised over real time. |
| A22 | P2 | D04 | Locally verified; product gates pending | Movie (and local-file) playback records one history row per title under a stable movie key that is independent of the rotating `movieData` link (`EpisodeProgress.kind`, additive). Statistics count the same played/owned rows History shows; "Episodes watched" stays episode-only and "Movies watched" is separate. Existing movie resume positions are migrated once. Privacy clear covers movie rows. Interactive History/Settings and minimum-OS acceptance remain. |
| A23 | P2 | D04 | Locally verified; product gates pending | The history backfill is a once-per-profile-store migration whose `history-backfill-v2` marker commits with its rows; deleted history is not reconstructed after reopen or profile reactivation (disk reopen test). Deleting a row that is the title's resume pointer moves the pointer to the latest remaining row or clears it in the same transaction; deleting an older row leaves a newer pointer alone. Limit: a store upgraded with zero history rows runs the legacy episode backfill one final time, because that state is indistinguishable from an unmigrated store. |
| A24 | P2 | D04 | Locally verified; product gates pending | Exact saved episode data wins; the coordinate fallback needs non-nil season+episode, the saved edition when known (`StoredMediaItem.lastAudio`, `EpisodeProgress.audio`, backup v2 optional fields) and exactly one candidate. Switching episodes resets the stale duration/coordinates/edition. Details, resume and the player share `PlaybackSequence` (see A34). Interactive and minimum-OS acceptance remain. |
| A25 | P2 | D05 | Locally verified; product gates pending | Optional note/rating/favorite/list/progress edit dates and existing playback time now govern independent merge fields, including explicit clears. Equal times preserve local with conflict warnings; missing times on either side preserve local without invented order. V1 decoding propagates to restore; Replace remains complete. Real disk reopen/rollback, identity-collision isolation, portable/local namespace rejection and failed-safety-copy warnings pass. Interactive/minimum-OS and broader D05 phases remain pending. |
| A26 | P2 | D04 | Locally verified; product gates pending | List removal keeps favorites, notes, ratings, history and playback settings (regression). A title is physically deleted only when no retained data needs it; history deletion follows the same rule. Import keeps history/settings whose title is missing and reports them (`unownedEntries`) instead of pruning; statistics exclude them and Settings states how many exist; Clear History removes them. Portable export no longer includes history/settings of local downloads, and validation rejects them. SwiftData cascade relationships were not introduced. |
| A27 | P2 | Q05 | Locally verified; packaged gate pending | If-Range requires a syntactically strong ETag or a proven date validator; response must match it and the complete remaining range. Missing/weak/ambiguous/changed validators restart, including equal-size replacement bytes. Identity content encoding is required. Local full-part recovery requires a synchronized, validated completion marker; legacy sidecars refetch safely. |
| A28 | P2 | Q05 | Locally verified; packaged gate pending | Direct-file routing requires no separate audio tracks. Existing copy-only ffmpeg remux preserves per-input headers. Actual queue download with independently authenticated video/audio inputs completed; inspection of saved MP4 confirmed H.264 video and AAC audio. |
| A29 | P2 | T01 | Locally verified with real ffmpeg; packaged gate pending | Every return to an active transfer goes through `drainQueue` admission: a frozen ffmpeg process gets SIGCONT only when a global/per-provider slot is free and the network is available; resume intent, user pause and network hold are tracked separately; a user pause during a network hold sticks. Link resolution that finishes while offline re-queues instead of starting IO. Real throttled-HLS test: pause, replacement, resume at a limit of one never exceeds one; offline manual resume is held. |
| A30 | P2 | T01 | Locally verified, including SIGKILL of a separate process; packaged gate pending | Additive `finalizing` status (raw 7) journals the planned final path and byte count before the rename; the completed video is committed immediately after the rename, before sidecars, notification and library entry; resume metadata is removed only after that commit. Launch reconciliation: final file of the journaled size → completed; finished part only → renamed and completed; both present, wrong size or missing → explicit failure with nothing overwritten; unplugged volume → journal kept. Tests stop finalization at each of three boundaries, restore from the same store and compare bytes, with no duplicate or re-download. In addition, a separate debug app process runs a real download and is killed with SIGKILL at each of the three boundaries; a second process reopens the same store and reconciles it to one completed file with the downloaded bytes, no part, no duplicate and no second request (`run_identity_migration_tests.sh`). |
| A31 | P2 | T01 | Locally verified; removable-volume hardware gate pending | Deletion returns a structured result. A durable deletion intent is saved before the file is touched; the record is removed only after the video is gone; a refused removal withdraws the intent and keeps everything; sidecar failures are named. A missing file and an unmounted volume are distinct and neither removes the record; "Remove from List" is a separate explicit action available only when the file is really absent. If the record commit fails after the file is removed, the saved intent completes it at the next launch. Covered with a read-only folder, a `/Volumes` path that is not mounted and injected commit failures; no real external disk was unplugged. |
| A32 | P2 | N01 | Locally verified and measured; corpus check pending | `BoundedHTTPResource` streams with a per-task delegate, refuses an oversized declared length before the body, cancels when received (decoded) bytes exceed the budget, allows only policy-valid HTTP(S) redirects and drops caller headers for another origin. Images: 32 MiB response budget, MIME check, 64 MP source-pixel limit checked before allocation, ImageIO downsample to 2560 px, six concurrent network loads, header-scoped cache identity. Subtitles keep the 5 MiB limit, now enforced during receipt. Eight fixture tests cover declared/undeclared/slow/gzip bodies, redirects, cancellation, a 10000x10000 PNG, cache scoping/dedup/clear and sidecars. The measurement found decodes unbounded (24 simultaneous 4000x3000 JPEGs: +914 MB peak): a load now keeps its turn through decoding, decodes share a 24-megapixel budget, disk-cache reads have their own turns, and the memory cache enforces its 256 MB itself because `NSCache` does not. Same load afterwards: +502 MB peak (about 330 MB of it retained cache and fixture), same duration. A valid-artwork corpus check against real providers has not been run. |
| A33 | P2 | Q06 | Locally verified in a real worker process; live-provider gate pending | Request and worker protocol state unchanged/set/clear explicitly (`clearUrl`, `clearCredentials`; null = unchanged; empty = clear for older callers). A clear removes the live credential and never falls back to the previous one; an empty URL is a clear, not a validation error. A failed remote configure stops the worker so it can only restart with the committed settings, and the response reports `applied=false, pending=true`. The client applies settings through one transaction: set keeps the previous Keychain value until the engine accepts and restores it otherwise; clear deletes the Keychain value first, never restores it, and restarts the engine if the engine cannot drop its in-memory copy. Route, worker-function and client transaction tests pass. A compiled fixture provider that reports its live address and credential now runs in a real worker process (`WorkerCredentialTest`): set, replace and clear take effect in the same running worker; a clear survives restart; a worker frozen with SIGSTOP does not acknowledge the clear, is reported `applied=false, pending=true`, is killed, and restarts without the secret. That test found a defect, now fixed: a worker restarted in the session its extension was installed in received no address/credential settings, because they were looked up by provider names the fresh record did not have yet. IPC is 6. A real provider with a real account has not been exercised. |
| A34 | P2 | R02 | Locally verified; product gates pending | `PlaybackSequence` (edition filter, then season/episode with stable provider order for missing coordinates) is built by the details screen and stored in the player session. Next/previous, Up Next, autoplay and prefetch read the session sequence; a session started on an alternate edition keeps that edition. Three tests, including the player's neighbour flags against interleaved provider order. Countdown/prefetch recreation on replacement uses the existing per-session reset; interactive acceptance remains. |
| A35 | P2 | R02 | Locally verified end to end with real mpv; pinned-libmpv and live-provider gates pending | Split streams whose audio needs other headers than the video are registered with the engine's relay (`MediaRelay`; `POST /media/relay`, `GET`/`HEAD /media/relay/{id}`): each resource is fetched with exactly its headers, the player contributes only a byte range, ids are unguessable, session-scoped and revoked on mirror switch, new play, failure and close; a late registration is revoked, not used. Not a proxy: no URL in a read request, progressive media only (manifests refused), bounded sessions, error bodies and origin cookies not forwarded, credentials dropped on a redirect to another origin. Seven daemon tests against a real listener and origin; four client tests (plan, ownership, late registration, fallback). End to end (`test_media_relay_playback.py`): the real engine jar and mpv 0.41 play a video-only and an audio-only file behind different cookies from a 12 s seek, with range requests reaching the origin and the audio origin never seeing the video's cookie; the same manifest loaded directly leaks the cookie and has no audio. Not proven: the pinned media stack's libmpv (not built here; the local one is Homebrew's 0.41), a real provider, and behaviour when the engine restarts mid-playback beyond failing over. |
| A36 | P2 | R02 | Locally verified; forced-init gate pending | Engine start failures are reported separately from a failed file; seek and screenshot commands are tagged and their replies reach the view model (rejected seek clears the pending wait; screenshot announced only after a successful reply and an existing file); a 45 s load deadline fails over. Real libmpv test confirms screenshot success/failure and seek replies. No initialization failure could be forced on this libmpv build, so that path has unit coverage only. |
| A37 | P2 | Q07 | Locally verified | Page-one and pagination tasks are both owned; clear, provider change and refresh advance a load generation, cancel both and reset pagination. A response applies only for its generation, provider and expected page. Controlled-loader tests cover late page two after refresh and late page one/two after clear and provider change. |
| A38 | P2 | D03 | Locally verified; interactive gate pending | `DetailsCache` entries are authoritative only for the engine generation, installed-extension generation (version/artifact/enable state/address/providers) and provider-settings generation they were loaded under, and for ten minutes; eviction is least-recently-used and skips open pages. Without a usable engine the held copy is display-only and is revalidated when an engine can answer. Discover homepages use the same generation. Unit tests cover each invalidation, freshness, LRU and generation changes; playing from a stale page in the running app was not exercised. |
| A39 | P2 | D03 | Locally verified with a controlled backend; live-index/product gates pending | One ordered writer serializes domain deletion and indexing and keeps only the newest queued state; an executing OS call finishes before its replacement. Snapshots capture `ProfileOperationContext` plus library version without SwiftData models. Ownership/enabled/generation are rechecked after each await; a late obsolete insertion is followed by cleanup; success is cached only after completed valid work; read/delete/index failures stay visible and retryable (Settings shows the failure and Retry Spotlight Update). Profile activation/startup and preference changes (including restore) invalidate and reschedule. Nine Spotlight tests pass in the 422-test client run. Not proven: live Spotlight query results, minimum-OS behavior, packaged acceptance. |
| A40 | P2 | B01 | Implemented; CI run pending | The client job (macOS 15 arm64, asserted) builds the pinned media stack, jar and runtime from the checkout, verifies them, and passes `CS_ENGINE_PREPARED=1` so Xcode does not rebuild the engine. The rewritten workflow parses but has never run. |
| A41 | P2 | B01 | Implemented; credentials gate pending | Release job imports the certificate into an ephemeral keychain, stores a notary profile, runs `package_app.sh --distribution`, uploads the DMG path the script prints and deletes the keychain. Distribution mode fails before building without a usable identity/profile (tested). Real signing and notarization have not been performed. |
| A42 | P2 | B01 | Locally verified on fixtures; real media stack pending | `stage_media.py` resolves absolute/@rpath/@loader_path/@executable_path dependencies, fails on anything unresolved or on a failed rewrite/signature, removes outside run paths, runs the staged ffmpeg and writes a manifest that is the only accepted proof of staging. `verify_macho_closure.py` checks every Mach-O. Tested on compiled stand-in stacks; no real media stack exists on this Mac. The verifier found that the Homebrew-built jlink runtime links `/opt/homebrew` libraries: local builds are labelled not-portable and distribution refuses that JDK. |
| A43 | P2 | B01 | Locally verified | `publish_artifact.sh` is the only writer of `dist`: verified candidate, private staging, generation directory, one atomic `current` switch, lock, last good generation kept. The Xcode dist-copy phase is removed. Twenty-one pipeline tests plus two real `build_dev.sh --launch` runs. |
| A44 | P2 | Q01 | Locally verified | Foundation service contracts and pure preference-change policy extracted; isolated harness executes 25 existing tests with no failures; full app and test targets compile. |
| A45 | P2 | Q06 | Locally verified | Download resolution classifies a typed operation failure by the engine's `retryable` flag before generic HTTP status handling; non-retryable typed failures are terminal without being reported as a missing provider. The client test decodes the daemon's response shape through `DaemonClient.validate`; a daemon route test pins that shape (503 capacity retryable, 422 incompatibility terminal). The two tests share the shape by convention, not by a generated fixture. |
| A46 | P2 | Q06 | Locally verified; live-provider gate pending | The challenge retry merges cookies by name on the same request/origin: provider session cookies stay, solver cookies replace same-named ones. Cached clearance is also merged into later requests that carry their own cookies, without overriding them. Only solver cookies are cached, per origin; invalid solver bytes are neither cached nor sent. Real TLS loopback tests pass. User-agent binding is unchanged and no live challenged provider was exercised. |
| A47 | P2 | R02 | Locally verified; live-provider gate pending | The player owns the extractor verifier for the active link and releases it on mirror switch, new play, close and failure; a late start is stopped instead of attached; bounded retry then a visible notice. Tested with injected start/stop; no real provider needing keep-alive was exercised. |
| A48 | P3 | Q07 | Locally verified | Artwork fetches carry a URL/token; a superseded fetch is cancelled and cannot publish, restore cleared playback, or release a newer fetch's ownership. Controlled-loader test covers title switch and clear. |
| A49 | P3 | Q07 | Locally verified | The TMDB request is built with URLComponents/URLQueryItem and a literal `+` is escaped; `&`, `=`, `+`, `%`, `#`, `?` and Unicode stay one exact query value (test). Debounce, limits and person filtering are unchanged. |
| A50 | P3 | Q07 | Locally verified | The existing-shelf merge updates its seen set per accepted item, like the new-shelf branch (test). |
| A51 | P3 | D05 | Locally verified | Android import keeps account+id through parsing, converts each account separately and resolves resume ids per account. Same-title conflicts take the more recently changed account for status and for the resume position as a unit; without usable dates the lowest-numbered account stays, favorites are a union and the titles are listed. The import dialog offers all accounts (default) or one. Fixture test covers same-number/different-title, dated and undated conflicts, determinism and single-account import. |
| A52 | P3 | Q08 | Locally verified | `smoke_launch.sh` uses a private root, the launched PID and the app's own published engine state; it fails nonzero for a dead app, no usable engine, a foreign or orphaned engine, missing player prerequisites, a hung quit or missing log markers, and signals only its own processes. Six script tests with a stand-in app; passed against the real Debug and Release apps. |
| A53 | P3 | Q08 | Locally verified | Engine stdout/stderr are appended with a start and exit marker per launch and rotate once above 2 MiB; Diagnostics shows and exports them redacted. Two real-process tests. |

## Execution evidence

Checks executed on 1 October 2026:

- `bash scripts/test_extensions_core.sh`: 25 tests passed. Actual transport/store/DTO/contract sources, no UI or production engine launch.
- `bash scripts/test_backup_core.sh`: 6 tests passed. Actual document/policy/preference/file-publication sources; temporary preference suite and files.
- `python3 -m unittest discover -s scripts/tests`: 7 tests passed, including real Swift compiler failure, Make failure propagation and isolated recording faults. Loopback fixtures required sandbox escalation; no rejection occurred.
- `./gradlew :engine:test :engine:jar :engine:sbom --console=plain`: 304 tests total, 301 passed, 3 explicitly skipped, zero failures/errors. Includes 6 real pipe/lifecycle/FIFO/capacity tests. The pre-existing crash fixture was corrected to start from a committed baseline, retaining first-write kill coverage.
- `xcodebuild … build-for-testing CODE_SIGNING_ALLOWED=NO`: full app/unit/UI targets compile with Swift 6 strict concurrency. This is compilation evidence, not execution of hosted tests.
- App-hosted isolation/lock/lifetime selection: 6 tests passed with private roots/preferences, in-memory credentials and disabled automatic engine startup. Full client unit suite: 300 tests, 276 passed, 24 explicitly skipped, zero failures. The new native stress test was added after this broad run and executed separately below.
- Thread Sanitizer build and real local-media selection: 5 tests passed (3 libmpv render/reload/shutdown checks plus 2 lifetime checks), zero skips/failures/race reports. Native dylibs are not sanitizer-instrumented; the app/test Swift ownership code is. Logs: `native-tsan-tests.log`, `tsan-build.log`.
- Framework staging regressions: 3 tests passed (real directory preserves Xcode sanitizer runtime, legacy symlink migration, unexpected symlink rejection); shell syntax and `git diff --check` passed. This repairs the sanitizer-blocking layout but does not close the broader B01 release findings.
- D01 snapshot/restore foundation: full client suite 305 tests (280 passed, 25 explicitly skipped), zero failures. After adding the safety-read guard regression and owned-store service seam, targeted persistence/backup/profile suite 22 tests passed, including 5 boundary tests. Logs: `client-unit-tests.log`, `persistence-tests.log`. This does not close A06: ordinary mutation/read APIs and their callers still require explicit errors/transactions and recovery.
- D01 ordinary mutations: full client suite 309 tests (284 passed, 25 explicitly skipped), zero failures. After adding 3 download failure cases, targeted SwiftData/queue suite 25 tests passed. Failed mutations roll back and can retry; neither library nor download writes save unrelated pending context work. Admission save failure prevents resolution; completion save failure preserves the final video without claiming durable completion; failed video deletion retains the record. Read APIs/recovery/progress retry and T01 crash journals remain pending.
- D01 read/recovery/progress: full client suite 318 tests (293 passed, 25 explicitly skipped), zero failures. All public query APIs distinguish failures from successful empty results; display errors publish after render and cannot attach to a newer generation. Failed latest playback positions retry in monotonic order; unsaved progress fences profile changes and backup. Explicit selected-profile recovery passed. Subsequent disk-backed selection: 17 persistence tests passed, including actual store reopening, default/named profile separation, shared downloads, failed mutation/replace durability and owned-root path rejection. These reopen tests do not simulate a process kill or OS-level save failure.
- Q05 integration: full client suite 330 tests (305 passed, 25 explicitly skipped), zero failures. Hostile HTTP fixtures compare actual file bytes; mismatched tails restart once, weak/missing/ambiguous/changed validators cannot splice equal-size entities, and complete unsolicited ranges require exact streamed length. Cancellation retains a resumable owned partial. A real queue remux with distinct required Cookie headers saved both video and audio; actual container inspection confirmed both streams. With a further cancellation-during-fallback regression, targeted download/policy/queue selection passed 46 tests. All 15 direct-transfer tests also passed under Thread Sanitizer, with zero failures/skips/race reports. Logs: `download-integrity-tests.log`, `download-tsan-tests.log`, `client-unit-tests.log`.
- `verify_runtime_modules.py`: compiled host references fit the declared jlink closure.
- `bundle_runtime.sh` with temporary output/tools directories: real reduced runtime self-test passed (translated multi-DEX extension and sandboxed worker search/details/links), 53 MiB image; isolated CDS recording and explicit `-Xshare:on` replay passed. This preceded the latest W01 jar; repeat on that jar/final artifact.

Logs for this implementation run live in `/tmp/cloudstream-remediation-baseline/`; pre-existing user diffs were captured there before edits. The generated project was updated for new sources while retaining the existing client-group identifier, and `scripts/clean.sh` was not edited.

## Current dependency work

D02/D05 field merge (2 October): StoredMediaItem has five optional edit clocks
(note, rating, favorite, list status, title resume). Existing rows default to
unknown, and real frozen-schema upgrade tests explicitly verify no edit clocks
are invented. Direct/bulk list operations, favorites, notes, ratings, progress,
watched/auto-promotion and preference writes maintain their relevant clocks.
Consecutive edits retain millisecond ordering; aggregate recency advances only
for applied known edits. List clears retain a portable clear tombstone and
independent data. History cleanup retains notes/ratings/clear metadata/settings;
full D04 history semantics remain pending.

Backup v2 exports these fields. Merge requires known times on both sides for a
mutable field, keeps local on equal/conflicting times, applies newer nil/zero/
false values and reports unknown/equal-order conflicts. Playback applies only
newer complete settings, including nil language/intro clears. V1/Android source
versions propagate to the restore snapshot; legacy Replace applies all supplied
values while retaining unknown clocks. Unknown playback time is represented by
an internal distant-past sentinel and exported as nil, not import time. A known
backup cannot bind an unknown same-name legacy owner: it creates a separate
canonical row and maps incoming dependencies there. An unidentified backup
cannot merge into an identified legacy owner through that name key.

Final integrated client evidence: 399 tests, 369 passed, 30 explicitly skipped,
zero failures (`backup-field-final-client-tests.log`). The final restore/history/
identity selection passed 55 tests without skips/failures
(`backup-field-restore-final-tests.log`). This includes field independence,
explicit clears, older playback rejection, equal-time warnings, unknown-local/
legacy conservatism, production v1 read, real disk reopen, restore rollback,
portable/local boundary and identity collision regressions. The final UI wording
and failed-safety-copy warning were covered by that focused run after integration.
The frozen-schema/process command passed all 18 tests without skips, including
eight default/named profile kills with the new additive model
(`backup-field-compatibility-tests.log`). Isolated backup/transport harnesses
passed 6/25 tests (`backup-field-backup-core.log`,
`backup-field-extension-core.log`). D05 repository/config restoration, scheduling,
Android account conflicts, D03 catalog ownership, D04 history/retention and
interactive/minimum-OS gates remain open; the complete audit is not resolved.


D02 interrupted migration: the final frozen-schema compatibility command passed
all 18 tests with no skips/failures
(`identity-process-final-compatibility-tests.log`). The earlier default/named
selection passed 17 (`identity-profile-process-kill-tests.log`). It
SIGKILLs a separate Debug app running production storage code at four boundaries
(snapshot publication, schema opening, immediately before identity commit, and
immediately after identity commit), for both default and named-profile stores.
Each of the eight cases reopens the same disk store, preserves notes/progress/
playback settings/shared downloads, completes an idempotent migration, and opens
the original-schema snapshot with the separately compiled old model. Named-profile
migration leaves default-profile title keys unchanged.

This exposed and fixed the lost original-schema pointer after schema upgrade but
before identity marker commit. Rediscovery binds snapshots to SQLite store UUID,
not filename alone; manifests remain v1 with an optional UUID field. Regressions
also cover another same-named store, unpublished partial copies, a corrupted
published copy, an unrelated profile's malformed manifest, oversized manifest
rejection and WAL integrity. Probe code is Debug-only and requires explicit
isolated roots; ordinary unit selection visibly skips its external prerequisites.
The final integrated client suite passed 390 tests: 360 passed, 30 explicitly
skipped, zero failures (`identity-process-final-client-tests.log`). The two
additional ordinary-unit skips require the externally provisioned lineage and
process fixtures and execute in the compatibility command. A disk-reopen
inspection failure during the first integrated run led to bounded SQLite
busy handling and actionable inspection errors. Ten reopen repetitions passed
(`identity-reopen-stress-tests.log`); an actual exclusive-lock regression fails
within the bound, preserves its data, and succeeds after the lock releases.

These tests prove process-kill recovery on the current machine, not power-loss or
minimum-OS acceptance. Interactive reassignment/per-field metadata and remaining
D02/D05/T01 gates remain open.


D02 local-download identity: local titles and playback details now use the shared
DownloadRecord UUID under `local-download-v2:`, retaining a nil remote provider ID.
Downloaded-file playback supplies its actual destination path instead of the
provider name, preventing same-provider files from sharing playback history.
The namespace survives display-name/path changes. Legacy path placeholders
rekey with history/preferences/aliases only when one shared UUID owns the path;
ambiguous/missing evidence stays unresolved. Removal targets the UUID and permits
legacy fallback only with unique shared-record evidence. Portable backups still
exclude local media.

The final integrated client suite passed 387 tests (359 passed, 28 explicitly
skipped, zero failures; `local-download-final-client-tests.log`). It includes
legacy local disk rekey/reopen/recovery, independent same-provider resume,
same-path/different-UUID isolation, path/name changes and selective deletion.
A full-suite read-fault regression exposed an unnecessary shared-store read
in remote-only migration; the final implementation reads download records only
when the migration contains local entries. The frozen-schema compatibility
command passed all 15 migration tests without skips
(`local-download-compatibility-tests.log`). Isolated transport/backup harnesses
passed 25/6 tests (`local-download-extension-core.log`,
`local-download-backup-core.log`). Abrupt-process/minimum-OS and origin-profile
admission/completion/deletion journals remain pending; these local tests do not
close A05 or T01.


D02 recovery/rekey: the final integrated client suite passed 379 tests (351 passed,
28 explicitly skipped, zero failures), before the reassignment additions. The extra skip is the explicitly gated frozen-schema fixture; its separate compatibility command executes that test. SQLite snapshot tests prove committed
WAL inclusion, integrity/hash verification, tamper rejection and preservation of
old title/history/preferences on snapshot or transaction failure. Migration
updates all dependent keys together, saves durable legacy activity aliases and
is idempotent. Default and selected-profile activation use the same gate; failed
named-profile migration restores the previous context/profile identity.

The frozen audited schema tool creates a real old-format database. Its upgrade
and original-schema recovery passed with zero skips: the current model preserved
notes/history/settings/shared downloads, and the separately compiled old model
opened the original recovery copy successfully. The repeatable
`run_identity_migration_tests.sh` command passed all 7 tests, including persistent
failure/retry and profile rollback. Logs: `identity-migration-client-tests.log`,
`identity-old-schema-tests.log`, `identity-compatibility-command-tests.log`.
These are local model/store proofs, not abrupt-process or minimum-OS proofs.
Explicit reassignment now has a Library card “Choose Provider…” action for
unknown remote owners, including History entries outside curated lists. Its dialog disambiguates installations, preserves title
fields/dependents, checks current profile/store ownership and lock state, and
uses the same verified snapshot/atomic migration path. A stale/unavailable
selection, already resolved row, or target identity collision is rejected.
Focused reassignment selection passed 9 tests with one explicit old-schema skip
(`identity-assignment-tests.log`); the expanded frozen-schema command passed all 11 tests without skips
(`identity-assignment-compatibility-tests.log`), including explicit assignment
commit rollback, verified recovery and reopened durable aliases. The integrated client suite then passed 383 tests (355 passed, 28 explicitly
skipped, no failures), including the Library/History integration
(`identity-assignment-final-client-tests.log`). The final lock/profile dismissal
changes compiled and passed a focused migration/window-state selection: 14 passed,
one external old-schema fixture skip, no failures
(`identity-assignment-dismissal-tests.log`). These units do not certify interactive
sheet behavior; that acceptance remains pending. Interactive UI, abrupt-process,
minimum-OS, per-field metadata and origin-profile/journal gates remain pending.

D02 identity foundation: full client suite passed 372 tests (345 passed,
27 explicitly skipped, zero failures). Final mixed-key merge/persistence/history/
system integration selection passed 72 tests with no skips or failures. The
isolated transport and backup harnesses passed 25 and 6 tests respectively after
including the shared identity contract. Tests cover two installations exposing
the same name/URL, original signed URL bytes, display-name changes, preview ID
propagation, v1 decoding/v2 exports, real disk reopen and canonical-backup merge
into a known legacy owner with history/preferences references preserved.
Logs: `provider-identity-client-tests.log`, `provider-identity-merge-tests.log`,
`provider-identity-extension-core.log`, `provider-identity-backup-core.log`.
This foundation result preceded the snapshot-backed rekey work above. Unknown
legacy rows remain separate unless an unambiguous catalog or explicit user
selection resolves ownership. A05 remains open for the remaining migration and
compatibility gates.

L01 multiwindow integration: full client selection passed 366 tests total
(339 passed, 27 explicitly skipped, no failures). Subsequent final lifecycle,
profile/lock and window-session selection passed 34 tests with no skips or
failures. Concurrent query fixtures prove searches cannot overwrite another
window or publish superseded results. The isolated two-window UI regression
passed actual window creation, independent Go commands, focused shortcut-sheet
presentation and surviving-window routing after close. Logs:
`window-session-client-tests.log`, `window-session-final-tests.log`,
`window-session-ui-tests.log`. The first build failed on a transient disk-full
jar copy; the successful retry rebuilt the jar input and all targets. No user
files or evidence were deleted. Signal durability, actual restore/credential
integration and minimum-OS/final artifact gates remain pending.

The extended final UI regression also passed Go commands from Settings targeting
the surviving main window (`window-session-ui-final-tests.log`, one test,
zero skips/failures). This checks the focused-scene fallback after the final
command compatibility change, not only the earlier two-window implementation.

L01 lifecycle foundation has passed the full client suite: 362 tests total,
335 passed, 27 explicitly skipped, zero failures. Final focused replay/shutdown/
recovery/readiness/terminal-download selection passed 20 tests with no skips or
failures. Real children cover slow lock release, coalesced restart, ignored TERM,
never-healthy startup, failed spawn, safe-mode crashes/clear, stable-health reset,
late health, cancelled preparation and independent transfer ownership. Common
shutdown ordering/idempotence/error tests and cancellable connection-signal
tests passed. Logs: `lifecycle-client-all-tests.log` and
`lifecycle-connection-final-tests.log`; corresponding xcresults are retained.
CDS producer regressions passed 3 tests with private loopback networking enabled;
consumer fixtures cover stale jar/modules/archive, missing/oversized metadata
and unsupported version. Actual provider restore and
credential failure integration, signal-level persistent-store durability,
minimum-OS and final packaged acceptance remain pending. This evidence does not
close those gates or the full L01 package.

P00 is in progress: foundation fixtures and source baseline exist; application-host preferences, credentials, file roots and profile deletion are isolated. Unit-test hosts skip automatic engine/connectivity/checker startup and system Spotlight writes. Explicit isolated UI launches retain their engine behavior with private roots. Additional persistence/process/clock failure seams will arrive with their owning packages. Q01 has passed its local gates. Q02 has passed producer/runtime checks and hash-consumer fixtures; repeat recording/replay on the final jar/artifact remains. W01 has passed the complete daemon suite. Q04 has passed pure validation/publication checks and now propagates truthful safety-snapshot read failures; D01 ordinary operations remain. D01 mutation and snapshot/restore boundaries have passed actual SwiftData failure and ownership regressions; the restore context cannot save or roll back unrelated pending context work. Successful import refreshes the facade context and publishes version only after commit. R01 has passed hosted lifetime and real render stress under Thread Sanitizer; packaged coverage remains. The A04 portion of Q03 passed actual locked API tests; modal timing coverage remains. Framework staging now uses a real Contents/Frameworks directory shared by Xcode/development/release scripts, preserving Xcode-owned sanitizer libraries.

Read-model callers now use explicit throwing service paths or the named display fallback/error policy; retryable progress and recovery UI are implemented. D01's next gates are abrupt process termination, progress intent when its owner cannot open, and interactive recovery/quit acceptance. Q05 has passed full client integration and direct-transfer Thread Sanitizer coverage, including cancellation during fallback. Q03 native confinement and W02 admission have local evidence recorded above. L01 process/connection/window ownership is implemented with local regression evidence; actual restore/signal/minimum-OS integration remains. D02 stable provider identity and snapshot-backed migration are implemented locally; remaining D02 acceptance and data metadata work continue as P1 dependencies. All remaining plan packages remain in scope; independent quick repairs must not replace these dependencies.

Broader native/session/quit coverage, minimum-OS, signed/notarized release, live-provider compatibility and final current-artifact gates remain pending. No claim of complete audit remediation is made.

- Q03 media boundary: full hosted client suite passed 340 tests (314 passed, 26 explicitly skipped), zero failures. Seven policy tests cover signed-byte preservation, root/nested/native/header rejection, local media/subtitle provenance and client/worker cardinality parity. Six additional live native checks passed with zero skips: security options accepted, resource headers sent and cleared, HLS/seek/subtitles, generated playlist and eager/lazy split audio with literal metadata, authorized local playback, and nested file/crypto/concat plus redirect rejection. Logs: `media-client-all-tests.log`, `media-native-boundary-tests.log`. This verifies the current bundled libmpv locally, not every external player or final packaged artifact. Benchmark fixtures now use the closed production EDL builder rather than passing arbitrary pseudo-protocol strings; obsolete duplicate split construction was removed.
- Q03 daemon follow-up: full daemon suite passed 309 tests (306 passed, 3 intentionally skipped), 57 suites, zero failures/errors, and the matching `jar` task succeeded. Explicit signed-query markers (including encoded parameter names and AWS/Google signature forms) preserve the complete URI, including marketing parameters and empty pairs; unsigned tracking cleanup remains separate. Worker output validation runs before cleanup and no longer redundantly truncates already-bounded nested media. Log: `media-daemon-tests.log`. Repeat reduced-runtime/CDS and final packaged gates with this rebuilt jar.
- W02 ownership/search admission: full daemon suite passed 320 tests (317 passed, 3 intentionally skipped), 60 suites, zero failures/errors, and the matching jar build succeeded. Seven real-child admission tests cover ten concurrent cold starts capped at one base plus four overflow slots, shared startup despite caller cancellation, preparation/launch/init failures, retirement during blocked preparation, independently timed startup, confirmed-exit idle eviction, and calls awaiting startup/routed overflow. Three search admission tests prove one eight-permit budget across batch/streaming, reusable permits after cancellation, and immediate fast-provider completion. An authenticated real Ktor/Netty socket test first reproduced idle-writer disconnect leakage, then passed after binding the structured search scope to connection close; no response/IPC format change. Existing sandbox/blocked-worker/nested-extraction tests passed in the full run. Logs: `worker-admission-tests.log`, `search-stream-route-tests.log`, `worker-admission-daemon-all-tests.log`. Minimum/runtime-image/final package gates remain.


D03 episode-check ownership (2 October): LibraryStore captures a selected-context
operation token distinct from ordinary mutation version. Successful activation
increments the profile epoch; failed activation restores the old owner. The
checker copies title ID/name/provider/URL before awaits, writes to that captured
title, and rechecks store, engine, authorization, preference and cancellation
state after requests/spacing/notification permission. AppLock lock/profile-switch
paths cancel owned batches; ordinary direct store switches are fenced by the
token. Scheduled sleeps now terminate on cancellation, and manual batches share
the same owned task. The focused discovery selection passed 14 tests; the full
client selection passed 403 total (373 passed, 30 explicitly skipped), zero
failures, before the final redundant task-state cleanup. Logs:
`profile-episode-check-tests.log`, `profile-episode-client-tests.log`. Final
profile/backup/persistence verification passed 56 tests, zero skips/failures
(`profile-episode-final-tests.log`). After replacing the test’s mutable captured
authorization variable with an actor-owned fixture, the 14-test discovery
selection passed again with no warning from the changed checker/test sources
(`profile-episode-warning-free-tests.log`). This
is partial A18/D03 implementation, not proof that resume/restore/download/cache/
Spotlight ownership or minimum-OS gates are complete.


D03/D04 Continue Watching ownership (2 October): Every production caller now
captures a value ResumeRequest before scheduling. Profile switches/locks cancel
owned requests; results and errors verify the selected-context token, engine
usability/generation and lock epoch, then compare persisted resume values before
playback. Exact episode identity is selected in a separate pass before unique,
non-nil coordinate fallback. Missing/ambiguous series episodes surface selection
errors. Player.play forwards caller cancellation into link resolution and closes
only the cancelled playback generation. The initial discovery/player selection
passed 34 tests, zero failures/skips (`profile-resume-tests.log`); final broad
verification, including two additional actual player cancellation tests, passed
409 total (379 passed, 30 explicitly skipped), zero failures
(`profile-resume-client-tests.log`). Remaining D03/R02 work includes consistent newer-play
intent supersession across entry points, plus restore/export/download/cache/
Spotlight ownership. D04 durable history/edition/sequence remained pending; local Continue Watching
was subsequently integrated below. This does not close A18 or A24.


D03/D04 local Continue Watching (2 October): Downloaded resume now bypasses
provider details/readiness and selects only an exact completed shared DownloadRecord
UUID/path with an available readable regular file. It preserves UUID identity and
position, ignores irrelevant legacy episode coordinates, supplies an authorized
local player URL, and retains all profile/lock/current-resume guards. Provider
output cannot acquire this capability by returning a Download type/local UUID.
Remote movie behavior has an explicit regression. Five new tests cover local
request/session routing without an engine, wrong/missing/incomplete/changed UUID
and path, missing file/directory, remote privilege claims and movie resume. The
initial discovery/identity selection passed 31 tests; the final full client suite
passed 414 total (384 passed, 30 explicitly skipped), zero failures. Logs:
`local-resume-tests.log`, `local-resume-client-tests.log`. The tiny valid WAV
fixture verifies session/resource routing, not decoded playback quality or final
packaged/minimum-OS behavior. No finding is closed by these local checks; the
remaining D03/D04/R02/V01 gates still apply.


D03 Spotlight ownership (2 October): SpotlightIndexer owns one ordered writer for
the library domain. Requests replace a single desired state (remove, or remove
then index a value snapshot); an OS call already executing keeps the writer until
it returns, so a replacement can never overlap an old insertion. Each snapshot
records the selected-store operation token and library version. After deletion
and after insertion the writer rechecks generation, the Spotlight preference and
store ownership; an insertion that became obsolete while in flight is followed by
domain cleanup even when no caller submitted a replacement. The indexed key is
recorded only after completed current work, so a failure or a disabled/replaced
generation cannot suppress a later attempt at the same library version. A newer
snapshot-read failure is not cleared by an older insertion's success or by its
cleanup. A scheduled reindex whose store is unavailable removes the old domain
and keeps the failure retryable. ProfileStore activation/startup calls
`invalidateAndSchedule`; UserPreferences exposes a Foundation-only change
callback so Settings and backup restore share that lifecycle. Settings shows the
last failure with Retry Spotlight Update. Isolated test hosts cannot reach the
system index; tests inject a controlled backend.

Evidence: full client suite 422 tests, 392 passed, 30 explicitly skipped, zero
failures (`spotlight-client-tests.log`, xcresult
`Test-CloudStreamMac-2026.10.02_01-24-45-+0530`). Nine Spotlight tests cover item
construction, delayed insertion across profile replacement, disable/re-enable,
ownership change after deletion, direct store change, read/delete/index failure
retry, failure ordering, unavailable-store recovery and disabled removal retry.
The Foundation-only backup harness passed 6 tests
(`spotlight-backup-core-tests.log`). Toolchain: macOS 27.0 (26A428), Xcode 27.0
(27A266a), Swift 6.4, arm64, Debug, ad-hoc signed test host. These results prove
ownership and failure behavior against a controlled backend. They do not prove
live Spotlight query results, minimum-OS behavior or packaged acceptance; A39
stays open on those gates, and A38 cache generations plus the restore/export and
download-owner parts of D03 remain unimplemented.


Remediation session of 2 October (continued), toolchain macOS 27.0 (26A428),
Xcode 27.0 (27A266a), Swift 6.4, OpenJDK 17.0.20.1, arm64, Debug, ad-hoc signed
test host. Packages touched: Q07, D04, part of R02 (A34), Q06, N01.

- Client suite after Q07/D04/A34/Q06: 443 tests, 413 passed, 30 explicitly
  skipped, zero failures (`q06-r02-client-all-tests.log`). Skips: 12
  PlayerEngineLiveTests, 9 PlayerStartupBenchmarkTests, 4 PlayerViewModelLiveTests,
  2 PlayerAudioPipelineTests (provisioned native/live fixtures) and 3
  IdentityMigrationTests that the compatibility command executes.
- Frozen-schema/process-kill command with the new additive history fields:
  18 tests, zero skips/failures (`d04-compatibility-tests.log`). The old-schema
  test now also asserts the defaults (`kind == episode`, unknown edition) and a
  single committed history marker.
- Focused runs: Q07 47 passed (`q07-focused-tests.log`); D04 selection 132 total,
  129 passed, 3 fixture skips (`d04-history-tests.log`); N01/Q06 client selection
  17 passed (`n01-bounded-tests.log`). The N01 tests and the relocated Q06
  coordinator tests were added after the 443-test run; a new full client run is
  still owed before these packages are treated as integrated.
- Daemon: 325 tests, 322 passed, 3 intentionally skipped (live repositories),
  60 suites, zero failures/errors; matching jar built
  (`q06-daemon-all-tests.log`). Five tests are new: explicit setting states,
  worker credential clear, typed 503/422 shape, authenticated challenge retry,
  cookie merge/invalid clearance.
- Isolated harnesses: extension transport 26 passed
  (`q06-extension-core.log`); backup core 6 passed (`q06-backup-core.log`).
- The Xcode project was regenerated with XcodeGen for
  `BoundedHTTPResourceLoader.swift` and `BoundedResourceTests.swift`; apart from
  those entries the generated file is identical to the previous one and keeps the
  client group identifier `TEMP_C231C666-C98D-4015-A997-7BEBDF03E303`.
  `scripts/clean.sh` is unchanged (SHA-256 `e571b44d…143b2`).

None of this closes a finding: reduced-runtime/CDS repetition on the new jar,
packaged, minimum-OS, interactive and live-provider gates are all still open.


T01 / D03 / D05 (2 October, same toolchain). Focused client runs: downloads and
persistence 79 passed, zero skips (`t01-download-tests.log`), including a real
frozen-ffmpeg admission test, three finalization interruption boundaries and
deletion outcomes; cache/extension/window selection 60 passed
(`d03-cache-tests.log`); backup/persistence/discovery selection 86 passed
(`d05-backup-tests.log`). Isolated harnesses: extension transport 27 passed
(`d03-extension-core.log`), backup core 6 passed (`d05-backup-core.log`).
Daemon: RepositoryMigrationTest 5 and ExtensionRoutesTest 10 passed
(`d05-daemon-tests.log`); the full daemon suite has not been rerun since
`/repos/register` was added. `DownloadRecord` gained two optional fields
(`originProfileID`, `deletionRequestedAt`) and one appended status value; the
frozen-schema/process-kill compatibility command has not been rerun against
them yet. A full client run after T01/D03/D05/N01 is also still owed.


## Final state of this session (2 October 2026)

Toolchain: macOS 27.0 (26A428), Xcode 27.0, Swift 6.4, Homebrew OpenJDK
17.0.20.1, arm64. Evidence in `/tmp/cloudstream-remediation-baseline/final-*`.

| Check | Result |
| --- | --- |
| Daemon suite + jar + SBOM | 327 tests: 324 passed, 3 skipped (live repositories), 0 failed |
| Client unit suite (Debug) | 484 tests: 451 passed, 33 skipped, 0 failed |
| Frozen-schema / process-kill command | 18 passed, 0 skipped |
| Live libmpv + lifetime + large-library (gated) | 24 run: 23 passed, 1 skipped (engine start failure could not be forced) |
| Isolated Swift harnesses | 27 and 6 passed |
| Script tests | 37 passed |
| `build_dev.sh --launch` (Release) | built, signed ad-hoc, verified, published, real smoke launch passed (IPC 6); native closure **not-portable** |

Skips in the client run that were not executed elsewhere: 9
PlayerStartupBenchmarkTests (need benchmark media).

Also changed late: IPC contract 5 → 6; daemon dependency lock
(`engine/gradle.lockfile`, OkHttp declared as the resolved 5.3.2; a tampered
lock fails the build); external mpv/IINA receive the nested-protocol whitelist
(checked against real mpv 0.41: `file:` HLS segment and local playlist entry
refused, valid HLS plays; VLC/QuickTime cannot be confined); badge counts are
COUNT queries (0.40 s → 0.004 s at 10,000 titles); player window geometry is
clamped to the usable screen; bridge polls are demand-aware.

Large library (Debug, 10,000 titles, 50,000 history rows): replace import
13.3 s and merge 13.0 s on the main thread, export 1.9 s, statistics 1.7 s,
library list 0.38 s, one playback write about 10 ms. Restore still blocks the
main thread for its duration; it was measured, not moved.

Observed and not investigated: in a unit test, closing the player window and
presenting it again within one run-loop turn raised an AppKit
"Update Constraints in Window" exception. The test was split; the sequence
may be reachable in the app.

### Still open

*State at the end of that session; the unimplemented items and the two
"measured, not moved" / "not investigated" notes above were taken up in the
Continuation section below.*

Nothing in the audit is closed. Open on evidence this Mac cannot give:
minimum-OS (macOS 15) execution of anything; Developer ID signing and
notarization; a portable artifact (needs a vendor JDK and a built media
stack); a run of the rewritten CI workflow; live-provider behavior (credential
clear in a real worker, keep-alive, challenged login); every interactive item
in `qa-ui-checklist.md`; SIGKILL-level download finalization; peak image
memory; idle memory against budget; frame pacing and VoiceOver.

Open as unimplemented work: A35 per-audio header transport; D01 progress
capture when the owning store cannot open; D02 catalogue reconciliation after
provider changes; moving large restores off the main thread; a compiled
configurable worker fixture; B02 advisory/licence scan and reproducibility
measurement; E01 entitlement review and removal of obsolete helpers
(`build_slim_ffmpeg.sh`, `build_mpv_metal.sh` were left as they are).


## Continuation (2 October 2026, later session)

The items listed above as unimplemented were taken up. Evidence in
`/tmp/cloudstream-remediation-baseline/final2-*` and the logs named below.
Still nothing is committed, pushed or released, and no finding is closed.

| Check on the final code | Result |
| --- | --- |
| Daemon suite + jar + SBOM | 337 tests: 334 passed, 3 skipped (live repositories), 0 failed |
| Client unit suite (Debug) | 497 tests: 462 passed, 35 skipped, 0 failed |
| Gated live libmpv, lifetime, large-library, image memory | 34 run: 33 passed, 1 skipped (an engine start failure cannot be forced) |
| Frozen-schema / process-kill command | 20 passed, 0 skipped (now includes the download-finalization kill) |
| Isolated Swift harnesses | 27 and 6 passed |
| Script tests | 42 passed (relay playback with real mpv, dependency report) |
| `build_dev.sh --launch` (Release) | built, ad-hoc signed, verified, published (`20261002T050033Z-3389a7b0-70977`), real smoke launch passed; native closure still **not-portable** (Homebrew JDK) |

Of the 35 client skips, 9 (PlayerStartupBenchmarkTests) were executed
nowhere; the others ran in the gated runs or the process-kill command.

What changed, by item:

- **A35** transport relay implemented and proven end to end (row above).
- **D01** progress for an unavailable owner is captured and adopted
  (`PersistenceBoundaryTests`, 2 new tests).
- **D02** reconciliation on provider changes and reassignment of titles whose
  installation is gone (`IdentityMigrationTests`, `ProviderGenerationTests`).
- **Restore off the main thread** (`importSnapshotInBackground`): measured
  first in a Release build (11.9 s replace, 12.1 s merge at 10,000 titles and
  50,000 history rows — not a Debug artefact), then moved; two tests cover
  fencing, retained playback positions and rollback; Settings shows
  "Restoring…".
- **Q06 worker fixture** `credential.cs3` (sources in
  `engine/src/test/fixtures/extension`; only this archive was built, the
  committed ones are byte-identical) and the start-time settings defect it
  exposed.
- **T01** SIGKILL-level finalization: three boundaries, separate processes.
- **N01** peak memory measured, three bounds added (A32 row).
- **AppKit constraint fault** (previously "observed and not investigated"):
  reproduced by a close/present stress test. Cause: the video view attached
  itself to an observed property (`PlayerViewModel.videoView`) from inside
  SwiftUI's update pass, which invalidated the layout that was running. The
  handle is no longer observed; the stress test and the player suites ran
  three times without the fault. Reachable in the app whenever the video view
  re-attached during a layout pass.
- **B02**: advisory lookup against the packed versions (OSV) found advisories
  in nine components. Netty moved 4.2.13 → 4.2.17 and Jackson core/databind
  2.13.1 → 2.13.5 inside their lines (daemon-local; lock updated; full suite
  passed). Ten Jackson advisories need a newer minor line and are an open
  product decision; four entries are not applicable. Licence report: two
  components need a person (`fuzzywuzzy` declares GPL 2 without "or later";
  the JitPack `nanojson` build declares no licence). Two clean builds of the
  jar are byte-identical; an incremental one is not, so distribution builds
  compile the daemon from clean. Details: `Dependency-Review.md`.
- **E01**: `build_slim_ffmpeg.sh` and `build_mpv_metal.sh` removed after a
  caller census (nothing consumed `ffmpeg-slim`; the player has only ever
  requested the `sw` render context; both wrote into the staged resources
  outside the manifest). Entitlements reviewed and documented in
  `Security.md`; left unchanged, as the plan requires, with one experiment
  recorded (the app launched and started its engine without its two JIT
  entitlements).

### Still open after this session

Needs machines, credentials or people: macOS 15 execution of anything;
Developer ID signing and notarization; a portable artifact (vendor JDK and a
built media stack); a first run of the rewritten CI workflow, including the
new advisory and licence steps; live providers (a split-header source through
the relay, an account credential, keep-alive, a challenged login); every item
in `qa-ui-checklist.md`; idle memory against the 160 MB budget; frame pacing;
VoiceOver; a real unplugged external disk.

Needs a decision: the Jackson line (ten open advisories); the two licences
above; removing the app's JIT and inert sandbox entitlements.

Known limits, stated where they live: progress captured for an unavailable
store is lost if the app quits first; the relay serves progressive media only
and ends with the engine; a store upgraded with zero history rows runs the
legacy backfill once more (A23); PlayerStartupBenchmarkTests have no media.

