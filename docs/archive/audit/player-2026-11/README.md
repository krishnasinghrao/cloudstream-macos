# Player audits, November 2026

Three audits of the video player, written during the `sprint-experimental`
sprint against commit `a23a928`. They are the input to
[ADR-0022](../../../adr/0022-live-playback.md) and to the reconciliation
recorded in [Sprint-Reconciliation-2026-11-12](../../plans/Sprint-Reconciliation-2026-11-12.md),
which says, finding by finding, what `main` took, what it rebuilt and what it
left out.

| Report | Scope |
| --- | --- |
| [video-player-audit-2026-11-01](video-player-audit-2026-11-01.md) | Picture: resolution, HDR, tone mapping, presentation timing, per-load state (13 findings) |
| [audio-video-redteam-2026-11-02](audio-video-redteam-2026-11-02.md) | Audio output, buffering, recovery, rendering and concurrency (F01–F25) |
| [live-playback-audit-2026-11-01](live-playback-audit-2026-11-01.md) | Live channels: identity, timeline, recovery, relay lifetime (15 findings) |

The machine-readable evidence the reports cite (`results.json`,
`review-snapshot.json`, the probe scripts) was not copied: it stays under
`docs/audit/` on the `sprint-experimental` branch.
