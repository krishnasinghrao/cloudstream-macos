# Video and audio player red-team audit

Date: 2 November 2026. Base commit: `a23a928`, with the working-tree playback changes present during review. Source hashes and runtime identity are recorded in `review-snapshot.json`. This report extends the 1 November picture-quality audit.

## Verdict and boundaries

The application does not yet have a sufficiently observable, recoverable playback lifecycle for the failures described. It delegates decoding, resampling, audio mixing, and audio output to libmpv/FFmpeg, but its integration treats successful loading, advancing media time, successful rendering, and functioning audio output as if they were equivalent. They are not. Several concrete defects allow a partially failed session to remain “playing” indefinitely.

The reported loud noise on **built-in speakers**, with **Mac system volume keys also ineffective**, is a release-blocking incident pending diagnosis. Its exact cause was not reproduced. The evidence does not justify claiming an identified memory-corruption bug, a particular codec failure, or a proven CoreAudio/AVFoundation crash. Ordinary clipping and delayed application mute do not adequately explain system volume control becoming ineffective.

This is a source audit plus controlled native-library fault and signal probes, not an exhaustive proof that every race or codec/device combination is covered. No problematic user stream, contemporaneous audio capture, output-device trace, or crash log was available. No probe emitted sound through physical speakers: audio output was restricted to `null` or a PCM file.

The workspace was being edited concurrently. I rechecked those changes and distinguish fixes already present from remaining defects. I did not implement player changes, overwrite those edits, or claim their tests passed.

## Evidence obtained

The actual bundled library reports **mpv v0.41.0 / FFmpeg n9.0.2**. The following results are retained as JSON and reproducible scripts beside this report.

| Probe | Result | What it establishes |
| --- | --- | --- |
| Six-channel correlated signal, explicit stereo downmix, default normalization | Peak **1.93127**, **62,880 / 96,000** output samples above full scale; about **+5.72 dBFS** peak | A downmix in this library can exceed unity even at application volume 100. This was a controlled mpv downmix, not a capture of the application's AVFoundation/system downmix. |
| Same signal, `audio-normalize-downmix=yes` | Peak **0.79996**, zero above-full-scale samples | Gain management prevents this specific overflow. It is not a universal cure for the reported noise. |
| Center-channel-only source, explicit stereo downmix | Nonzero stereo output, peak **0.56566** | The tested mpv stereo conversion preserves center content; a blanket claim that mpv drops all dialogue is false. |
| Audio decoder deliberately unavailable | `aid=no`, no audio parameters/output; video time advanced to **1.4 s**; PLAYBACK_RESTART occurred; no immediate END_FILE | A per-track failure can leave the overall session running. |
| Video decoder deliberately unavailable | `vid=no`, no video parameters; audio time advanced to **1.22 s**; PLAYBACK_RESTART occurred; no immediate END_FILE | A playing clock/restart is insufficient proof that video works. |
| Production cache options, paused 60-second controlled file | About **59.90 s** cached and **27.19 MB** total cached bytes | `demuxer-readahead-secs=30` does not impose the intended limit with cache enabled. |
| Same fixture with `cache-secs=30` | About **30.02 s** cached and **13.70 MB** total cached bytes | Setting the effective cache option changes behavior. This does not prove the app waits for 128 MiB before starting. |
| Two-rendition loopback HLS master | Default `hls-bitrate=max` selected **1280×720 / 4 Mbit/s**; explicit 500 kbit/s selected **640×360** | The library selects the high rendition unless the host controls it. |
| Actual `PlaybackPolicies.swift`, compiled with DTO stubs | Initial French track with remembered English returns `isComplete=true`, no selected audio; rerunning after English appears selects track 2 | Automatic selection can finish before the wanted track arrives. |

The decoder tests used an explicit decoder exclusion, not malformed media. They demonstrate the failure-state contract rather than reproducing the user's codec crash. Probe output contains no nonfinite samples in the tested PCM conversions.

An additional Xcode run selecting `PlayerLifetimeTests`, `PlaybackPolicyTests`, and `PlayerRemediationTests` **did not execute tests**: compilation stopped with `NSPOSIXErrorDomain Code 28`, “No space left on device.” Its temporary DerivedData directory was removed. The previous day's 20 passing tests are historical evidence, not a pass for the current working tree. See `test-run-status.json`.

## How the symptoms map to the evidence

