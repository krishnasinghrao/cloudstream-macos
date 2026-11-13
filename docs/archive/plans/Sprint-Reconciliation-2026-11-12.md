# Reconciling `sprint-experimental` into `main` — 12 November 2026

`sprint-experimental` (29 commits from `ccb8b34`) was a prototyping sprint.
`main` was reset and took most of it by hand in 11 commits. This record is
the second pass: every difference left between the two branches, read
against `main` as it is, and one of three answers for each. Code and tests
decide; where the sprint's own documents and its code disagreed, the code won.

Verification: engine suite 488 tests (473 before), client unit suite as
recorded in the commit that adds this file.

## What `main` already had, or has better

Nothing to do, listed so that a later diff of the branches is not read as
missing work.

| Area | State |
| --- | --- |
| Security audit 2026-11, system trust anchors, TLS parity, Android stubs, worker stdout resync, GC grace, download limiter | on `main` (`a0b8b2f`) |
| In-app updates, portable builds | on `main` (`1cc4046`); `main` adds the `hdiutil` output fix and off-main staging cleanup the sprint lacks |
| Artwork cards, details hero, gallery | on `main` (`7f76bf7`); `main` also waits for the measured width before grouping gallery rows and makes `ArtworkMetadataStore` reads lock-free |
| Timeline thumbnails, swap reported after every render call | on `main` (`93f9dbf`); `main` adds the idle release of the preview engine |
| Release-year hydration, provider User-Agent on links | on `main` (`50782a7`), with a bounded query |
| Menu commands, Disable All Extensions, Search Other Providers | on `main` (`f56f030`) |
| Dolby Vision ranking, one unseekable failover, exact audio-track memory | on `main` (`e664a2e`) |
| Worker egress proxy idle timeout and saturation log | `main` only; the sprint's diff would remove them |

## Ported as written

| Change | Why it is safe |
| --- | --- |
| Relay: upstream calls owned through the body, cancelled on disconnect, revoke and reset; 15 s inactivity limit; sessions being read are not evicted | A player that went away left the upstream download running to the end of the file. Engine tests |
| Relay: rolling HLS / windowed DASH keep two generations of directory mappings; redirecting playlists keep one owner | A long channel exhausted the 64-directory limit and began answering 415. Engine tests, including 120 playlist updates |
| Fresh link resolution (`refresh`, `budgetMs`) through both caches, with cache revisions; `/links` cancels on disconnect; IPC v7 | Needed by live reconnects; default requests are unchanged |
| `POST /media/inspect` | Used for one question only (see ADR-0022) |
| Session cookies on links (`LinkIntake.withSessionHeaders`) | `main` had deferred this "until the relay work"; that work is the two rows above. Cookies only for the stream's own host; the extension's own headers win |
| GL bridge null guards; `MpvNodeReader` depth limit | Crash guards |
| Live visits in history; live titles out of resume and Continue Watching | Additive store code, backup format unchanged |
| Timeline text for non-finite and huge timestamps | `Int(Double)` trap guard |

## Rebuilt for `main`

The idea was right and the sprint's code was not.

| Idea | What went wrong in the sprint | What `main` does |
| --- | --- | --- |
| Live playback (ADR-0022) | The playlist was sampled to guess whether a title was live, and a "yes" loaded the stream a second time; a second no-progress watchdog and a quality step-down reloaded streams that were buffering; recovery state was spread over a dozen flags | Catalogue type only; the existing stall policy is the only stall detector; one budget, one task; the playlist is asked one question, at the end of a file |
| Events of a replaced file must not reach the new one | Built into a rewrite of the load path together with asynchronous renderer start-up and a property snapshot | A generation fence in `MpvEventSink` and `MpvCore.enqueueLoad`, nothing else: the outgoing file's queued events are dropped, and events before the new file's START_FILE are discarded |
| 4K is rendered at 4K | Came with 16-bit half-float surfaces and a colour pipeline that reconfigured itself every second | The GPU path's own size limit (4096) instead of the CPU path's 1920; the 8-bit sRGB pipeline is untouched |
| A new engine starts at the session's volume and mute | Tied to forced stereo CoreAudio output and "safety mutes" that then overwrote the user's own mute | The two values are set as options before the core starts; the model re-applies mute to a rebuilt view |
| Late links join the mirror list in rank order | Re-ranked the whole list around the playing source, so mirrors that had already failed were tried again | Only the mirrors not tried yet are re-ranked; a link arriving after "all mirrors failed" gets its turn |
| One episode transition at a time | A second request while resolving was dropped, including the user picking a different episode | Same episode again: ignored. Another episode: replaces the first |
| Bounded network retries | Changed together with cache timings | The retry options only; cache and read-ahead values stay as `main` had them |

