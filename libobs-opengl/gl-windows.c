/******************************************************************************
    Copyright (C) 2023 by Lain Bailey <lain@obsproject.com>

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

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <util/darray.h>
#include "gl-subsystem.h"
#include <glad/egl.h>

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

/* Basically swapchain-specific information.  Fortunately for windows this is
 * super basic stuff */
struct gl_windowinfo {
	HWND hwnd;
	EGLSurface surface;
};

/* Like the other subsystems, the GL subsystem has one swap chain created by
 * default. */
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

static void GLAD_API_PTR gl_debug_proc(EGLenum error,
				       const char *command,
				       EGLint messageType,
				       EGLLabelKHR threadLabel,
				       EGLLabelKHR objectLabel,
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

/* For now, only support basic 32bit formats for graphics output. */
static inline int get_color_format_bits(enum gs_color_format format)
{
	switch (format) {
	case GS_RGBA:
	case GS_BGRA:
		return 32;
	default:
		return 0;
	}
}

static inline int get_depth_format_bits(enum gs_zstencil_format zsformat)
{
	switch (zsformat) {
	case GS_Z16:
		return 16;
	case GS_Z24_S8:
		return 24;
	default:
		return 0;
	}
}

static inline int get_stencil_format_bits(enum gs_zstencil_format zsformat)
{
	switch (zsformat) {
	case GS_Z24_S8:
		return 8;
	default:
		return 0;
	}
}

/* would use designated initializers but Microsoft sort of sucks */
static inline void init_dummy_pixel_format(PIXELFORMATDESCRIPTOR *pfd)
{
	memset(pfd, 0, sizeof(PIXELFORMATDESCRIPTOR));
	pfd->nSize = sizeof(PIXELFORMATDESCRIPTOR);
	pfd->nVersion = 1;
	pfd->iPixelType = PFD_TYPE_RGBA;
	pfd->cColorBits = 32;
	pfd->cDepthBits = 24;
	pfd->cStencilBits = 8;
	pfd->iLayerType = PFD_MAIN_PLANE;
	pfd->dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL |
		       PFD_DOUBLEBUFFER;
}

void gl_update(gs_device_t *device)
{
	/* does nothing on windows */
	UNUSED_PARAMETER(device);
}

void gl_clear_context(gs_device_t *device)
{
	if (!eglMakeCurrent(device->plat->edisplay, EGL_NO_SURFACE, EGL_NO_SURFACE,
			    EGL_NO_CONTEXT)) {
		blog(LOG_ERROR, "Failed to reset current context.");
	}
}

static void init_dummy_swap_info(struct gs_init_data *info)
{
	info->format = GS_RGBA;
	info->zsformat = GS_ZS_NONE;
}

static bool gl_context_create(struct gl_platform *plat)
{
	int frame_buf_config_count = 0;
	EGLDisplay edisplay = EGL_NO_DISPLAY;
	EGLConfig config = NULL;
	EGLContext context = EGL_NO_CONTEXT;
	int egl_min = 0, egl_maj = 0;
	bool success = false;

	    static int display_args[] = {0x3203, 0x3208, EGL_NONE};
	    edisplay = eglGetPlatformDisplayEXT(0x3202, (void *)EGL_DEFAULT_DISPLAY, display_args);
//	edisplay = eglGetDisplay(EGL_DEFAULT_DISPLAY);
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

struct gl_platform *gl_platform_create(gs_device_t *device, uint32_t adapter)
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
	HWND win = swap->wi->hwnd;

	const struct gl_platform *plat = swap->device->plat;
	bool success = true;

	const EGLSurface surface =
		eglCreateWindowSurface(plat->edisplay, plat->config, win, 0);
	if (EGL_NO_SURFACE == surface) {
		blog(LOG_ERROR, "Cannot get window EGL surface: %s",
		     get_egl_error_string());
		success = false;
	}
	if (success) {
		swap->wi->surface = surface;
	}

	return success;
}

void gl_platform_cleanup_swapchain(struct gs_swap_chain *swap)
{
	eglDestroySurface(swap->device->plat->edisplay, swap->wi->surface);
}

struct gl_windowinfo *gl_windowinfo_create(const struct gs_init_data *info)
{
	struct gl_windowinfo *wi = bzalloc(sizeof(struct gl_windowinfo));
	wi->hwnd = info->window.hwnd;

	return wi;
}

void gl_windowinfo_destroy(struct gl_windowinfo *wi)
{
	if (wi) {
		bfree(wi);
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

bool device_is_present_ready(gs_device_t *device)
{
	UNUSED_PARAMETER(device);
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

extern void gl_getclientsize(const struct gs_swap_chain *swap, uint32_t *width,
			     uint32_t *height)
{
	RECT rc;
	if (swap) {
		GetClientRect(swap->wi->hwnd, &rc);
		*width = rc.right;
		*height = rc.bottom;
	} else {
		*width = 0;
		*height = 0;
	}
}

EXPORT bool device_is_monitor_hdr(gs_device_t *device, void *monitor)
{
	return false;
}

EXPORT bool device_gdi_texture_available(void)
{
	return false;
}

EXPORT bool device_shared_texture_available(void)
{
	return false;
}
