# ADR-0019: OpenGL render context with Metal presentation

**Status:** Implemented; documents the existing renderer and supersedes
ADR-0001's software-only description.

`MetalVideoView` tries libmpv's supported OpenGL render context first. The
private CGL context and framebuffer cache live in `PlayerSupport/gl_surface.c`.
mpv draws into pooled IOSurface-backed pixel buffers, which Metal samples when
presenting a drawable. The render queue owns the CGL context; GPU completion
precedes reuse of a surface. There is no native Metal mpv render context and
no `wid` embedding.

When CGL or mpv's OpenGL setup fails, or `CS_PLAYER_RENDERER=sw` is selected,
mpv renders into a pooled CPU-accessible pixel buffer and Metal presents it.
Both paths retain the same player controls, event fencing, display pacing and
shutdown ownership. The renderer selector is an environment override for diagnosis and tests.

OpenGL is deprecated by Apple but remains necessary for this libmpv render
path. Its calls stay in the C bridge; the application does not expose an
OpenGL view. `GL_SILENCE_DEPRECATION` is defined in the target's C settings so
framework modules see it before compilation. It does not suppress Swift or
other C diagnostics.

This record corrects stale documentation; the cleanup introduces no renderer
or minimum-OS change. The product still targets macOS 15 and arm64.