Smaller fixes taken from inside the sprint's large player commit, each
re-applied to `main`'s code and each with a test in `PlayerGuardTests`: the
Up Next countdown no longer runs while the video is buffering or seeking; the
next episode's prefetched links and subtitles are used instead of resolving
it again, for three minutes and only for the title they belong to; a relayed
load keeps the video view (it used to rebuild the whole engine) and is
covered by the load deadline; a segment list with a cookie goes through the
relay; a preload no longer shrinks the playing file's buffer; a late error
for a file already given up on does nothing; the error card has Retry; the
end of a file no longer pauses the player under the next episode's play
command.

## Left out

| Sprint change | Reason |
| --- | --- |
| Renderer health monitor and readiness gating (`checkPlaybackHealth`) | The source of the stuck spinner and of the spurious failovers: "ready" waited on the audio device, the HLS rendition and a presented frame, and a one-second timer declared output failures from properties that had not been published yet. The sprint's last commit loosened three of its conditions; the design stayed |
| 16-bit linear P3/EDR output | Display headroom changes continuously on an XDR panel; the sprint re-set the target peak and suppressed presentation on every change, and had to switch dithering off to hide noise. Real HDR output needs a fixed-reference design and a display to verify it on. `main` keeps tone-mapped SDR, which the October measurements confirmed |
| Presentation at mpv's target time, 50 ms timing offset, fence polling timers | `main` has the swap-report fix that cured the 20 fps case. The rest could not be measured here and changes frame pacing for every stream |
| CoreAudio only, forced stereo downmix | Removes multichannel output for everyone to address a crackling incident the sprint could not reproduce |
| Software renderer refusing HDR | A pale picture on a rare fallback path was replaced by no picture |
| Rejecting Dolby Vision profiles other than 7 and 8 | Also rejects profiles 9 and 10.1/10.4, which have a compatible base layer. Ranking DV-only links last stays |
| A stall with no other mirror ends playback | A slow network on a single-source title became a failure |
| "This source did not finish seeking" deadline | A notice with no action, wrong for slow 4K seeks |
| Preferred-source fast start removed | `main` chose the faster first frame on purpose (Remaining-Work 7) |
| HLS rendition forced by track height | Switches the video track after start (a visible restart), and its check was one of the spurious failures. Open: a quality cap on a master playlist is still enforced by bitrate only |
| Asynchronous renderer start-up | Worth doing; too entangled with the health monitor to take alone |
| Per-section navigation stacks | `main`'s sidebar unwinds pushed pages when the section changes, as Mac sidebars do, and its latest commit restates that. The sprint's version also rebuilt the whole detail pane on every switch |
| Custom-drawn sidebar selection, item counts in gallery headers | Replaced on `main` by the native list and the count-free headers |
| `PlaybackDiagnostics` ring and support-bundle fields | Fed by the health monitor |
| Synthetic live origin (`scripts/live_cdn.py`), sustained-broadcast runner | Assert on the sprint renderer's counters |
| Sprint working documents (fix plans, implementation records, OTT prompts) | They describe the sprint's code. The three audit reports are kept in [audit/player-2026-11](../audit/player-2026-11/README.md) |

## Still open from the audits

Not fixed by either branch in a form `main` can take: real HDR/EDR output
(video audit 2); adaptive peak detection (4); actual presentation feedback
and a renderer failure signal (7, 8, F16, F17); renderer start-up on the main
thread (F19); HLS quality cap by resolution (F11).
