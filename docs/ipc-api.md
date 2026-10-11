# CloudStream macOS — IPC API (Contract v6)

Every request requires `Authorization: Bearer <ephemeral-token>` except `/health`
and reads of a registered relay resource (`GET`/`HEAD /media/relay/{id}`), whose
unguessable id is the credential.
`GET /health` reports `ipcVersion`; the client refuses to talk to a mismatched
daemon. The client never sends the token to `/health`: it sends
`X-CloudStream-Nonce: <64 hex>` and accepts the engine only when `proof` equals
`hex(HMAC-SHA256(token, "cloudstream-health-v1:" + nonce))`. Every response
carries `Cache-Control: no-store`. The schema source of truth is the domain files in
`engine/src/main/kotlin/com/lagradost/macos/models/`
with a Swift mirror in `client/Sources/Models/IPC/`.

## Launch

The supervisor writes two lines to the daemon's stdin: the bearer token, then a
launch-options JSON object `{policy, safeMode}` (managed organization policy and
safe mode, and `isolation`: `worker` in production, `in-process` for
development; see Security.md → Managed configuration). The daemon reads both
before serving (waiting up to 10 s for the second line) and then treats stdin
EOF as parent exit. Options are fixed for the life of the process; missing or
invalid options fail closed (safe mode, no allowed repositories, no community
repositories, no repository additions). The client also fails closed when a
managed preference has the wrong type.

The app starts the engine with port `0` and an explicit environment (nothing
inherited). Once listening, the engine prints one line on its stdout,
`CLOUDSTREAM-ENGINE-LISTENING {"port":N,"pid":P}`; the app reads it from its own
pipe, checks that port is one of the child's listening sockets, and then proves
the engine's identity over `/health` (above) before sending the token or any
provider credential. The engine records its pid in `daemon.lock`; an engine
orphaned by an earlier app run that still holds the lock (exit status 75) is
stopped once, after its identity and data root are confirmed.

## Identity

- **Installation ID** — `sha256(len(repoUrl):repoUrl + internalName)`; the only
  identifier for install/update/enable/uninstall.
- **Provider ID** — `<installationId>:<providerName>` (built-in providers use the
  name). Every result carrying `provider` also carries `providerId`; follow-up
  `plugin`/`providerId` parameters accept either, but a bare name resolves only
  when exactly one provider has it.

## Errors (v4)

Extension and repository routes return typed errors:
`{"error": "<user-presentable message>", "code": "<stable code>", "detail": null}`.

| Code | HTTP | Meaning |
|---|---|---|
| `invalid_request` | 400 | Malformed input |
| `unknown_repository` / `unknown_extension` | 404 | Not added / not installed |
| `consent_required` | 403 | Community repository needs `/repos/consent` first |
| `policy_denied` | 403 | Blocked by organization policy |
| `untrusted` | 403 | Signature, digest or evidence check failed |
| `digest_required` | 403 | Catalog entry has no SHA-256 |
| `unavailable` | 409 | Publisher disabled the extension (status 0) |
| `stale_catalog` | 409 | Request no longer matches the catalog; sync first |
| `downgrade` | 409 | Older version offered; resend with `allowDowngrade` |
| `no_previous_version` | 409 | Nothing to roll back to |
| `operation_conflict` | 409 | State changed during the operation; retry |
| `unsupported` | 422 | Extension needs capabilities the engine lacks (e.g. Android resources) |
| `load_failed` | 422 | Extension failed to start; nothing was published |
| `download_failed` | 502 | Network or storage failure |
| `recovery_required` | 503 | Saved state needs repair; mutations disabled |
| `rate_limited` | 429 | Slow down |

## Media operation failures (v5)

`/home`, `/details`, `/links` and `/links/stream` report a failed provider
operation with a typed record instead of a generic 502:
`{"error", "detail", "failure": {code, stage, requestId, publicMessage, retryable, installationId?, providerId?, redactedCause?, remoteStatus?, elapsedMs}}`.
The record never contains URLs or provider data.

