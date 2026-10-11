# ADR-0003: per-architecture DMGs; JRE selected at runtime

**Status:** Accepted

A universal DMG would exceed the 95 MB budget (dual JREs alone). We ship
per-arch DMGs from CI (arm64 / x86_64 runners). The bundle layout still allows
`runtime-<arch>` directories selected by `DaemonSupervisor.hostArchitecture`,
falling back to a single `runtime` — so a universal bundle remains possible
later without client changes. Rules.md §3 budget note: compressed DMG target
applies per architecture.
