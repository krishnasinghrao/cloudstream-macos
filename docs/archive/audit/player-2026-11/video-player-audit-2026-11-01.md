# Video player implementation audit

Reviewed on 1 November 2026 against commit `a23a928`. This is an analysis of the current implementation; production code was not changed.

Follow-up: the broader [2 November audio/video red-team audit](audio-video-redteam-2026-11-02.md) includes native probes and VLC/IINA comparisons. Playback changes subsequently added per-load event fencing and buffering-aware countdown guards, so findings 9 and 12 below describe the original snapshot, not the newer working tree. Consult the follow-up report for current status and remaining gaps.

## Assessment

The player can decode 4K HEVC and tone-map HDR10 to SDR on its GPU path, but it does not deliver native 4K or native HDR output. Its software fallback is unsafe for HDR color reproduction. There are also limitations in tone mapping, Dolby Vision compatibility, presentation timing, failure detection, and per-load state handling.

“4K” describes resolution, not color format. A 4K SDR file, HDR10 file, HLG file, and Dolby Vision profile 5 file take materially different color-processing requirements. No affected user video or comparison capture was supplied, so the exact cause of the reported color difference cannot be selected conclusively. In particular, correct SDR tone mapping will look different from native HDR; that alone is not evidence of an incorrect conversion.

## Actual pipeline

```text
Provider/local file -> load request -> libmpv/FFmpeg demuxing
  GPU: VideoToolbox -> mpv OpenGL renderer -> SDR BT.709/sRGB
       -> 8-bit BGRA IOSurface, longest side <= 1920
  Fallback: VideoToolbox-copy -> CPU software renderer -> BGR0
       -> 8-bit BGRA IOSurface, longest side <= 1920
Both -> Metal texture sampling -> 8-bit sRGB CAMetalLayer -> macOS compositor
```

Metal is the final presentation stage. Decoding, HDR conversion, subtitle composition, and initial scaling are not implemented in a native Metal video renderer. The GPU path uses mpv's OpenGL render API. The shipped build also includes libplacebo, but this does not make the selected render API a `gpu-next` renderer.

## Findings

### 1. P1 — Software fallback displays HDR without HDR-to-SDR conversion

**Evidence:** `client/Sources/UI/Player/MetalVideoView.swift:630–645`, `699–714`, `1206–1238`; the implementation explicitly documents the omission at lines 31–35.

If OpenGL/context creation fails, playback automatically uses mpv's software render API. It converts/scales into BGR0 but has no HDR tone-mapping filter or equivalent conversion. Those values are then presented through the same sRGB-tagged layer as correctly converted GPU output. Merely labeling a layer sRGB does not convert PQ/HLG samples into sRGB or implement the required source-to-target gamut conversion.

**Impact:** HDR videos can look flat, dull, too dark, or incorrectly colored while audio and playback otherwise work. The software renderer's single-threaded CPU conversion/scaling can also struggle with high-resolution sources. This is the most direct code-supported explanation of washed-out HDR when this fallback is active. The actual renderer used for the reported video is unknown.

**Fix:** Make fallback conditional on the decoded color format. Supply a verified HDR conversion path, use another compatible renderer/player, or clearly report unsupported HDR rendering. Do not silently treat this path as equivalent to GPU playback.

### 2. P1 — HDR-capable displays always receive SDR, with wide gamut and high precision discarded

**Evidence:** `MetalVideoView.swift:221–233`, `635–637`, `741–754`, `1111–1114`, `1180`, `1723–1728`; `client/Sources/PlayerSupport/gl_surface.c:96–100`.

The GPU renderer is forced to `target-prim=bt.709` and `target-trc=srgb`. Every output buffer and the Metal layer are 8-bit BGRA. The layer never opts into EDR. The C bridge supports a half-float surface, but the Swift caller always passes `false`, and the pool/shader/presentation pipeline never uses that capability.

There is no display-headroom policy or HDR/SDR output-mode negotiation. Backing-property changes update pixel scale, not the video output color mode.