| `failure.code` | HTTP | Meaning |
|---|---|---|
| `missing_host_class` | 422 | The extension needs an Android or CloudStream-app class the engine does not provide (`redactedCause` names it) |
| `missing_host_member` | 422 | The extension calls a method or field the engine's version of a class lacks |
| `translation_rejected` | 422 | The JVM rejected the extension's translated code (`VerifyError`, `ClassFormatError`) |
| `host_abi_mismatch` | 422 | Any other linkage error: built against a different CloudStream API |
| `unsupported_capability` | 422 | The operation needs a capability the engine lacks |
| `unsupported_sources` | 422 | The provider answered only with links the Mac app cannot play (torrent, DRM it cannot decrypt); see `skipped` |
| `rejected_media_resource` | 422 | The provider answered only with malformed links |
| `timeout` | 504 | The extension did not finish in time (the worker is killed after the grace period) |
| `worker_terminated` | 503 | The extension's process stopped during the operation |
| `worker_out_of_memory` | 503 | The extension's process ran out of memory; its next start gets a larger heap (retryable) |
| `provider_no_data` | 404 | The provider returned nothing (e.g. no links for this title) |
| `remote_http_failure` | 502 | The provider's own server returned an HTTP error (`remoteStatus`) |
| `dns_failure` | 502 | The provider's server name could not be resolved (often a blocked site) |
| `tls_failure` | 502 | No secure connection could be established; not retried |
| `network_timeout` | 502 | The server did not answer in time |
| `connection_refused` | 502 | The server refused the connection |
| `connection_reset` | 502 | The connection was cut off (often blocking on the network) |
| `network_failure` | 502 | Any other transport failure |
| `capacity` | 503 | Too many extension processes or routed extractions are busy; retryable |

A client must show an unknown `code` with its `publicMessage` and decide on
retries by `retryable` only; codes are added without a version bump.
`runtime_incompatibility` (v5) was split into the four `missing_*` /
`translation_rejected` / `host_abi_mismatch` codes.

## Endpoints

