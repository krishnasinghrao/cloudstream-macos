# ADR-0005: repository authenticity via Ed25519 + TOFU pinning

**Status:** Accepted

repo.json may carry `signature {algorithm, publicKey, value}` over the
canonical body (signature member removed, keys recursively sorted, compact
UTF-8). First sync pins the key (fingerprint shown in Settings); later syncs
verify; key change hard-refuses until explicit re-trust (`/repos/trust`).
Unsigned repos remain usable but badged Unverified. Reference implementation
and tests: `RepoSignature`, `RepoSignatureTest`.
