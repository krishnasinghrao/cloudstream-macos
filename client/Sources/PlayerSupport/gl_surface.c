// OpenGL is deprecated on macOS but remains the only GPU API libmpv's render
// API offers there; this file is the one place that calls it.
#define GL_SILENCE_DEPRECATION 1

#include "gl_surface.h"

#include <OpenGL/OpenGL.h>
#include <OpenGL/CGLIOSurface.h>
#include <OpenGL/gl3.h>
#include <dlfcn.h>
#include <stdlib.h>

#define CS_GL_MAX_TARGETS 8

typedef struct {
    IOSurfaceID surface;
    bool half_float;
    GLuint texture;
    GLuint framebuffer;
} cs_gl_target;

struct cs_gl_context {
    CGLContextObj cgl;
    cs_gl_target targets[CS_GL_MAX_TARGETS];
    int count;
};

cs_gl_context *cs_gl_create(void) {
    CGLPixelFormatAttribute attributes[] = {
        kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_GL4_Core,
        kCGLPFAAccelerated,
        kCGLPFAAllowOfflineRenderers,
        (CGLPixelFormatAttribute)0,
    };
    CGLPixelFormatObj format = NULL;
    GLint formats = 0;
    if (CGLChoosePixelFormat(attributes, &format, &formats) != kCGLNoError || !format) return NULL;
    CGLContextObj cgl = NULL;
    CGLError error = CGLCreateContext(format, NULL, &cgl);
    CGLReleasePixelFormat(format);
    if (error != kCGLNoError || !cgl) return NULL;
    cs_gl_context *context = calloc(1, sizeof(cs_gl_context));
    if (!context) {
        CGLReleaseContext(cgl);
        return NULL;
    }
    context->cgl = cgl;
    return context;
}

void cs_gl_make_current(cs_gl_context *context) {
    CGLSetCurrentContext(context ? context->cgl : NULL);
}

void cs_gl_forget_framebuffers(cs_gl_context *context) {
    cs_gl_make_current(context);
    for (int i = 0; i < context->count; i++) {
        glDeleteFramebuffers(1, &context->targets[i].framebuffer);
        glDeleteTextures(1, &context->targets[i].texture);
    }
    context->count = 0;
}

void cs_gl_destroy(cs_gl_context *context) {
    if (!context) return;
    cs_gl_forget_framebuffers(context);
    CGLSetCurrentContext(NULL);
    CGLReleaseContext(context->cgl);
    free(context);
}

void *cs_gl_get_proc_address(void *ctx, const char *name) {
    (void)ctx;
    static void *library;
    if (!library) library = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY | RTLD_LOCAL);
    return library ? dlsym(library, name) : NULL;
}

unsigned cs_gl_framebuffer(cs_gl_context *context, IOSurfaceRef surface, bool half_float) {
    cs_gl_make_current(context);
    IOSurfaceID id = IOSurfaceGetID(surface);
    for (int i = 0; i < context->count; i++) {
        if (context->targets[i].surface == id && context->targets[i].half_float == half_float) {
            return context->targets[i].framebuffer;
        }
    }
    // The pool hands out a bounded set of surfaces; anything beyond means it
    // was replaced, so start over rather than leak framebuffers.
    if (context->count == CS_GL_MAX_TARGETS) cs_gl_forget_framebuffers(context);

    GLsizei width = (GLsizei)IOSurfaceGetWidth(surface);
    GLsizei height = (GLsizei)IOSurfaceGetHeight(surface);
    GLuint texture = 0, framebuffer = 0;
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_RECTANGLE, texture);
    CGLError error = half_float
        ? CGLTexImageIOSurface2D(context->cgl, GL_TEXTURE_RECTANGLE, GL_RGBA16F, width, height,
                                 GL_RGBA, GL_HALF_FLOAT, surface, 0)
        : CGLTexImageIOSurface2D(context->cgl, GL_TEXTURE_RECTANGLE, GL_RGBA8, width, height,
                                 GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, surface, 0);
    glBindTexture(GL_TEXTURE_RECTANGLE, 0);
    if (error != kCGLNoError) {
        glDeleteTextures(1, &texture);
        return 0;
    }
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_RECTANGLE, texture, 0);
    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    if (status != GL_FRAMEBUFFER_COMPLETE) {
        glDeleteFramebuffers(1, &framebuffer);
        glDeleteTextures(1, &texture);
        return 0;
    }
    context->targets[context->count++] = (cs_gl_target){ id, half_float, texture, framebuffer };
    return framebuffer;
}

bool cs_gl_finish(cs_gl_context *context, unsigned long long timeout_ns) {
    cs_gl_make_current(context);
    GLsync fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    if (!fence) return false;
    GLenum result = glClientWaitSync(fence, GL_SYNC_FLUSH_COMMANDS_BIT, timeout_ns);
    glDeleteSync(fence);
    return result == GL_ALREADY_SIGNALED || result == GL_CONDITION_SATISFIED;
}

void *cs_gl_fence(cs_gl_context *context) {
    cs_gl_make_current(context);
    GLsync fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    // Submits the frame's commands (and the fence) without waiting for them.
    glFlush();
    return (void *)fence;
}

int cs_gl_fence_poll(cs_gl_context *context, void *fence) {
    if (!fence) return -1;
    cs_gl_make_current(context);
    GLenum result = glClientWaitSync((GLsync)fence, 0, 0);
    if (result == GL_ALREADY_SIGNALED || result == GL_CONDITION_SATISFIED) return 1;
    return result == GL_TIMEOUT_EXPIRED ? 0 : -1;
}

void cs_gl_fence_release(cs_gl_context *context, void *fence) {
    if (!fence) return;
    cs_gl_make_current(context);
    glDeleteSync((GLsync)fence);
}
