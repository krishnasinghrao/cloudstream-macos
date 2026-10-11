# Extensions: trust, updates and safe mode

CloudStream finds content through **extensions** published in **repositories**.
Extensions are code written by third parties, so CloudStream runs them inside
the macOS sandbox, which keeps them out of your documents, keys and other apps'
data.

## Verified and Community repositories

- **Verified** repositories are signed by their publisher. CloudStream
  remembers the publisher's key the first time; if the key ever changes, installs
  stop until you compare the old and new fingerprints and choose
  **Trust New Signing Key…**.
- **Community** repositories are not signed (most existing repositories). You
  can browse them right away. To install from one, choose **Allow Installs…**
  for that repository. CloudStream checks publisher SHA-256 digests when
  provided. For an extension without one, it records the downloaded bytes'
  SHA-256 locally and checks those same bytes again before execution. A local
  byte record does not verify the publisher; a changed download creates a new
  receipt. Invalid declared digests or signatures still block installation.
  **Stop Allowing Installs** blocks new installs and updates; extensions you
  already installed keep working until you uninstall them.

## Extensions from files (developer mode)

Extension authors can test a build without publishing it: turn on
**Settings → Advanced → Developer mode**, then choose **Install from File…** on
the Extensions screen. The extension is marked **Developer**, starts disabled,
and stops loading when you turn developer mode off.

## Updates

Open **Extensions** and choose **Update** on an extension, or **Update All**.
With **Update extensions automatically** on, CloudStream checks your
repositories shortly after it starts and every six hours, installs updates and
shows a notification. Each update keeps the previous version:
**Restore Previous Version** rolls back in one step.

If a publisher withdraws an extension, CloudStream stops it and explains why.

## When an extension misbehaves

- **Retry** reloads an extension that failed to start.
- An extension that was loading when the engine stopped is **quarantined** and
  stays off until you choose **Retry**.
- **Safe mode** starts CloudStream without loading any extension, so you can
  disable or uninstall the one causing trouble. Hold **⌥ Option** while
  CloudStream opens, or choose **Settings → Advanced → Restart in Safe Mode**.
  CloudStream also enters safe mode after the engine stops twice within a
  minute. Choose **Restart Normally** to leave it.

## Managed Macs

If your organization manages CloudStream, some choices (allowed repositories,
Community repositories, automatic updates, safe mode) may be fixed and marked
**Managed by your organization**.