**Impact:** Even on an HDR/P3/XDR display, highlights remain SDR and colors outside BT.709 are compressed or lost. The 10-bit source also becomes 8-bit output, increasing the potential for visible banding. On an SDR display, SDR tone mapping is appropriate; 8-bit output alone does not explain a hue shift or prove broken tone mapping.

**Fix:** Implement a coherent display-aware output contract across mpv, IOSurface format, Metal texture/pipeline format, layer color space, and EDR. Use high precision through conversion and choose one owner for tone mapping. A different layer tag or one HDR option alone is insufficient. Preserve a validated SDR mode for SDR displays.

### 3. P1 — Every GPU frame is limited to 1920 pixels, including 4K playback

**Evidence:** `MetalVideoView.swift:148–150`, `1051–1055`, `1166–1171`, `741–744`.

`gpuRenderSize` reuses the 1920-pixel limit described as a CPU-rendering limit. A 3840×2160 drawable therefore receives a 1920×1080 video buffer, which Metal enlarges with linear filtering. Only 25% of the 4K output pixel count survives the intermediate stage.

**Impact:** Fine detail and subtitle edges soften on Retina and 4K displays. Selecting a 2160p stream does not produce a 2160p render. This explains poor sharpness, independently of the color problem.

**Fix:** Separate GPU and CPU sizing policies. Render the GPU path at the required drawable resolution, subject to explicit device limits and a deliberate performance policy. Verify real output-buffer dimensions, not just decoded `dwidth`/`dheight`.

### 4. P2 — Automatic HDR peak detection cannot operate on this OpenGL context

**Evidence:** `MetalVideoView.swift:635–637`; `gl_surface.c:28–34`. A diagnostic using the same CGL creation function returned:

```text
GL_VERSION=4.1 Metal - 91.7
GL_RENDERER=Apple M1
ARB_compute_shader=0
ARB_shader_storage_buffer_object=0
```

mpv 0.41's `video/out/gpu/video.c:3636–3642` disables HDR peak computation without compute shaders and SSBOs. Setting `hdr-compute-peak=auto` successfully does not mean peak detection is active. This implementation's log level will not normally show the verbose automatic-disable message.

**Impact:** The tone mapper relies on available source metadata and nominal fallback peaks instead of measured scene peaks. Missing or misleading mastering/MaxCLL metadata can therefore yield unnecessarily compressed or dim scenes. Ordinary GPU tone mapping still works; this limitation does not mean all HDR conversion is disabled.

**Fix:** Expose effective capabilities, validate static mapping with trustworthy metadata and a reference corpus, and use a rendering backend with the necessary capabilities if adaptive peak detection is required. Forcing this option to `yes` cannot create missing GPU features.

### 5. P1 — Unsupported Dolby Vision is deprioritized by filename, but still admitted

**Evidence:** `client/Sources/Services/Playback/LinkRanker.swift:55–78`, `85–96`; `client/Sources/UI/Player/StreamInfo.swift:18–27`; `PlayerViewModel.swift:1311–1317`.

The ranker explicitly acknowledges that the renderer cannot apply Dolby Vision reshaping. It guesses whether a stream lacks an HDR10 base from words in `name` and `source`, then sorts it later within a source tier. It does not reject it. A preferred source or remembered choice can still put it first; unmarked links and local files bypass that heuristic. Actual Dolby Vision profile metadata is observed only for the stream-info label, without a compatibility decision.

**Impact:** Profile 5 and other unsupported Dolby Vision cases can produce severe green/purple or otherwise incorrect colors without a playback error or automatic compatible-source switch. Name text containing “HDR” does not verify a usable base layer.

**Fix:** Make compatibility decisions from the decoded format/profile and effective renderer capabilities. Where an HDR10-compatible base is available, select and verify that path. Otherwise offer a compatible source or player. A representative real Dolby Vision corpus remains necessary to validate exact profile support.

### 6. P2 — Critical color-property failures bypass option validation