| Endpoint | Method | Auth | Notes |
|---|---|---|---|
| `/health` | GET | no | `{status, version, ipcVersion, uptimeMs, providersLoaded, recoveryError?, extensions: {phase, restored, failed, quarantined}, safeMode, policyManaged, isolation: {mode, sandboxed, runningWorkers}}`. Served before installed extensions finish restoring (`phase`: `restoring` → `ready` / `safe_mode` / `recovery`) |
| `/repos` | GET | yes | Repositories: `tier` (`verified`/`community`), `consented`, `status` (`ok`/`error`/`not_synced`/`needs_sync`), `error`, `lastSyncedAt`, `lastAttemptAt`, `installedCount`, `keyFingerprint`, `discoveredVia`, `allowedByPolicy` |
| `/repos/sync` | POST | yes | Body `{repoUrl, installAll = false}`. https only; policy-checked. Verifies signed catalogs (TOFU or policy-pinned key); captures exact list bytes for both tiers; records failures on the repository; then reconciles installations (revocation, re-proof) and adopts legacy artifacts. Runs automatic updates when enabled. An HTML discovery page loads its child repositories two at a time within one 120 s sync budget; the result's `skippedRepositories [{url, reason}]` lists children that failed, timed out or were not reached, and the children that loaded are still committed. `sync` rate bucket |
| `/repos/consent` | POST | yes | Body `{repoUrl, allow}`. Consent to install from a community repository; audit-logged |
| `/repos/import` | POST | yes | Body `{urls}` — one-time import of the legacy client list (policy-filtered). After its migration marker is set it does nothing; it is not a general way to add repositories |
| `/repos/register` | POST | yes | Body `{urls}` (≤ 64) → `[{url, status, reason?}]` with `status` `applied`, `already_present` or `rejected`. Ordinary, repeatable registration used by backup restore. Records the address only: nothing is fetched, installed or trusted and no consent is created. Each address is validated (HTTPS, no credentials or fragment) and checked against the same policy as a repository the user adds by hand |
| `/repos/remove` | POST | yes | Body `{repoUrl, deleteDownloadedPlugins = true}`; `true` also uninstalls its extensions, `false` keeps them (they stop receiving updates) |
| `/repos/plugins` | GET | yes | `?repoUrl=` — catalog with `tier`, `installationAllowed`, `installationBlockedReason`, `requiresConsent`, `installationId`, `installedVersion`, `updateState` (`none`/`update`/`older_in_catalog`) |
| `/repos/trust` | POST | yes | Body `{repoUrl}`. Explicit key rotation; the new key must deliver a complete valid catalog before it replaces the pin. Installations with unchanged artifacts are re-proved; others are revoked until updated |
| `/plugins` | GET | yes | Installed extensions from receipts (never filesystem paths): `id` (installation ID), `state` (`running`/`starting`/`disabled`/`failed`/`revoked`/`quarantined`/`safe_mode`), `tier`, `version`, `availableVersion`, `updateAvailable`, `previousVersion`, `missingFromCatalog`, `repositoryPresent`, `providers`, `providerIds`, `extractorCount`, `unsupportedFeatures`, `lastError`, `sharedProviderNames: [{provider, alsoIn}]` (provider names other enabled extensions also register) |
| `/plugins/install` | POST | yes | Body `{repoUrl, internalName, pluginUrl?, fileHash?, allowDowngrade = false}` → `PluginDto`. The daemon derives URL and digest from the catalog; request values only guard against stale UIs |
| `/plugins/update` | POST | yes | Body `{installationId}` → `PluginDto` |
| `/plugins/updateAll` | POST | yes | Body `{repoUrl?}` → `[{installationId, name, error?}]` |
| `/plugins/rollback` | POST | yes | Body `{installationId}` → restores the previous generation |
| `/plugins/retry` | POST | yes | Body `{installationId}` → clears quarantine and loads the committed generation |
| `/plugins/setEnabled` | POST | yes | Body `{installationId, enabled}` → `PluginDto`. Extension-level; persisted in the receipt (disabled extensions never load) |
| `/plugins/uninstall` | POST | yes | Body `{installationId}`. Removes the receipt, unloads, deletes the extension's private data; unreferenced blobs are collected |
| `/plugins/config` | POST | yes | Body `{providerId, url?, credentials?, reset = false, clearUrl = false, clearCredentials = false}` → `{providerId, mainUrl, applied, detail?, pending = false, retryable = false}`. Each setting is unchanged (absent), set (non-empty) or cleared (flag, or an empty value). A cleared credential is removed from the running provider at once and never falls back to the previous one. The address persists; credentials are memory-only (the client keeps them in the Keychain and re-sends them after each start and again when restore finishes). `applied`: the running provider uses the settings now. `pending`: accepted and held, effective when the extension next loads — a provider not loaded yet, a default address that needs a reload, or a running extension that did not accept the change and was therefore stopped. A URL needs the loaded provider |
| `/providers` | GET | yes | Enabled providers with `providerId` |
| `/providers/all` | GET | yes | Every loaded provider with `providerId` and `enabled` |
| `/providers/setEnabled` | POST | yes | Body `{providerId, enabled}` — provider-level toggle within a multi-provider extension |
| `/extensions/settings` | GET / POST | yes | `{autoUpdate, autoUpdateManaged, allowCommunityTier, allowUserRepositories, policyManaged, safeMode, legacyArtifactsPending, lastBackgroundRefresh?, developerMode, developerModeAllowed}`; POST `{autoUpdate?, developerMode?}` (`policy_denied` when managed). Turning developer mode off unloads developer extensions immediately. `lastBackgroundRefresh` = `{at, repositories, syncFailures, updated[], updateFailures[]}` from the periodic refresh (30 s after start, then every 6 h: sync top-level repositories, then auto-update when enabled) |
| `/extensions/developer/install` | POST | yes | Body `{path}`: absolute path of a regular `.cs3` file (no symbolic links, ≤ 32 MiB) the user picked. Requires developer mode; tier `developer`; a new import is committed **disabled**; re-importing replaces the version and keeps the enabled state |
| `/extensions/legacy/dismiss` | POST | yes | Forget pre-receipt cached artifacts that could not be matched |
| `/extensions/audit` | GET | yes | `?limit=` → `{verified, entries}` from the hash-chained audit log |
| `/search`, `/search/stream` | GET | yes | `?q=&plugins=` (`plugins` accepts provider IDs, names or installation IDs). Fan-out bounded to 8 concurrent providers |
| `/home` | GET | yes | `?plugin=&page=` (provider ID or unambiguous name) |
| `/details` | GET | yes | `?plugin=&url=[&refresh=1]`; cached 10 min per provider ID + URL |
| `/links`, `/links/stream` | POST | yes | Body `{"plugin", "data"}`; cached 3 min per provider ID + data. A link the Mac app cannot use never fails the extension's resolution: it is left out and listed in `skipped: [{source, name, reason}]` (`torrent`, `drm`, `invalid`; never the URL), on the response and on the stream's `done` event. Transport headers (`Host`, `Connection`, `Content-Length`, `Transfer-Encoding`, `TE`, `Upgrade`, `Trailer`, `Proxy-*`) are dropped from a link's headers. A ClearKey stream carries `drm: {kid?, key}` (lowercase hex) for the player's CENC decryption |
| `/links/verify/start` / `stop` | POST | yes | Verifier jobs are owned by the extension generation and cancelled when it is disabled, updated or removed |
| `/media/relay` | POST | yes | Body `{"resources":[{"url","headers"}]}` (1–33 validated HTTP(S) resources of one split stream) → `{sessionId, paths[]}` in request order. When four sessions exist, the least recently used one idle for at least 60 s without an open stream is evicted; 503 when none qualifies. Literal private, loopback and link-local addresses are refused, and resolved addresses are checked again at connect time; 400 for an invalid URL or header set, without echoing it |
| `/media/relay/revoke` | POST | yes | Body `{"sessionId"}`; its resources stop being readable at once |
| `/media/relay/{id}` | GET, HEAD | no (id) | Streams that one registered resource, fetched with its own headers. Only a single `Range: bytes=a-b` is taken from the caller; every other request header is ignored. Passes 200/206 with `Content-Type`, `Content-Length`, `Content-Range`, `Accept-Ranges`, `ETag`, `Last-Modified`; other upstream statuses are returned without a body. An HLS playlist or DASH manifest is rewritten so every URL it names (segments, keys, absolute DASH segment templates) is read through the relay; one that cannot be expressed that way (an unknown scheme, a template inside a host name) is refused with 415. `HEAD` on a manifest answers 200 with its content type. A non-identity `Content-Encoding` is refused with 502. Redirects are followed only to valid HTTP(S) URLs, and credentials are dropped when one leaves the resource's origin. Unknown, revoked or expired ids are 404 |
| `/lock` | GET, POST | yes | App lock state: `GET` → `{locked}`; `POST {"locked": bool}` sets it and returns `{locked}`. Locking drops solved challenge cookies and pending solves. While locked, every route except `/health`, `/lock`, relay reads and the download routes (`/links`, `/links/verify/start`, `/links/verify/stop`, `/media/relay`, `/media/relay/revoke`) answers 423 `{"error":"locked"}`. A new engine starts unlocked; the client re-sends the state once it is ready |
| `/diagnostics/export` | GET | yes | Redacted support bundle (extensions, repositories, audit, recent engine log) |
| `/extract` | POST | yes | Built-in extractors first, then the installed extension whose extractor matches the URL (its worker starts on demand); failures of routed calls are reported in `failures` |
| `/solve/*`, `/diagnostics`, `/settings/network*`, `/network/test`, `/test/run` | | yes | Unchanged from v3; network settings changes are pushed to running workers. `/settings/network` also carries `githubMirror` (fetch GitHub-hosted repositories through jsDelivr); a request without it keeps the current value |

