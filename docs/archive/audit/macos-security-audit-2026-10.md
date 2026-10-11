# Security audit: CloudStream for macOS (October 2026)

Branch audited: `engine-logic-fixes` (base `c7c9fb0`). No code was changed during the audit.

## Summary

The codebase was clearly designed with a threat model in mind, and most classic attack surfaces held up under testing or review. The serious problems are at the edges of the extension sandbox and in how the app trusts its local engine. Found: **1 High, 5 Medium, 6 Low**, plus documentation drift.

**Method.** Engine, library, client and build scripts were read. Where possible, claims were tested directly:
- the built engine was run against a throwaway data folder and sent crafted requests;
- sandbox profiles copying the worker's rules were run and probed for escapes;
- the live engine log and the app's web cache were inspected by counting matches, without printing secret values.

Findings marked **[verified]** were reproduced; the rest come from code review.

| # | Severity | Finding |
|---|---|---|
| H1 | **High** | Extension sandbox allows connections to any local socket or loopback port, and workers inherit the full environment → sandbox escape **[verified]** |
| M1 | Medium | The app trusts whatever answers `/health` on the port it picked, then sends it the bearer token and Keychain credentials |
| M2 | Medium | Sandboxed extensions can read every same-user process's command line (ffmpeg's header arguments) and check whether any file exists **[verified]** |
| M3 | Medium | Engine responses and the live bearer token are written to the app's on-disk web cache **[verified]** |
| M4 | Medium | "Verified" tier means only "signed with *some* key": it skips consent and satisfies the `AllowCommunityRepositories=false` policy |
| M5 | Low–Med | The repository blocklist can be bypassed with a different URL spelling or a redirect |
| L1 | Low–Med | Extension output containing tokens is kept in the engine log; the diagnostics redactor misses common shapes **[verified]** |
| L2 | Low | The media relay follows the Mac's proxy settings, which skips its private-address check |
| L3 | Low | Challenge cookies a worker solves go into the shared cache, contrary to the code comment |
| L4 | Low | The global app lock doesn't clear the Spotlight index |
| L5 | Low | Keychain items use the legacy file keychain (`SecItemUpdate` on a pre-existing item) |
| L6 | Low | `requireSandbox` defaults to false, so extensions run unsandboxed if `sandbox-exec` is missing |

---

## H1 — Worker sandbox escape through local sockets [verified]

**Where:**
- `engine/src/main/kotlin/com/lagradost/macos/worker/WorkerLauncher.kt:112`: `(allow network-outbound)` with no restriction.
- `engine/src/main/kotlin/com/lagradost/macos/worker/WorkerClient.kt:94`: `ProcessBuilder(command)` passes on the engine's full environment.
- `client/Sources/App/DaemonSupervisor.swift`: the engine is started with the app's environment.

**Attack path:** A malicious or compromised `.cs3` extension (community tier, or a takeover of a signed repository) runs in its worker. `network-outbound` covers Unix-domain-socket connects as well as TCP to `127.0.0.1`; JDK 17 can open Unix sockets from plain Java. The worker also inherits `SSH_AUTH_SOCK`, `HOME` and the rest of the environment. That gives an extension:
- **Docker Desktop / Colima socket** (`~/.docker/run/docker.sock`): start a container mounting the home folder → full user compromise.
- **ssh-agent / 1Password / gpg-agent sockets**: sign with the user's keys (e.g. push to GitHub as the user).
- **Any unauthenticated loopback service**: dev servers, Jupyter, Ollama, Redis, debug ports.

**Evidence:** A profile with the same `deny default` / `network-outbound` / `system-socket` rules could not read a file outside its directory, but did connect to a Unix socket created outside the sandbox and read a secret from it, and reached a loopback TCP listener.

**Impact:** Breaks the core promise in `docs/Security.md` that an extension cannot reach user files.

**Fix:**
```
(allow network-outbound (remote ip "*:*"))       ; IP only, so no AF_UNIX
(deny  network-outbound (remote ip "localhost:*"))
(deny  network-outbound (remote unix-socket))
```
- Clear the worker environment and set only what it needs: `environment().clear()`, then `HOME`/`TMPDIR` pointing to the worker's own folder, `PATH=/usr/bin:/bin`, `LANG`.
- Do the same when the app starts the engine (set `process.environment` explicitly).
- SBPL cannot block LAN ranges; if LAN access matters, route worker traffic through an engine-side proxy that checks addresses.
- Add `WorkerIsolationTest` cases for a Unix-socket connect and a loopback connect.