**Evidence:** `MetalVideoView.swift:123–137`, compared with `635–637` and `713`.

Initial options use a checked setter and populate `rejectedOptions`. The subsequent writes enabling zero-copy decoding and configuring target color/transfer/tone mapping ignore every return value. The existing rejected-options test therefore does not cover these critical writes.

**Impact:** An incompatible runtime can initialize successfully while using unintended color or decoding behavior. The bundled runtime accepted all five GPU-path writes in a direct probe during this audit, so this is a robustness defect, not an observed rejection on this installation. Acceptance also does not guarantee a feature is active, as finding 4 demonstrates.

**Fix:** Check these writes, read back the effective settings/capabilities where meaningful, and report failures with renderer/runtime context. Fail or select a supported mode if the requested output contract cannot be established.

### 7. P1 — Rendering can fail repeatedly while the UI reports successful playback

**Evidence:** `MetalVideoView.swift:1056–1084`, `1099–1141`; `PlayerViewModel.swift:1182–1195`.

Pixel-buffer, framebuffer/render, texture, drawable, command-buffer, and encoder failures return or skip rendering without a persistent failure signal or recovery policy. Metal command-buffer completion discards its status/error. Separately, `MPV_EVENT_PLAYBACK_RESTART` moves the UI to `.ready`, cancels the load deadline, and logs `player.first_frame`; no successful drawable presentation is required.

**Impact:** Audio and clock progress can continue over a black or frozen picture indefinitely, with the loading spinner already dismissed. Network-stall logic will not catch a renderer-only failure.

**Fix:** Track consecutive render/presentation failures, inspect Metal errors, and distinguish engine restart from the first successfully presented frame. Tie startup success and a bounded renderer-health recovery policy to actual presentation for the current load.

### 8. P2 — Presentation timing feedback reports submission as display, including skipped frames

**Evidence:** `MetalVideoView.swift:1020–1035`, `1069–1075`, `1135–1140`, `1163`, `1241–1250`; bundled `client/include/mpv/render.h:710–722`.

`mpv_render_context_report_swap` is called immediately after Metal command submission, before the drawable is actually presented. It is also called when rendering is skipped or presentation fails. mpv's API describes a notification that the frame was flipped, so this feedback does not describe actual display timing.

The zero video-timing offset is permitted by mpv and is not itself a defect. However, frames are then processed on a display-link tick, and an unfinished OpenGL fence is polled on a later tick. Only one unfinished GL frame is kept. This introduces refresh-interval latency and can quantize throughput under load. No target or actual presentation timestamps are used to assess this delay.

**Impact:** A/V timing and frame cadence are less trustworthy than the comments imply, particularly near 4K/60 performance limits or when the main run loop is busy. The magnitude of perceptible drift/judder was not measured in this audit; the existing 24/30 fps tests do not resolve it.

**Fix:** Base swap feedback on actual drawable presentation with safe render-context lifetime/queue handling, and measure presentation timestamps against media time. Test sustained 23.976/24/25/30/50/59.94/60 fps and display refresh changes. Revisit the single pending-GL-frame design if measurements show missed cadence.

### 9. P2 — Engine-lifetime event fencing does not protect individual loads

**Evidence:** `client/Sources/UI/Player/MpvCore.swift:181–183`, `205–211`, `232–270`; `MetalVideoView.swift:465–472`, `549–570`; `PlayerViewModel.swift:737–752`, `1182–1195`.

An event sink remains active across mirror/episode replacements in the same engine. Event delivery closures carry no load-request generation. The END_FILE filter compares against the entry current at event-drain time, not against the application's request when the closure eventually runs on the main actor. FILE_LOADED and PLAYBACK_RESTART are untagged altogether.

**Impact:** An old file's queued restart can mark a replacement ready and cancel its deadline. An old FILE_LOADED can consume the replacement's pending track attachments; a queued error can advance another mirror. FIFO delivery and shutdown invalidation solve different problems and do not exclude these interleavings. This is established by the state flow; the precise race was not reproduced with a live provider.

