/******************************************************************************
    Copyright (C) 2013 by Ruwen Hahn <palana@stunned.de>

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 2 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
******************************************************************************/

#include "gl-subsystem.h"
#include <glad/egl.h>

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <AppKit/AppKit.h>

static const int ctx_attribs[] = {
#ifdef _DEBUG
        EGL_CONTEXT_FLAGS_KHR,
        EGL_CONTEXT_OPENGL_DEBUG_BIT_KHR,
#endif
        EGL_CONTEXT_MAJOR_VERSION,
        3,
        EGL_CONTEXT_MINOR_VERSION,
        0,
        EGL_NONE,
};

static int ctx_pbuffer_attribs[] = {EGL_WIDTH, 2, EGL_HEIGHT, 2, EGL_NONE};

static const EGLint ctx_config_attribs[] = {EGL_STENCIL_SIZE,
                                            0,
                                            EGL_DEPTH_SIZE,
                                            0,
                                            EGL_BUFFER_SIZE,
                                            24,
                                            EGL_ALPHA_SIZE,
                                            0,
                                            EGL_RENDERABLE_TYPE,
                                            EGL_OPENGL_ES3_BIT,
                                            EGL_SURFACE_TYPE,
                                            EGL_WINDOW_BIT | EGL_PBUFFER_BIT,
                                            EGL_NONE};

struct gl_windowinfo {
    NSView *view;
    EGLSurface surface;
    gs_texture_t *texture;
    GLuint fbo;
};

struct gl_platform {
    EGLDisplay edisplay;
    EGLConfig config;
    EGLContext context;
    EGLSurface pbuffer;
};

static const char *get_egl_error_string2(const EGLint error)
{
    switch (error) {
#define OBS_EGL_CASE_ERROR(e) \
        case e:               \
                return #e;
            OBS_EGL_CASE_ERROR(EGL_SUCCESS)
            OBS_EGL_CASE_ERROR(EGL_NOT_INITIALIZED)
            OBS_EGL_CASE_ERROR(EGL_BAD_ACCESS)
            OBS_EGL_CASE_ERROR(EGL_BAD_ALLOC)
            OBS_EGL_CASE_ERROR(EGL_BAD_ATTRIBUTE)
            OBS_EGL_CASE_ERROR(EGL_BAD_CONTEXT)
            OBS_EGL_CASE_ERROR(EGL_BAD_CONFIG)
            OBS_EGL_CASE_ERROR(EGL_BAD_CURRENT_SURFACE)
            OBS_EGL_CASE_ERROR(EGL_BAD_DISPLAY)
            OBS_EGL_CASE_ERROR(EGL_BAD_SURFACE)
            OBS_EGL_CASE_ERROR(EGL_BAD_MATCH)
            OBS_EGL_CASE_ERROR(EGL_BAD_PARAMETER)
            OBS_EGL_CASE_ERROR(EGL_BAD_NATIVE_PIXMAP)
            OBS_EGL_CASE_ERROR(EGL_BAD_NATIVE_WINDOW)
            OBS_EGL_CASE_ERROR(EGL_CONTEXT_LOST)
#undef OBS_EGL_CASE_ERROR
    default:
            return "Unknown";
    }
}

static const char *get_egl_error_string()
{
    return get_egl_error_string2(eglGetError());
}

static void GLAD_API_PTR gl_debug_proc(EGLenum error __unused,
				       const char *command,
				       EGLint messageType,
				       EGLLabelKHR threadLabel __unused,
				       EGLLabelKHR objectLabel __unused,
				       const char* message)
{
    char *typeStr;

    switch (messageType) {
    case EGL_DEBUG_MSG_CRITICAL_KHR:
	    typeStr = "CRITICAL";
	    break;
    case EGL_DEBUG_MSG_ERROR_KHR:
	    typeStr = "ERROR";
	    break;
    case EGL_DEBUG_MSG_WARN_KHR:
	    typeStr = "WARN";
	    break;
    case EGL_DEBUG_MSG_INFO_KHR:
	    typeStr = "INFO";
	    break;
    default:
	    typeStr = "Unknown";
    }

    blog(LOG_DEBUG, "[%s]{%s}: %s", command, typeStr, message);
}

