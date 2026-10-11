# ADR-0014: App lock via system owner authentication

**Status:** Accepted (2026-09-30) · **Decides:** Offline-Features-Plan Phase 7.3

## Context

Users asked for a lock on the app and on individual profiles (kids,
shared Macs). A custom PIN would mean storing and protecting a secret,
rate-limiting guesses, and a recovery path.

## Decision

Use LocalAuthentication's `.deviceOwnerAuthentication` policy — Touch ID
when available, otherwise the Mac account password. The app stores no
secret, only booleans (global lock, per-profile lock) and an idle timeout.

* Locks on launch, after the idle timeout in the background, when the
  display sleeps or the user session switches, and before switching into a
  locked profile. Locking closes the player (saving progress).
* The lock screen covers the main window **and** Settings (which can export
  backups and delete profiles). The Dock menu, menu bar extra, URL links,
  Spotlight results, Handoff and App Intents all route through
  `AppState.perform`, which ignores routes while locked.
* Enabling a lock first requires a successful authentication, so it can
  never be switched on for a Mac that cannot authenticate.
* Authentication is behind a test seam; unit tests never prompt.

## Consequences

* No PIN storage, brute-force handling or recovery flow to get wrong; the
  OS owns all of it.
* It is a privacy screen, not encryption: the SwiftData files on disk are
  protected only by the user account and FileVault. The Settings footer
  says so.
* Anyone who knows the Mac password can unlock — intended for a shared
  family Mac, not for hostile users.
