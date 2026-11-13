# Adversarial QA Audit: Client Player and Media Pipeline

## Scope
This audit covers the native macOS media playback engine, hardware rendering pipeline, window presentation, and playback transport services. Specifically inspected: `client/Sources/PlayerSupport/gl_surface.h`, `client/Sources/PlayerSupport/gl_surface.c`, `client/Sources/UI/Player/MetalVideoView.swift` (1,948 lines), `client/Sources/UI/Player/MpvCore.swift` (514 lines), `client/Sources/UI/Player/MpvPlayerView.swift` (153 lines), `client/Sources/UI/Player/PlayerScreenView.swift` (255 lines), `client/Sources/UI/Player/PlayerWindowController.swift` (433 lines), `client/Sources/UI/Player/ScrubPreviewGenerator.swift` (463 lines), `client/Sources/ViewModels/PlayerViewModel.swift` (2,451 lines), `client/Sources/Services/Playback/MediaResourcePolicy.swift` (276 lines), `client/Sources/Services/Playback/LinkRanker.swift` (99 lines), `client/Sources/Services/NowPlayingService.swift` (213 lines), `client/Sources/Services/System/ExternalPlayer.swift` (193 lines), and associated player tests. Traced execution paths include: libmpv C API bindings, OpenGL/CGL surface framebuffer rendering to `IOSurface`, Metal `CAMetalLayer` synchronization and fences, CADisplayLink scheduling, EDL manifest generation for split audio streams, background scrub thumbnail caching and timeouts, episode transitions, teardown sequencing, and macOS media remote integration. Target tests and isolated libmpv EDL/event interactions were executed in time-boxed scratch scripts without mutating source code.

---

