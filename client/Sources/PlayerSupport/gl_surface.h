#ifndef CLOUDSTREAM_GL_SURFACE_H
#define CLOUDSTREAM_GL_SURFACE_H

#include <IOSurface/IOSurfaceRef.h>
#include <stdbool.h>

/// A private OpenGL (CGL, 4.1 core) context that mpv's GPU renderer draws
/// into: each target is an IOSurface the Metal presenter samples, so frames
/// never pass through the CPU. All calls for one context must come from one
/// serial queue; each entry point makes the context current itself.
typedef struct cs_gl_context cs_gl_context;

/// Nil when no hardware-accelerated OpenGL context is available.
cs_gl_context *cs_gl_create(void);
void cs_gl_destroy(cs_gl_context *context);
void cs_gl_make_current(cs_gl_context *context);

/// For mpv_opengl_init_params.get_proc_address (ctx is ignored).
void *cs_gl_get_proc_address(void *ctx, const char *name);

/// The framebuffer that renders into `surface` (32-bit BGRA, or 64-bit
/// half-float RGBA when `half_float`); created once per surface and cached.
/// Returns 0 on failure.
unsigned cs_gl_framebuffer(cs_gl_context *context, IOSurfaceRef surface, bool half_float);

/// Forgets every cached framebuffer (after the surface pool changed).
void cs_gl_forget_framebuffers(cs_gl_context *context);

/// Waits until the GPU finished the commands issued so far, so another API
/// may read the surfaces. Returns false on timeout or error. Blocks the
/// caller; the render loop uses the non-blocking fence calls below instead.
bool cs_gl_finish(cs_gl_context *context, unsigned long long timeout_ns);

/// Fences the commands issued so far and flushes them to the GPU without
/// waiting. NULL on failure. Release with cs_gl_fence_release.
void *cs_gl_fence(cs_gl_context *context);

/// Never waits: 1 once the GPU has passed `fence` (the surfaces it wrote may
/// be read), 0 while it has not, -1 on error.
int cs_gl_fence_poll(cs_gl_context *context, void *fence);

void cs_gl_fence_release(cs_gl_context *context, void *fence);

#endif /* CLOUDSTREAM_GL_SURFACE_H */
