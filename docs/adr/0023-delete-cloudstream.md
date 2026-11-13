# ADR-0023: Delete CloudStream — a complete, guarded uninstall

**Status:** Accepted. 2026-11-13. Not yet run end to end on a real install
(it ends by deleting the app); see "Verification" below.

## Context

CloudStream is not sandboxed (SEC-05: it starts the bundled JRE and ffmpeg),
so dragging the app to the Trash leaves its data behind in about ten places:
the engine's home `~/.cloudstream-macos`, the SwiftData stores (one per
profile) and their recovery snapshots in Application Support, automatic
backups, image and URL caches, HTTP storage, WebKit data, logs, the
preference domain, saved window state, two Keychain services, Spotlight
entries and delivered notifications. People had no reliable way to find
them all.

## Decision

**Settings ▸ General ▸ Delete CloudStream…** opens a three-step sheet
(`DeleteCloudStreamView`):

1. **Review.** Every category that exists, with its size on disk, and what is
   kept. Downloaded videos are kept unless the person turns on "Also delete
   the videos I downloaded"; screenshots are always kept.
2. **Back up.** Continue is disabled until the person saves a backup (to a
   place outside the folders being deleted) or ticks "I don't need a
   backup…". A backup holds one profile, so other profiles are named with
   instructions to back them up first.
3. **Confirm.** Type `DELETE` (case-sensitive), then authenticate with the
   Mac's password or Touch ID. A Mac with no password set relies on the typed
   word alone.

`Uninstaller.perform` then runs, in this order, so nothing is recreated and
nothing is lost if an early step fails:

1. Stop everything that writes (`ApplicationShutdown`, without saving
   progress), and cancel an update download.
2. Start `UninstallScript` (`/bin/sh`, detached). It waits for CloudStream to
   exit, runs `defaults delete` on the bundle's domain (so cfprefsd forgets it
   too) and removes the listed paths. If it can't start, nothing has been
   deleted, and the person is told to reopen CloudStream.
3. Remove what only the app's own process can: the Keychain items of
   `ProviderCredentialStore` and `ProfileLockSecurity`, Spotlight entries,
   notifications.
4. Move the app bundle to the Trash (`FileManager.trashItem`, so Finder's
   Put Back works). From a disk image, an App Translocation copy or a
   folder the person can't write to, an alert asks them to remove it by hand.
5. `exit(0)`: the normal quit path would write progress and preferences again.

**What may be deleted is a fixed list, checked twice.** `UninstallFootprint`
names each location; the SwiftData store files are matched by an exact
pattern, and the generically named `IdentityRecovery` folder is listed only
when it holds nothing but CloudStream snapshot folders. Downloads are only
the files recorded in the downloads store (each video, its subtitle sidecars,
and `.part` files with their resume record), never folders.
`isSafeToDelete` refuses relative paths, `..`, the home folder, its standard
folders (Library and its standard subfolders, Movies, Downloads, Documents,
Desktop, Pictures, the Trash) and system roots, and anything outside the home
folder except recorded downloads on `/Volumes/<drive>/…`. The script receives
paths as arguments, never as script text, quotes every use, and removes a
symbolic link rather than what it points to.

**Isolated launches never touch real data.** Under `CS_IN_MEMORY_DB` or a test
host, the footprint is computed for the isolated root, and `perform` refuses.

## Consequences

- A complete uninstall is one place in Settings, with the backup offered
  before anything is removed.
- The app's own deletion is reversible from the Trash until it is emptied;
  the data deletion is not, which is why the backup step cannot be skipped
  silently.
- New storage locations must be added to `UninstallFootprint` and to
  `UninstallerTests.testListsEveryExistingLocationAndNothingElse`.
- Not removed: screenshots, downloads unless chosen, backups the person saved
  elsewhere, and copies of CloudStream other than the running one.

## Verification

`UninstallerTests` covers the footprint (every location, nothing beside it),
the path guards, download companions, the script (waits for the app, deletes
the preference domain, treats hostile file names as data, does not follow
links) and the app-location rules. `DeleteCloudStreamUITests` drives the
three steps and their guards without pressing the final button. The full run
(Keychain, Spotlight, the Trash move and the post-quit script against a real
install) needs a manual check on a spare user account or a test Mac.