**Fix:** Fence main-actor delivery against the current load as well as engine lifetime, using a request/playlist-entry association established at a safe load boundary. Include restart, file-loaded, EOF, command outcomes, and per-file state in the design. Add a targeted rapid-replacement test.

### 10. P2 — Preferred-source fast start can select a worse quality than the configured ranking

**Evidence:** `PlayerViewModel.swift:502–507`, `560–567`; `LinkRanker.swift:46–52`, `70–78`.

Without a remembered quality, any first link from the first preferred source starts immediately. Quality and the configured maximum are not considered. A 720p link can start before a 2160p sibling, or a 2160p link can start before the preferred 1080p link under a 1080p cap. Links arriving after start are appended without re-ranking the failover order.

**Impact:** The selected stream and subsequent fallback can disagree with the promised quality ranking. This does not cause HDR conversion errors, but it complicates reports about which “4K” source was actually selected.

**Fix:** Fast-start only when the candidate is known to satisfy the relevant ranking constraints, or explicitly make this a startup-speed preference. Preserve the user's current selection while ranking subsequently discovered alternatives.

### 11. P2 — Next-episode preloading reduces the active 4K stream's buffering protection

**Evidence:** `PlayerViewModel.swift:1790–1813`; `MetalVideoView.swift:514–527`.

The next episode is queued up to 60 seconds before the current one ends. `queueNext` globally lowers `demuxer-max-bytes` from 128 MiB to 32 MiB, before mpv necessarily finishes reading the current video. The buffer is restored only on cancellation or the next load.

**Impact:** The final minute of a high-bitrate stream can have much less protection against network variability. At an illustrative 80 Mbit/s, 128 MiB holds roughly 13.4 seconds of compressed data, while 32 MiB holds 3.4 seconds, before packet overhead. This is a capacity calculation, not a measured stall in this audit.

**Fix:** Keep the active stream's budget independent of preload limits, or wait for a trustworthy condition that the current stream is fully read. Validate with a long, high-bitrate fixture and bursty bandwidth.

### 12. P2 — Up-next countdown advances during buffering

**Evidence:** `PlayerViewModel.swift:1197–1202`, `1235–1238`, `1599–1608`.

`isPlaying` follows the user's/engine's `pause` property. Cache pausing is tracked separately in `isBuffering`. The countdown subtracts wall-clock time whenever `isPlaying` is true, including while the media clock is stopped for buffering.

**Impact:** A stalling 4K stream near the end can advance to the next episode before the remaining content plays. Renderer-only freezes have the same problem because there is no presentation-health gate.

**Fix:** Advance the countdown from media progress, or pause it while loading, seeking, buffering, or unable to present video. Keep an explicit immediate “Play Now” action.

### 13. P2 — Stream information and tests describe the source, but cannot establish output correctness

**Evidence:** `StreamInfo.swift:8–41`; `client/Tests/PlayerEngineLiveTests.swift:92–106`, `147–173`, `188–216`; `MetalVideoView.swift:1107`, `1131–1140`.

The info line can say `3840×2160 / PQ / HDR10 / GPU` while the actual render is 1920×1080, 8-bit SDR. It lacks output size/transfer/gamut/precision, effective peak-detection state, dropped-frame counts, presentation lateness, and A/V timing.

The HDR test compares one neutral pixel in an intermediate buffer against the software path. It proves a brightness conversion happened, but cannot verify saturated colors, hue preservation, black level, highlight roll-off, banding, or final ColorSync/compositor output. The “presented” counter increments at submission and includes redraws; it is not a count of successful, unique, displayed video frames. The 4K test accepts 20 submitted frames/s for a 24 fps source and runs for only three seconds after warm-up. It does not exercise native 4K output, sustained 4K/60, HLG, Dolby Vision, HDR display transitions, or long high-bitrate network playback.

**Impact:** Passing tests and a reassuring stream-info line can conceal the quality limitations above.

