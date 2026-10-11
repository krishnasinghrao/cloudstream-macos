# UI QA Checklist (macOS)

Manual regression pass for the UI remediation (UI-Remediation-Plan §WS-L
U-75). Run before each release cut and after any player/settings change.

## Keyboard & menus

- [ ] Type "star wars" (with spaces) into Search — no playback toggle fires, spaces appear.
- [ ] Arrow keys move the text cursor in every field.
- [ ] ⌘1/2/3/4/5/6 jump to Home/Watching/Plan/Favorites/Completed/Downloaded; ⇧⌘E opens Extensions.
- [ ] ⌘, opens the standard Settings window; tabs switch.
- [ ] During playback: Space pauses, ←/→ seek 10 s, ↑/↓ volume, F fullscreen, M mute, Esc exits fullscreen then closes.
- [ ] During playback: ⌘W closes only the player; ⌘Q quits the whole app; ⌘Tab switches apps.
- [ ] Playback menu items are disabled (not hidden) with no session.
- [ ] ⇧⌘N / ⇧⌘M work for next-episode/mute; File ▸ New Window (⌘N) and Window ▸ Minimize (⌘M) still work.

## Player window

- [ ] Play opens a separate window; main window stays alive behind it with its state.
- [ ] No overlap between the Done/title controls and the traffic lights (windowed and fullscreen).
- [ ] Window title shows "Title — S1, E2" for series.
- [ ] Green button / F / double-click fullscreen; controls adapt.
- [ ] Resume: start an episode mid-way, close, reopen — playback resumes (no silent restart at 0:00).
- [ ] Multi-subtitle episode: all subtitle tracks appear in the captions menu.
- [ ] Subtitle color Yellow/Cyan/Green render visibly and correctly.
- [ ] No PiP button in the HUD.
- [ ] Continuous Playback OFF (Settings ▸ Playback): episode end closes the player. ON: next episode auto-starts.

## Library & Home

- [ ] Add a title to any of the five watch states; each appears under its sidebar collection (incl. On Hold and Dropped — nothing vanishes).
- [ ] Home updates within ~a beat of any library mutation without scroll jumps.
- [ ] "0m left" never appears; unknown-duration items show position only; <1 min shows "<1m".
- [ ] "Mark as Watched" moves the title to Completed and clears its resume position.
- [ ] Library "Date Added" differs from "Recent Activity" for old entries; "Release Year" keeps titles without a year last in both directions.
- [ ] Library sort, direction and type/provider filters survive leaving the page and relaunching, separately per collection.
- [ ] Dragging a library card rearranges smoothly, switches the sort to "Custom Order", and the order survives relaunch; releasing outside the window leaves no hidden card. "Move to Beginning/End" in the card menu does the same without the mouse.
- [ ] The Home library shelf remembers its collection across relaunch and shows it in that collection's sort, custom order included.
- [ ] A source picked in the player's Quality & Mirrors menu is tried first the next time that title plays; automatic failover does not change it.
- [ ] Sort menu is a single picker (no nested blue "Sort By ›" submenu).

## Search

- [ ] Toolbar search field (not an in-content fake); ⌘F focuses it on the Search screen.
- [ ] Suggestions navigate with ↑/↓ and Return; Esc dismisses.
- [ ] Results with non-ASCII titles (é, 中, emoji) render correctly.
- [ ] Failed providers show a "Some providers failed: …" note.

## Downloads

- [ ] Segmented control switches Queue / Downloaded Titles.
- [ ] Active downloads show speed + ETA (ETA only when duration is known).
- [ ] Pause/resume/cancel work; cancel removes the partial file.
- [ ] Delete asks for confirmation and names the file.
- [ ] Queueing the same episode twice is refused with a visible message.
- [ ] A title with "/" in the name (e.g. "Face/Off") downloads to a valid file.
- [ ] Quit the app mid-download: no ffmpeg process survives (Activity Monitor).

## Extensions & Settings

- [ ] Toggle/uninstall/sync failures surface as an error banner (test: stop engine, toggle).
- [ ] Uninstall / remove repository ask for confirmation.
- [ ] Sync shows a spinner while running.
- [ ] Settings ▸ Clear Cache clears disk *and* memory cache (posters reload).

## Watch history & playback (Offline-Features Phases 1, 4, 5)

