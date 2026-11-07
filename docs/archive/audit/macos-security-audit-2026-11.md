# Security audit: CloudStream for macOS (November 2026)

Scope: the working tree on `main` (after `a23a928`, including the uncommitted
work in progress): engine (Kotlin control plane, worker sandbox, egress proxy,
relay, repository trust), client (Swift app, WebKit bridges, player, downloads,
backup, lock, keychain, logging), build scripts and CI. This audit follows the
October 2026 audit ([macos-security-audit-2026-10.md](macos-security-audit-2026-10.md));
its remediations were re-checked rather than re-reported.

**Result: 1 High, 3 Low, all fixed in the same change.** No critical issue was
found. The informational items at the end were reviewed and left as they are,
with reasons.

| # | Severity | Finding | Status |
|---|---|---|---|
| H1 | **High** | Extension-driven WebKit content escapes the worker network sandbox: an extension can read this Mac's loopback services, the LAN and cloud metadata through the app's WebKit | Fixed |
| L1 | Low | The engine's loopback listener answered any `Host`, so a DNS-rebinding web page could use it | Fixed |
| L2 | Low | The engine's connectivity test and the app's artwork/subtitle loader sent requests to local addresses an extension declared | Fixed |
| L3 | Low | The signing/release CI job ran third-party actions from mutable tags | Fixed |

## Method

- Read every trust boundary: IPC auth and handshake (`Main.kt`, `EngineTransport.swift`), worker launcher and sandbox profile, egress proxy, media relay, repository transport and policy, the worker→engine request bridges (solve, WebViewResolver, WebViews, routed extraction), every client consumer of extension-supplied data (WebKit services, player, external players, ffmpeg downloads, artwork, deep links, backup import), keychain, app lock, logs and diagnostics, entitlements, `Info.plist`, packaging and CI.
- Grepped for dangerous APIs (process execution, JavaScript evaluation, HTML loading, deserialization, SQL, randomness, logging of secrets) and followed each hit.
- Measured WebKit's behaviour with throwaway programs (macOS 27.2, Xcode 27.2): which destinations bypass a configured proxy, whether a SOCKS5 proxy receives host names, whether `allowFailover = false` prevents direct connections, and whether a content rule list blocks each loopback spelling.
- Counted secret-shaped strings in the live logs (`~/Library/Logs/CloudStreamMac`) without printing them: none.

## H1 — Extension WebKit content escapes the network sandbox (High)

**Where (before the fix):**
- `client/Sources/Services/WebViewSessionService.swift` — `load` opened any http(s) URL, or HTML with any http(s) base URL; `eval` returned the page's JavaScript result to the extension.
- `client/Sources/Services/MediaResolverService.swift` — loaded the extension's URL with its headers, ran its script and returned the result and the cookies of every host the page used.
- `client/Sources/Services/WebViewSolverService.swift` — loaded worker-requested challenge targets.
- `engine/.../WebViewSessionBridge.kt`, `MediaResolveBridge.kt`, `SolveBridge.kt` — checked only that URLs were http(s).

**Why it matters.** The security model's core promise is that an extension reaches only public internet hosts: the worker sandbox allows one loopback port (the egress proxy), and the proxy refuses loopback, private, link-local and CGNAT addresses. These three bridges, however, run the extension's page in the *app's* WebKit, which is not sandboxed and had no address restriction, and hand the extension what the page reads.