static bool gl_context_create(struct gl_platform *plat)
{
    int frame_buf_config_count = 0;
    EGLDisplay edisplay = EGL_NO_DISPLAY;
    EGLConfig config = NULL;
    EGLContext context = EGL_NO_CONTEXT;
    int egl_min = 0, egl_maj = 0;
    bool success = false;

//    static int display_args[] = {0x3203, 0x320D, EGL_NONE};
//    edisplay = eglGetPlatformDisplayEXT(0x3202, (void *)EGL_DEFAULT_DISPLAY, display_args);
    edisplay = eglGetDisplay(EGL_DEFAULT_DISPLAY);
#ifdef _DEBUG
    static EGLAttrib all_messages[] = {EGL_DEBUG_MSG_CRITICAL_KHR, EGL_TRUE,
				 EGL_DEBUG_MSG_ERROR_KHR, EGL_TRUE,
				 EGL_DEBUG_MSG_WARN_KHR, EGL_TRUE,
				 EGL_DEBUG_MSG_INFO_KHR, EGL_TRUE,
				 EGL_NONE};
    eglDebugMessageControlKHR(&gl_debug_proc, all_messages);
#endif

    if (EGL_NO_DISPLAY == edisplay) {
            blog(LOG_ERROR,
                 "Failed to get EGL display using eglGetDisplay");
            return false;
    }

    if (!eglInitialize(edisplay, &egl_maj, &egl_min)) {
            blog(LOG_ERROR, "Failed to initialize EGL: %s",
                 get_egl_error_string());
            return false;
    }

    gladLoaderLoadEGL(edisplay);

    eglBindAPI(EGL_OPENGL_ES_API);

    if (!eglChooseConfig(edisplay, ctx_config_attribs, &config, 1,
                         &frame_buf_config_count)) {
            blog(LOG_ERROR, "Unable to find suitable EGL config: %s",
                 get_egl_error_string());
            goto error;
    }

    context =
            eglCreateContext(edisplay, config, EGL_NO_CONTEXT, ctx_attribs);
#ifdef _DEBUG
    if (EGL_NO_CONTEXT == context) {
            const EGLint error = eglGetError();
            if (error == EGL_BAD_ATTRIBUTE) {
                    /* Sometimes creation fails because debug gl is not supported */
                    blog(LOG_ERROR,
                         "Unable to create EGL context with DEBUG attrib, trying without");
                    context = eglCreateContext(edisplay, config,
                                               EGL_NO_CONTEXT,
                                               ctx_attribs + 2);
            } else {
                    blog(LOG_ERROR, "Unable to create EGL context: %s",
                         get_egl_error_string2(error));
                    goto error;
            }
    }
#endif
    if (EGL_NO_CONTEXT == context) {
            blog(LOG_ERROR, "Unable to create EGL context: %s",
                 get_egl_error_string());
            goto error;
    }

    plat->pbuffer =
            eglCreatePbufferSurface(edisplay, config, ctx_pbuffer_attribs);
    if (EGL_NO_SURFACE == plat->pbuffer) {
            blog(LOG_ERROR, "Failed to create OpenGL pbuffer: %s",
                 get_egl_error_string());
            goto error;
    }

    plat->edisplay = edisplay;
    plat->config = config;
    plat->context = context;

    success = true;
    blog(LOG_DEBUG, "Created EGLDisplay %p", plat->edisplay);

error:
    if (!success) {
            if (EGL_NO_CONTEXT != context)
                    eglDestroyContext(edisplay, context);
            eglTerminate(edisplay);
    }

    return success;
}

static void gl_context_destroy(struct gl_platform *plat)
{
    eglMakeCurrent(plat->edisplay, EGL_NO_SURFACE, EGL_NO_SURFACE,
                   EGL_NO_CONTEXT);
    eglDestroyContext(plat->edisplay, plat->context);
}

struct gl_platform *gl_platform_create(gs_device_t *device, uint32_t adapter __unused)
{
    struct gl_platform *plat = bmalloc(sizeof(struct gl_platform));

    if (!gladLoaderLoadEGL(NULL)) {
	    blog(LOG_ERROR, "Unable to load EGL entry functions.");
	    goto fail_load_gl;
    }

    device->plat = plat;
    if (!gl_context_create(plat)) {
            blog(LOG_ERROR, "Failed to create context!");
            goto fail_context_create;
    }