**Fix:** Show separately labeled source and output information. Measure actual presentation and establish numeric tolerances against a trustworthy color reference. Add saturated patches, ramps, near-black/highlight steps, HDR mastering metadata variants, and representative real content. Cover fallback behavior and display changes as explicit cases.

## Additional engineering concern

Engine initialization, Metal shader compilation, synchronous dispatch to create the OpenGL renderer, and synchronous color-property writes run from `makeNSView` on the main actor (`MpvPlayerView.swift:86–98`; `MetalVideoView.swift:363–376`, `615–637`, `664–696`, `748–754`). The render-context failure branch also calls `mpv_terminate_destroy` there. This creates a UI-stall risk on startup/failure despite the comments about asynchronous controls and teardown. No startup-freeze duration was measured, so this is not presented as a proven cause of ongoing 4K stutter. Move expensive engine work into a carefully owned initialization lifecycle while retaining AppKit/layer mutations on the main actor.

## Verification performed

- Reviewed player rendering, CGL/IOSurface bridge, event core, SwiftUI binding, HUD/overlays, player window, stream information, source ranking, session lifecycle, buffering, preload logic, build configuration, and relevant tests.
- Ran the existing four focused live checks: GPU orientation/VideoToolbox decoding, software orientation, HDR10-to-SDR conversion, and 4K HDR decoding/CPU comparison, plus `PlayerRemediationTests`.
- Xcode result: **20 passed, 0 failed, 0 skipped** on the local Apple Silicon Mac. Result bundle: `client/build/DerivedData-repair/Logs/Test/Test-CloudStreamMac-2026.11.01_22-36-25-+0530.xcresult`.
- Queried the shipped library directly: **mpv v0.41.0 / FFmpeg n9.0.2**. All five GPU color/decoder writes returned success. This does not prove feature activation or color accuracy.
- Compiled a small diagnostic against the existing `gl_surface.c` and confirmed OpenGL 4.1 with no compute-shader or SSBO extensions on the Apple M1.
- Did not run a full application regression suite, a calibrated display comparison, a sustained 4K/60 benchmark, or the user's affected video. No production player changes were made.

## Repair order

1. Establish truthful source/output diagnostics and presentation success/error tracking, so failures can be diagnosed during the remaining work.
2. Fix HDR fallback and runtime Dolby Vision compatibility handling.
3. Remove the GPU's accidental 1080p ceiling and verify output dimensions.
4. Implement and validate a display-aware high-precision HDR/SDR output policy. Choose the renderer based on proven format support; simply setting `vo=gpu-next` is not a drop-in replacement for the current render API.
5. Verify static/adaptive tone mapping, actual display timing, and per-load event fencing.
6. Correct source-selection, preload buffering, and up-next behavior; expand tests around these specific failure modes.

## Primary references

- [Apple: Display HDR video in EDR with AVFoundation and Metal](https://developer.apple.com/videos/play/wwdc2022/110565/) — output precision, color space, and EDR configuration must agree.
- [Apple: Performing your own tone mapping](https://developer.apple.com/documentation/metal/performing-your-own-tone-mapping) — extended linear color output and EDR setup.
- [mpv 0.41 GPU renderer source](https://github.com/mpv-player/mpv/blob/v0.41.0/video/out/gpu/video.c#L3636-L3642) — effective HDR peak-detection capability checks.
- [mpv manual](https://mpv.io/manual/stable/) — target color configuration, peak detection, and renderer-specific options. The pinned 0.41 source and bundled headers were used for version-specific conclusions.
- Bundled `client/include/mpv/render.h:127–153`, `302–315`, `710–722` — software-renderer limitations, timing-offset guidance, and swap reporting contract.

The sRGB layer tag is appropriate for the GPU path's stated SDR output. The final pass uses unorm input/output with no additional transfer conversion, so the code does not independently establish a double-sRGB/gamma-conversion bug. Similarly, the absence of an mpv ICC profile is not sufficient to claim missing display color management: the sRGB-tagged layer allows macOS to perform display conversion. Changing either without a measured color contract could introduce a new error.