| Reported symptom | Supported failure paths | What remains unproved |
| --- | --- | --- |
| Dialogue disappears but ambience continues | Wrong audio program/role; channel/layout conversion; source channel content; output backend behavior | No amplitude gate, denoiser, or generally missing center channel was found. Actual track/layout is unknown. |
| Audio stops while video runs | Per-track decoder/output failure is not classified as session failure; output/reconfiguration state is unobserved | Which decoder or output event caused the user's dropout |
| Video freezes while controls say playing | Silent rendering failures; video-track failure; missing presentation-health checks | Whether the observed freeze originated in the decoder, GL, Metal, or the display path |
| Video seems to speed up until it catches audio | Audio-master synchronization correcting a delayed video path; inaccurate presentation feedback; decoder/render stalls | A genuine change of the user's `speed` property, or the source of visual corruption |
| Blocky/noisy image during recovery | Damaged packets/reference frames, timestamp discontinuity, hardware decode, or surface synchronization are candidates | No packet corruption, unsafe reference-frame dropping, or decoder memory bug was reproduced. |
| Loud persistent crackling, system volume ineffective | Output/backend/system-audio fault or a stuck/retired output is a serious candidate; the host lacks assured output shutdown | No exact cause of the uncontrolled noise has been identified. |
| Excessive buffering and jank | Ineffective cache-duration limit, fixed high HLS rendition, reduced buffer during preload, incomplete recovery, unnecessary renderer recreation | The failing source's bitrate, CDN behavior, and measured sustained throughput |

## Audio output and control findings

### F01 — P1: AVFoundation is forced first without a demonstrated compatibility/recovery policy

**Status:** Confirmed configuration; conditional backend risk. **Location:** `MetalVideoView.setup`, around line 356.

The app forces `ao=avfoundation,coreaudio`. That is an ordered initialization preference, not a watchdog that will switch an already malfunctioning AVFoundation output to CoreAudio. There is no host setting to compare drivers, no observation of `current-ao`/output-device changes, and no driver-specific recovery classification.

The bundled version's AVFoundation backend restarts itself on output-configuration and automatic-flush notifications by stopping and starting its renderer. Its own source warns that this restart causes desynchronization (`audio/out/ao_avfoundation.m:208–214`). It also uses a separate render synchronizer and aggressively queued audio. These are meaningful integration conditions, not proof that the driver causes every failure.

**Comparison:** In the pinned IINA source, AVFoundation is explicitly opt-in, its preference defaults to false, and the selected default is CoreAudio. IINA also filters device choices to the selected driver. VLC's macOS AUHAL path explicitly negotiates the selected device's layout and restores output-unit volume/mute.

**Remediation:** Evaluate CoreAudio as the default on built-in speakers, retain an explicit controlled AVFoundation comparison path, and validate route/reconfiguration/underrun behavior before changing defaults. Record the actual driver, format, layout, sample rate, device, and recovery reason. Merely reversing the preference list cannot certify the incident fixed.

### F02 — P1: Application mute changes future PCM gain, not already queued output

**Status:** Source-confirmed limitation; its audible duration was not measured. **Locations:** `MetalVideoView.setMuted/setVolume`; mpv `player/audio.c:173–193`, `audio/out/ao.c:613–661`; AVFoundation backend `feed/init`.

The app writes mpv's software `mute` and `volume`. mpv applies that gain when samples are read for output. The AVFoundation renderer may already contain audio prepared with the old gain; its backend declares a two-second device-buffer estimate. The app does not couple an emergency mute to a verified output-level mute/flush/stop operation or wait for an acknowledgement.

The backend provides renderer-level `ao-mute`/`ao-volume` controls, but their support differs across output drivers. They must be capability-checked and synchronized with the normal volume model, not blindly enabled everywhere.

**Impact:** Application mute can lag behind queued audio, and it is not an independent containment mechanism for a broken output path. This does **not** explain why Mac system volume keys also failed.

**Remediation:** Define a bounded mute/stop contract that accounts for queued audio, with an acknowledged backend operation where supported. Validate response latency and failure behavior under injected output faults.

### F03 — P1: A new core starts at full application volume, unmuted, without the complete user intent

**Status:** Confirmed state/ordering defect. **Locations:** `MetalVideoView.setup/loadStream`; `MpvPlayerView.makeNSView`; `PlayerViewModel.applySessionPreferences/startSession`.

Setup sets `volume=100` and `mute=no`, and submits the file before `applySessionPreferences` writes the remembered volume. That method restores speed, subtitle delay, and volume, but not mute or the current play/pause intent. A zero volume is also converted back to a nonzero/default value at session start. Current replacement-load code explicitly writes `pause=false` after loading.

**Impact:** Muted/silent state can be lost when a view/core is recreated, and pause issued during relay registration or a delayed load need not survive the later load. There is an unsafe ordering window between initial media submission and volume restoration; a full-volume audible burst was not reproduced.

**Remediation:** Pass an immutable initial transport/volume/mute snapshot into core initialization. Begin paused/muted, establish the output and intended gain, and only then enable playback for the still-current request. Preserve explicit zero and pause choices.

### F04 — P1: Teardown drops the control handle before output is confirmed stopped

**Status:** Confirmed ownership gap; indefinite rogue audio not reproduced. **Locations:** `MetalVideoView.performShutdown`; `PlayerViewModel.close/fail`; `MpvPlayerView.dismantleNSView`.