    if (!eglMakeCurrent(plat->edisplay, plat->pbuffer, plat->pbuffer,
                        plat->context)) {
            blog(LOG_ERROR, "Failed to make context current: %s",
                 get_egl_error_string());
            goto fail_make_current;
    }

    if (!gladLoaderLoadGLES2()) {
            blog(LOG_ERROR, "Failed to load OpenGL entry functions.");
            goto fail_load_gl;
    }

    goto success;

fail_make_current:
    gl_context_destroy(plat);
fail_context_create:
fail_load_gl:
    bfree(plat);
    plat = NULL;
success:
    return plat;
}

void gl_platform_destroy(struct gl_platform *plat)
{
        if (!plat)
                return;

        gl_context_destroy(plat);
        eglTerminate(plat->edisplay);
        bfree(plat);
}

bool gl_platform_init_swapchain(struct gs_swap_chain *swap)
{
    NSView *view = swap->wi->view;

    const struct gl_platform *plat = swap->device->plat;
    bool success = true;

    const EGLSurface surface =
            eglCreateWindowSurface(plat->edisplay, plat->config, [view layer], 0);
//    view.layer.layoutManager = [CAConstraintLayoutManager layoutManager];
    // TODO this is super gross and an awkward interaction between ANGLE and opengl
    CALayer *sublayer = [[view layer] sublayers][0];
    [sublayer setPosition:CGPointMake([sublayer position].x, 0)];
    if (EGL_NO_SURFACE == surface) {
                blog(LOG_ERROR, "Cannot get window EGL surface: %s",
                     get_egl_error_string());
                success = false;
    }
    if (success) {
//         struct gs_init_data *init_data = &swap->info;
//         swap->wi->texture = device_texture_create(swap->device, init_data->cx, init_data->cy, init_data->format, 1,
//                                                   NULL, GS_RENDER_TARGET);
//         glFlush();
//         eglMakeCurrent(plat->edisplay, surface, surface, plat->context);
//
//         gl_gen_framebuffers(1, &swap->wi->fbo);
//         gl_bind_framebuffer(GL_FRAMEBUFFER, swap->wi->fbo);
//         glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, swap->wi->texture->texture, 0);
//         gl_success("glFrameBufferTexture2D");
//         glFlush();
//         eglMakeCurrent(plat->edisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
         swap->wi->surface = surface;
    }

    return success;
}

void gl_platform_cleanup_swapchain(struct gs_swap_chain *swap __unused)
{
    eglDestroySurface(swap->device->plat->edisplay, swap->wi->surface);
}

struct gl_windowinfo *gl_windowinfo_create(const struct gs_init_data *info)
{
    if (!info)
        return NULL;

    if (!info->window.view)
        return NULL;

    struct gl_windowinfo *wi = bzalloc(sizeof(struct gl_windowinfo));

    wi->view = info->window.view;
    wi->view.window.colorSpace = NSColorSpace.sRGBColorSpace;

//    if (![wi->view.layer isKindOfClass:[CAMetalLayer class]])
//    {
//	[wi->view setLayer:[CAMetalLayer layer]];
//	[wi->view setWantsLayer:YES];
//    }

    return wi;
}

void gl_windowinfo_destroy(struct gl_windowinfo *wi)
{
    if (!wi)
        return;

    wi->view = nil;
    bfree(wi);
}

void gl_update(gs_device_t *device __unused)
{
//    gs_swapchain_t *swap = device->cur_swap;
//    dispatch_async(dispatch_get_main_queue(), ^() {
//        if (!swap || !swap->wi) {
//            return;
//        }
//
//        eglMakeCurrent(device->plat->edisplay, swap->wi->surface, swap->wi->surface, device->plat->context);
////        [context update];
//        struct gs_init_data *info = &swap->info;
//        gs_texture_t *previous = swap->wi->texture;
//        swap->wi->texture = device_texture_create(device, info->cx, info->cy, info->format, 1, NULL, GS_RENDER_TARGET);
//        gl_bind_framebuffer(GL_FRAMEBUFFER, swap->wi->fbo);
//        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, swap->wi->texture->texture, 0);
//        gl_success("glFrameBufferTexture2D");
//        gs_texture_destroy(previous);
//        glFlush();
//        eglMakeCurrent(device->plat->edisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, device->plat->context);
//    });
}

