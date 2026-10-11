# CloudStream macOS documentation

Start with the [project README](../README.md) for building and running. This
page says which document answers which question. Everything listed here
describes the app as it is now. Finished plans, status trackers and audit
reports are kept for history in [archive/](archive/README.md).

## Reference

| Document | Read it for |
| --- | --- |
| [Context](Context.md) | What the app is and why it exists |
| [Maintenance](Maintenance.md) | Code layout, compatibility boundaries and local checks |
| [Architecture](Architecture.md) | The three tiers (client, engine, workers), process lifetimes, data flow |
| [Design](Design.md) | Visual and interaction design system |
| [Security](Security.md) | Assets, trust boundaries, threat model |
| [Rules](Rules.md) | Engineering and AI-policy rules for contributions |
| [Dependency-Review](Dependency-Review.md) | Licence and advisory decisions for the engine's packed dependencies |

## Contracts

| Document | Read it for |
| --- | --- |
| [ipc-api](ipc-api.md) | The client ↔ engine HTTP/NDJSON contract (`ipcVersion`) |
| [repository-signing](repository-signing.md) | `cloudstream-json-v1` signing profile |
| [repository-transport](repository-transport.md) | How repositories are fetched and ingested |
| [help/extensions](help/extensions.md) | User-facing extension help |
| [qa-ui-checklist](qa-ui-checklist.md) | Manual regression pass before a release |

## Decisions

Architecture decision records live in [adr/](adr/), numbered in the order they
were taken (0001 mpv render backend … 0021 library pages). Add a new
record rather than editing an accepted one.

## Open work

[Remaining-Work](Remaining-Work.md) is the single list of what is left to do,
in order. Active working plans in progress remain at the root until finished:
- [Compatibility-Fix-Plan](Compatibility-Fix-Plan.md) — compatibility, playback, and UI fixes

A new piece of work gets a plan while it is in progress, and the plan moves to
the archive when it is done.

## Archive

[archive/](archive/README.md) holds the dated plans, status trackers and audit
reports this app was built from. They are read-only records of one point in
time; paths and line numbers in them can differ from today's layout.