Shutdown clears `mpvHandle`/`core` immediately and then queues actual destruction behind the event and render queues. It does not first establish that audio is muted/stopped, and the UI loses the handle needed to control that core. A replacement core can be created while destruction of the previous core is outstanding. Entering the view model's failed state also does not itself stop/mute the transport.

**Impact:** Normally orderly asynchronous destruction should finish quickly. If a native queue, render operation, or output shutdown stalls, however, the UI can be controlling a new core while the old output remains alive. Close/failure is not an acknowledged silence barrier.

**Remediation:** Keep ownership of retiring engines until output quiescence is acknowledged. Stop/mute before dropping ordinary control, serialize or account for overlapping retirements, and expose bounded shutdown failure. If hard containment of a stuck native output is a product requirement, evaluate process isolation; unsafe forced destruction of a live C handle from another thread is not a valid shortcut.

### F05 — P1: Loss of one media track is accepted as healthy playback

**Status:** Reproduced native failure contract plus confirmed host omission. **Locations:** `MpvCore.drainEvents`, `MetalVideoView.observeProperties`, `PlayerViewModel.handlePlaybackRestart`.

The host principally fails over on END_FILE(error) and cache stalls. It ignores audio/video reconfiguration events, does not observe the actual audio output parameters/driver or selected video state, and has no distinction between intentional audio-off and unexpected audio loss. `MpvTrack` also omits selected/availability state.

In controlled tests, disabling only audio decoding left video advancing and emitted PLAYBACK_RESTART without immediate END_FILE. Disabling only video decoding left audio advancing under the same condition. The host's restart handler can therefore mark either case ready and cancel startup protection.

**Remediation:** Declare expected streams for each request and independently track decoded audio, active audio output, decoded video, and successful video presentation. Recover/report a lost required component without treating valid audio-only content or intentional mute as failures. This does not require treating ordinary silent passages as an audio crash.

### F06 — P1: No validated downmix/headroom policy for speaker output

**Status:** Reproduced conditional clipping risk; actual system downmix unmeasured. **Locations:** audio setup; shipped defaults in `results.json`.

The library defaults are `audio-channels=auto-safe`, `audio-normalize-downmix=no`, no added audio filter, and volume 100. On the AVFoundation path the backend can accept multichannel PCM and leave downstream mixing to Apple's renderer, rather than performing the same explicit stereo conversion used in the probe. The host neither records that boundary nor provides a verified speaker/stereo fallback.

The correlated six-channel test produced +5.72 dBFS float samples in an explicit mpv stereo conversion. Normalization prevented it. The result demonstrates a real headroom requirement, but does not establish that every multichannel stream or Apple's downstream downmix clips. No gate that selectively deletes loud dialogue was found.

**Remediation:** Validate channel identification, center preservation, LFE policy, phase/correlation, gain, and clipping across 5.1/7.1 and stereo on built-in speakers. Provide an appropriate downmix/headroom mode at the stage that actually mixes. A limiter alone cannot repair wrong channel mapping or noise produced after its insertion point.

### F07 — P2: Audio selection discards roles and remembers only language

**Status:** Source-confirmed selection limitation. **Locations:** `MpvTrack`, `MpvNodeReader.tracks`, `TrackSelectionPolicy.plan`, `PlayerViewModel.preferredAudioOrder/selectAudioTrack`.

The native track list includes default, selected, dependent, accessibility, channel, and other metadata that the model discards. Remembered selection stores only a language; the next matching track wins, even if it is commentary or a music-and-effects program. Provider-track ordering additionally prefers AAC and then bitrate without proving that those are the same program. The comment claiming AAC is decoded by the system is not established by the selected FFmpeg `aac` decoder seen in the probe.

**Impact:** A track containing ambience but no normal dialogue is a plausible selection failure. It is not proved to be the user's case.

**Remediation:** Preserve stable track/program identity and role metadata, prefer an appropriate default/main track, and present useful codec/layout/role labels. Fall back to language when identity cannot be carried across mirrors.

### F08 — P2: Automatic audio selection can finish before the preferred language arrives

**Status:** Reproduced by compiling the actual policy source. **Locations:** `PlaybackPolicies.swift:191–196`; `PlayerViewModel.applyRememberedTracks`.

With remembered English and an early nonempty French-only track list, the plan returns `isComplete=true` with no audio selection. The caller records that the current load is finished with automatic track selection. When English arrives later, it never gets another attempt. This differs from the case where the list was initially empty.

**Remediation:** Keep the audio preference pending while a requested track can still arrive, independently of subtitle completion. Add a test for nonempty-but-nonmatching early tracks followed by the desired track.

### F09 — P1: Segmented-playlist loading bypasses per-resource header isolation