## M1 — Engine impersonation through port squatting

**Where:** `client/Sources/App/DaemonSupervisor.swift:434` (`Int.random(in: 49_152...65_535)`), `:413–421` (`isHealthy` sends `Authorization: Bearer` even to `/health`), `client/Sources/ViewModels/AppState.swift:368` (`ProviderCredentialStore.resendAll`).

**Attack path:**
1. Another local user, or a sandboxed App Store app with `network.server`, pre-binds `127.0.0.1` ports in that range (~16k ports is feasible).
2. The real engine fails to bind.
3. The client's 150 ms health poll reaches the impostor first and accepts any `{status:"ok", ipcVersion:6}` reply.
4. The impostor receives the bearer token, search and viewing activity, and Keychain-stored provider credentials (re-sent for whichever provider IDs the fake `/plugins` lists; IDs are predictable).
5. The impostor can also feed fake catalogs, trust tiers and links.

**Fix:**
- Start the engine with port `0` (already supported in `resolvePort`) and report the bound port over its stdout pipe, or listen on a Unix socket in a 0700 folder.
- Have the engine prove possession of the token: client sends a nonce to `/health`, engine returns `HMAC(token, nonce)`. Stop sending the token to `/health`.
- Optionally confirm the listening socket belongs to the child PID.
- Send credentials only after the proof succeeds.

## M2 — Workers can read other processes' command lines and probe for files [verified]

**Where:** `WorkerLauncher.kt:105` (`(allow sysctl-read)`), `:104` (`(allow file-read-metadata)` everywhere), `client/Sources/Services/DownloadService.swift:1749` (ffmpeg `-headers` in argv).

**Attack path:** Inside the worker-style sandbox, a JVM calling `ProcessHandle.allProcesses()…info().arguments()` read another process's full command line. ffmpeg downloads put each link's request headers (Cookie, Authorization) in argv, so any extension can collect another extension's session credentials while a download runs, plus secrets other apps pass in argv. Global metadata access lets it check whether any path exists (`stat` outside the sandbox succeeded).

**Fix:**
- Replace `sysctl-read` with an allowlist of the `sysctl-name` values the JVM needs; add `(allow process-info* (target self))`.
- Limit `file-read-metadata` to the paths the worker needs.
- Send downloads that need credential headers through `MediaRelay`, so ffmpeg's argv only contains an opaque relay URL.

## M3 — Engine responses and the bearer token on disk [verified]

**Where:** `client/Sources/Services/DaemonClient.swift:271, 346, 358, 487…` use `URLSession.shared` (disk cache). The engine sends no `Cache-Control`.

**Evidence:** `~/Library/Caches/com.lagradost.CloudStreamMac/Cache.db` held **493** loopback entries, including `/links`, `/links/stream`, `/details`, `/search/stream`, `/repos`, `/settings/network`, `/media/complete`. A cached `/links` body contained per-link `headers`; stored request objects contained the `Bearer` header.

**Impact:** Signed stream URLs, per-link cookies/auth headers, ClearKey keys, and search/viewing history persist on disk, survive the app lock, profile locks and history clearing, and contradict the "token never written to disk" claim.

**Fix:**
- Give `DaemonClient` its own `URLSessionConfiguration.ephemeral` with `urlCache = nil`.
- Add `Cache-Control: no-store` to every engine response in the Ktor interceptor.
- Delete existing `Cache.db` entries during migration.

## M4 — "Verified" tier is only TOFU, and skips consent and policy

**Where:** consent required only for community tier (`InstallationManager.kt:112`, `RepositoryService.kt:608`); `ExtensionPolicy.requireTier` blocks only community; `client/Sources/UI/Extensions/ExtensionsView.swift:311` shows a green "Verified" seal with "the publisher's key authenticates this extension".

**Attack path:** An attacker signs their own `repo.json` with a key they generated. The repository then shows as Verified, installs without the community-consent prompt, and is accepted by organizations that set `ExtensionsAllowCommunityRepositories=false` expecting "signed only".

**Fix:**
- Rename the tier to "Signed" and show the key fingerprint.
- Require first-time consent for every non-pinned repository.
- Treat a repository as "verified" only when its key is pinned by policy or on a curated list.
- When `allowCommunityTier=false`, require a pinned key or an allowlist.

## M5 — Repository blocklist bypass

**Where:** `ExtensionPolicy.kt:70`. `URI.normalize()` doesn't lowercase the host, drop the default port or ignore the query. Policy is checked on the entered URL (`RepositoryService.kt:341`), not on each redirect hop or `effectiveUrl`.