## Worker protocol (engine ⇄ extension worker, ADR-0016)

Not an HTTP API: `daemon.jar --worker` speaks length-prefixed JSON frames
(4-byte big-endian length, ≤ 16 MiB) `{id, type, payload, error?, code?}` on its
stdin/stdout. Engine requests (positive IDs): `init`, `search`, `home`,
`details`, `links` (streamed `event` frames, then `result`), `extract`, `verify`,
`configure` (`{provider, url?, credentials?, clearCredentials = false}`; a null
credential is unchanged, `clearCredentials` removes the live one), `network`,
`cancel`, `shutdown`. Worker requests (negative IDs):
`solve` (anti-bot challenge; cookies are returned only to that worker). Replies
are `result` or `error` with the request's ID. Worker stdout carries only frames;
extension output goes to stderr, which the engine logs with a rate limit.

## Security invariants (enforced in code)

1. **SEC-01** — the Ktor server binds only `127.0.0.1`.
2. **SEC-02** — bearer token, constant-time comparison; token and launch options arrive via stdin. The one exception besides `/health` is reading a relay resource: the native player sends one header set to every origin of a stream and so must not hold the token. Its 256-bit random id is issued only to the authenticated client, names exactly one registered resource, and expires with its session (revoked by the player, idle for 15 minutes after its last stream ended, evicted when the relay is full, or engine exit).
3. **SEC-04** — every link passes `URLSanitizer` (`sanitizeStream` for playable media).
4. **SEC-06** — the daemon writes only under its data root (`cs.cloudstream.home`); the macOS app launches it inside the engine sandbox, where no other location is writable and user files are not readable.
5. **SEC-07** — only committed installation receipts authorize execution. Artifacts require a catalog SHA-256; verified catalogs require the signed chain; community catalogs require explicit consent; translated bytecode is hash-bound to the receipt.