**Status:** Confirmed source control-flow defect; no real credential transfer performed. **Locations:** `PlayerViewModel.loadPlan`, especially the playlist return before `carriesCredentials/validateSplitHeaders`; `MetalVideoView.handleFileLoaded`.

The playlist branch returns native EDL segments plus external audio before the credential-relay and split-header checks used for ordinary split streams. External audio is later opened with `audio-add` under the global video header set; its DTO's own headers are validated but never applied there.

**Impact:** Audio requiring different headers can fail or lose its authenticated fetch. Credentialed segmented playlists can also enter a native path despite the stated policy that credentials are confined to the engine relay, where global headers may reach other segment/audio origins. Validating an HTTP URL does not establish header authority for its origin.

**Remediation:** Apply credential and per-resource header planning before every playlist/split/plain branch. Relay authorized components with their own headers and preserve one synchronized timeline where possible. Test with dummy headers and two controlled origins.

## Buffering, transport, and recovery findings

### F10 — P2: The 30-second read-ahead control is effectively overridden

**Status:** Reproduced. **Location:** `MetalVideoView.setup` cache options.

`cache=yes` activates `cache-secs`, whose bundled default is 3,600,000 seconds. mpv uses the larger cache/read-ahead duration, bounded by bytes. Setting only `demuxer-readahead-secs=30` therefore does not implement a 30-second cache. The controlled 60-second file was almost entirely prefetched; explicitly setting `cache-secs=30` roughly halved its cached bytes.

**Impact:** Unnecessary memory, read-ahead traffic, and contention can occur, particularly for low-bitrate or local content. It does not mean startup waits for all these bytes; the default initial-cache-pause setting is false.

**Remediation:** Configure effective cache duration and byte ceilings deliberately for local, remote VOD, and live media. Measure startup/rebuffering separately from memory occupancy.

### F11 — P2: Master-playlist rendition selection bypasses the app's quality cap

**Status:** Reproduced library behavior plus host omission. **Locations:** `LinkRanker`, stream load configuration; no `hls-bitrate`/variant constraint in the host.

The host ranks provider links by nominal quality, but a selected HLS URL may be a master containing many renditions. mpv defaults to the highest advertised bitrate; the loopback probe selected the high rendition even though a lower one was available. The app does not connect user quality limits or measured bandwidth to that choice and has no hysteretic adaptation policy. Preferred-source fast start can also start a link before a higher-ranked sibling arrives.

**Impact:** A connection that can sustain a lower rendition may repeatedly stall at the selected higher one. This is not evidence that VLC always has superior adaptive streaming or that arbitrary mpv settings will fix a slow CDN.

**Remediation:** Expose/choose actual variants and apply caps at the manifest/track level. Use bounded, measured adaptation or offer a clear lower-quality fallback. Preserve explicit user selections.

### F12 — P2: Preloading lowers the current stream's global buffer

**Status:** Source-confirmed. **Locations:** `MetalVideoView.queueNext`, `PlayerViewModel.queueNextEpisodeIfDue`.

Up to 60 seconds before the current episode ends, the global forward cap falls from 128 MiB to 32 MiB. The current stream need not be fully read yet. At an illustrative 80 Mbit/s these capacities represent about 13.4 versus 3.4 seconds before overhead, not a guaranteed number of buffered seconds.

**Remediation:** Separate the active and preload budgets, or wait for a confirmed fully-read condition. Verify near-end playback under bursty bandwidth; do not describe a global cap as a separate preload-only allocation.

### F13 — P1: Recovery detects cache starvation but misses output freezes and can abandon the last mirror silently

**Status:** Source-confirmed. **Locations:** `handleBuffering`, `trackStall`, `switchMirrorForStalls`.

One second of refill is used regardless of stream bitrate/jitter; repeated stalls lead to mirror switching rather than a coordinated assessment of throughput, decoding, and output progress. Only `paused-for-cache` starts the stall monitor. A frozen renderer or failed audio output can leave that property false. When the long-stall callback fires on the final mirror, tracking is reset and the function returns without retry, re-resolution, or a terminal message; an ongoing stall need not produce another true transition to rearm it.

**Remediation:** Maintain independent network, decode, audio-output, and presentation health. Bound last-mirror recovery with a fresh-link attempt or actionable terminal state. Tune refill thresholds against a jitter corpus rather than treating one fixed value as universally wrong or sufficient.

### F14 — P2: Relay setup and cancellation are outside the claimed playback deadline

**Status:** Source-confirmed; timeout/cancellation durations not newly measured. **Locations:** `beginRelayedLoad`, `commitLoad/armLoadDeadline`; `MediaRelay.open/serve/revoke`.

The normal load deadline is armed only after a relay registration completes and commits a load. Registration itself has no player-owned outer deadline. In the engine, revocation removes mappings but does not cancel an already opened OkHttp call/response. A coroutine on `Dispatchers.IO` blocked in `execute()`/`InputStream.read()` is not automatically interrupted merely because the coroutine or player is canceled; the read timeout can remain 30 seconds.