**Attack path.** A malicious or compromised extension (community repository, a taken-over signed repository, or an update):
1. calls `WebViewResolver` or creates a hidden `WebView` with `url = "http://127.0.0.1:11434/api/tags"` (Ollama), a Jupyter or dev-server port, `http://192.168.1.1/` (router), or `http://169.254.169.254/latest/meta-data/` (cloud metadata on a Mac VM);
2. or loads its own HTML with `baseUrl` set to such an origin, so the page's same-origin `fetch()` can read any path there;
3. evaluates `document.body.innerText` (or receives the resolver's `scriptResult`), and sends the answer out through its normal egress.

A host name that resolves to a local address (`127.0.0.1.nip.io`) or re-resolves to one (DNS rebinding) reaches the same services, so a spelling check alone would not be enough.

**Impact.** Read access to unauthenticated services on this Mac and the local network (local AI servers, notebooks, development servers, Docker's TCP API if enabled, NAS and router admin pages), state-changing requests to LAN devices, and cloud credentials on virtualised Macs. It bypasses SEC-06 as documented.

**Fix (defence in depth):**
1. **Proxy for all extension WebKit traffic.** A dedicated `WorkerEgressProxy.webContent` (same public-only rule, own password and connection budget) is handed to the app by the authenticated `GET /webview/egress`. `WebContentNetworkPolicy.prepare` sets it as the data store's only `ProxyConfiguration` with `allowFailover = false` before any view exists. Measured: WebKit sends host names (SOCKS5 domain type), so the engine resolves once and connects to the address it checked — rebinding is refused; when the proxy refuses, nothing connects directly.
2. **Content rule list for what WebKit never proxies.** Measured: WebKit connects to `127/8`, `localhost`, `::1`, `169.254/16` and `fe80::/10` without the proxy. A compiled `WKContentRuleList` blocks every resource type to those hosts in all spellings WebKit canonicalises (`2130706433`, `0x7f.1`, `0177.0.0.1`, `[0:0:0:0:0:0:0:1]`, `[::ffff:127.0.0.1]`, user-info prefixes, `*.localhost`), plus private ranges, `.local`, `.lan`, `.internal`, `.home.arpa` and single-label names.
3. **Early refusal.** The engine refuses load/resolve/worker-solve requests whose URL or base URL names a local destination (`WebDestination`, a WHATWG-compatible IPv4 parser plus `isPublicAddress`); the app's navigation delegates and entry points refuse the same hosts (`LocalDestination`).
4. **Fail closed.** No proxy settings or rule list → `prepare` returns false: the resolver completes empty, the solver attempt ends, the WebView never loads.

**Proof:** `WebContentNetworkPolicyTests.testPagesCannotFetchLoopbackServices` runs a page that `fetch()`es a loopback fixture: the control run (loopback rules off) reaches it; the confined run is blocked and the server never sees the request. Further tests cover classification, refusal at every entry point, the proxy without failover, fail-closed behaviour and rule compilation in WebKit; `WebContentConfinementTest` covers the engine side and the route.

## L1 — DNS rebinding against the loopback listener (Low)

**Where:** `Main.kt` request interceptor. No `Host` validation.

**Attack path.** A web page in the user's browser re-resolves its own name to `127.0.0.1` and, after finding the random port, reads `/health` same-origin: recovery errors, safe mode, policy and isolation state, provider counts, and an HMAC oracle for arbitrary nonces. It could also probe relay ids (256-bit, so not practical). Everything else needs the bearer token.

**Fix:** `LoopbackHost.allowed` — only `127.0.0.1`, `localhost` and `[::1]` (with an optional numeric port) are answered; anything else is 403 before any route, including `/health` and relay reads. The app, libmpv, ffmpeg and external players all use `127.0.0.1:<port>`.

## L2 — Requests to extension-declared local addresses (Low)

**Where:** `ConnectivityTester.kt` probed each provider's `mainUrl` from the unsandboxed engine, following redirects; `BoundedHTTPResourceLoader.swift` (posters, backdrops, subtitle sidecars) fetched any http(s) URL.

**Impact:** blind requests (the answer is not returned to the extension) to this Mac or LAN devices, for example a router endpoint that changes state on GET.

**Fix:** the connectivity test refuses local site URLs up front, checks every hop's host and refuses DNS answers that are not public; the bounded loader refuses local hosts initially and on every redirect.

## L3 — Mutable third-party actions in the release job (Low)

**Where:** `.github/workflows/ci.yml`. `softprops/action-gh-release@v3` runs in the `package` job after the Developer ID certificate is imported and the app is signed and notarised; `gradle/actions/setup-gradle@v6` runs in every job.

**Impact:** whoever controls a moved tag runs code with the job's `contents: write` token and next to the imported signing identity.

**Fix:** both are pinned to the commit their tag pointed to on 6 November 2026 (with the tag in a comment, which Dependabot keeps current). GitHub's own `actions/*` stay on major tags.

## Informational (reviewed, unchanged)

1. **App entitlements** keep `allow-jit`, `allow-unsigned-executable-memory` and `disable-library-validation`. Already recorded in `Security.md`; removing them needs a notarised Developer ID build with playback and the solver verified.
2. **`NSAllowsArbitraryLoads`** stays (provider artwork and downloads are often plain HTTP); accepted in `Security.md`.
3. **Native media consumers** (libmpv, ffmpeg, external players) open extension stream URLs directly and can be pointed at a LAN host. Requests are blind and confined to HTTP(S) by protocol whitelists; added to the residual risks.
4. **Worker frames** may be up to 16 MiB against a 192 MiB engine heap. A hostile extension could pressure engine memory with repeated maximum frames; the engine would exit (`ExitOnOutOfMemoryError`) and restart. Recommend measuring the largest legitimate responses and lowering `MAX_FRAME_BYTES`, or streaming large results.
5. **Dependency verification.** Gradle lockfiles, the SBOM advisory gate and the wrapper checksum are in place, but there is no `gradle/verification-metadata.xml`. Recommend `./gradlew --write-verification-metadata sha256 :engine:test :engine:jar` reviewed into the repository. Build tools in `scripts/media-build-requirements.txt` are version-pinned without hashes; media sources are pinned to commit SHAs.
6. **App lock** is a privacy screen: preferences live in `UserDefaults`, so another process of the same user can turn it off. Locked-profile IDs are in the Keychain. This matches its documented purpose.
7. **Backup restore** re-adds the repositories a backup lists (no extension is installed; consent rules still apply). A crafted backup the user chooses to import can therefore add a repository; the restore report lists what was added.
8. **`/health`** stays unauthenticated by design (handshake); with L1 fixed only loopback-named requests reach it.

## Checked and found sound

- IPC: loopback bind, 256-bit token over stdin, constant-time comparison, port announced on the child's own stdout, HMAC proof, socket-ownership check, credentials sent only after the proof, `no-store` on every response, ephemeral client sessions.
- Worker sandbox profile (deny default, narrowed sysctl and process-info, metadata limited to needed paths, only the egress port and mDNSResponder reachable), isolated environment, unsandboxed workers refused by default.
- Egress proxy: authenticated SOCKS5, CONNECT only, resolve-once connect-to-checked-address, IANA special-purpose ranges (IPv4-mapped, NAT64, 6to4, Teredo, documentation) refused.
- Media relay: registered resources only, 256-bit ids, dot-segment and encoded-separator guards, credentials kept to their origin across redirects and rewritten manifests, no system proxy, connect-time address checks, bounded manifests and sessions.
- Repository transport and trust: HTTPS only, per-hop policy, byte limits, strict JSON, Ed25519 signed catalogs, consent tiers, hash-bound receipts, in-memory verified class loading.
- Player and downloads: libmpv without scripts/config, protocol whitelists, length-prefixed option values, EDL built only from validated URLs, ffmpeg via argv with credentials only through the relay, header validation, sanitized filenames, external players given only Referer/User-Agent.
- Client: deep links blocked while locked and repository adds confirmed, http(s)-only "Open in Browser", HTML stripped to plain text, bounded image decoding, keychain items this-device-only in the data-protection keychain, no secrets in logs.
- CI: least-privilege `permissions`, tag/version gate, media sources pinned to commits, Gradle wrapper checksum, advisory gate.

## Verification

- Engine: `./gradlew :engine:test` on this tree — 459 passed, 0 failed, 3 live-network tests skipped as usual; includes the new `WebContentConfinementTest` (9 tests).
- Client: built with Xcode 27.2 (`build-for-testing`, no errors); the whole `CloudStreamMacTests` target ran with the engine jar staged outside `~/Desktop` (`CS_LIVE_ENGINE_JAR`, as `run_full_client_tests.sh` does): 670 tests, 0 failures, 61 skipped (gated tiers), including the new `WebContentNetworkPolicyTests` (9). `scripts/test_swift_core.sh extensions`: 34 passed. CI builds with Xcode 26.3, whose Swift is stricter about sendability; that build has not been run on this change.
- WebKit behaviour above was measured directly; the programs were throwaway and are not part of the repository.

## Residual risk after the fix

- Same-origin reads of a *public* host by extension pages are expected (that is the feature).
- Requests WebKit makes outside the network stack it proxies (none observed) would be covered only by the rule list and navigation checks.
- If the user's network requires an HTTP proxy for outbound traffic, extension WebKit content now connects directly through the engine's proxy, as extension workers already do, and may fail there.
