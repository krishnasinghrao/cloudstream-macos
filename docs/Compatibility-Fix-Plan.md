# Compatibility and playback fix plan

Written 8 October 2026 from two investigations: manual testing notes in
`archive/plans/To-dos/to-dos.md`, and an analysis of why many community extensions fail
on Mac, compared with how CloudStream for Android
(`recloudstream/cloudstream`, commit `4e2516d`) loads and runs them.
Feature ideas from the to-do list are not part of this plan; they need their
own brainstorm. Moves to `archive/plans/` when done.

## Status (8 October 2026)

Implemented on branch `compat-fix-plan` and merged into `main` (commit `c7c9fb0`). Verified by:
`make build` (native closure, signatures and the packaged sandboxed-worker
self-test pass), 384 engine/library tests (plus the library ABI check) and 535 Swift unit tests (43 gated live tests skipped), 0 failures.

| Item | State |
| --- | --- |
| E1–E3, L1–L5, A1–A3, A6, X2, X3, N1, N2, N4, W1, W2, U1–U3 | Done, with tests |
| C0 | Tool ready: `python3 scripts/catalog_compat_run.py --wiki` (runs community extensions in the app's sandboxed workers; you run it) |
| C1, W3, N3 | Need the C0 numbers first |
| U4 | Needs an Instruments trace taken while you use the app |
| A5, X1 | Deferred, see each item |

## Evidence this plan is built on

- The wiki's [list of extensions](https://cloudstream.miraheze.org/wiki/List_of_extensions):
  26 plugin lists, 25 reachable (cartoonyrepo's list is a 404), 463 extensions.
- The source code of 23 of those repositories (303 extension modules) was read,
  not run. Counts below are from source, so they are estimates; phase 0 replaces
  them with measured numbers.
- This Mac's engine state and log (`~/.cloudstream-macos`): 14 installed
  extensions, worker crashes, an uncaught `RejectedMediaResourceException`.
- The shipped `daemon.jar`, tested directly for `org.json` behaviour.

What is **not** the problem: the vendored `library/` matches upstream's public
JVM API, its dependency versions match upstream's, and the existing app
stand-ins (`CommonActivity`, `DataStore`, `PluginManager`) match upstream's
signatures.

## How each user-visible error maps to causes

| What you saw | Where it comes from | Real causes (items below) |
| --- | --- | --- |
| "Runtime API issue" / "not compatible with this version of CloudStream" | Every `LinkageError` → `runtime_incompatibility` (`OperationFailure.kt`) | Missing Android/app classes (A2), missing members (A3), dex2jar output the JVM rejects (A4) |
| "Provider is not installed" when it is | `ProviderExecutor.unavailableReason` | Duplicate provider names (X2), extensions that look up other extensions' providers (X1), failed or quarantined starts reported as "not installed" (E2) |
| "Android backend not present" | Static compatibility warning, `ExtensionsView.swift` | Mostly settings-screen widgets that never run on Mac (E3); a few real gaps (A2) |
| "Network connection error" | Any `IOException` → `network_failure` | macOS system proxy ignored (N1), `raw.githubusercontent.com` blocked with no mirror (N2), anti-bot TLS fingerprint (N3) |
| Streams fail or no links appear | Link validation and the player | One bad link aborts the extension's whole link list (L1, L2, L3), DRM keys dropped (L4), no DASH support in ffmpeg and picky HLS (L5) |

---

## Phase 0 — Measure before fixing

Every later item is judged against this baseline, not against source estimates.

- [ ] **C0 — Catalog-wide compatibility run.** Tool done:
  `scripts/catalog_compat_run.py` (`--wiki`, or repository URLs) — not yet run.
  It, in a throwaway engine home
  (never `~/.cloudstream-macos`), adds each repository, installs every
  extension with status 1–3, and records per extension: install result,
  worker init result, one search, one details call and one links call, each with
  failure `code`, `stage` and `redactedCause`. Output `catalog-report.json` plus
  a summary grouped by failure code and by missing symbol.
  - Runs sandboxed, as the app does. Extension code runs only inside workers.
  - Search uses a fixed query per language group; "no results" is recorded
    separately from failures.
  - Done when: one full run over the 25 lists completes and its summary is saved
    as the baseline (`catalog-baseline-<date>.md`).
- [ ] **C1 — Re-run after each phase** and record the delta in that phase's
  section here. A phase is not done if the run shows a regression in extensions
  that previously worked.

## Phase 1 — Honest errors (makes the rest diagnosable)

- [x] **E1 — Split `runtime_incompatibility`.** Classify by the `LinkageError`
  subtype found in the cause chain:
  - `NoClassDefFoundError` → `missing_host_class` ("This extension needs part of
    Android or the CloudStream app that the Mac version does not have: `<Class>`.")
  - `NoSuchMethodError` / `NoSuchFieldError` → `missing_host_member`
  - `VerifyError` / `ClassFormatError` → `translation_rejected` ("This extension's
    code could not be converted to run on Mac.")
  - `IncompatibleClassChangeError` (other) → `host_abi_mismatch`
  - Keep `redactedCause` (symbol only). Update `docs/ipc-api.md`; the client
    must show unknown codes with the server's message, so older clients keep working.
  - Tests: one case per subtype in `engine/src/test` (`OperationFailures.capture`).
- [x] **E2 — Say why a provider is unavailable.** `unavailableReason` returns a
  reason code and text: `not_installed`, `disabled`, `failed_to_start` (with the
  installation's last error), `quarantined`, `ambiguous_name` (with the
  candidates). The client shows these on Details/Play and links the extension
  in Settings ▸ Extensions.
- [x] **E3 — Calm, accurate compatibility warnings.** Show the "may not work"
  line only for missing types used by start-up or provider code (roles
  `startup`/`provider`). Show `other` gaps as one quiet line: "Settings screens
  aren't available on Mac." Count unsupported features once per extension.

## Phase 2 — Link pipeline (biggest effect on playback)

- [x] **L1 — Never throw into the extension.** In `ProviderExecutor.loadLinksStreaming`
  (in-process and in workers), validate each link inside a `try`; drop an
  invalid link, record `rejected_link` with the field name, and keep the
  extension running. Same for subtitles. Wrap the callbacks so nothing escapes
  to a dispatcher thread. Test: a fixture provider emits magnet → valid → bad
  header → valid, and the response has 2 links and 2 rejections.
- [x] **L2 — Normalise headers instead of rejecting.** Remove hop-by-hop and
  transport headers (`Host`, `Connection`, `Content-Length`, `Transfer-Encoding`,
  `TE`, `Upgrade`, `Trailer`, `Proxy-*`) from link and audio headers, case
  insensitively, before validation. Keep rejecting control characters and
  malformed names. Keep `MediaResourcePolicy` as the single place for this rule.
- [x] **L3 — Torrent and magnet links.** Classify `MAGNET`/`TORRENT` links as
  unsupported sources: not offered to the player, counted per link, and shown
  in the source list as "Torrent sources aren't supported on Mac" instead of
  making the link list fail. Decided: no torrent playback and no hand-off to
  other apps.
- [x] **L4 — DRM links.** Carry `DrmExtractorLink` fields (`kid`, `key`,
  `uuid`/`kty`, `licenseUrl`) through `StreamLinkDto` (IPC version bump).
  - ClearKey with an inline key: pass the key to ffmpeg/mpv. First confirm the
    option the pinned FFmpeg 9 exposes (`ffmpeg -h demuxer=dash`,
    `ffmpeg -h demuxer=mov`: `cenc_decryption_key` / `decryption_key`) and
    test with a public ClearKey sample.
  - Widevine or a licence server: mark the link "DRM-protected (not supported
    on Mac)" and skip it during mirror failover.
- [x] **L5 — DASH and HLS in the player and downloader.**
  - Add libxml2 (pinned source and checksum) to `scripts/build_media_stack.sh`,
    enable it in the FFmpeg configure line, rebuild the media stack, and make
    the build fail if `ffmpeg -demuxers` lacks `dash`.
  - In `MetalVideoView.remoteProtocolOptions` (and the downloader's equivalent),
    add HLS demuxer options `allowed_extensions=ALL` and `extension_picky=0`.
    The protocol whitelist is unchanged, so this does not widen what can be
    opened.
  - Check `Remaining-Work` §9: DASH manifests through the relay are already
    rewritten; verify a relayed DASH stream end to end.
  - Done when: one DASH and one disguised-segment HLS stream from real
    extensions reach their first frame (gated player test).
- **L6 — Local-network streams (BDIX): dropped.** Not used, so `MediaRelay`
  keeps refusing private addresses (SEC-02 SSRF defence) with no exception.

## Phase 3 — Android runtime parity

- [x] **A1 — Android-behaving `org.json`.** The engine ships JSON-java
  (`org.json:json:20251224`), whose behaviour differs from Android's built-in
  `org.json`. Measured on the shipped jar: `getString` on a number or boolean
  throws (Android coerces), `optString` on JSON null returns `""` (Android:
  `"null"`), and key order is lost (Android keeps insertion order). About 79
  extensions use `org.json`.
  - Replace it with AOSP libcore's `org.json` (Apache 2.0; 6 classes:
    `JSON`, `JSONArray`, `JSONException`, `JSONObject`, `JSONStringer`,
    `JSONTokener`) as host source, and exclude `org.json:json` everywhere.
    Check nothing in the engine uses JSON-java-only classes (`XML`, `CDL`,
    `JSONPointer`).
  - Bump `RuntimeProfile.VERSION`; record the change in `Dependency-Review.md`.
  - Tests: coercion, null handling, insertion order, `NaN` rejection, and
    `JSONObject(Map)` with nested values, each against Android's documented behaviour.
- [x] **A2 — Add the missing stand-ins that real provider code reaches.**
  Ordered by evidence. Each one either does the real thing on Mac or throws
  `UnsupportedExtensionException` with a named feature; never fake data.
  - `androidx.preference.PreferenceManager` and `android.preference.PreferenceManager`:
    `getDefaultSharedPreferences(context)` returns that extension's
    `FileSharedPreferences` named `<package>_preferences`, which the
    preference scanner and settings sheet already understand. Used in provider
    code by Cinemana, Replaymatch and YouTube (Abodabodd).
  - `android.content.Intent`: plain data holder; `Context.startActivity` reports
    "Opening other apps isn't available on Mac" through the unsupported-feature
    sink.
  - `android.widget.Toast`: `makeText(...).show()` logs like `CommonActivity.showToast`.
  - `com.lagradost.cloudstream3.utils.AppContextUtils`: the non-UI subset
    (`html`, `isNetworkAvailable`, `isUsingMobileData` → false,
    `getApiSettings`/`getApiProviderLangSettings` from preferences); UI members
    throw the named unsupported error.
  - `syncproviders.providers.OpenSubtitlesApi` companion `headers`/`userAgent`
    constants.
  - Bump the stub ABI part of `PluginBridge.TRANSLATION_PROFILE` and
    `RuntimeProfile.VERSION` together.
  - After C0, add stand-ins for anything that shows up in the measured
    `missing_host_class` list for ≥ 3 extensions, using the same rule.
- [x] **A3 — Check members, not just classes.** Extend `CompatibilityAssessment`
  to resolve every `INVOKE*`/`GET*`/`PUT*` against host classes (walking
  supertypes, using the same parent-first view as `HostAbiAdapter`) and report
  missing members with role. This catches `NoSuchMethodError` at install time
  and feeds E3 and C0.
- [ ] **A4 — Translation failures.** From C0, collect every
  `translation_rejected` class. For each pattern: try the current dex2jar fork
  (and options) on a copy; if a newer dex2jar fixes it, upgrade and bump the
  translation profile; otherwise record it as a known limit. Report oversized
  methods (`TranslationGuard`) in the extension row by method name.
- [ ] **A5 — Prefer ready-made JVM builds. Deferred.** The spike found the
  jars carry no `manifest.json` (the entry class is the one annotated
  `@CloudstreamPlugin`), and that a receipt's proof requires the catalog entry
  to equal the stored metadata exactly: adding `jarUrl`/`jarHash` to it would
  make existing receipts of official-repository extensions fail verification.
  It needs a new proof format with a receipt migration, for 16 extensions that
  already install from their `.cs3`. Revisit with the C0 numbers. 16 catalog entries (5 from the
  official repository) publish a `jarUrl` alongside the `.cs3`.
  - Spike first: confirm the jar layout (manifest location, entry class, Kotlin
    target) produced by the CloudStream gradle plugin, with one official jar.
  - Then: when an entry has both `jarUrl` and a valid `jarHash`, install the
    jar and skip dex2jar. Without `jarHash`, keep the `.cs3` (SEC-07: nothing
    loads without a verified hash). Both artifacts stay bound to the same
    catalog entry and update path.
- [x] **A6 — Allow "beta" extensions.** Treat status 3 like upstream: installable,
  shown with a "Beta" badge. Status 0 stays blocked. Affects 14 extensions in
  the current lists. Update `RepositoryService` (count and `blocked`) and the
  catalog UI.

## Phase 4 — Cross-extension behaviour

- [ ] **X1 — Let an extension see other extensions' providers. Deferred.**
  The callers use the returned `SearchResponse`/`LoadResponse` objects
  directly, so a proxy must rebuild CloudStream's whole data model from IPC
  values across processes — a large, lossy layer for 6–7 extensions whose
  behaviour cannot be checked here. Original design kept below. On Android all
  providers share one process; here each extension's worker sees only its own,
  which breaks `CatalogoGeneral`, `CatalogoHboMax`, `CatalogoInfantil`,
  `CatalogoNetflix`, `SectionOrganizer` and `StreamCenter`.
  - Publish read-only proxies of the other installations' enabled providers
    into each worker's `APIHolder.allProviders`/`apis`, whose calls (search,
    `load`, `loadLinks`, main page) route through the engine like
    `ExtractorRouter` does for extractors (RT-12): same visited-set, hop limit
    and deadline, so routes cannot loop.
  - Write ADR-0020 (provider routing across workers) before implementing.
- [x] **X2 — Duplicate provider names.** Two installed extensions both register
  "MovieBox" on this Mac.
  - On install, warn when a new provider's name matches an installed one, and
    say which repository each comes from.
  - Library records that carry only a name (Android backup imports) and match
    several providers go through the existing "Choose Provider…" flow once, and
    the choice is stored as a provider ID.
- [x] **X3 — Say up front what can never work.** At install, detect use of
  `dalvik.system.*ClassLoader` (loading Android APKs, e.g. AniyomiCompat) and
  of `plugins.RepositoryManager` mutation (Mega's repository installer); show
  "This extension can't work on Mac: <reason>" instead of a runtime failure.

## Phase 5 — Network parity

- [x] **N1 — Use the Mac's proxy settings.** Start the engine and workers with
  `-Djava.net.useSystemProxies=true` so OkHttp's default `ProxySelector` reads
  macOS proxy settings (workers already may reach `configd`). Decide whether
  `RepositoryTransport` (currently `Proxy.NO_PROXY`) should follow the system
  proxy too; keep its address checks on the final target. PAC files are not
  supported by the JDK: detect a PAC configuration and say so in Diagnostics.
  Test with a local HTTP proxy.
- [x] **N2 — jsDelivr mirror for GitHub-hosted repositories.** Like upstream's
  `convertRawGitUrl`: a setting "Download repositories through jsDelivr", off
  by default. When on, GitHub-hosted repository files and extensions are
  fetched through `cdn.jsdelivr.net/gh/<user>/<repo>@<ref>/<path>`. Decided:
  no automatic fallback; when `raw.githubusercontent.com` fails with a DNS or
  connect error, the error message points to this setting. Hashes and
  signatures are verified exactly as before, so the mirror cannot change what
  is installed.
- [ ] **N3 — TLS fingerprint spike (go/no-go).** The solver already backs off
  sites that reject a fresh clearance (Remaining-Work §8). Measure the
  challenge and rejection rate for 10 Cloudflare-protected providers with the
  JDK stack, then with Conscrypt (if an arm64 macOS build is available) or
  another fingerprint-matching client. Adopt only if rejections fall clearly;
  record the result either way.
- [x] **N4 — Specific network errors.** Split `network_failure` into
  `dns_failure`, `tls_failure`, `connect_timeout`, `connection_refused` and
  `connection_reset`, each with a hint (change DNS in Settings, try a VPN,
  the site may be down).

## Phase 6 — Worker resources

- [x] **W1 — Name out-of-memory exits.** Workers run with
  `-XX:+ExitOnOutOfMemoryError` (exit code 3). Record such exits as
  `worker_out_of_memory` in the log and the failure, instead of
  `worker_terminated`.
- [x] **W2 — More heap only where needed.** After an out-of-memory exit,
  restart that extension's worker with 512 MB (once; recorded on the receipt).
  Idle cost does not change (`-Xms16m`, heap returned when idle). Check it
  against the CineStream/Movies4u crashes seen on 8 October.
- [ ] **W3 — First-start timeouts.** From C0, list extensions whose first
  worker init exceeds the restore timeout (20 s) because of translation; if
  any do, keep translation off the timed path (translate once at install, then
  load from the cached jar).

## Phase 7 — Playback and UI bugs from manual testing

- [x] **P1 — DASH/HLS streams don’t play.** Covered by L5.
- [x] **U1 — Header wrong in full screen.** Title pages run their hero
  artwork under a transparent toolbar, which in full screen blended the
  toolbar into the artwork. Fix: in full screen the toolbar stays visible
  (`windowToolbarFullScreenVisibility(.visible)`, like Finder) and title
  pages give it a solid background and start the hero below it.
  `WindowSessionAnchor` keeps `WindowSession.isFullScreen` current from the
  window's full-screen notifications. Earlier attempts that hid the toolbar or
  drew a custom header in the content were removed.
- [x] **U2 — Hero placeholder placed at the top.** In `PosterImage.swift`, the
  placeholder icon shares the image's `alignment` (`.top` for the hero).
  Always centre the placeholder; for the hero, show a gradient instead of an
  empty 580 pt box.
- [x] **U3 — Duplicate titles in the library.** The same show from two
  providers is two items today (identity is provider + URL). Decision: merge
  them into one entry with several sources.
  - Model: a library title owns one or more sources (provider ID + URL), one of
    them the preferred source. Watch status, favourite, rating, note and
    per-episode progress belong to the title, not the source. A SwiftData
    migration folds existing duplicates together.
  - Matching: merge automatically only on a strong match (same IMDb/TMDb ID
    when both sources have one; otherwise same normalised title, same year and
    same type). Weaker matches are offered, never applied silently. The user
    can split a merged title again.
  - Conflicts when merging: keep the furthest watch progress per episode, the
    "most active" status (Watching over Plan to Watch, Completed over both),
    favourite if either is, and both notes.
  - Details page: a source switcher lists the merged sources; Play uses the
    preferred source and falls back to the others like mirror failover.
  - Backups: export keeps every source; Android backup import merges by the
    same rules. Write ADR-0021 (library title identity) before implementing.
- [ ] **U4 — Heat and battery.** (Needs you: an Instruments trace.) Profile first (Instruments: Time Profiler and
  Energy Log, 60 s of playback and 60 s of browsing), compare against the
  budgets in `Rules.md` §3, then fix what the trace shows. Candidates:
  confirm the GPU renderer is active (no `GPU renderer unavailable` in logs),
  the always-running pulse animation on Home (`HomeView.swift`), glass effects
  over playing video, and the number of running extension workers.

---

## Order and milestones

| Milestone | Items | Done when |
| --- | --- | --- |
| M0 Baseline | C0 | Baseline report saved |
| M1 Links play | E1, E2, L1, L2, L3, L5, U2 | C1 shows no extension losing all links to one rejected link; DASH and HLS gated tests pass |
| M2 Runtime parity | A1, A2, A6, E3, W1 | C1: fewer `missing_host_class` and JSON failures than baseline, no regressions |
| M3 Network | N1, N2, N4 | Repository install works through a proxy and with `raw.githubusercontent.com` blocked |
| M4 Deeper parity | A3, A4, A5, L4, W2, W3, X2, X3 | C1 rerun recorded |
| M5 Cross-extension | X1 (with ADR-0020) | A Catalogo extension returns results from another extension |
| M6 UI | U1, U3, U4, N3 | Per item |

## Decisions

Answered 8 October 2026:

1. **Library duplicates (U3):** merge copies of a title into one library
   entry with several sources.
2. **Torrents (L3):** stop at a clear "not supported" message; no hand-off to
   other apps.
3. **Local-network sources (L6):** skipped; no BDIX extensions are used.
4. **jsDelivr (N2):** only when switched on; no automatic fallback.

## Verification for every item

- Unit tests in `engine/src/test` or `client/Tests` for the behaviour changed.
- The standing rule in `Remaining-Work.md`: build the app, use the built app,
  search, open a title and load links on 2–3 extensions, check the log for
  `worker.killed`, `worker.crashed` or `daemon.recovery`.
- For phases 1–6, a C1 catalog run, with the delta recorded here.
- Commits disclose AI assistance (`Rules.md` §1).