**Impact:** “Close,” seek, or mirror switch can leave old network work consuming resources, and relay setup can outlive the advertised player loading budget.

**Remediation:** Include extraction/relay/load/output setup in one request budget. Register active calls and cancel/close them on owner cancellation/revocation; verify prompt cancellation while a server stalls before headers and during a body read.

### F15 — P2: Relay registration removes the video view and rebuilds the renderer

**Status:** Source-confirmed lifecycle cost. **Locations:** `beginRelayedLoad` sets `loadRequest=nil`; `PlayerScreenView` requires a nonnil load request to keep `MpvPlayerView` mounted.

An asynchronous relay round trip can unmount the old representable, shutting down mpv/GL/Metal, then recreate all of it when the new request arrives. Ordinary mirror/episode replacements otherwise reuse the player. Rebuilding also re-enters the unsafe initial volume/mute ordering in F03 and asynchronous retirement in F04.

**Remediation:** Keep the renderer mounted while a replacement request is prepared. Separate the visible/loading state from engine lifetime, and commit a fully prepared request atomically. Measure the avoided rebuild cost before making CPU/latency claims.

## Rendering, synchronization, and concurrency findings

### F16 — P2: Timing feedback describes submission, not actual presentation

**Status:** Source-confirmed contract mismatch; perceptible drift not quantified here. **Locations:** `MetalVideoView.present/skipRender/dropPendingGPUFrame`; bundled `mpv/render.h` swap contract.

Swap feedback is sent just after committing a Metal command buffer, before the drawable is displayed, and also after unsuccessful/skipped presentation. The counter named `presentedFrames` increments at submission and can include redraws. This cannot measure actual frame cadence.

An unfinished GL frame is polled on subsequent display-link ticks, with only one unfinished GL frame retained. The design can add refresh-interval delay and quantize throughput under load. `video-timing-offset=0` is an allowed mpv strategy; the issue is failing to assess the downstream delay added by this implementation.

**Remediation:** Use actual drawable presentation timing with safe render-context ownership, separate submitted/presented/unique/dropped counters, and measure against the audio clock at 23.976 through 60 fps. Do not turn off frame dropping merely to conceal catch-up behavior.

### F17 — P1: Renderer failures have no bounded recovery, while readiness is declared too early

**Status:** Source-confirmed. **Locations:** `renderFrame`, `present`, `handlePlaybackRestart`.

Buffer/FBO/texture/drawable/encoder failures return or skip silently. Metal completion status/error is discarded. An early PLAYBACK_RESTART cancels the deadline without requiring one successfully presented frame. Subsequent audio progress can keep the UI apparently alive indefinitely.

**Remediation:** Add per-load first-presentation acknowledgement and a health monitor eligible only when video should be visible/advancing. Count and classify repeated render failures, recover within a budget, and distinguish minimized/occluded/paused/audio-only cases.

### F18 — P2: `glContext` is read outside the lock used to mutate it during teardown

**Status:** Source-confirmed unsynchronized access; no runtime crash reproduced. **Locations:** `renderFrame` around line 1030; `scheduleUpdate` around line 938; `performShutdown` around line 1547.

Rendering snapshots the mpv context and other fields under `renderLock`, releases it, then reads `glContext`. Teardown can concurrently replace that field with nil under the lock. `scheduleUpdate` has the same pattern. The serial render queue delays physical destruction but does not synchronize these shared-field reads with main-thread mutation.

**Impact:** A render/update can see an inconsistent context/renderer tuple or choose the software branch for a GPU render context during shutdown. This is a real Swift data race; proving specific visible corruption or use-after-free requires a sanitizer/reproduction.

**Remediation:** Snapshot all related handles under one ownership boundary and confine mutable renderer state to its queue. Exercise close/reopen/replacement with Thread Sanitizer and delayed render operations. Do not mark the entire unchecked-Sendable bridge unsafe without distinguishing its correctly queue-confined parts.

### F19 — P2: Main-thread work can delay both controls and frame scheduling

**Status:** Source-confirmed coupling; no new profiler comparison. **Locations:** `makeNSView/setup/createRenderContext/createGPURenderContext/buildBlitPipeline`; `MpvCore.beginLoad`; display-link setup.

Core initialization, runtime Metal shader compilation, synchronous render-context creation, and synchronous color-property writes happen from the main actor. The new `beginLoad` synchronously drains the event queue from the main actor. A render-context failure also calls synchronous native destruction there. Frame scheduling is driven by a display link on the main run loop, so unrelated UI work can delay it even though rendering itself has a private queue.

