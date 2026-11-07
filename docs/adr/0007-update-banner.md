# ADR-0007: in-app updates from GitHub Releases

**Status:** Accepted, implemented (November 2026). Supersedes the earlier
"signed `latest.json` + banner linking the DMG" plan, which was never built.

## Decision

The app updates itself from the project's GitHub Releases, with no
third-party framework (Sparkle stays out, keeping the zero-dependency posture).

- **Check** — `GET api.github.com/repos/{CSUpdateRepository}/releases/latest`
  (Info.plist names the repository). Drafts, pre-releases and non-semver tags
  are ignored; a release must be newer than the running version. Automatic
  checks run 20 s after launch when the last one is 12 h old, then every 12 h;
  Settings ▸ General ▸ Software Update turns them off. Debug builds and
  isolated (test) runs never check.
- **Offer** — a compact row directly above the profile button in the sidebar
  (Download), and the same state in Settings. Closing the row skips that
  version; a newer one shows again, and Settings always offers it.
  CloudStream ▸ Check for Updates… checks and shows the result in Settings.
- **Download** — HTTPS through an ephemeral session to `github.com`,
  `api.github.com`, `objects.githubusercontent.com` and
  `release-assets.githubusercontent.com` only, including every redirect; the
  size must match the release asset; progress is shown; cancellable.
- **Verify and stage** (`UpdateInstaller.prepare`) — the disk image's SHA-256
  must equal GitHub's asset digest and/or the release's `CloudStream.dmg.sha256`
  (both must agree when present). The image is mounted read-only and hidden; it
  must contain exactly `CloudStream.app` with this bundle identifier, exactly
  the release's version, newer than this one, and a minimum macOS this Mac
  meets. Its code signature is validated strictly and deeply; a Developer ID
  build requires the same team (no downgrade to ad-hoc). The app is copied
  beside the installed one, on the same volume, and verified again.
- **Install** — only once quitting is certain (`applicationWillTerminate`,
  after the engine has stopped and progress is saved): one atomic
  `renamex_np(RENAME_SWAP)` exchanges the folders. Restart relaunches the new
  version; an ordinary quit installs without relaunching. If the swap fails,
  the current version stays (and Restart still relaunches it); Settings
  explains at the next launch. The previous version is removed at the next
  launch.
- **Where it can't replace itself** — running from a disk image, under App
  Translocation, or from a folder the user can't write to — Download opens
  the release page instead and Settings says why.

## Consequences

- Releases must publish `CloudStream.dmg` and `CloudStream.dmg.sha256` from a
  `v*` tag whose version equals `MARKETING_VERSION` (the release workflow
  already guarantees all three).
- Copies of 1.0.0 have no updater: the first release that ships it has to be
  installed by hand once.
- Trust is GitHub's: anyone who can publish a release on the repository can
  ship an update to ad-hoc builds. Developer ID builds additionally pin the
  signing team. An offline release-signing key (Sparkle-style EdDSA) would
  remove that dependency; it was left out because CI would have to hold the
  key, which gives little over GitHub's own account security.
- Ad-hoc signatures change with every build, so after an update macOS may ask
  once again for Keychain access that the previous build had been granted.
