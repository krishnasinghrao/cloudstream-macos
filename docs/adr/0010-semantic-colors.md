# ADR-0010: Semantic system colors, both appearances

**Status:** Accepted (2026-09-29) · **Decides:** UI-Remediation-Plan DP-3

## Context

`DesignSystem.swift` shipped an "Apple TV" token sheet — hardcoded dark
hexes (`#0E0F11` canvas), `.white` text everywhere, a hardcoded `#0A84FF`
accent — invented font sizes (9–32 pt, fractional), hover scale-jumps,
and hand-built `.ultraThinMaterial` glass pills. The app was dark-only,
ignored the user's accent color, failed 4.5:1 contrast in metadata text,
and fought system rendering on macOS 26+.

## Decision

The UI is rebuilt on semantic system colors and the macOS type scale:

* Surfaces: `windowBackgroundColor` (canvas), `controlBackgroundColor`
  (inset cards), `separatorColor` (borders) — both appearances for free.
* Text: hierarchical label colors (`.primary/.secondary/.tertiary`),
  never raw white.
* Accent: the user's (`Color.accentColor` / asset catalog), never a
  hardcoded blue.
* Type: semantic styles only (`.largeTitle/.title3/.body/.callout/.caption`);
  the grep gate `font(.system(size:` over `Sources/UI` must return zero.
  (The player HUD, rendered over video, still uses explicit `Color.white`
  foregrounds — that is a media overlay, where bright-on-dark is correct.)
* Hover = background/border change, never `scaleEffect`; decorative
  transitions honor Reduce Motion.
* Glass is the system's job (sidebar/toolbar/sheets are automatic on
  macOS 26+); custom chrome uses standard materials with an availability
  path for `.glassEffect` when the deployment target allows.

Dark-only was the alternative; rejected because most of the app is
browsing UI, not immersive playback, and semantic colors give dark mode
plus light mode plus Increased Contrast for the same cost.