**Remediation:** Move expensive initialization/retirement into an explicitly owned asynchronous lifecycle and keep AppKit mutations on the main actor. Avoid replacing synchronous calls with unstructured `Task` blocks that still inherit the main actor. Measure main-thread stalls and presentation deadlines under menus, resizing, and library activity.

### F20 — P1: The GPU path decodes 4K but caps rendering at 1920 pixels

**Status:** Confirmed, still present. **Locations:** `maxRenderDimension=1920`, `gpuRenderSize`, final linear sampler.

A 3840×2160 drawable receives at most a 1920×1080 intermediate frame, then an upscale. Only 25% of the 4K pixel count remains before presentation. This explains softness, not audio corruption.

**Remediation:** Separate GPU and CPU resolution policies; verify actual buffer/output dimensions and performance at supported native resolutions.

### F21 — P1/P2: HDR/color limitations remain, independently of the audio failures

**Status:** Confirmed configuration/capability limitations; exact affected stream still unavailable. **Locations:** GPU/software context setup, pool pixel format, layer setup, `LinkRanker.isDolbyVisionOnly`, stream-info handling.

- **P1:** Software fallback does not tone-map HDR before presenting through an sRGB layer.
- **P1:** GPU output is forced to 8-bit SDR BT.709/sRGB; no coherent native EDR/HDR output exists. SDR output is appropriate on an SDR display, but is a limitation on HDR displays.
- **P2:** OpenGL 4.1 on the tested M1 lacks compute shaders/SSBOs needed for effective automatic HDR peak detection. A successful option write does not make that feature active.
- **P1:** Dolby Vision compatibility is guessed from names and used for sorting; unsupported actual profiles are not rejected or redirected when metadata appears.

The previous audit contains the full color-path evidence. The current code does not independently prove double-sRGB conversion, and a missing mpv ICC profile alone does not prove missing display color management because the output layer is tagged for macOS conversion.

**Remediation:** Define one high-precision, display-aware output contract and test actual format/profile capabilities. This is a rendering design change, not a saturation slider or a one-option `gpu-next` switch.

## Failure reporting, UI, and validation findings

### F22 — P2: Asynchronous control failures and native failure detail are discarded

**Status:** Source-confirmed. **Locations:** `commandAsync/set*Async`, `MpvCore.drainEvents`, `handleCommandReply`, `createRenderContext`.

Immediate submission return codes are ignored. Property-write replies are logged but not delivered with the affected property/intent to the UI. Untagged command errors reach `.other` and are discarded by the view model. END_FILE's detailed error code is reduced to a reason enum. Critical synchronous decoder/color writes bypass the checked option setter.

**Impact:** A volume, pause, track, speed, or load request can fail while the UI preserves its optimistic state. Failover cannot reliably distinguish an expired URL from a decoder/output problem that another mirror will not repair.

**Remediation:** Correlate commands/properties to load and intent, check submission results, reconcile failed writes, and carry a bounded structured native error record. Preserve actionable categories without exposing URLs, headers, or decryption data.

### F23 — P2: UI state and available controls do not reliably describe capability or failure

**Status:** Source-confirmed. **Locations:** `MpvPlayerView.onPropertyChange`, `PlayerTimelineScrubber`, `PlayerViewModel.dismissError`; audio menu.

Observed `speed` and `seeking` changes fall through into a stream-info model that ignores them. The scrubber enables seeking from known duration rather than actual seekability. Dismissing an exhausted-mirror error can set the phase back to ready without a successful reload. Missing audio can still be labeled “Default Audio Track,” and there is no normal audio route/channel/layout or audio-delay control for diagnosing the reported failures.

**Remediation:** Keep transport intent separate from acknowledged state and capabilities. Disable unsupported seeks, show degraded audio/video explicitly, and use retry/reopen actions after terminal failure. Preserve familiar keyboard and menu behavior while making recovery actionable.

### F24 — P1/P2: Diagnostics and tests are inadequate to certify audio or presentation correctness

**Status:** Source-confirmed validation gap. **Locations:** `PlayerAudioPipelineTests`, `PlayerStartupBenchmarkTests`, `PlayerEngineLiveTests`, `StreamInfo`, `DiagnosticsExporter`.

The audio initialization test records property changes but never asserts that an audio output exists or that PCM is valid, nonclipping, correctly mapped, or audible. Its short wait and `isInitialized` assertion primarily prove core setup. Several startup benchmarks print results without meaningful pass/fail limits; a test named “split-current” still exercises the old audio-add path rather than the current EDL load plan. Tests sampling `audio-pts` do not prove acoustic output.

Picture tests sample an intermediate gray pixel and count submissions. Stream info reports source size/HDR, not output size/transfer/precision/presentation health. The exported support bundle contains application/daemon information, not a bounded client libmpv audio/output/presentation timeline sufficient to investigate these symptoms.

