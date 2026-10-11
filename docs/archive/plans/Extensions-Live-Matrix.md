# Extension live compatibility matrix

Evidence from runs against real repositories and extensions. It is dated because
remote sites change; a row is a record of one run, not a guarantee. A stage that
was not run says **not run** — a pass in one stage never fills another.

Environment for every row below: 1 October 2026, macOS 27.0 (arm64), engine from
branch `macos/extensions-remediation`, runtime profile `cloudstream-macos-runtime-3`,
IPC contract 5. "Engine" means the real daemon code paths (repository sync,
verification, translation, load, provider call) driven by a gated live test or a
live engine session; "packaged" means the built `CloudStream.app` runtime.

| Repository (how added) | Extension | Provenance mode | Catalog sync | Install + load | Search | Details | Links | Playback (first frame) | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Megix `SaurabhKaperwan/CSX` (raw GitHub URL) | Moviesmod | publisher digest | pass | pass (packaged-form jar, sandboxed worker) | pass | pass | pass (9); re-run on the shipped runtime: 3 links for “Inception” | **stream opens**: `ffprobe` read 2 of 3 links (HEVC 1920×800 and 1280×536); the third mirror was dead | Previously `NoSuchMethodError` (`Result.constructor-impl`). Player UI not driven |
| 〃 | VegaMovies | publisher digest | pass | pass | pass | pass | pass (20) | not run | |
| 〃 | BollyFlix | publisher digest | pass | pass | pass | pass | pass (19); re-run on the shipped runtime: 14 links for “Inception” | **stream opens**: `ffprobe` read 4 of 6 probed links (H.264/HEVC 1920×800); two mirrors were dead | Player UI not driven |
| 〃 | CineStream | publisher digest | pass | pass | pass | pass | pass (108) | not run | Previously `NoClassDefFoundError` (app sync types) |
| 〃 | CineTmdb (in CineStream) | publisher digest | pass | pass | pass | pass | pass (120) | not run | |
| 〃 | MoviesDrive | publisher digest | pass | pass | pass | pass | no links for the tested title (`provider_no_data`) | not run | Typed failure, not a host fault |
| Hexated (`hexated` shortcode → cutt.ly → Codeberg) | SoraStream | publisher digest | pass | pass (engine, in-process) | not run | not run | not run | not run | Previously failed: shortcode fetched Codeberg's raw URL (403). Gated test `live sync Hexated repository via Codeberg bridge` |
| cloudstream-apk.com repository list (HTML page) | — (aggregate of ~51 linked repositories) | community | pass (~10 s) | not run | not run | not run | not run | not run | Previously rejected by a 32-repository cap. Gated test `live sync from cloudstream-apk website catalog aggregates repositories` |
| phisher98 `cloudstream-extensions-phisher` (raw GitHub URL) | StreamPlay **v682** (morning) | local observation (no publisher digest) | pass | pass — providers StreamPlay, StreamPlay-Anime (engine, in-process) | pass (13 results for “Inception”) | not run | not run | not run | Ships Android resources; `invokeMovieBox` not translated (too large) and reported on the row. Gated test `live install StreamPlay with Android resources and an oversized method` |
| 〃 | StreamPlay **v683** (published the same day) | publisher digest | pass | **failed** on the build of that morning: v683 creates an `android.webkit.WebView` and uses `Dispatchers.Main` in `load()`; **pass** after the follow-up (inert WebView, `Dispatchers.Main` on the main looper) — shipped-form runtime, sandboxed worker | pass (13) | pass | pass: 136 links, 200 subtitles, outcome `partial` (one source timed out) | **stream opens**: `ffprobe` read 1 of 6 probed links (HEVC 3840×1598); the other five did not open (not investigated: dead mirrors or links needing more than the returned headers) | Row reports: `invokeMovieBox` (too large to translate), Android settings screens, sources that run JavaScript in an Android WebView |
| 〃 | AnimePahe, Animexin, Aniworld (+ Serienstream), Anizone, Cinemacity, DoraBash, Jellyfin, Kartoons, MovieBoxProvider, ShowBox, StremioAddon, StremioX (+ StremioC), SuperStream, TorraStream (+ TorraStream-Anime), Ultima, XDMovies, Zinkmovies | local observation | pass | pass — every provider registered (17 extensions) | not run | not run | not run | not run | All declare `requiresResources`; previously rejected at install. Settings screens are Android UI (row reports it); settings are editable through Extension Settings (RT-15) |
| Official/built-in | YouTube (NewPipe) | built-in | n/a | pass (installed in the user's engine, no missing host types) | not run this session | not run | not run | not run | |

## What a same-day update taught

StreamPlay went from v682 to v683 during this run and stopped loading: the new version needed two more Android facilities at startup. An extension that works today can need new host APIs tomorrow, so (1) every row here is dated and versioned, (2) the engine now logs and reports the exact missing class or member when an extension fails to start (`worker.init_failed`, and “missing: …” in the install error), and (3) the packaging gate checks the facilities this run found missing on the shipped runtime.

## Interactive use of the packaged app (2 October 2026)

Reported by the user from hands-on use, not from an automated run. Build: published generation `20261002T060608Z-e5b95124` (commit `e5b95124`, development signing, native closure not-portable), macOS 27.0 (arm64).

| Repository (how added) | Installed extensions (version, state shown in Settings) |
| --- | --- |
| Cloudstream providers repository `recloudstream/extensions` (raw GitHub URL; 5 extensions, 1 installed) | YoutubeProvider v1 — Ready |
| Phisher Repo `phisher98/cloudstream-extensions-phisher` (raw GitHub URL; 84 extensions, 4 installed) | Movies4u v17 — Ready; SuperStream v38 — Ready; UHDmoviesProvider v41 — Ready; MovieBoxProvider v36 — enabled, no “Ready” badge shown, reported working smoothly by the user |

Both repositories synced and show “Installs allowed”. The assignment of extensions to repositories was confirmed by the user.

- **Playback in the player UI**: the user played titles resolved from these extensions and reported smooth playback.
- **Downloads**: the user downloaded titles and reported them fast and working.

Limits of this record: it is not per extension — which of the five extensions supplied the titles that were played and downloaded was not recorded, nor were titles, resolutions, link counts or failures. MovieBoxProvider works for the user although Settings shows no “Ready” badge for it; why the badge is absent was not investigated. No row in the table above is upgraded by this section.

## Live playback through the app's player (5 October 2026)

Build: published development generation of commit `c876c8d4` (portable Temurin runtime, class archive loaded, GPU video path), macOS 27.0 (arm64). The app's own engine ran on a **copy** of this Mac's engine data (`scripts/live_extension_run.py`): installed extensions restored in sandboxed workers, then search → details → links for every provider. The first three links of each provider were then played by the app's player code — the same load plan, header handling and `MetalVideoView` (GPU renderer, VideoToolbox) — in the gated test `testLiveExtensionStreamsReachTheirFirstFrame` (`CS_MPV_ENGINE_TESTS=1 CS_LIVE_PLAYBACK_TESTS=1`). “Reached frames” means playback position past 1 s with more than 10 frames presented.

| Provider | Search “Inception” | Details | Links | Player (first 3 links) | Streams that played |
| --- | --- | --- | --- | --- | --- |
| Castle TV (Use VLC) | pass | pass | 7 | 3 of 3 reached frames (first second after 2.4 s, 2.0 s, 2.2 s) | 1280×536 · H.264 · BT.709 / BT.1886 · SDR; 1280×720 · H.264 · BT.709 / BT.1886 · SDR |
| YouTube | pass | pass | 10 | 3 of 3 reached frames (first second after 1.6 s, 1.4 s, 1.4 s) | 1280×720 · VP9 · BT.709 / BT.1886 · SDR; 1280×720 · H.264 · BT.709 / BT.1886 · SDR; 854×480 · H.264 · BT.709 / BT.1886 · SDR |
| CineSimkl | pass | pass | 66 | 1 of 3 reached frames (first second after 8.1 s) | 3840×1598 · H.265 · BT.709 / BT.1886 · SDR |
| Movies4u | pass | pass | 6 | 3 of 3 reached frames (first second after 7.5 s, 4.1 s, 3.5 s) | 1920×800 · H.264 · BT.709 / BT.1886 · SDR; 3840×1600 · H.265 · BT.2020 / PQ · HDR10 |
| CineTmdb | pass | pass | 66 | 1 of 3 reached frames (first second after 6.7 s) | 3840×1598 · H.265 · BT.709 / BT.1886 · SDR |
| CineStream | pass | pass | 61 | 1 of 3 reached frames (first second after 6.1 s) | 3840×1598 · H.265 · BT.709 / BT.1886 · SDR |
| MovieBox | pass | pass | 11 | 2 of 3 reached frames (first second after 3.5 s, 3.5 s) | 1920×1080 · H.264 · BT.709 / BT.1886 · SDR; 1920×800 · H.264 · BT.709 / BT.1886 · SDR |
| UHDmovies | pass | pass | 5 | 3 of 3 reached frames (first second after 3.3 s, 3.1 s, 2.2 s) | 1920×800 · H.265 · BT.709 / BT.1886 · SDR; 3840×1600 · H.265 · BT.2020 / PQ · HDR10 |

Every provider that returned links has a stream that plays. The links that did not open are mirrors that did not answer (the app fails over to the next one automatically; the test plays each link alone). The 4K HDR10 streams of Movies4u and UHDmovies are reported as BT.2020/PQ and rendered through the GPU tone-mapping path, which is the pale-4K case of Remaining-Work section 5. The player window and HUD were not driven (no desktop control in this run); the player engine, load plan and renderer are the app's own.

## Anti-bot challenges in the running app (5 October 2026)

The isolated app (`scripts/live_extension_run.py --app`, copy of the engine data) searched and resolved links for every provider while the app's hidden WebKit solver answered the challenges the engine parked. Before challenges carried the requesting client's User-Agent, none cleared (clearance is bound to the agent that earned it); after, 119 of 123 parked challenges cleared. One host (primesrc.me) kept challenging even with a fresh clearance, which points at a TLS-fingerprint check the JVM's network stack cannot pass; the engine now treats a fresh clearance that is still challenged as rejected and stops solving for that site for 10 minutes (`ChallengePathTest`).

Android CloudStream solves only for extensions that add `CloudflareKiller`, invisibly, and drops the source otherwise. The Mac engine solves every provider's challenges but, like Android, never shows a window: a challenge that wants a person times out after 30 s and that source is missing.

## Not yet covered

- **Playback of a stream resolved from a live extension in the player UI**: per-extension playback through the app's player engine is recorded above (5 October 2026); the player window itself was driven only by the user (2 October 2026). Streams from three live extensions were opened with `ffprobe` using the headers the engine returned (see the rows above), which proves the links and headers are usable, not that the app's player was driven. The player itself is verified with synthetic fixtures through the real mpv engine (run 1 October 2026, `CS_MPV_ENGINE_TESTS=1`): MP4 and segmented HLS with a caption — frames advance at native resolution, seek, resume point, end of file, replay, and required headers on every segment request. That proves the player, not any provider's links.
- **A JavaScript-dependent extractor against a real host** (RT-11): the path is verified end to end with deterministic fixtures (real worker; real WebKit on a loopback server), not yet against a live player page.
- **A challenge requiring user interaction**: deliberately not solved (as on Android); the source is skipped.
- **Restart with these installations in the packaged app**: covered by deterministic tests (lazy restore, hashless receipts), not by a live packaged run.

## How to reproduce the gated rows

```bash
CS_LIVE_REPO_TESTS=1 ./gradlew :engine:test --tests 'com.lagradost.macos.RepositoryServiceTest'
```

These tests use the network and third-party sites; they are skipped in ordinary and CI runs so deterministic regressions are never masked by a remote outage.