- [ ] Detail page: watched episodes show a tick, part-watched ones a progress bar; context menu marks watched/unwatched and "all previous".
- [ ] Reopening a part-watched episode offers Resume / Start Over.
- [ ] Play picks the next unwatched episode; finishing the last one moves a library title to Completed.
- [ ] Up Next countdown appears near the end; Play Now and Cancel work; ring is static with Reduce Motion on.
- [ ] Skip Intro / Credits appears from chapters or a marked intro; S skips.
- [ ] Audio/subtitle language and subtitle delay are remembered per show after relaunch.
- [ ] Drag a .srt/.vtt/.ass onto the player — it loads and is selected.
- [ ] Player ▸ tools ▸ Open In lists only installed players; IINA/mpv open with the right position and title.
- [ ] Sleep timer stops playback; screenshot lands in the chosen folder.

## Network & metadata (Phases 2, 3)

- [ ] Settings ▸ Network: switching DNS applies without restart; Test Connection reports each provider.
- [ ] Wi-Fi off: offline banner appears, downloads pause; Wi-Fi on: they resume on their own.
- [ ] Detail page shows recommendations, trailer, airing status/next episode where the provider has them; ⌘R reloads.

## Library, discovery & history (Phase 6)

- [ ] Home ▸ Discover shows the selected provider's homepage; providers without one are not offered.
- [ ] Search type filters (Movies/Series/Anime…) narrow results.
- [ ] Library filters and bulk select (move status, remove) work on 100+ items.
- [ ] "N NEW" badge appears on a followed show after a new episode; notification fires once.
- [ ] History (⌘Y) lists recent episodes; stats are plausible; notes and personal rating persist.

## Backup, profiles & lock (Phase 7)

- [ ] File ▸ Export Backup, then Import (Merge) on a fresh profile restores library, ticks and per-show settings.
- [ ] Import (Replace) asks twice and writes a safety backup first.
- [ ] Importing a CloudStream Android backup brings in bookmarks, favorites and resume positions.
- [ ] Profiles: create, rename, change icon, switch — each has its own library; downloads are shared.
- [ ] Lock on: relaunch shows the lock screen; Touch ID/password unlocks; cancelling stays locked.
- [ ] While locked: Settings window is covered, menu bar shows "CloudStream is locked", Dock menu is empty, a `cloudstreamapp://continue` link does nothing.

## Diagnostics (Phase 8)

- [ ] Settings ▸ Diagnostics ▸ Test All Providers streams results; Stop cancels; Copy Report copies text.
- [ ] "Disable N Failing" disables only failing providers.
- [ ] Log viewer switches Engine/App, filters, "Problems only" works; exported file contains no tokens or cookies.

## macOS integration (Phase 9)

- [ ] Spotlight: typing a library title shows it; choosing it opens its page. Turning the setting off removes results.
- [ ] Menu bar extra lists Continue Watching and download status; can be hidden in Settings.
- [ ] Dock icon badge shows downloads in flight; Dock menu resumes a title.
- [ ] Handoff: a title page open on one Mac appears on another signed into the same Apple Account.
- [ ] Shortcuts app shows "Continue Watching" and "Search CloudStream".
- [ ] Help ▸ Keyboard Shortcuts (⌘/) lists shortcuts that actually work.

## Deep links

- [ ] `open "cloudstreamapp://search?q=dune"` searches; `cloudstreamapp://continue` resumes the latest title.
- [ ] `cloudstreamrepo://`, `cloudstream://`, `cs.repo://`, `cs3://` links open the Add-Repository sheet prefilled.
- [ ] `cloudstreamplayer://<query>` opens Search and runs the query.

## Appearance & accessibility

- [ ] Both light and dark appearances are coherent (no white-on-white, no stranded dark cards).
- [ ] Accent color follows System Settings (try graphite + multicolor).
- [ ] Reduce Motion: no scale/bounce animations.
- [ ] Increase Contrast: text remains legible (no tertiary-on-tertiary).
- [ ] VoiceOver: poster cards announce title; scrubber is adjustable (±10 s); all icon buttons have labels.
- [ ] Full Keyboard Access: Tab reaches sidebar, cards, and HUD controls.

## Extensions (plan T7.8)

