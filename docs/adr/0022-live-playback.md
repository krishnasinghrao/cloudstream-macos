# ADR-0022: live channels — identity, timeline and bounded recovery

**Status:** Accepted. 2026-11-12. Real-channel and long-run acceptance is open
([Remaining-Work](../Remaining-Work.md) section 7).
**Input:** the [live playback audit](../archive/audit/player-2026-11/live-playback-audit-2026-11-01.md).
A first implementation was written on the `sprint-experimental` branch; this
record describes what `main` does and where it deliberately differs
([reconciliation](../archive/plans/Sprint-Reconciliation-2026-11-12.md)).

## Context

The player treated a live channel as a film. It resumed it at a stored
second, counted a watched percentage against the length of a rolling window,
offered it in Continue Watching, and answered a dropped stream by walking the
mirror list, each mirror resuming at a position that means nothing on a live
clock. A positive duration does not make a stream finite, and the end of a
file does not mean a broadcast ended.

## Decision

**Identity comes from the catalogue.** `PlaybackKind.catalogue` reads the
title's type: `Live` and `LiveStream` are live, everything else is not.
Trailers, extras and downloaded files are finite whatever the title is. The
stream is never asked: the sprint also sampled the playlist and, when it
looked like a growing one, reclassified a title as live and loaded it a
second time. A finite video served as an event playlist then restarted
moments after it began and lost its resume point. A wrong catalogue type is a
provider defect with a visible, stable effect; a wrong guess from a sample was
an intermittent one.

**No stored position.** A live session starts, fails over, reconnects and
returns to the live position with no start time. It saves no progress. A
visit is recorded once, when the first frame arrives, in the title's existing
history row with zero position, zero duration and not watched
(`LibraryStore.recordLiveVisit`), so History shows the channel and backups
carry it in the existing format, while resume and Continue Watching skip it.

**The timeline is what is cached.** mpv's `demuxer-cache-state` seekable
ranges are the only part of a live stream that can be seeked. Every seek —
scrubber, keyboard, media keys, accessibility — is clamped to them
(`PlaybackRange.clamped`), relative seeks are taken from the stream's own
clock, and with nothing cached the seek controls are off. The scrubber shows
*Live* while playback follows the stream and *Replay* after a pause or seek.
**Go Live** opens the stream again, which is where a live playlist starts;
seeking to the end of the cache would only reach the newest data already
downloaded.

**One interruption, one budget.** A stream error, an unexpected end or a
stall (the existing stall policy: one long stall or several short ones)
starts a reconnect instead of a mirror walk. `PlaybackRecoveryBudget` gives
one interruption 45 seconds, three loads and one fresh link resolution, with
1, 2 and 4 seconds between loads. The first attempt asks the provider for
fresh links (`refresh`, IPC v7), because the usual cause is an expired
address, and plays the best of them; later attempts move to the next mirror
when there is one. A first frame does not refill the budget. Only 30 seconds
of uninterrupted advancing playback does (`PlaybackHealthWindow`: a pause,
buffering, a seek, a backward step or a two-second gap starts the window
over), so a stream that dies every few seconds ends with an error and a
Retry instead of reconnecting forever. While offline the reconnect waits for
the network inside the same deadline rather than spend loads on it.

**The user's pause wins.** Nothing reconnects behind a pause: the reconnect
is deferred and starts, with a full budget, when the user plays again. A
manual mirror switch, Go Live, a new title and closing the player cancel a
reconnect in progress.

**A broadcast that ended, ends.** At the end of a live file the engine is
asked once what the playlist says (`POST /media/inspect`). Complete
(`ended`): the player closes, as at the end of a film. Anything else,
including no answer, is an interruption. The sample is a separate request,
not the bytes mpv read, which is why it decides this one question and nothing
else.

**No second watchdog.** The sprint added a live "no progress for 12 seconds"
timer beside the stall policy, and stepped the quality down on each stall.
Both acted on a clock that legitimately stops (buffering, a slow first
segment) and both reloaded a stream that was about to recover. A playlist
that stops updating starves the player, which is what the stall policy
already measures.

## Engine side (IPC v7)

- `refresh` and `budgetMs` on `/links` and `/links/stream` bypass the
  engine's link cache and the worker's, with the remaining deadline carried
  into the worker. A cache revision keeps an older resolution that finishes
  late from replacing the fresh result.
- The relay owns each upstream call through its whole body: a player that
  disconnects, a revoked session and a replaced load cancel it, and an
  upstream that goes silent for 15 seconds is dropped. A rolling HLS
  playlist, or a DASH manifest with an explicit window, keeps the current and
  previous generation of directory mappings and retires the rest, so a long
  channel no longer runs into the 64-directory limit and starts failing with
  415. Finite and unknown manifests, and anything being read, are never
  retired.
- `POST /media/inspect` reads at most two playlist levels, 512 KiB each, in
  three seconds, under the relay's address and header rules, and returns
  facts only.

## Consequences

- A channel whose provider reports another type plays as a film, as before
  this record.
- A reconnect to another address cannot map the old position: it returns to
  the live position and says so.
- Synthetic sustained-broadcast tests exist on the sprint branch
  (`scripts/live_cdn.py`) and were not carried over, because they assert on
  the sprint's renderer counters. Acceptance on real channels, a multi-hour
  run and a token-expiry run against a real provider are open.