void gl_clear_context(gs_device_t *device)
{
        if (!eglMakeCurrent(device->plat->edisplay, EGL_NO_SURFACE, EGL_NO_SURFACE,
                            EGL_NO_CONTEXT)) {
                blog(LOG_ERROR, "Failed to reset current context.");
        }
}

void device_enter_context(gs_device_t *device)
{
        const EGLContext context = device->plat->context;
        const EGLDisplay display = device->plat->edisplay;
        const EGLSurface surface = (device->cur_swap)
                                           ? device->cur_swap->wi->surface
                                           : device->plat->pbuffer;

        if (!eglMakeCurrent(display, surface, surface, context))
                blog(LOG_ERROR, "Failed to make context current: %s",
                     get_egl_error_string());
}

void device_leave_context(gs_device_t *device)
{
	glFlush();
	device->cur_vertex_buffer = NULL;
	device->cur_index_buffer = NULL;
	device->cur_render_target = NULL;
	device->cur_zstencil_buffer = NULL;
	device->cur_swap = NULL;
	device->cur_fbo = NULL;
        if (!eglMakeCurrent(device->plat->edisplay, EGL_NO_SURFACE, EGL_NO_SURFACE,
                            EGL_NO_CONTEXT)) {
                blog(LOG_ERROR, "Failed to reset current context: %s",
                     get_egl_error_string());
        }
}

void *device_get_device_obj(gs_device_t *device)
{
    return device->plat->context;
}

void device_load_swapchain(gs_device_t *device, gs_swapchain_t *swap)
{
    if (device->cur_swap == swap)
		return;

    device->cur_swap = swap;

    device_enter_context(device);
}

bool device_is_present_ready(gs_device_t *device __unused)
{
    return true;
}

void device_present(gs_device_t *device)
{
    struct gl_platform *plat = device->plat;
    struct gl_windowinfo *wi = device->cur_swap->wi;
    if (eglSwapInterval(plat->edisplay, 0) == EGL_FALSE) {
	blog(LOG_ERROR, "eglSwapInterval failed");
    }
    if (eglSwapBuffers(plat->edisplay, wi->surface) == EGL_FALSE) {
	blog(LOG_ERROR, "eglSwapBuffers failed (%s)", get_egl_error_string());
    }
}

bool device_is_monitor_hdr(gs_device_t *device __unused, void *monitor __unused)
{
    return false;
}

void gl_getclientsize(const struct gs_swap_chain *swap, uint32_t *width, uint32_t *height)
{
    if (width)
        *width = swap->info.cx;
    if (height)
        *height = swap->info.cy;
}

