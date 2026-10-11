# ADR 0018: User-owned repositories and truthful artifact provenance

Date: 1 October 2026. Status: accepted for implementation; migration and release validation pending.

The Android ecosystem permits catalogs without artifact digests. The macOS rule excludes 137 of 170 active entries in the six compiled suggestions examined by the audit. Keeping that rule cannot satisfy broad compatibility with user-selected community repositories.

Start fresh installations with no repository choices. Remove compiled recommendations, source aliases, replacement URLs, and publisher-specific offline blocks. Retain repositories already saved by the user. Ordinary shortcodes resolve through cutt.ly and !codes through py.md; explicit URLs retain their identity subject to generic HTTPS, redirect, size, and policy validation.

Allow unsigned catalogs only after per-repository consent and policy checks. When a publisher digest is declared, require valid SHA-256 formatting and matching bytes. Valid signed chains retain all signature/catalog binding guarantees. Signature failures and digest mismatches never fall back to a weaker mode.

For a consented hashless catalog, compute the downloaded bytes' SHA-256 and persist an explicitly named local-observation proof bound to the exact accepted entry and resolved artifact identity. Do not modify the publisher metadata to fabricate a digest. Bound temporary download size, atomically publish content-addressed bytes, and verify those bytes again on restart. A subsequent download is a new candidate with new evidence.

Version proofs and migrate state schema 2 to 3 with readers for existing signed/community receipts. Preserve transactional install/update/rollback/restore guarantees. Present publisher-digest, signed-catalog, and local-observation evidence accurately in native consent/status UI and support documentation. Managed policy can restrict community sources and weaker artifact modes.

This decision supersedes Rules SEC-07 and the mandatory publisher-digest choice in the historical remediation plan for consented legacy catalogs. Verification of exact executing bytes remains mandatory. See [implementation plan](../archive/plans/Extensions-Runtime-Implementation-Plan.md).
