# ADR-0007: update story — signed banner, no auto-install

**Status:** Accepted

v1 checks a signed `latest.json` on GitHub Releases, compares semver, and
shows an update banner linking the DMG (no silent install). Sparkle adoption
deferred — banner keeps the zero-third-party posture and works before
notarization credentials exist.