## Contract history

- **v6 additions** (Security audit 2026-10, additive, no version bump): the engine is launched with port `0` and prints `CLOUDSTREAM-ENGINE-LISTENING {"port":N,"pid":P}` on its stdout once it listens; `/health` answers `X-CloudStream-Nonce` with `proof` (HMAC of the token); every response is `no-store`. Repository `tier` adds `"signed"` (signed by a key no policy pins; `"verified"` now means a policy-pinned key) and `consentRequired`; `/repos/consent` accepts signed repositories. Relay: up to 12 sessions; manifests with absolute DASH segment URLs or templates are rewritten instead of refused; `HEAD` on a manifest answers 200.

- **v6** (Audit remediation), additive: `/media/relay`, `/media/relay/revoke` and `GET`/`HEAD /media/relay/{id}` — per-resource request headers for split streams (audit A35). A client whose engine lacks them treats such a stream as unsupported.
- **v6 additions** (Compatibility-Fix-Plan, additive, no version bump): the split failure codes above, `skipped` and `drm` on link responses, `githubMirror` on network settings, `sharedProviderNames` on installed extensions, and status 3 (beta) catalog entries being installable.
- **v6** (Audit remediation): `/repos/register`; explicit `clearUrl` / `clearCredentials` on `/plugins/config` with `pending` / `retryable` in its response; `clearCredentials` on the worker `configure` request. The client requires `ipcVersion == 6`: an older engine would accept a clear request and silently keep the credential, so mixed pairs are refused instead. Download resolution now retries a typed `failure` by its `retryable` flag (no wire change).
- **v5** (Extensions runtime), additive: extractor routing (plan RT-12): a provider's `loadExtractor` reaches extractors shipped by other installed extensions, and `/extract` reaches stopped workers; new failure code `capacity` (503). Installed `/plugins` entries add `state: "ready"` (registered, process not started), `process`, and `health [{provider, providerId, stage, ok, code?, message?, at}]` for the installed version (plan RT-16). Native JavaScript media resolution (plan RT-11): `GET /media/pending` lists pages extensions' `WebViewResolver` asked to load; the app reports each request a page makes with `POST /media/observe {taskId, requests:[{url, method}]}` → `{known, stop}` and finishes with `POST /media/complete {taskId, scriptResult?, cookies{host: header}, userAgent?, pageUrl?}`. Extension settings (plan RT-15): `GET /plugins/preferences?installationId=` → `{fields:[{key, type, default?, value?, values?, isSet}], truncated}` (the extension's own preference keys, read from its code); `POST /plugins/preferences {installationId, updates:[{key, value?, values?, remove}]}` validates against that schema, saves, and restarts the extension. `/repos/sync` reports `skippedRepositories` for HTML discovery pages instead of dropping failed children silently (plan RT-10).
- **v5** (Extensions runtime), additive: `/plugins` entries carry `compatibility {profile, current, coreCode[], otherCode[], truncated}`, the host APIs the extension references that this engine lacks (static evidence from translation, assessed in the sandboxed worker; plan RT-05).
- **v5** (Extensions runtime): typed media-operation failures (`failure` record) replace the generic 502 "provider failure"; the client requires `ipcVersion == 5`.
- **v4** (Extensions remediation): installation IDs replace hashes/names on every lifecycle route; typed errors; tiers and consent; update/rollback/retry/updateAll; provider IDs on all result DTOs; provider-level enable and credential-free config persistence; extension settings, audit and legacy endpoints; background restore reported by `/health`; two-line stdin launch protocol.
- **v3** (Offline-Features-Plan): `/providers`, `/extract`, `/settings/network*`, `/network/test`, `/test/run`; optional metadata on `/details` plus the 10-minute details cache.
- **v2**: `/links` became POST; `/links/stream`, `/search/stream`.