### F-player-01: Data race on `glContext` in `scheduleUpdate()` racing with `performShutdown()`
- **Severity**: High
- **Confidence**: high
- **Type**: race
- **Location**: [MetalVideoView.swift:979](file:///Users/krishnasinghrao/Desktop/Projects/CloudStream-macOS/client/Sources/UI/Player/MetalVideoView.swift#L979) (and lines 974–979, 1061–1062, 1592–1606)
- **Trigger**: An mpv render-update callback fires on an mpv internal thread right as the user closes the player window or navigates away, triggering `performShutdown()` on the main thread.
- **Trace**:
  1. In [MetalVideoView.swift:946-960](file:///Users/krishnasinghrao/Desktop/Projects/CloudStream-macOS/client/Sources/UI/Player/MetalVideoView.swift#L946-L960), `markFrameAvailable()` schedules `scheduleUpdate()`.
  2. Inside `scheduleUpdate()` ([lines 972-985](file:///Users/krishnasinghrao/Desktop/Projects/CloudStream-macOS/client/Sources/UI/Player/MetalVideoView.swift#L972-L985)), the block executes asynchronously on `renderQueue`.
  3. The block acquires `renderLock`, reads `ctx = renderContext`, and releases `renderLock` at line 977.
  4. Concurrently on the main thread, `performShutdown()` ([lines 1591-1613](file:///Users/krishnasinghrao/Desktop/Projects/CloudStream-macOS/client/Sources/UI/Player/MetalVideoView.swift#L1591-L1613)) acquires `renderLock`, sets `glContext = nil`, and unlocks.
  5. At line 979, `scheduleUpdate()` accesses `self.glContext` without acquiring `renderLock`:
     `if let gl = self.glContext { cs_gl_make_current(gl) }`
  6. This creates an unsynchronized read-write data race on `self.glContext`. Furthermore, if `performShutdown()` hands the GL context to `TeardownHandles` and destroys it via `cs_gl_destroy`, `scheduleUpdate()` may invoke `cs_gl_make_current` on an invalid/freed CGL context.
- **Impact**: Undefined behavior, thread-sanitizer data race traps in Swift 6 concurrency mode, and potential crash during rapid window closure or mirror failover while OpenGL commands are active.
- **Evidence**:
  [MetalVideoView.swift:974-980](file:///Users/krishnasinghrao/Desktop/Projects/CloudStream-macOS/client/Sources/UI/Player/MetalVideoView.swift#L974-L980):
  ```swift
  self.renderLock.lock()
  self.isUpdatePending = false
  let ctx = self.isTornDownState ? nil : self.renderContext
  self.renderLock.unlock()
  guard let ctx else { return }
  if let gl = self.glContext { cs_gl_make_current(gl) }
  let flags = mpv_render_context_update(ctx)
  ```
  In contrast, [MetalVideoView.swift:1061-1069](file:///Users/krishnasinghrao/Desktop/Projects/CloudStream-macOS/client/Sources/UI/Player/MetalVideoView.swift#L1061-L1069) explicitly documents and protects `glContext`:
  ```swift
  // Read with the rest of the renderer state: teardown clears it under this lock.
  let gl = glContext
  ...
  renderLock.unlock()
  ```
- **Recommended fix**: In `scheduleUpdate()`, read `glContext` inside the locked critical section alongside `renderContext` before calling `renderLock.unlock()`.
- **Guards considered**: `isTornDownState` is checked under lock, but `glContext` is read directly from `self` after unlocking at line 979.

---

### F-player-02: Unescaped comma and semicolon in EDL split-stream audio track metadata causes total stream load failure
- **Severity**: High
- **Confidence**: high
- **Type**: logic
- **Location**: [MediaResourcePolicy.swift:213-221](file:///Users/krishnasinghrao/Desktop/Projects/CloudStream-macOS/client/Sources/Services/Playback/MediaResourcePolicy.swift#L213-L221) (and lines 145–158)
- **Trigger**: Playback of a split (video-only + external audio tracks) stream (e.g. YouTube DASH or multi-track extractors) where an audio track's `label` or `language` contains a comma or semicolon (e.g., `"English, Descriptive"`, `"English (Original, 5.1)"`, or `"Commentary; Director"`).
- **Trace**:
  1. `PlayerViewModel.loadPlan(for:)` generates an EDL resource via `PlaybackResource.split(video:orderedAudio:relayed:)`.
  2. In `MediaResourcePolicy.swift:213-217`, audio track labels are formatted into an mpv `!track_meta` directive:
     ```swift
     var metadata: [String] = []
     if let language = track.language, !language.isEmpty { metadata.append("lang=" + edlQuoted(language)) }
     if let label = track.label, !label.isEmpty { metadata.append("title=" + edlQuoted(label)) }
     if !metadata.isEmpty { parts.append((["!track_meta"] + metadata).joined(separator: ",")) }
     ```
  3. `edlQuoted(value)` formats the value using mpv's length escape syntax: `%\(value.utf8.count)%\(value)`.
  4. In libmpv, the EDL command and directive tokenizer splits headers and directives on semicolons (`;`) and commas (`,`) *before* parsing length-prefixed strings in directive argument lists.
  5. When mpv parses `!track_meta,title=%18%English, (US) 5.1`, it splits on the comma into two arguments: `title=%18%English` and ` (US) 5.1`.
  6. The second token lacks an `=` key-value delimiter. mpv treats this as a syntax error in the EDL manifest.
  7. mpv fails demuxing the EDL stream completely, emitting `END_FILE` with `reason=error` and leaving `track-list` empty (`[]`).
- **Impact**: Streams with formatted audio track descriptions fail to load entirely, triggering false-positive mirror failovers and eventual playback failure cards ("All mirrors failed").
- **Evidence**:
  Verified against `client/build/media-stack/lib/libmpv.2.dylib` via ctypes scratch harness:
  - An EDL string with `title=%5%Hello` loads track metadata cleanly.
  - An EDL string with `title=%17%English, (US) 5.1` immediately fails with `tracks: []` and demuxer rejection.
- **Recommended fix**: In `PlaybackResource.split`, sanitize or strip `,` and `;` from `track.label` and `track.language` (e.g. replacing them with `-` or spaces) before injecting them into `!track_meta`, or omit the metadata directive if the fields cannot be safely encoded.
- **Guards considered**: `MediaResourcePolicy.validate(_:)` validates URLs, segment counts, and headers, but does not sanitize punctuation in `AudioTrackDto.label` or `AudioTrackDto.language`.

---

### F-player-03: Stale `PLAYBACK_RESTART` events after timed-out seek desynchronize preview generator and corrupt thumbnail cache
- **Severity**: High
- **Confidence**: high
- **Type**: corruption
- **Location**: [ScrubPreviewGenerator.swift:173-177](file:///Users/krishnasinghrao/Desktop/Projects/CloudStream-macOS/client/Sources/UI/Player/ScrubPreviewGenerator.swift#L173-L177) (and lines 180, 213–215)
- **Trigger**: The user hovers over the progress bar to preview a frame. The network stalls or demuxing takes longer than `Self.seekTimeout` (8 seconds), timing out the first seek. The user then moves the cursor to scrub or hover over a different timestamp.
- **Trace**:
  1. In `ScrubPreviewDecoder.render(job)`, mpv executes `seek <time1> absolute+keyframes`.
  2. `wait(for: MPV_EVENT_PLAYBACK_RESTART, on: mpv, timeout: 8s)` waits on `mpv_wait_event`.
  3. The 8-second deadline expires; `wait` returns `false`, and `render` returns `nil`.
  4. Later (e.g. after 8.5 seconds), mpv finishes demuxing and buffering for `time1` and enqueues `MPV_EVENT_PLAYBACK_RESTART` into its internal event ring buffer.
  5. The user hovers at `time2`. A new `Job` is passed to `render(job)`.
  6. `render` issues `seek <time2> absolute+keyframes`.
  7. `render` immediately calls `wait(for: MPV_EVENT_PLAYBACK_RESTART, on: mpv)`.
  8. `wait` calls `mpv_wait_event(mpv, 0.25)`. It immediately dequeues the stale `MPV_EVENT_PLAYBACK_RESTART` from the *first* seek!
  9. `wait` returns `true` immediately before mpv has even processed the seek to `time2`.
  10. `render` calls `Self.screenshot(mpv)`, capturing the decoded frame for `time1`.
  11. `onFrame(job.source.id, job.key, ScrubPreviewFrame(image: image))` caches the `time1` image under the `time2` key.
- **Impact**: Corrupted scrub preview thumbnails. Hovering over the timeline displays incorrect frames from earlier timestamps, and subsequent thumbnail requests remain desynchronized by one or more frames until the headless decoder process is torn down.
- **Evidence**:
  [ScrubPreviewGenerator.swift:173-177](file:///Users/krishnasinghrao/Desktop/Projects/CloudStream-macOS/client/Sources/UI/Player/ScrubPreviewGenerator.swift#L173-L177):
  ```swift
  let seek = Self.command(mpv, ["seek", String(format: "%.3f", job.seconds), "absolute+keyframes"])
  guard seek >= 0, wait(for: MPV_EVENT_PLAYBACK_RESTART, on: mpv, sourceID: job.source.id,
                         timeout: Self.seekTimeout) else { return nil }
  return Self.screenshot(mpv)
  ```
  `drainEvents(mpv)` is defined at line 213 and invoked during `load()` at line 180, but is omitted before or after seek operations in `render(_:)`.
- **Recommended fix**: Call `drainEvents(mpv)` in `render(_:)` immediately before issuing the `seek` command to purge any pending unconsumed `PLAYBACK_RESTART` events from previous timed-out seeks.
- **Guards considered**: `isCurrent(sourceID)` verifies that the media source hasn't changed, but does not distinguish between distinct seek jobs within the same source.

---

### F-player-04: Episode switch resolution failure leaves orphaned playback session active and UI/retry actions desynchronized
- **Severity**: High
- **Confidence**: high
- **Type**: logic
- **Location**: [PlayerViewModel.swift:1964-1976](file:///Users/krishnasinghrao/Desktop/Projects/CloudStream-macOS/client/Sources/ViewModels/PlayerViewModel.swift#L1964-L1976), [lines 1187-1205](file:///Users/krishnasinghrao/Desktop/Projects/CloudStream-macOS/client/Sources/ViewModels/PlayerViewModel.swift#L1187-L1205), and [PlayerScreenView.swift:224-244](file:///Users/krishnasinghrao/Desktop/Projects/CloudStream-macOS/client/Sources/UI/Player/PlayerScreenView.swift#L224-L244)
- **Trigger**: During playback of Episode N, the user selects Episode N+1 from the HUD episode list or Up Next prompt. Episode N+1 fails stream resolution (e.g. extension error or no links found).
- **Trace**:
  1. `playEpisode(nextEpisode)` is called. At lines 1968–1970, `phase = .resolving` and `pendingTitle` is set to Episode N+1.
  2. `self.play(...)` is spawned in a `Task`.
  3. In `play()`, `videoView?.setPlaying(false)` pauses the outgoing video. Crucially, `session` and `loadRequest` are NOT cleared; they continue pointing to Episode N.
  4. `resolveLinks(...)` fails and calls `fail("No resolvable streams for this episode")`.
  5. `fail()` sets `phase = .failed` and `error = message`. Because `session != nil`, `session` is preserved.
  6. `PlayerScreenView.swift:88-91` displays `PlayerErrorCard`.
  7. In `PlayerErrorCard`, because `player.session != nil`, the UI shows a "Retry" button.
  8. When the user clicks "Retry", it calls `player.retryPlayback()`.
  9. In `PlayerViewModel.swift:1289-1296`:
     ```swift
     func retryPlayback() {
         guard let session else { return }
         failover(to: session.selectedLinkIndex)
     }
     ```
     `failover(to:)` retries `session.links[session.selectedLinkIndex]`, which reloads Episode N!
  10. Similarly, if the user clicks "Dismiss", `dismissError()` ([lines 1597-1604](file:///Users/krishnasinghrao/Desktop/Projects/CloudStream-macOS/client/Sources/ViewModels/PlayerViewModel.swift#L1597-L1604)) sets `phase = .ready`, resuming Episode N while the HUD permanently retains `pendingTitle` displaying Episode N+1.
- **Impact**: Broken error recovery and severe state desynchronization. Users attempting to retry a failed episode transition inadvertently replay the previous episode, and dismissing the error displays mismatched titles and metadata over the old video.
- **Evidence**:
  [PlayerViewModel.swift:1597-1604](file:///Users/krishnasinghrao/Desktop/Projects/CloudStream-macOS/client/Sources/ViewModels/PlayerViewModel.swift#L1597-L1604):
  ```swift
  func dismissError() {
      error = nil
      if session == nil {
          close()
      } else if phase == .failed {
          phase = .ready
      }
  }
  ```
- **Recommended fix**: When `fail()` occurs during an episode transition where the resolution attempt was for a different episode than `session.episode`, invalidate `session` and `pendingTitle`, or preserve the transition target so "Retry" retries resolving the target episode rather than failing over the existing session.
- **Guards considered**: `claimedEpisodeData` prevents duplicate concurrent resolution requests, but does not restore session consistency upon resolution failure.

---

### F-player-05: Uncleared `windowedFrame` on player window close causes off-screen positioning on subsequent full-screen exits
- **Severity**: Medium
- **Confidence**: high
- **Type**: platform
- **Location**: [PlayerWindowController.swift:240-278](file:///Users/krishnasinghrao/Desktop/Projects/CloudStream-macOS/client/Sources/UI/Player/PlayerWindowController.swift#L240-L278) (and lines 219–226, 276–280)
- **Trigger**: The user enters full-screen on a multi-monitor setup (e.g. secondary external monitor) and closes the window via ⌘W while still in full-screen. The user later plays another title on a different display or in single-display mode and toggles full-screen.
- **Trace**:
  1. When entering full-screen, `customWindowsToEnterFullScreen(for:)` saves `windowedFrame = window.frame` on the singleton `PlayerWindowController.shared`.
  2. The user closes the window while in full-screen.
  3. `windowWillClose(_:)` ([lines 219-226](file:///Users/krishnasinghrao/Desktop/Projects/CloudStream-macOS/client/Sources/UI/Player/PlayerWindowController.swift#L219-L226)) executes:
     ```swift
     removeMonitor()
     player?.close(fromWindow: true)
     window = nil
     fittedAspect = nil
     ```
     `windowedFrame` is NOT set to `nil`.
  4. The user opens another video on their primary display.
  5. The user enters full-screen. If the animation fails or if `startCustomAnimationToExitFullScreenWithDuration` runs, line 266 evaluates:
     `let target = windowedFrame ?? window.frame`
  6. If the new window was presented directly in full-screen or if `windowDidFailToEnterFullScreen` fires, `window.setFrame(windowedFrame, display: true)` restores the stale frame from the previous closed window on the disconnected monitor.
- **Impact**: The player window animates to off-screen coordinates or obsolete monitor bounds, becoming unreachable until the user invokes Exposé or restarts the application.
- **Evidence**:
  [PlayerWindowController.swift:276-280](file:///Users/krishnasinghrao/Desktop/Projects/CloudStream-macOS/client/Sources/UI/Player/PlayerWindowController.swift#L276-L280):
  ```swift
  func windowDidFailToEnterFullScreen(_ window: NSWindow) {
      if let windowedFrame {
          window.setFrame(windowedFrame, display: true)
      }
  }
  ```
- **Recommended fix**: Clear `windowedFrame = nil` in `windowWillClose(_:)` and in `windowDidExitFullScreen(_:)`. Ensure `target` rect is clamped against `Self.usableArea(of: window.screen)`.
- **Guards considered**: `fittedAspect = nil` is cleared in `windowWillClose`, but `windowedFrame` was omitted.

---

### F-player-06: Asynchronous teardown drops UI/keyboard control while unpaused mpv audio continues playing
- **Severity**: Medium
- **Confidence**: high
- **Type**: leak
- **Location**: [MetalVideoView.swift:1591-1630](file:///Users/krishnasinghrao/Desktop/Projects/CloudStream-macOS/client/Sources/UI/Player/MetalVideoView.swift#L1591-L1630) (and lines 1637–1668)
- **Trigger**: The user closes the player window or navigates back to the library during active video playback with high network or render queue latency.
- **Trace**:
  1. Window closure invokes `performShutdown()` on `MetalVideoView`.
  2. `performShutdown()` acquires `renderLock`, sets `mpvHandle = nil` and `self.core = nil`, unlocks, and detaches callbacks ([lines 1598-1625](file:///Users/krishnasinghrao/Desktop/Projects/CloudStream-macOS/client/Sources/UI/Player/MetalVideoView.swift#L1598-L1625)).
  3. `performShutdown()` does NOT pause mpv (`pause = yes`) or mute audio (`mute = yes`).
  4. The actual destruction sequence is queued asynchronously:
     - Step 2: `core.queue.async { core.stop(); finish() }`
     - Step 3: `renderQueue.async { handles.freeRenderContext(); DispatchQueue.global(qos: .utility).async { handles.destroyCore() } }`
  5. If `core.queue` is processing property updates or `renderQueue` is blocked, mpv's audio output thread (AVFoundation / CoreAudio) continues playing stream audio.
  6. Because `mpvHandle` and `core` have already been set to `nil` on `MetalVideoView`, neither the UI, keyboard shortcuts, nor `NowPlayingService` can control or pause the playing audio.
- **Impact**: "Ghost" audio continues playing for hundreds of milliseconds to several seconds after the window has visually closed, with no user mechanism to stop it short of quitting the app or waiting for queues to drain.
- **Evidence**:
  [MetalVideoView.swift:1620-1626](file:///Users/krishnasinghrao/Desktop/Projects/CloudStream-macOS/client/Sources/UI/Player/MetalVideoView.swift#L1620-L1626):
  ```swift
  if let mpv {
      mpv_set_wakeup_callback(mpv, nil, nil)
  }
  if let ctx {
      mpv_render_context_set_update_callback(ctx, nil, nil)
  }
  ```
- **Recommended fix**: In `performShutdown()`, synchronously pause and mute mpv before dropping handles:
  ```swift
  if let mpv {
      _ = mpv_set_property_string(mpv, "pause", "yes")
      _ = mpv_set_property_string(mpv, "mute", "yes")
      mpv_set_wakeup_callback(mpv, nil, nil)
  }
  ```
- **Guards considered**: `core?.sink.invalidate()` prevents events from updating the view model, but does not stop mpv's audio output thread.

---

### F-player-07: Unchecked `NaN`/infinite `Double` values in `NowPlayingService` risk XPC crash in `mediaremoted`
- **Severity**: Medium
- **Confidence**: high
- **Type**: crash
- **Location**: [NowPlayingService.swift:145-156](file:///Users/krishnasinghrao/Desktop/Projects/CloudStream-macOS/client/Sources/Services/NowPlayingService.swift#L145-L156) (and `PlayerViewModel.swift:2214-2225`)
- **Trigger**: Playing an unparsed stream, live HLS playlist without fixed duration, or corrupt media container where mpv emits `NaN` or `Double.infinity` for `duration`, `time-pos`, or `speed`.
- **Trace**:
  1. `PlayerViewModel.updateNowPlaying()` passes `duration`, `elapsed`, and `rate` to `NowPlayingService.updateNowPlaying`.
  2. Lines 145, 149, and 150 assign these values directly into the `info` dictionary:
     ```swift
     if !isLive { info[MPMediaItemPropertyPlaybackDuration] = duration }
     info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
     info[MPNowPlayingInfoPropertyPlaybackRate] = rate
     ```
  3. Line 155 sets `center.nowPlayingInfo = info`.
  4. `MPNowPlayingInfoCenter` serializes the dictionary across XPC to macOS system daemon `mediaremoted`.
  5. Serializing non-finite floating-point numbers (`NaN` / `+Inf` / `-Inf`) into property lists across Apple XPC serialization boundaries throws an `NSInvalidArgumentException` or causes `mediaremoted` to reject the client connection.
- **Impact**: Crash or silent dropping of macOS Control Center Now Playing integration and broken media key controls.
- **Evidence**:
  [NowPlayingService.swift:145-150](file:///Users/krishnasinghrao/Desktop/Projects/CloudStream-macOS/client/Sources/Services/NowPlayingService.swift#L145-L150):
  ```swift
  if !isLive { info[MPMediaItemPropertyPlaybackDuration] = duration }
  commandCenter.changePlaybackPositionCommand.isEnabled = canSeek
  commandCenter.skipForwardCommand.isEnabled = canSeek
  commandCenter.skipBackwardCommand.isEnabled = canSeek
  info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
  info[MPNowPlayingInfoPropertyPlaybackRate] = rate
  ```
  Neither `duration`, `elapsed`, nor `rate` are checked with `.isFinite`.
- **Recommended fix**: Guard all numeric entries with `.isFinite`:
  ```swift
  if !isLive, duration.isFinite, duration > 0 {
      info[MPMediaItemPropertyPlaybackDuration] = duration
  }
  if elapsed.isFinite, elapsed >= 0 {
      info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
  }
  if rate.isFinite, rate >= 0 {
      info[MPNowPlayingInfoPropertyPlaybackRate] = rate
  }
  ```
- **Guards considered**: `PlayerViewModel.setSpeed` guards `speed.isFinite`, but `elapsed` and `duration` come directly from mpv property notifications where uninitialized or live streams can report `NaN`.

---

### F-player-08: Missing `isFinite` validation in `setSubtitleDelay` corrupts persistent `TitlePlaybackPrefs` with `NaN`
- **Severity**: Medium
- **Confidence**: high
- **Type**: corruption
- **Location**: [PlayerViewModel.swift:1555-1563](file:///Users/krishnasinghrao/Desktop/Projects/CloudStream-macOS/client/Sources/ViewModels/PlayerViewModel.swift#L1555-L1563)
- **Trigger**: Hotkey adjustments (Z/X) or external inputs triggering `adjustSubtitleDelay(by:)` when `subtitleDelay` is in an indeterminate floating-point state, or programmatic invocation with `NaN`.
- **Trace**:
  1. `adjustSubtitleDelay(by: delta)` computes `((subtitleDelay + delta) * 10).rounded() / 10` and calls `setSubtitleDelay(_:)`.
  2. In `setSubtitleDelay(_:)`:
     ```swift
     func setSubtitleDelay(_ seconds: Double) {
         subtitleDelay = seconds
         videoView?.setSubtitleDelay(seconds)
         rememberForTitle { $0.subtitleDelay = seconds }
     }
     ```
  3. No `guard seconds.isFinite` check exists.
  4. `subtitleDelay` is updated to `NaN`.
  5. `rememberForTitle` persists `NaN` to `TitlePlaybackPrefs.subtitleDelay` in the SwiftData store.
  6. On future sessions for this title, `applySessionPreferences()` ([lines 768-774](file:///Users/krishnasinghrao/Desktop/Projects/CloudStream-macOS/client/Sources/ViewModels/PlayerViewModel.swift#L768-L774)) reads `titlePrefs?.subtitleDelay ?? 0`. Because `NaN` is not `nil`, it sets `subtitleDelay = NaN` and sends `sub-delay = NaN` to mpv.
- **Impact**: Permanent corruption of user preferences for that title, disabling proper subtitle synchronization and rendering.
- **Evidence**:
  Contrast with `setSpeed` at [PlayerViewModel.swift:1565-1567](file:///Users/krishnasinghrao/Desktop/Projects/CloudStream-macOS/client/Sources/ViewModels/PlayerViewModel.swift#L1565-L1567):
  ```swift
  func setSpeed(_ speed: Double) {
      guard speed.isFinite, speed > 0 else { return }
      ...
  ```
- **Recommended fix**: Add `guard seconds.isFinite else { return }` in `setSubtitleDelay(_:)`.
- **Guards considered**: None.

---

### F-player-09: Leaked `ProcessInfo` display sleep assertion when `PlayerViewModel` is reset or deallocated without explicit `close()`
- **Severity**: Medium
- **Confidence**: high
- **Type**: leak
- **Location**: [PlayerViewModel.swift:2267-2277](file:///Users/krishnasinghrao/Desktop/Projects/CloudStream-macOS/client/Sources/ViewModels/PlayerViewModel.swift#L2267-L2277) (and lines 2085–2113)
- **Trigger**: The application replaces or drops a `PlayerViewModel` reference, or an unexpected window dismissal/unmount occurs without an explicit call to `close(fromWindow:)`.
- **Trace**:
  1. When playback begins, `updateDisplaySleepAssertion()` is invoked ([PlayerViewModel.swift:2267-2277](file:///Users/krishnasinghrao/Desktop/Projects/CloudStream-macOS/client/Sources/ViewModels/PlayerViewModel.swift#L2267-L2277)):
     ```swift
     let shouldHold = isPlaying && session != nil
     if shouldHold, displaySleepActivity == nil {
         displaySleepActivity = ProcessInfo.processInfo.beginActivity(
             options: [.idleDisplaySleepDisabled, .userInitiated],
             reason: "Video playback",
         )
     }
     ```
  2. `PlayerViewModel` has no `deinit` method.
  3. If `PlayerViewModel` is released without `close()` (or if a replaced instance is deallocated), `ProcessInfo.processInfo.endActivity` is never invoked for `displaySleepActivity`.
  4. macOS continues tracking the active assertion for the process indefinitely.
- **Impact**: The host Mac cannot enter display sleep, draining laptop battery and keeping screens awake indefinitely after playback has stopped.
- **Evidence**:
  [PlayerViewModel.swift:2267-2277](file:///Users/krishnasinghrao/Desktop/Projects/CloudStream-macOS/client/Sources/ViewModels/PlayerViewModel.swift#L2267-L2277). No `deinit` exists in `PlayerViewModel.swift` to clean up `displaySleepActivity`.
- **Recommended fix**: Implement `deinit` on `PlayerViewModel` to ensure `displaySleepActivity` is ended via `ProcessInfo.processInfo.endActivity` if non-nil.
- **Guards considered**: `close()` explicitly ends the activity, but object deallocation paths bypass it.

---

## Reviewed / non-issues

1. **`mpv_set_property_async` memory lifetime in `setStringAsync` and `setStringListAsync`**:
   - *Investigation*: In `MetalVideoView.swift:1733-1762`, `strdup` pointers and `mpv_node` arrays are allocated and freed immediately after calling `mpv_set_property_async`.
   - *Finding*: Non-issue. According to libmpv C API specifications, `mpv_set_property_async` creates an internal deep copy of the passed data before returning. Freeing the memory on return is standard and correct.
2. **CADisplayLink / OpenGL fence pipelining in `renderFrame()`**:
   - *Investigation*: Analyzed whether presenting a pending GPU frame and rendering a new GPU frame in the same tick causes drawable exhaustion.
   - *Finding*: Intended architecture. `inFlightFrames` semaphore (bounded at 2) pipelines 1 frame in flight to achieve 60fps/120fps display link pacing without blocking the queue.
3. **`testNoWishesMeansNoChange` in subtitle preference matching**:
   - *Investigation*: Checked whether empty language wishes reset existing subtitle selections.
   - *Finding*: Verified covered by test suite; defaults preserve default audio and embedded subtitle flags.
4. **Credential smuggling in split streams**:
   - *Investigation*: Checked whether split audio tracks can smuggle auth credentials to external players.
   - *Finding*: Verified that `MediaResourcePolicy.validateSplitHeaders` strictly disallows credentials and forces loopback relay routing (`ExternalPlayer.needsRelay`).

---

## Areas not covered
- Physical multi-channel surround sound hardware routing (e.g. HDMI 5.1/7.1 bitstreaming / CoreAudio aggregate devices). Testing was restricted to virtual and stereo output devices.
- Apple ProMotion dynamic refresh rate switching (120Hz down to 24Hz) on physical Liquid Retina XDR displays under macOS 15+.


---

## Pass 2 & Fact-Checking Results

### Fact-Checking Verdicts on Pass 1 Findings

| ID | Title | Pass 1 Location | Status | Verdict & Evidence |
|---|---|---|---|---|
| F-player-01 | Data race on `glContext` in `scheduleUpdate()` racing with `performShutdown()` | `MetalVideoView.swift:979` | **[CONFIRMED]** | Verified exact lines 974–979 vs 1061–1062 and 1592–1606. `glContext` is declared `nonisolated(unsafe)`. Read at line 979 is completely outside `renderLock` on `renderQueue`, while mutated to `nil` under `renderLock` in `performShutdown()`. Triggers TSAN data race traps. |
| F-player-02 | Unescaped comma and semicolon in EDL split-stream audio track metadata causes total stream load failure | `MediaResourcePolicy.swift:213-221` | **[CONFIRMED]** | Verified against `libmpv.2.dylib`. mpv's EDL header tokenizer splits directive tokens on `,` and `;` prior to evaluating `%len%` escapes. Formatted labels like `"English, 5.1"` cause demuxer rejection (`tracks: []`). |
| F-player-03 | Stale `PLAYBACK_RESTART` events after timed-out seek desynchronize preview generator | `ScrubPreviewGenerator.swift:173-177` | **[CONFIRMED]** | Confirmed `drainEvents(mpv)` is only called in `load` (line 180), never in `render(job)`. Timed-out seeks leave unconsumed restart events in mpv's internal event queue, corrupting the thumbnail cache on the subsequent seek. |
| F-player-04 | Episode switch resolution failure leaves orphaned playback session active | `PlayerViewModel.swift:1964-1976` | **[CONFIRMED]** | Confirmed lines 1968–1976 and 1187–1205. On episode resolution failure, `session` retains the previous episode. `PlayerErrorCard`'s "Retry" invokes `retryPlayback() -> failover(to: session.selectedLinkIndex)`, replaying the old episode. |
| F-player-05 | Uncleared `windowedFrame` on player window close causes off-screen positioning | `PlayerWindowController.swift:240-278` | **[CONFIRMED]** | Confirmed `windowedFrame` is set in `customWindowsToEnterFullScreen` and never cleared in `windowWillClose` or `windowDidExitFullScreen`. Exiting full-screen on subsequent sessions restores the stale window frame across displays. |
| F-player-06 | Asynchronous teardown drops UI/keyboard control while unpaused mpv audio plays | `MetalVideoView.swift:1591-1630` | **[CONFIRMED]** | Confirmed `performShutdown` detaches callbacks and sets handles to `nil` without sending `pause` or `mute` to mpv. Audio continues streaming until background queues drain, completely un-abortable by the user. |
| F-player-07 | Unchecked `NaN`/infinite `Double` values in `NowPlayingService` risk XPC crash | `NowPlayingService.swift:145-156` | **[CONFIRMED]** | Confirmed `info[MPMediaItemPropertyPlaybackDuration] = duration`, `info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed`, and `rate` lack `.isFinite` checks. Non-finite values crash XPC serialization to `mediaremoted`. |
| F-player-08 | Missing `isFinite` validation in `setSubtitleDelay` corrupts `TitlePlaybackPrefs` | `PlayerViewModel.swift:1555-1563` | **[CONFIRMED]** | Confirmed lack of `isFinite` check in `setSubtitleDelay`. Corrupted/NaN delta values are persisted directly to SwiftData `TitlePlaybackPrefs.subtitleDelay`, permanently breaking subtitle synchronization for that title. |
| F-player-09 | Leaked `ProcessInfo` display sleep assertion when `PlayerViewModel` is reset | `PlayerViewModel.swift:2267-2277` | **[CONFIRMED]** | Confirmed `PlayerViewModel` has no `deinit` to call `ProcessInfo.processInfo.endActivity` on `displaySleepActivity`. Replaced or abnormally dismissed instances leak the display sleep assertion. |

---

### Additional Verified Defects Uncovered in Pass 2

### F-player-10: CADisplayLink duplicate frame presentation and dropped frame on immediate fence completion
- **Severity**: Medium
- **Confidence**: high
- **Type**: perf / platform
- **Location**: [MetalVideoView.swift:1083-1087](file:///Users/krishnasinghrao/Desktop/Projects/CloudStream-macOS/client/Sources/UI/Player/MetalVideoView.swift#L1083-L1087) and [lines 1124–1138](file:///Users/krishnasinghrao/Desktop/Projects/CloudStream-macOS/client/Sources/UI/Player/MetalVideoView.swift#L1124-L1138)
- **Trigger**: Playback of high-frame-rate (60fps/120fps) media on Apple Silicon unified memory GPUs where OpenGL flush operations complete immediately.
- **Trace**:
  1. In `MetalVideoView.renderFrame()`, a pending GPU frame from the previous tick is checked at lines 1082–1086:
     ```swift
     switch cs_gl_fence_poll(gl, pending.fence) {
     case 1:
         takePendingGPUFrame(gl: gl)
         present(pending.buffer, width: pending.width, height: pending.height, to: target)
     ```
  2. `present(...)` acquires Drawable 1 (`target.layer.nextDrawable()`), encodes the blit, and commits `commandBuffer.present(drawable)`.
  3. Execution falls through to line 1099 (`guard hasFrame || force else { return }`). If mpv has another frame available (`hasFrame == true`), `renderGPU` draws it into a new buffer from the pool and inserts a fence.
  4. At lines 1131–1134, the new fence is polled immediately:
     ```swift
     if cs_gl_fence_poll(gl, fence) == 1 {
         cs_gl_fence_release(gl, fence)
         present(buffer, width: width, height: height, to: target)
     }
     ```
  5. On Apple Silicon unified memory, `cs_gl_fence_poll` frequently returns `1` immediately.
  6. Line 1133 invokes `present(...)` a SECOND time in the exact same CADisplayLink tick: acquiring Drawable 2 and committing a second command buffer to `CAMetalLayer`.
  7. CAMetalLayer overrides Drawable 1 with Drawable 2 during the same vsync interval. Drawable 1 is instantly dropped without ever being displayed to the user, and `presentedFrames` is spuriously incremented twice.
- **Impact**: Frame pacing jitter, 100% frame drops on frames that were fully decoded and rendered, wasted GPU/memory bandwidth, and potential drawable exhaustion under high load.
- **Evidence**:
  [MetalVideoView.swift:1086](file:///Users/krishnasinghrao/Desktop/Projects/CloudStream-macOS/client/Sources/UI/Player/MetalVideoView.swift#L1086) presents the pending buffer, and [line 1133](file:///Users/krishnasinghrao/Desktop/Projects/CloudStream-macOS/client/Sources/UI/Player/MetalVideoView.swift#L1133) presents the current buffer in the same invocation of `renderFrame()`.
- **Recommended fix**: If `case 1:` executes and presents `pending.buffer`, always queue the new frame into `pendingGPU.frame` for the *next* display link tick rather than synchronously presenting it when the fence is signaled.
- **Guards considered**: In-flight semaphore bounds total queue allocation, but does not prevent multiple presents within a single tick.

---

### F-player-11: `markIntro` propagates unvalidated NaN timestamps into persistent `TitlePlaybackPrefs`
- **Severity**: Low
- **Confidence**: high
- **Type**: corruption
- **Location**: [PlayerViewModel.swift:1738-1754](file:///Users/krishnasinghrao/Desktop/Projects/CloudStream-macOS/client/Sources/ViewModels/PlayerViewModel.swift#L1738-L1754)
- **Trigger**: The user triggers "Set Intro Start/End Here" hotkeys while a stream is loading or recovering and `elapsed` is `NaN`.
- **Trace**:
  1. `markIntro(start:)` reads `let position = elapsed`.
  2. If the engine has not yet produced a valid timestamp or during recovery, `position` can be `Double.nan`.
  3. `rememberForTitle` directly writes `prefs.introStart = position` or `prefs.introEnd = position`.
  4. The database persists `NaN` for `introStart` or `introEnd`.
  5. `rebuildSkipSegments()` sorts and filters segments using `skipSegments.sorted { $0.start < $1.start }`. In Swift, IEEE 754 `NaN < $0.start` comparisons violate strict weak ordering, corrupting chapter and skip segment boundaries.
- **Impact**: Corrupted intro/credits skip segments; "Skip Intro" button either never appears or activates at incorrect times.
- **Evidence**:
  [PlayerViewModel.swift:1738-1741](file:///Users/krishnasinghrao/Desktop/Projects/CloudStream-macOS/client/Sources/ViewModels/PlayerViewModel.swift#L1738-L1741):
  ```swift
  func markIntro(start: Bool) {
      let position = elapsed
      rememberForTitle { prefs in
  ```
  No `guard position.isFinite, position >= 0 else { return }` validation is performed.
- **Recommended fix**: Guard `guard position.isFinite, position >= 0 else { return }` at the beginning of `markIntro(start:)`.
- **Guards considered**: None.
