# Repository signing profile

The native verifier implements `cloudstream-json-v1`. This is a deliberately restricted canonical JSON profile, not an implementation of RFC 8785. An Ed25519 signature authenticates the canonical root object after removing its top-level `signature` member.

The `signature` object contains string members `algorithm` (`ed25519`), `publicKey` (Base64-encoded raw 32-byte Ed25519 public key), and `value` (Base64-encoded 64-byte signature). Its optional string `format` must equal `cloudstream-json-v1`; omission selects that profile for compatibility with existing signed roots. Explicit null and unknown formats are rejected, as is any other member in the `signature` object.

Canonical bytes use UTF-8 without a byte-order mark or trailing newline:

1. Sort object keys lexicographically by UTF-16 code units at every depth. Preserve array order. Omit insignificant whitespace.
2. Preserve string Unicode scalar values without normalization. Reject unpaired surrogates. Escape quotation marks and backslashes, use the short JSON escapes for backspace, form feed, newline, carriage return and tab, and lowercase `\u00xx` for the other U+0000–U+001F controls. Do not escape slashes or ordinary non-ASCII characters.
3. Serialize booleans and null as their lowercase JSON literals.
4. Accept only integer number tokens within −9007199254740991 through 9007199254740991. Reject fractional and exponent syntax. Canonicalize negative zero to `0`.

For example, input `{"b":1,"a":"x"}` produces bytes for `{"a":"x","b":1}`. Publishers must use an encoder matching these rules; arbitrary language-default JSON serialization is not sufficient.

A first-use signing key establishes continuity, not independently verified publisher identity. Once a key is pinned, a missing signature, invalid signature, different key, or HTML response cannot replace it. Explicit re-trust validates the complete candidate sync before replacing saved trust; failure leaves the prior pin and catalog intact. A result also cannot commit over a repository entry changed while that sync was fetching.

## Authenticated catalog chain and freshness

Signed manifests must also contain:

- `catalogVersion`: a positive monotonic integer, separate from the schema's `manifestVersion`.
- `expiresAt`: an ISO-8601 UTC instant, later than sync/installation time and no more than 30 days ahead.
- `pluginListHashes`: an object mapping each exact string in `pluginLists` to the SHA-256 of that list's exact UTF-8 bytes. Every list must appear exactly once, with no extra entries.

Every entry in an authenticated list must provide a valid artifact `fileHash`. The verifier checks the root signature, list byte digest, and source artifact byte digest. Redirects can change retrieval and relative-resolution locations; they cannot change accepted list or artifact bytes.

The daemon atomically stores the root, original list bodies and effective bases, signing key, highest accepted catalog revision, and canonical root digest. Lower revisions and different root bodies reusing the same revision are rejected. Identical revisions are idempotent. Trust anchors survive catalog removal and restart. Explicit key rotation still obeys the revision policy. A failed candidate, rotation or stale sync does not replace the current anchor.

Freshness is required for new installations. Previously accepted cached evidence can retain authenticity after expiration for offline loading; no online revocation freshness is implied. Persisted `signed` flags and normalized display metadata alone cannot authorize execution: the root and original list bytes are reverified against the durable trust anchor. Source digests are checked again at the loader boundary.

## Trust tiers

Repositories fall into two tiers:

- **Verified** — a signed catalog under this profile. Installs require fresh evidence; receipts record the signed root and exact list bytes. An organization can pin a repository's key by policy (`ExtensionsPinnedRepositoryKeys`), which overrides first-use trust and forbids rotation from the app.
- **Community** — an unsigned catalog (the format every existing CloudStream repository publishes). It is browseable immediately; installing requires explicit per-repository consent in the app. Every entry still needs a valid SHA-256 `fileHash`; entries without one are shown but not installable. The receipt records the exact list bytes and the consent it was accepted under. Withdrawing consent blocks new installs and updates from that repository; extensions already installed keep running until they are uninstalled. An organization can disable this tier (`ExtensionsAllowCommunityRepositories = false`), which also stops community extensions from loading.

- **Developer** — a local `.cs3` imported in developer mode (off by default). Not verified by any repository; the receipt binds the imported bytes. A new import starts disabled; developer extensions stop loading when developer mode is turned off. An organization can forbid them (`ExtensionsAllowDeveloperExtensions = false`), and an allow-list of repositories also excludes them.

A repository that ever had a trust anchor, or that policy pins, can never be read as community, so stripping a signature cannot downgrade it (F14). Root and list parsing reject duplicate decoded keys, excessive structure, malformed UTF-8 and invalid Unicode for both tiers.

## Publishing a verified repository

The daemon jar includes the signer used by the verifier's tests:

```sh
java -cp daemon.jar com.lagradost.macos.tools.RepositorySigner keygen repo.key
# publish repo.key.pub (raw Ed25519 public key) out of band; keep repo.key private
java -cp daemon.jar com.lagradost.macos.tools.RepositorySigner sign repo.json repo.key 1 14
```

`sign` reads the lists named in `pluginLists` (relative paths, resolved next to the manifest), refuses entries without a valid `fileHash`, binds each list by SHA-256, sets `catalogVersion` and an `expiresAt` of at most 30 days, signs the canonical root and verifies the result with the production verifier. Increase `catalogVersion` on every publication and re-sign before expiry; clients reject lower or reused revisions. Publish the list files byte-for-byte as signed.

## Key rotation

Rotation is an explicit user action (Extensions → repository → Trust New Signing Key…). The candidate key must deliver a complete, valid catalog before it replaces the pin; on failure the old pin and catalog stay. After rotation, installed extensions whose artifact bytes are unchanged receive new evidence under the new key; others are disabled ("revoked") until updated or removed.

## Release status

Signed-chain, expiry, replay, rotation, removal, community-consent and policy-pinning behavior are covered by the daemon suite (`CatalogTrustTest`, `RepositoryTrustTest`, `InstallationLifecycleTest`, `RepositorySignerTest`). Committed installation receipts, transactional generations, hash-bound translated bytecode and the engine sandbox are implemented; the verification record is in [Extensions-Remediation-Plan](archive/plans/Extensions-Remediation-Plan.md) and open work is in [Remaining-Work](Remaining-Work.md).
