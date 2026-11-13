# Changelog

All notable changes to CloudStream for macOS. Versions follow
[Semantic Versioning](https://semver.org); a release is published by pushing
a `v<version>` tag that matches `MARKETING_VERSION` in `client/project.yml`.

## 1.1.0

The first release with in-app updates. Copies of 1.0.0 have no updater, so
install 1.1.0 by hand once; later versions arrive through the app.

### Added

- **In-app updates** from GitHub Releases ([ADR-0007](docs/adr/0007-update-banner.md)):
  an Update Available row in the sidebar, CloudStream ▸ Check for Updates…,
  and Settings ▸ General ▸ Software Update. Nothing downloads until you choose
  Download. Every update is checked against the release's SHA-256 and its code
  signature (same bundle identifier, exact version, newer, runnable on this
  macOS) before an atomic swap with rollback.
- **Live channels** ([ADR-0022](docs/adr/0022-live-playback.md)): live identity,
  a cached-range timeline, Go Live, bounded reconnects with fresh links and
  live history.
- **Timeline thumbnail previews** while hovering or scrubbing the player
  (can be turned off in Settings ▸ Playback).
- **Library layouts**: By Artwork and Gallery; artwork-shaped cards (2:3, 16:9,
  1:1); card context menus on Home and Library; History grouped by Today and
  Yesterday.
- **Menu bar commands**: Lock CloudStream (⌃⌘L), Reload Page (⌘R), Play,
  Add to/Remove from Favorites (⌘D), Disable All Extensions, Search Other
  Providers.
- **Delete CloudStream** in Settings ▸ General ([ADR-0023](docs/adr/0023-delete-cloudstream.md)):
  removes everything CloudStream keeps on this Mac (library, profiles,
  extensions, settings, caches, logs, Keychain items, Spotlight entries) and
  moves the app to the Trash. It offers a backup first, and asks you to type
  `DELETE` and confirm with your Mac's password or Touch ID. Downloaded videos
  are kept unless you choose otherwise.
- Background release-year lookup for library titles that lack one.
- Profile icon picker and an avatar profile button in the sidebar.

### Changed

- Sidebar redrawn natively with Apple TV proportions and the new colour theme;
  native List selection restored.
- Details hero uses landscape artwork when that is all a title has; the title
  waits briefly for its logo instead of flashing.
- Player: Dolby Vision ranking, one failover for unseekable streams, exact
  audio-track memory, 4K render size.
- Engine & IPC v7: relay call ownership, rolling manifests, fresh links, and
  the provider's session cookies and User-Agent on stream links.
- Downloads: one header row, confirmed Cancel All, fuller row menus.

### Security

- Extension WebKit content is confined to public addresses through its own
  SOCKS5 egress proxy; loopback answers loopback Host names only; local
  artwork, subtitle and connectivity-test hosts are refused (security audit
  2026-11, findings H1, L1, L2).
- The engine and workers also trust the CA roots the Mac's keychain trusts,
  falling back to the JDK roots. Extensions that opt in with `@UnsafeSSL` skip
  verification as on Android; app, repository and DoH traffic stay verified.
- CI third-party actions are pinned to commit SHAs (L3).
- Portable builds use a checksum-pinned, signature-checked Temurin 17 runtime.

### Fixed

- Egress proxy tunnels no longer leak slots when an upstream dies.
- Preparing an update no longer hangs on `hdiutil`'s helper process.
- Duration and progress labels no longer crash on NaN or infinite values.
- Staging folders are cleaned up off the main thread.
- Workers resynchronise on stray stdout instead of exiting.

## 1.0.0

First public release.