**Remediation:** Establish signal-level channel/clipping/finite-sample tests; per-component decoder/output fault injection; acknowledged mute/stop latency; route and sample-rate changes; actual presentation/A-V timing; corrupt/discontinuous media; direct/relayed network faults; and sustained soaks. Include a redacted diagnostic timeline with driver/device/format/PTS/drift/cache/decoder/presentation/error state. Keep real-speaker incident reproduction separate from safe automated file/null tests.

### F25 — P3: Dead transport methods, misleading comments, and optimization opportunities obscure ownership

**Status:** Source-confirmed cleanup plus unmeasured optimization candidates.

No production callers were found for the transport's native `togglePlayPause`, relative `seek(by:)`, or `toggleMute`; the view model instead sends explicit pause/mute and absolute seeks. Keeping unused alternative command paths weakens the intended single transport contract. The 1920 cap is documented as a CPU limit while also applied to GPU output, and the subtitle/audio-add/benchmark comments describe historical paths as current.

The GPU path also adds a GL-to-IOSurface-to-Metal presentation pass/fence and flushes the Metal texture cache every frame. These are real costs and candidates for profiling, not proof that every cache flush is wrong or that zero-copy IOSurface sharing is a CPU frame copy. Repeated size changes recreate pools/GL targets and deserve measured resize/fullscreen profiling.

**Remediation:** Remove unused paths after verifying external/test usage, correct the architecture comments and benchmark names, and profile these costs before replacing the renderer. Preserve the existing correct buffer-retention/in-flight protections while optimizing.

## Comparison with established open-source players

These are source-backed architecture comparisons, **not** measured performance rankings on the same media. VLC is inspected at its 3.0.21 tag, IINA at a pinned develop commit, and mpv at the exact version shipped. The IINA snapshot is not a claim about every released IINA version; VLC 3.0.21 is not presented as the newest VLC release.

| Area | Inspected peers | CloudStream gap |
| --- | --- | --- |
| macOS audio driver | IINA defaults to CoreAudio and makes AVFoundation explicit; VLC uses macOS output-unit control | AVFoundation forced first, no user comparison path or runtime health-driven fallback |
| Device/channel handling | VLC queries preferred device layout; IINA observes device/driver changes; mpv supplies channel conversion | Host drops relevant audio format/role/device state and has no verified speaker-output policy |
| Volume/mute | VLC controls the output unit and restores mute/volume on setup; mpv distinguishes software gain from AO controls | Host uses software controls alone, resets initial mute/volume, and loses retired-engine control before silence acknowledgement |
| Audio recovery/timing | mpv already has underrun/reload/A-V correction; VLC has explicit output/filter restarts and synchronization correction | Host lacks component health and request-aware recovery above the library; using mpv does not automatically supply that product behavior |
| Rendering | IINA explicitly manages display-link/display changes, render-context locking, and EDR modes | Custom two-stage presentation has inaccurate swap feedback, a 1080p ceiling, and insufficient output telemetry |
| Failure visibility | Native engines expose track/output/reconfiguration/error state | Wrapper reduces errors to generic mirror failure or leaves partial failure ready |
| Streaming quality | mpv exposes cache and HLS-rendition controls | Host configures some ineffective cache settings and does not map source quality limits to actual variants |

The primary deficit is integration discipline: state ownership, capability negotiation, correct timing feedback, output control, error classification, and evidence. Replacing libmpv with libVLC without repairing those boundaries would recreate many of the same bugs. Conversely, mpv's own buffering and timing logic should be used correctly before adding a second independent synchronization system.

## Fixes that arrived during review — not counted as untouched old defects

The working tree now contains per-load generation fencing, outgoing-file event suspension, duration reset, `keep-open-pause=no`, native preload ownership checks, guarded episode transitions, consumption of prefetched links/subtitles, and a countdown guard for buffering/loading/seeking. These address important findings from the earlier snapshot.

In particular, the earlier statement that no per-load event fence exists and that the countdown always advances during buffering is no longer an accurate description of this working tree. Some asynchronous boundaries still merit adversarial testing, including overlapping pending loads and acknowledgements from retiring engines. I do not label those fixed or broken merely from a patch's intent. The new synchronous `beginLoad` path remains relevant to F19.

## Remediation order and acceptance gates

1. **Contain the noise incident and retain useful evidence.** Establish intended/acknowledged mute, volume, pause, stop, and retired-engine ownership. Compare CoreAudio against AVFoundation with captured route/format state. Do not claim a decoder or limiter change has fixed a system-output failure without reproducing it.
2. **Detect partial failure.** Require expected audio/video/output components and actual first presentation. Bound recovery and retain specific errors. Test one failed component while the other continues.
3. **Correct effective transport policy.** Fix cache duration, master-rendition caps, last-mirror recovery, relay setup/cancellation budgets, and active/preload buffer ownership. Retain the renderer while preparing relay requests.
4. **Repair concurrency and presentation.** Eliminate the inconsistent GL-handle snapshot, remove expensive main-thread work, and measure actual presentation and A/V drift at supported resolutions/frame rates.
5. **Finish picture quality and selection.** Restore native GPU resolution, validate HDR/SDR/Dolby Vision policy, and correct audio track roles/late language selection. Fix playlist header isolation before exercising credentialed sources.

