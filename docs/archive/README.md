# Documentation archive

Records kept for history. Nothing here describes current work or the current
design: the open work is in [Remaining-Work](../Remaining-Work.md) and the
current reference documents are listed in the [docs index](../README.md).

Treat these files as read-only. Paths, line numbers and version numbers in
them are from the time they were written, often before this repository was
split out of the CloudStream fork (where the app lived under `macos/`, the
engine was `macos/daemon` and the library was multiplatform). New findings go
into a new document, not into these.

## Plans and status trackers (`plans/`)

| Area | Plan | Status / evidence |
| --- | --- | --- |
| October 2026 audits (code quality, security) | [Audit-Fix-Plan](plans/Audit-Fix-Plan.md), [Remediation-Plan-2026-10](plans/Remediation-Plan-2026-10.md) | [Audit-Traceability](plans/Audit-Traceability.md) |
| Audit remediation (53 findings) | [Audit-Remediation-Implementation-Plan](plans/Audit-Remediation-Implementation-Plan.md) | [Audit-Remediation-Status](plans/Audit-Remediation-Status.md) |
| Adversarial QA (17 defects) | in the audit report | [Adversarial-QA-Status](plans/Adversarial-QA-Status.md) |
| Extension runtime | [Extensions-Runtime-Implementation-Plan](plans/Extensions-Runtime-Implementation-Plan.md) | [Extensions-Runtime-Implementation-Status](plans/Extensions-Runtime-Implementation-Status.md), [Extensions-Live-Matrix](plans/Extensions-Live-Matrix.md) |
| Extensions and repositories | [Extensions-Remediation-Plan](plans/Extensions-Remediation-Plan.md) | in the plan |
| Verified defects | [Implementation-Plan](plans/Implementation-Plan.md) | in the plan (superseded) |
| Hardening | [Remediation-Plan](plans/Remediation-Plan.md) | in the plan (superseded) |
| Player | [Player-Remediation-Plan](plans/Player-Remediation-Plan.md) | in the plan |
| UI and platform | [UI-Remediation-Plan](plans/UI-Remediation-Plan.md) | implemented |
| Offline features | [Offline-Features-Plan](plans/Offline-Features-Plan.md) | implemented |
| Siri integration | [Siri-Integration-Plan](plans/Siri-Integration-Plan.md) | draft, never built |
| Manual testing notes & to-dos | [To-dos](plans/To-dos/to-dos.md) | bugs fixed; features in ADR-0020/0021 |
| Original phases | [Roadmap](plans/Roadmap.md) | superseded |
| Original build blueprint | [Implementation](plans/Implementation.md) | superseded by [Architecture](../Architecture.md) and [Maintenance](../Maintenance.md) |

Code comments still cite these plans by name and item (for example
"Offline-Features-Plan Phase 3"); look them up here. "Remediation n.n" in a
code comment is an item of [Remediation-Plan-2026-10](plans/Remediation-Plan-2026-10.md),
and "security audit M2" a finding of the
[October security audit](audit/macos-security-audit-2026-10.md).

## Audit reports (`audit/`)

The frozen inputs to the plans above: the
[engineering audit](audit/macos-engineering-audit-2026-10-01.md) with its
[traceability table](audit/macos-remediation-traceability.csv), the
[app audit](audit/macos-app-audit-2026-10-01.md), the October
[code-quality audit](audit/macos-code-quality-audit-2026-10.md) and
[security audit](audit/macos-security-audit-2026-10.md), the
[adversarial QA audit](audit/macos-adversarial-qa-audit-2026-10-04.md), the
[extension runtime audit](audit/extension-runtime-2026-10-01/) and the
[extensions repository audit](audit/extensions-repository/). Some of their
evidence links point at files on the machine where the audit ran and do not
open elsewhere.