gs_texture_t *device_texture_create_from_iosurface(gs_device_t *device __unused, void *iosurf __unused)
{
    return NULL;
//    IOSurfaceRef ref = (IOSurfaceRef) iosurf;
//    struct gs_texture_2d *tex = bzalloc(sizeof(struct gs_texture_2d));
//
//    OSType pf = IOSurfaceGetPixelFormat(ref);
//
//    FourCharCode l10r_code = 0;
//    l10r_code = ('l' << 24) | ('1' << 16) | ('0' << 8) | 'r';
//
//    FourCharCode bgra_code = 0;
//    bgra_code = ('B' << 24) | ('G' << 16) | ('R' << 8) | 'A';
//
//    const bool l10r = pf == l10r_code;
//    if (pf == 0)
//        blog(LOG_ERROR, "Invalid IOSurface Buffer");
//    else if ((pf != bgra_code) && !l10r)
//        blog(LOG_ERROR, "Unexpected pixel format: %d (%c%c%c%c)", pf, pf >> 24, pf >> 16, pf >> 8, pf);
//
//    const enum gs_color_format color_format = l10r ? GS_R10G10B10A2 : GS_BGRA;
//
//    tex->base.device = device;
//    tex->base.type = GS_TEXTURE_2D;
//    tex->base.format = color_format;
//    tex->base.levels = 1;
//    tex->base.gl_format = l10r ? GL_BGRA_EXT : convert_gs_format(color_format);
//    tex->base.gl_internal_format = convert_gs_internal_format(color_format);
//    // TOD that second one is super wrong
//    tex->base.gl_type = l10r ? GL_UNSIGNED_INT_2_10_10_10_REV : GL_UNSIGNED_INT_VEC4;
//    tex->base.gl_target = GL_TEXTURE_2D;
//    tex->base.is_dynamic = false;
//    tex->base.is_render_target = false;
//    tex->base.gen_mipmaps = false;
//    tex->width = (uint32_t) IOSurfaceGetWidth(ref);
//    tex->height = (uint32_t) IOSurfaceGetHeight(ref);
//
//    if (!gl_gen_textures(1, &tex->base.texture))
//        goto fail;
//
//    if (!gl_bind_texture(tex->base.gl_target, tex->base.texture))
//        goto fail;
//
//    CGLError err = CGLTexImageIOSurface2D([[NSOpenGLContext currentContext] CGLContextObj], tex->base.gl_target,
//                                          tex->base.gl_internal_format, tex->width, tex->height, tex->base.gl_format,
//                                          tex->base.gl_type, ref, 0);
//
//    if (err != kCGLNoError) {
//        blog(LOG_ERROR,
//             "CGLTexImageIOSurface2D: %u, %s"
//             " (device_texture_create_from_iosurface)",
//             err, CGLErrorString(err));
//
//        gl_success("CGLTexImageIOSurface2D");
//        goto fail;
//    }
//
//    if (!gl_tex_param_i(tex->base.gl_target, GL_TEXTURE_MAX_LEVEL, 0))
//        goto fail;
//
//    if (!gl_bind_texture(tex->base.gl_target, 0))
//        goto fail;
//
//    return (gs_texture_t *) tex;
//
//fail:
//    gs_texture_destroy((gs_texture_t *) tex);
//    blog(LOG_ERROR, "device_texture_create_from_iosurface (GL) failed");
//    return NULL;
}

gs_texture_t *device_texture_open_shared(gs_device_t *device, uint32_t handle)
{
    gs_texture_t *texture = NULL;
    IOSurfaceRef ref = IOSurfaceLookupFromMachPort((mach_port_t) handle);
    texture = device_texture_create_from_iosurface(device, ref);
    CFRelease(ref);
    return texture;
}

bool device_shared_texture_available(void)
{
    return true;
}

bool gs_texture_rebind_iosurface(gs_texture_t *texture __unused, void *iosurf __unused)
{
    return false;
//    if (!texture)
//        return false;
//
//    if (!iosurf)
//        return false;
//
//    FourCharCode l10r_code = 0;
//    l10r_code = ('l' << 24) | ('1' << 16) | ('0' << 8) | 'r';
//
//    FourCharCode bgra_code = 0;
//    bgra_code = ('B' << 24) | ('G' << 16) | ('R' << 8) | 'A';
//
//    struct gs_texture_2d *tex = (struct gs_texture_2d *) texture;
//    IOSurfaceRef ref = (IOSurfaceRef) iosurf;
//
//    OSType pf = IOSurfaceGetPixelFormat(ref);
//    if (pf == 0) {
//        blog(LOG_ERROR, "Invalid IOSurface buffer");
//    } else if ((pf != bgra_code) && (pf != l10r_code)) {
//        blog(LOG_ERROR, "Unexpected pixel format: %d (%c%c%c%c)", pf, pf >> 24, pf >> 16, pf >> 8, pf);
//    }
//
//    tex->width = (uint32_t) IOSurfaceGetWidth(ref);
//    tex->height = (uint32_t) IOSurfaceGetHeight(ref);
//
//    if (!gl_bind_texture(tex->base.gl_target, tex->base.texture))
//        return false;
//
//    CGLError err = CGLTexImageIOSurface2D([[NSOpenGLContext currentContext] CGLContextObj], tex->base.gl_target,
//                                          tex->base.gl_internal_format, tex->width, tex->height, tex->base.gl_format,
//                                          tex->base.gl_type, ref, 0);
//
//    if (err != kCGLNoError) {
//        blog(LOG_ERROR,
//             "CGLTexImageIOSurface2D: %u, %s"
//             " (gs_texture_rebind_iosurface)",
//             err, CGLErrorString(err));
//
//        gl_success("CGLTexImageIOSurface2D");
//        return false;
//    }
//
//    if (!gl_bind_texture(tex->base.gl_target, 0))
//        return false;
//
//    return true;
}