Required release evidence should include a channel-identification corpus, correlated multichannel peaks, near-silence and nonfinite/error cases, PCM/AAC/AC-3/E-AC-3/DTS/TrueHD where supported, timestamp discontinuities, corrupt segments, switching/seeking/closing under output faults, device changes, repeated retire/recreate cycles, long direct/relayed playback, and sustained 4K/60 on supported hardware. A stable run of one short AAC stereo file is not sufficient. Exact performance thresholds must be measured on named hardware rather than invented as achieved numbers.

## Conclusions I am explicitly not making

- No general loudness gate, dialogue-removal filter, or denoiser was found; the default added audio-filter list is empty.
- Encoded passthrough is not enabled in the tested default configuration (`audio-spdif` is empty). “Turn off passthrough” is not an established fix for the built-in-speaker incident.
- The app is not intercepting Mac volume keys in its player input monitor: that monitor handles key-down and mouse events, not the system-defined media-key path.
- The tested center-only downmix works. Actual missing dialogue could still involve a different layout/track/system output path.
- Default frame dropping is `vo`, not decoder-frame dropping. I did not prove that the app is deliberately dropping reference frames or changing playback speed behind the user's back.
- I did not reproduce an unstoppable output, sanitizer fault, exact corrupted stream, or a measured performance regression against VLC/IINA. Those remain investigation/acceptance work, not facts inferred from the symptom description.
- Existing IOSurface pooling and completion-based retention are meaningful protections; there is no evidence supporting a blanket claim that all video buffers are reused unsafely.

## Primary source references

Exact upstream commit identifiers and paths are retained in `upstream-sources.json`.

- [mpv 0.41 AVFoundation backend](https://github.com/mpv-player/mpv/blob/41f6a645068483470267271e1d09966ca3b9f413/audio/out/ao_avfoundation.m): `feed`, `control`, notification restart, format setup, and device-buffer estimate.
- [mpv 0.41 software gain/output processing](https://github.com/mpv-player/mpv/blob/41f6a645068483470267271e1d09966ca3b9f413/audio/out/ao.c#L613-L661) and [audio lifecycle](https://github.com/mpv-player/mpv/blob/41f6a645068483470267271e1d09966ca3b9f413/player/audio.c): gain, underrun, reconfiguration, and per-track failures.
- [mpv 0.41 option documentation](https://github.com/mpv-player/mpv/blob/41f6a645068483470267271e1d09966ca3b9f413/DOCS/man/options.rst): cache/read-ahead precedence, downmix normalization, channel negotiation, and HLS bitrate selection.
- [mpv 0.41 video timing](https://github.com/mpv-player/mpv/blob/41f6a645068483470267271e1d09966ca3b9f413/player/video.c) and [timeline demuxing](https://github.com/mpv-player/mpv/blob/41f6a645068483470267271e1d09966ca3b9f413/demux/demux_timeline.c): A/V synchronization and lazy-stream codec replacement. A codec-name guess alone is not proof of decoding with the wrong codec, because timeline packets carry the real codec.
- [IINA audio configuration](https://github.com/iina/iina/blob/1b05edd0f7524ecc95286af75529007d4cfe1124/iina/MPVController.swift#L577-L580), [default preferences](https://github.com/iina/iina/blob/1b05edd0f7524ecc95286af75529007d4cfe1124/iina/Preference.swift#L1161), and [driver/device handling](https://github.com/iina/iina/blob/1b05edd0f7524ecc95286af75529007d4cfe1124/iina/PlayerCore.swift#L1900-L1945).
- [IINA display/EDR handling](https://github.com/iina/iina/blob/1b05edd0f7524ecc95286af75529007d4cfe1124/iina/VideoView.swift) and [render layer locking](https://github.com/iina/iina/blob/1b05edd0f7524ecc95286af75529007d4cfe1124/iina/ViewLayer.swift).
- [VLC macOS AUHAL output](https://github.com/videolan/vlc/blob/dd8bfdbabe8ae3974ca3864ad3125879f523e3a2/modules/audio_output/auhal.c): output-unit volume/mute, device layout, restart handling.
- [VLC audio-output lifecycle and synchronization](https://github.com/videolan/vlc/blob/dd8bfdbabe8ae3974ca3864ad3125879f523e3a2/src/audio_output/dec.c) and [CoreAudio common code](https://github.com/videolan/vlc/blob/dd8bfdbabe8ae3974ca3864ad3125879f523e3a2/modules/audio_output/coreaudio_common.c).