**Example:** With `https://evil.example/repo.json` blocked, `https://EVIL.example/repo.json`, `…:443/…`, `…/repo.json?x` and any redirector all pass.

**Fix:** Canonicalize with `HttpUrl`; match the blocklist by host (or host + path prefix); re-check policy on every redirect hop, on the effective URL, and on discovered child repositories.

## L1 — Secrets in logs, and a leaky redactor [verified]

**Where:** `WorkerClient.kt:310` writes worker stderr to `daemon.log` unredacted. `DiagnosticsExport.kt:25` builds its key=value pattern with `\b`, which fails on prefixed names such as `access_token` or `hashedToken`.

**Evidence:** The live `daemon.log` had 1,767 `worker.stderr` lines; 47 mentioned a token, cookie or authorization (e.g. a file-host extension printing `token:` / `hashedToken:`). A redactor test missed `hashedToken: …`, `{"access_token":"…"}`, `access_token=…`, `auth_token: …` and path-embedded tokens; it caught `token: …`.

**Fix:** Don't persist extension stderr by default (opt-in verbose mode); redact at write time; use `[A-Za-z_-]*(token|secret|…)` with optional quotes for JSON keys; redact high-entropy path segments.

## Low findings

- **L2:** `MediaRelay.kt:188` doesn't set `.proxy(Proxy.NO_PROXY)` while the engine runs with `-Djava.net.useSystemProxies=true` (`DaemonSupervisor.swift:463`). With an HTTP proxy/PAC configured, OkHttp never resolves the target host, so the private-address check is skipped. `RepositoryTransport` already does this correctly.
- **L3:** `SolveBridge.kt:89` always calls `cache(origin, cookies)`, so a worker's solved cookie reaches engine-side and repository fetches; the comment at `:46` says it stays with the requesting worker.
- **L4:** `client/Sources/Services/System/SpotlightIndexer.swift:71` skips only locked *profiles*; with the global `requireUnlock` lock on, library titles remain searchable in Spotlight.
- **L5:** `client/Sources/Services/Security/GenericPasswordKeychain.swift:23` updates legacy file-keychain items; a same-user app that pre-created an item with the same service controls its ACL. Use `kSecUseDataProtectionKeychain: true` with an access group.
- **L6:** `ExtensionPolicy.kt:31` defaults `requireSandbox` to false. Consider failing closed when unmanaged, behind a warning the user must acknowledge.

## Hardening notes and documentation drift

- The shipped `Info.plist` contains the TMDB API key (extractable). Normal for a client key; proxy it if quota abuse matters.
- `NSAllowsArbitraryLoads` is enabled app-wide.
- The dev `dist/` build and default `package_app.sh` are ad-hoc signed **without the hardened runtime** (`flags=0x2`). Release builds use `--options runtime`. Never distribute the development DMG.
- External VLC gets no nested-resource confinement (already documented).
- Engine subfolders and `daemon.log` are created 0755/0644; safe only because the client creates the data root as 0700. Set 0700/0600 explicitly in the engine.
- `Security.md:75` says the relay lasts "six idle hours"; code uses 15 minutes (`MediaRelay.kt:50`). `ipc-api.md:126` says manifests are "refused with 415"; they are now rewritten.

## Checked and found sound

- Engine binds to loopback only; token comparison is constant-time.
- Relay prefix path tricks (`../`, `%2e%2e/`, `..;/`, 8 variants) all returned 404; no auth bypass. The relay's dot-segment guard works.
- Repository downloads: HTTPS only, no proxy, connect-time address checks, byte limits, redirect limit.
- Ed25519 signatures with strict canonical JSON; signed repositories cannot downgrade to unsigned or HTML.
- Extension archives read in memory with size limits; no zip-slip.
- XXE disabled for DASH manifests.
- libmpv built without Lua/JavaScript, `config`/`load-scripts` off, protocol whitelist. ffmpeg gets an argument array (no shell) plus a protocol whitelist. Download filenames are sanitized.
- Repository deep links need confirmation and are blocked while locked. Backup restore applies only whitelisted settings.
- Rhino uses `initSafeStandardObjects`. Extension WebViews use a non-persistent store, http(s) only, main-frame bridge only.
- Missing/invalid launch options fail closed; `state.json` is 0600.

## Suggested remediation order

1. H1 and M2 (sandbox profile and environment)
2. M3 (dedicated cacheless session + cache cleanup)
3. M1 (port handshake / engine authentication)
4. M4 and M5 (trust tier semantics, policy matching)
5. Low findings and documentation fixes