- [ ] VoiceOver reads every extension row as name, version, state chip and tier ("Verified repository" / "Community repository"); decorative icons are skipped.
- [ ] Icon-only buttons announce their action with the target's name ("Sync <repository>", "More actions for <extension>", "Details for <extension>", "Dismiss error").
- [ ] The per-extension switch announces "Enable <name>" and its state.
- [ ] Keyboard only: Tab reaches the section picker, filter field, Sync All, Update All, Refresh and Add Repository; every row menu opens with Space; sheets close with Esc and confirm with Return.
- [ ] Consent, re-trust (fingerprints shown and read aloud) and uninstall confirmations are reachable and dismissible from the keyboard.
- [ ] Safe-mode, sandbox-fallback, managed-policy and legacy-extension banners are read before the list.
- [ ] Settings → Advanced: Restart in Safe Mode and Export Diagnostics… are reachable and announce their purpose.


## Audit remediation — interactive gates (2026-10-02)

These need a person at the running, packaged app. Automated tests cover the
logic behind each; none of the items below has been performed yet.

- [ ] Lock: with a file panel for Export or Import open, lock the app (sleep, or switch user) — the panel result is refused and nothing is read or written.
- [ ] Profiles: start Continue Watching, switch profile before it loads — nothing plays and the new profile's history is untouched.
- [ ] Profiles: queue a download in profile A, switch to B, let it finish — it appears in Downloads for both and in A's library only.
- [ ] Restore: import a backup while the engine is starting — the library restores, Settings shows "Finish Restoring Extensions", and finishing adds the repositories without changing the library again.
- [ ] Restore: choose a backup, switch profile before confirming — nothing is restored into the other profile.
- [ ] Android import with two accounts: the dialog offers all accounts or one; conflicts are listed.
- [ ] History: play a movie, see it in History and in "Movies watched"; remove its row; relaunch — it stays removed and Continue Watching no longer offers it.
- [ ] Player: start a dub episode of an anime; Next/Previous and autoplay stay within dub and in season/episode order.
- [ ] Player: take a screenshot into a folder that cannot be written — the notice says it could not be saved.
- [ ] Player: open an ultra-wide (32:9) and a vertical video on the smallest attached display; unplug an external display while the player window is on it — the window stays fully on screen.
- [ ] Downloads: pause three remux downloads at a limit of three, let three others start, resume the first three — never more than three transfer at once; turn Wi-Fi off and press Resume — it waits.
- [ ] Downloads: delete a download stored on an external disk that is unplugged — "disk not connected", the entry stays; with the file removed in Finder — "Remove from List" appears and deletes nothing.
- [ ] Extensions: clear a provider's credentials while it is running — the next request is unauthenticated; the address field can be emptied to restore the default.
- [ ] Spotlight: titles of the selected profile are found; after switching profile or turning the setting off they are not.
- [ ] Diagnostics: the Engine Output and Engine Errors logs show one start and one exit marker per engine launch, in order.
- [ ] VoiceOver, Reduce Motion, Reduce Transparency, light and dark, and display scale: History rows (movie label), Downloads rows (disk not connected / Remove from List), the Spotlight retry row and the restore button are announced and reachable from the keyboard.
- [ ] Player: play a source whose audio is a separate track behind different headers than its video (e.g. the YouTube provider): audio and video play in sync, seeking works, and switching mirror or closing the player leaves nothing playing. Stop the engine mid-playback: the player moves to the next mirror or reports the failure.
- [ ] Restore: import a large backup and keep using the app meanwhile — the app stays responsive, Settings shows "Restoring…", library edits are refused with "A restore is still being applied", and a video playing during the restore keeps its position afterwards.
- [ ] Library: uninstall the extension a saved title came from and reinstall it from another repository — the title offers "Choose Provider…"; choosing the new provider keeps its note, history and playback settings. While the engine is still starting, no title offers it.
- [ ] Library: with an old title whose provider was never recorded, install the only extension that provides it — the title opens without a relaunch.
- [ ] Profiles: make the selected profile's store unreadable, play something, restore access and press Retry Library — the position played meanwhile appears in that profile only.
- [ ] Home with many large backdrops (a provider with 4K artwork): scrolling stays smooth and memory in Activity Monitor settles instead of climbing.
- [ ] Minimum OS: every item above on macOS 15.0.
