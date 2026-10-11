# ADR-0001: mpv render backend — sw context + Metal blit

**Status:** Accepted

mpv 0.41 upstream has no Metal render context (`MPV_RENDER_API_TYPE_METAL`
verified absent from source and runtime). We keep the invariant that matters —
CAMetalLayer + mpv_render_context, no `wid` — using the `sw` render context
into a Metal-compatible CVPixelBuffer, blitted to the drawable by a GPU
fullscreen-quad pipeline. Decoding stays on VideoToolbox. A
Metal-API-enabled libmpv could later be preferred without architectural
change; that is a separate feature decision.

*Update, October 2026:* the `build_mpv_metal.sh` helper this record used to
name was removed. It only copied a hand-supplied library into the staged
resources, outside the pinned media build and its manifest, and the player
has never requested anything but the `sw` context.
