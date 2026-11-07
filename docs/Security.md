# CloudStream macOS — Security Model

Status: describes the current engine (IPC v7, per-extension sandboxed workers). The remediation that produced this model is recorded in [Extensions-Remediation-Plan](archive/plans/Extensions-Remediation-Plan.md), with evidence in [REMEDIATION.md](archive/audit/extensions-repository/REMEDIATION.md). The latest security audit and its fixes: [macos-security-audit-2026-11](archive/audit/macos-security-audit-2026-11.md).

## Assets

1. **Provider credentials** — optional provider account credentials. Stored only in the login Keychain (`ProviderCredentialStore`, this-device-only, when unlocked), sent to the engine in memory after each start. Engine state records only that credentials exist.
2. **Ephemeral IPC token** — 32 crypto-random bytes generated per launch (`SecRandomCopyBytes`), delivered to the daemon **over stdin** (never argv), kept in memory.
3. **User files** — library, downloads, documents. Extension workers cannot read them (worker sandbox).
4. **Extension code** — third-party DEX, translated and executed only inside per-extension sandboxed workers.
5. **Trust state** — repository keys, catalog revisions, consents and installation receipts (`state.json`, private, atomic, fsynced, backed up; unknown or damaged state enters recovery rather than resetting policy).

## Trust boundaries

```
Internet ⇄ [worker sandbox: one extension each]   — outbound TCP/UDP to remote hosts; own directory only
Engine (control plane) ⇄ workers                   — stdin/stdout frames; engine runs no extension code
UI ⇄ engine                                        — loopback + bearer token (constant-time); the engine
                                                     proves the token first (HMAC handshake, port from its stdout)
Internet ⇄ [app WebKit for extensions]            — solver, WebViewResolver pages, extension WebViews;
                                                     only through the web-content egress proxy (public
                                                     addresses only); loopback/link-local blocked in WebKit
UI ⇄ ffmpeg / libmpv                               — sanitized URLs + headers only
Organization ⇄ app                                 — managed preferences (configuration profile)
GitHub Releases ⇄ app updater                     — HTTPS to GitHub hosts only (redirects too); SHA-256
                                                     from GitHub, bundle/version/signature checks, then an
                                                     atomic swap at quit (ADR-0007)
```

## Extension isolation (P5, ADR-0016)

The engine is a **control plane that runs no extension code**. Each installed extension runs in its own worker JVM, launched by the engine through the macOS sandbox with a per-worker deny-by-default profile. A worker can:

- read only the bundled runtime, the daemon jar, its one verified artifact file, the exported keychain roots file (public certificates, read-only), and system TLS/DNS configuration;
- read and write only its own home, `workers/<installationId>/` (its translation cache, its `Context` storage, its temp directory);
- reach the network only through the engine's egress proxy. The profile denies every outbound TCP and UDP connection except TCP to that proxy's one loopback port, and every Unix-domain socket (Docker, ssh-agent, 1Password, gpg-agent) except mDNSResponder. The proxy (`WorkerEgressProxy`, SOCKS5 with a per-engine password sent in INIT, never on argv) resolves names with the engine's resolver and connects only to public addresses, so loopback, private, link-local, CGNAT, multicast and documentation ranges (this Mac's services and the local network) are refused. A worker cannot listen and talks to the engine over its stdin/stdout pipes;
- read sysctl values only for hardware, CPU and OS version (never `kern.proc*`/`kern.procargs*`, which expose other processes' command lines), inspect only its own process, and see file metadata only for the paths it may read and their parent directories (so it cannot probe whether other files exist).

The narrowing follows the `system.sb` import, which otherwise allows every `sysctl-read`. Workers and the engine start with an explicit environment (`HOME`, `TMPDIR`, `PATH=/usr/bin:/bin`, `LANG`): nothing is inherited, so no agent socket, credential, `CS_DAEMON_*` value or JVM option reaches extension code. Workers ignore the system proxy settings (`java.net.useSystemProxies` is not set for them); their egress proxy connects directly so its address check always applies. The engine's own repository and provider traffic still follows the system proxy.

So an extension cannot read user files, the engine's trust state (`state.json`, keys, receipts) or any other extension's data (`WorkerIsolationTest`, including real sandbox denials). Every response from a worker is treated as untrusted: stream and subtitle URLs are sanitized again, result counts are bounded and provider IDs are forced into the extension's namespace.

**Deadlines and budgets.** Each call has a hard deadline (the provider's budget plus 2 s); the engine then cancels the call and kills the worker if it has not answered within 3 s. Workers run with a 256 MB heap, exit on out-of-memory, and are capped at two processors. Three crashes or kills within an hour quarantine the extension (persisted, audit-logged, the user can Retry). At most 8 workers run at once; idle workers stop after 5 minutes, or once their resident memory exceeds 256 MB while idle, and restart on the next call. Response bodies an extension never closes are reclaimed when no operation is running.

**Why the engine itself is not sandboxed.** A sandboxed process cannot sandbox its children further, and per-extension confinement is stronger than confining the engine as a whole. The engine runs only first-party code: routes, trust, state, built-in providers. Untrusted inputs it parses (catalogs, HTTP) go through strict, bounded parsers; DEX translation runs inside the worker.

If the sandbox launcher is unavailable, extensions do not run: `requireSandbox` is on by default and the engine refuses to start an unsandboxed worker. An organization may turn this off explicitly with `ExtensionsRequireSandbox = false`; a misconfigured profile never relaxes it. The JVM's entitlements are JIT, unsigned executable memory and disabled library validation (Netty extracts unsigned native libraries at runtime). `allow-dyld-environment-variables` is not granted. Packaging runs `daemon.jar --self-test` on the bundled runtime, which boots a sandboxed worker.

**Requests a worker may make to the engine** (ADR-0016 amendment). Workers never reach each other directly. A worker can ask the engine to (1) solve an anti-bot challenge, (2) route a video-host URL to the extension that registered a matching extractor, and (3) load a page in the app's WebKit for `WebViewResolver`. Each is bounded in count and by the deadline of the call the worker is serving. Routed extraction cannot loop (visited installations, three hops; the engine does not trust the worker's own route state) and returns only sanitized links. Page loads run in a per-task non-persistent WebKit data store, accept only http(s) URLs, block hand-offs to other apps and local files, and report only request URLs; the engine matches the extension's regular expressions itself under a per-match time budget, so neither a crafted pattern nor a crafted URL can hang it.

**WebKit content an extension asks for** (security audit 2026-11, H1). Challenge solves, `WebViewResolver` pages and extension WebViews load in the app's WebKit, outside the worker sandbox, and the extension reads what they return (script results, page events, cookies). Without confinement an extension could open `http://127.0.0.1:<port>/`, a router or `169.254.169.254` there and read the answer. Three layers keep that content on the public internet:

1. **Proxy.** Every request goes through the engine's web-content SOCKS5 proxy (`WorkerEgressProxy.webContent`, `GET /webview/egress`), the same public-only address rule as the workers' proxy, in its own instance with its own password and connection budget. WebKit sends host names to the proxy, which resolves them itself and connects to exactly the address it checked, so a name that resolves (or re-resolves, DNS rebinding) to a local address is refused. `allowFailover` is off: without the proxy nothing loads. `WebContentNetworkPolicy.prepare` refuses to configure a view when the proxy settings or the rule list are unavailable.
2. **Content rule list.** WebKit connects to loopback (`127/8`, `localhost`, `::1`) and link-local (`169.254/16`, `fe80::/10`) destinations without asking a proxy (measured on macOS 27). A compiled `WKContentRuleList` blocks every request, of every resource type (pages, frames, fetch/XHR, media), to those addresses in every spelling WebKit accepts (`2130706433`, `0x7f.1`, `[::ffff:7f00:1]`, user-info prefixes) and to other local spellings (private ranges, `.local`, `.lan`, `.internal`, `.home.arpa`, single-label names).
3. **Refusal before loading.** The engine refuses load, resolve and worker-solve requests whose URL or HTML base URL names a local destination by spelling (`WebDestination`), and the app's navigation delegates refuse the same hosts (`LocalDestination`).

The engine's connectivity test applies the same rule to the site URLs extensions declare, and the app's artwork and subtitle loader refuses local hosts on every redirect.

**Extension settings.** The engine derives an extension's preference keys and types from its translated code without running it, and edits only those keys with those types, inside the process hosting the extension. Values never appear in logs, audit records (keys only) or the diagnostics export; the app hides text values by default.

**Translation.** DEX translation runs inside the worker under its heap limit. Methods beyond a fixed size bound are replaced by a stub that throws a named error, so an oversized or crafted method cannot exhaust the worker.

**Android compatibility types** the engine provides describe the Mac truthfully (`Build` reports Apple/Mac with no Android SDK level; `ActivityManager` reports real memory) and never widen access: `ApplicationInfo.dataDir` is the extension's own private directory, `PluginManager` lists nothing and ignores unload requests, and UI base classes are inert.

**Provider TLS.** As on Android (upstream #2655, stable since 4.8.0), `app` verifies certificates and `insecureApp` does not; an extension opts into the latter (`@UnsafeSSL`) for provider hosts with broken certificates. Repository traffic and the DoH resolver never use the insecure client; which client an extension uses for its own logins is its choice, as on Android. Workers fetch a missing intermediate certificate from its AIA address (`com.sun.security.enableAIAcaIssuers`) through the egress proxy, so the fetch obeys the public-address rule and the result must still chain to a trusted root.

**Keychain roots.** JDK 17 cannot read macOS keychain trust settings (`KeychainStore` is empty and there is no `KeychainStore-ROOT`), so a network whose TLS is inspected by a root installed in the keychain (antivirus HTTPS scanning, company proxies, MDM profiles) used to fail every engine connection while Safari worked. At each engine start the app (`SystemTrustAnchors`) exports the certificates the user and admin trust domains mark as trusted roots for SSL (an empty trust-settings array, or an entry for the SSL policy or for every policy, not limited to one application or host name). A certificate the user domain marks as never trusted is left out even when the admin domain trusts it. Apple's built-in system roots are not exported. The PEM file is `trust/system-anchors.pem` under the engine data root, owner-only (0600 in a 0700 folder), rewritten each launch and removed when there is nothing to export; its path reaches the engine in the stdin launch options, never argv. The engine (`SystemTrust`) reads at most 1 MiB and 256 certificates, skips malformed blocks and expired certificates, and builds one trust manager whose anchors are the JDK's `cacerts` plus those roots. It is used by `app`, repository traffic, the DoH resolver and the JDK default `SSLContext` (URLConnection); hostname verification is unchanged. Workers receive the file's path as a system property and their sandbox profile allows reading that one file. `insecureApp` is unaffected (it verifies nothing), and repository signing does not depend on TLS trust. A root added to the keychain is picked up at the next engine start.

Residual: a compromised extension can still use the network as its own origin, and all workers run as the same user, so they are not protected from other processes of that user. A routed extractor runs with the target extension's identity, not the caller's.

## Invariants and where they live

| Invariant | Enforcement point |
|---|---|
| SEC-01 loopback-only | `Main.kt` `embeddedServer(Netty, host = "127.0.0.1", …)`; sandbox allows inbound only on loopback; a non-loopback `Host` header answers 403 before any route (`LoopbackHost`, DNS-rebinding defence) |
| SEC-06a extension WebKit confinement | `WebContentNetworkPolicy` (proxy without failover, content rule list, navigation checks), `WorkerEgressProxy.webContent`, `WebDestination` on `WebViewSessionBridge`, `MediaResolveBridge`, `SolveBridge.solveForWorker` (audit 2026-11 H1) |
| SEC-02 ephemeral bearer auth | `Main.kt` interceptor (constant-time compare), `DaemonSupervisor` stdin delivery. Relay resource reads (`/media/relay/{id}`) are authorized by their 256-bit id instead; see below |
| SEC-02a engine authentication | The engine binds port 0 and announces the port on its stdout pipe (`EngineHandshake`); the app checks the port is the child's own listening socket, then sends a nonce to `/health` and accepts only `HMAC-SHA256(token, "cloudstream-health-v1:" + nonce)`. The token is never sent to `/health`; provider credentials are sent only after the proof (`EngineHealthProbe`, `EngineSocketOwnership`) |
| SEC-02b no IPC caching | Every engine response carries `Cache-Control: no-store`; the app's engine sessions are ephemeral with no URL cache, cookies or proxy (`EngineTransport`); engine responses left in the shared cache by older builds are purged once |
| SEC-03 zero telemetry | No analytics SDKs; logs are local files only |
| SEC-04 URL sanitization | `URLSanitizer` on every link; CDN-auth params preserved |
| SEC-06 filesystem restriction | **OS-enforced per extension** by the worker sandbox (ADR-0016); each worker may write only `workers/<installationId>/` |
| SEC-07 extension integrity + authenticity | Receipts (`InstallationManager`) are the only execution authority. Exact byte SHA-256 + declared length; signed catalogs: signed root → list digests → artifact digests with revision/expiry and durable anchors, shown as **Verified** only when an organization pinned the key and as **Signed** (with the key fingerprint, first-time consent required) otherwise; community tier: explicit consent + exact list bytes + publisher digest when provided, otherwise an explicitly named local observation proof (ADR 0018). Translated JARs are hash-bound to the receipt and loaded from verified in-memory bytes (`VerifiedClassLoader`) |
| SEC-08 Android stub isolation | `android.*` stubs match Android descriptors (`AndroidStubConformanceTest`, d8-built fixture) |
| SEC-09 lifecycle integrity | Per-installation serialized operations, durable commit before publication, staged registration, rollback generation, crash quarantine, safe mode |
| SEC-10 audit | Hash-chained append-only log (`AuditLog`) of repository, consent, trust, install/update/rollback/uninstall, enable/disable, revoke, quarantine and provider-configuration events; identifiers and digests only |

## Split-stream relay

`MediaRelay` lets the native player read a split stream whose video and audio
need different request headers. It is not a proxy: the authenticated client
registers each resource (validated HTTP(S) URL and headers) and receives one
random 256-bit id per resource; only those ids can be read, without the bearer
token, by `GET`/`HEAD`. Nothing in a read request selects the destination, and
of the caller's headers only one simple byte range is used. Upstream error
bodies, cookies set by the origin and manifests are not passed on; redirects
must stay valid HTTP(S) and lose credentials when they leave the origin. At
most twelve sessions of 33 resources exist; a session ends when the player
revokes it, after 15 idle minutes, or with the engine (one never read may be
evicted after 10 seconds when the relay is full). Credentialed streams
(cookies, authorization) are played and downloaded only through the relay, so
their credentials never reach ffmpeg's argv or a host a manifest or redirect
names; absolute DASH segment URLs and templates are relayed too. Relay
fetches never use the system proxy, so the private-address check always
applies. Another local process
would have to guess an id to read a resource the user is already playing; it
gains no way to make the engine fetch anything else.

## Entitlements

| File | Entitlement | Why it is there |
|---|---|---|
| App | `cs.disable-library-validation` | Development builds are ad-hoc signed, so libmpv and the bundled libraries carry no team identity to validate against. A Developer ID build signs every nested library with one identity and may not need it; unverified without such a build |
| App | `cs.allow-jit`, `cs.allow-unsigned-executable-memory` | Historical. The app process itself runs no JIT: the JVM has its own entitlements and WebKit's JIT runs in its own processes. A copy of the development build re-signed without these two launched, started its engine and passed the smoke launch (2 October 2026); playback and the anti-bot web view were not exercised that way, so the file is unchanged |
| App | `network.client`, `network.server` | App Sandbox entitlements; inert because the app is not sandboxed (Hardened Runtime only) |
| `java` | `cs.allow-jit`, `cs.allow-unsigned-executable-memory`, `cs.disable-library-validation` | HotSpot's JIT, and Netty's native libraries extracted at run time. `allow-dyld-environment-variables` is not granted |
| ffmpeg, `jspawnhelper` (ad-hoc builds only) | `cs.disable-library-validation` (`client/adhoc-tool.entitlements`) | Every build runs under the Hardened Runtime. Ad-hoc libraries carry no team identity, so library validation would refuse them. Developer ID builds sign every library with one team, so these tools get no entitlements there |

Removing the app's two JIT entitlements and the two inert sandbox keys is a
candidate change. It needs playback, the web-view solver and a notarized
Developer ID build checked first, so it is recorded here rather than made.

## Managed configuration

Organizations deploy a configuration profile for the app's preference domain. Only values the system reports as **forced** apply (a user cannot relax them with `defaults write`). The client passes them to the engine at launch; the engine enforces them on every route and at load time. A forced key with the wrong type, or a policy the engine does not receive, fails closed: safe mode, no allowed repositories, no community tier, no additions.

| Key | Type | Effect |
|---|---|---|
| `ExtensionsAllowedRepositories` | [String] | Only these repository URLs can be added, synced or loaded (compared canonically: case, default port, query and fragment ignored) |
| `ExtensionsBlockedRepositories` | [String] | Never allowed. A host entry blocks the host and its subdomains, a host + path entry that path and below; enforced on every redirect hop and on the effective URL |
| `ExtensionsPinnedRepositoryKeys` | {URL: base64 key} | Repository must be signed by this key; rotation from the app is refused |
| `ExtensionsAllowLocalArtifactObservation` | Bool | `false`: hashless downloads and receipts are blocked; publisher digests are required |
| `ExtensionsAllowCommunityRepositories` | Bool | `false`: only approved repositories (key pinned by policy, or allow-listed) can be used; unsigned and merely signed repositories do not load |
| `ExtensionsAllowUserRepositories` | Bool | `false`: users cannot add repositories beyond the allowed list |
| `ExtensionsAutoUpdate` | Bool | Forces the automatic-update setting |
| `ExtensionsSafeModeOnly` | Bool | No extension code loads |
| `ExtensionsRequireSandbox` | Bool | Default `true`: the engine refuses to start extension workers without the macOS sandbox; `false` allows them unsandboxed |
| `ExtensionsAllowDeveloperExtensions` | Bool | `false`: developer mode (installing extensions from local files) cannot be turned on and developer extensions do not load |

## Anti-bot bridge

Challenges are detected by an OkHttp interceptor (`SolveInterceptor`), the request parks in `SolveBridge` (bounded 90 s), the client solves it in an offscreen WKWebView with a fresh nonpersistent store and returns only root-scoped `cf_clearance` cookies. Daemon clearance cookies are scoped to HTTPS origin, held in memory for at most five minutes and capped at 128 origins. A challenge a worker asked for is answered to that worker only; its cookies never enter the engine's shared cache.

Repository HTTP uses `RepositoryTransport`: verified TLS, explicit HTTPS redirects, public-address DNS validation, no proxy or cookie jar, bounded concurrency and byte limits (manifest 2 MiB, lists 8 MiB, artifacts 32 MiB), strict JSON validation.

## Residual risks

1. **Extensions are arbitrary code.** Workers confine them to their own directory and to public internet hosts reached through the engine's egress proxy; a signature gives key continuity only (trust on first use), so every repository whose key no policy pins needs the user's consent.
2. **Loopback authentication** — local processes of the same user can reach the listener; routes require the bearer token except `/health` and reads of a relay resource by its id. Web pages cannot use it through DNS rebinding (Host check).
3. **ffmpeg/libmpv** execute remote-controlled URLs; protocol whitelists, scheme checks and header sanitization apply. ffmpeg and external players receive only Referer and User-Agent as arguments; any other header (credentials, custom tokens), and every header for QuickTime, sends the stream through the relay instead, and a relayed external player gets a `127.0.0.1` URL and no headers at all.
4. **Sandbox launcher** — `sandbox-exec` is deprecated by Apple but present on supported macOS versions; without it extensions are refused unless policy allows them unsandboxed. The engine process itself is not sandboxed (ADR-0016).
5. **Logs** — extension stderr is not persisted unless `-Dcs.extensionLogs=verbose`; every engine log value is redacted at write time, and logs and engine folders are owner-only.
6. **Keychain** — items use the data protection keychain where the build has an access group; the file-keychain fallback (ad-hoc builds) never writes into an item another process created.
7. **Blind requests from native media consumers.** libmpv, ffmpeg and external players open the stream URLs an extension returns directly. Their protocol whitelists keep them on HTTP(S), but they can still be pointed at a LAN address; a request is sent and its answer is played or discarded, never returned to the extension. Engine-side relayed fetches and the app's artwork loader refuse local addresses.
8. **Updates trust the GitHub repository.** An update must match GitHub's checksum and be validly signed for this app's identifier; a Developer ID build also requires the same signing team. Ad-hoc builds have no identity to pin, so anyone able to publish a release on the repository can ship them an update (ADR-0007).

## Accepted exposures

Noted by the October 2026 audit and kept on purpose:

- **TMDB API key in `Info.plist`.** A client key for public metadata, so anyone can extract it. Abuse costs only request quota; proxy it through a server if that ever matters.
- **`NSAllowsArbitraryLoads`.** Provider artwork and direct downloads are often plain HTTP, so App Transport Security is relaxed app-wide. That content is untrusted anyway: images go through the bounded decoder, downloads through the protocol whitelist, and anything carrying credentials through the relay. Engine IPC is loopback only and authenticated.
- **Development builds are ad-hoc signed.** They carry the Hardened Runtime like a release, but no Developer ID or notarization, and library validation is disabled (see Entitlements). Never distribute a development DMG.

## Verification hooks

- Daemon: `./gradlew :engine:test` (lifecycle, trust, routes, loader with d8-built DEX, stubs, signer, audit).
- Packaging: `scripts/bundle_runtime.sh` gates on required JVM modules and `daemon.jar --self-test` (real DEX translation on the bundled runtime).
- Isolation: `WorkerIsolationTest` (real worker JVMs: deadlines, OOM, crash budget, sandbox denials including Unix sockets, loopback, other processes' arguments, file probing and the inherited environment); `EngineHandshakeTest` / `EngineHandshakeTests` (port announcement, HMAC proof, no-store); `WorkerCredentialTest` (credential set/clear in a real worker); `MediaRelayTest` (relay boundary).
- Dependencies: `scripts/dependency_report.py advisories|licenses` on the daemon SBOM.
- Client: `EngineDataRootTests`, `ExtensionsStoreTests`.
- `GET /extensions/audit` returns recent audit entries and whether the chain verifies.
- Every finding and its proof: [Audit-Traceability](archive/plans/Audit-Traceability.md); the complete client run: `make test-client-full`.
