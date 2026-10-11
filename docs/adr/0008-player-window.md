# ADR-0008: Player presented in its own AppKit window

**Status:** Accepted (2026-09-29) · **Decides:** UI-Remediation-Plan DP-1

## Context

Playback was a full-window SwiftUI overlay inside the main window
(`RootView` ZStack). Consequences: the "Done" pill needed a hardcoded
80 pt leading offset to dodge the traffic lights, the main window's state
froze under the overlay, and the local key event monitor swallowed every
keyDown (⌘W/⌘Q/⌘Tab) app-wide while playing.

## Decision

Playback lives in a dedicated `NSWindow` owned by
`PlayerWindowController` (singleton, opened by `PlayerViewModel.play()`,
closed by `close()` / red button / Esc — all idempotent through the
window delegate).

* **AppKit `NSWindowController`, not a SwiftUI `Window` scene** — the video
  surface is already an `NSView` (`MetalVideoView`); a controller gives
  precise `styleMask`/fullscreen/title-visibility control, and a
  window-scoped local event monitor keyed on `event.window === playerWindow`
  that consumes exactly the shortcut matrix and passes everything else
  through.
* **Not `UtilityWindow`** — it hides when the app deactivates, which is
  wrong for video.
* The SwiftUI side (`PlayerScreenView`) is only the window *content*;
  window chrome (traffic lights, title, fullscreen) is the system's.

## Consequences

* No hardcoded chrome offsets anywhere in the player UI.
* The main window survives playback (selection, scroll, search state).
* Keyboard: Space/arrows work only while the player window is key; typing
  anywhere is never eaten; ⌘W closes the player, ⌘Q quits the app.
* Fullscreen state flows from the delegate into `PlayerViewModel.isFullScreen`.
