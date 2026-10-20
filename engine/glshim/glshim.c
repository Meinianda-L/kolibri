// Kolibri GLES shim for the engine's host GLES mode (ANDROID_EGL_ON_EGL=1).
//
// The engine (gfxstream) loads the host EGL/GLES implementation from the engine's
// lib64/gles_angle/. In Kolibri's engine clone those files are these shims: every
// export jumps to the bundled ANGLE (real/angle_GLESv2.dylib, unchanged) through
// generated trampolines, except a few entry points we replace:
//   - glGetString: report a configurable GPU name (KOLIBRI_GPU_RENDERER / KOLIBRI_GPU_VENDOR)
//   - EGL surface / viewport / readback calls: optional tracing (KOLIBRI_GLSHIM_LOG=path)
//
// Built once per machine by build.sh (it copies ANGLE from the installed SDK).

#include <dlfcn.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef unsigned int GLenum;
typedef unsigned int GLuint;
typedef int GLint;
typedef int GLsizei;
typedef unsigned char GLubyte;
typedef unsigned int GLbitfield;
typedef void* EGLDisplay;
typedef void* EGLConfig;
typedef void* EGLSurface;
typedef void* EGLContext;
typedef intptr_t EGLNativeWindowType;
typedef int32_t EGLint;
typedef unsigned int EGLBoolean;
typedef void (*Proc)(void);

#define GL_VENDOR 0x1F00
#define GL_RENDERER 0x1F01
#define EGL_WIDTH 0x3057
#define EGL_HEIGHT 0x3056
#define EGL_NONE 0x3038

// ---------------------------------------------------------------------------
// Tracing

static FILE* log_file(void) {
    static FILE* f;
    static int tried;
    if (!tried) {
        tried = 1;
        const char* p = getenv("KOLIBRI_GLSHIM_LOG");
        if (p && *p) f = fopen(p, "a");
        if (f) setvbuf(f, NULL, _IOLBF, 0);
    }
    return f;
}

static pthread_mutex_t log_lock = PTHREAD_MUTEX_INITIALIZER;

static void trace(int* budget, const char* fmt, ...) {
    FILE* f = log_file();
    if (!f || *budget <= 0) return;
    pthread_mutex_lock(&log_lock);
    (*budget)--;
    va_list ap;
    va_start(ap, fmt);
    fprintf(f, "[%p] ", (void*)pthread_self());
    vfprintf(f, fmt, ap);
    fputc('\n', f);
    va_end(ap);
    pthread_mutex_unlock(&log_lock);
}

// ---------------------------------------------------------------------------
// The real ANGLE: real/angle_GLESv2.dylib next to this shim (renamed so it can never
// be confused with the shim by name). It implements GL (gl*) and EGL (EGL_*).

static void* angle(void) {
    static void* h;
    if (!h) {
        Dl_info info;
        dladdr((void*)angle, &info);
        char path[4096];
        snprintf(path, sizeof path, "%s", info.dli_fname);
        char* slash = strrchr(path, '/');
        if (slash) *slash = 0;
        strncat(path, "/real/angle_GLESv2.dylib", sizeof path - strlen(path) - 1);
        h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
        static int budget = 2;
        trace(&budget, "angle(%s) -> %p %s", path, h, h ? "" : dlerror());
    }
    return h;
}

// Forwarding table for every export we do not override (see gen_trampolines.py).
extern void* fwd_tab[];
extern const char* const fwd_names[];
extern const int fwd_count;

__attribute__((constructor)) static void fill_forwarders(void) {
    void* h = angle();
    int missing = 0;
    for (int i = 0; i < fwd_count; i++) {
        fwd_tab[i] = h ? dlsym(h, fwd_names[i]) : NULL;
        if (!fwd_tab[i]) missing++;
    }
    static int budget = 1;
    trace(&budget, "forwarders: %d resolved, %d missing", fwd_count - missing, missing);
}

// GLSHIM_TRACE builds: per-function call counts, dumped to the log every 3 seconds.
#include <stdatomic.h>
#include <time.h>
static _Atomic unsigned long fwd_counts[4096];
__attribute__((visibility("hidden"))) void fwd_count_call(long i) {
    atomic_fetch_add_explicit(&fwd_counts[i], 1, memory_order_relaxed);
    static _Atomic long last;
    long now = (long)time(NULL);
    long prev = atomic_load(&last);
    if (now - prev < 3 || !atomic_compare_exchange_strong(&last, &prev, now)) return;
    FILE* f = log_file();
    if (!f) return;
    pthread_mutex_lock(&log_lock);
    fprintf(f, "--- calls (%s) ---\n", fwd_count > 200 ? "GLES" : "EGL");
    for (int k = 0; k < fwd_count; k++) {
        unsigned long n = atomic_exchange(&fwd_counts[k], 0);
        if (n) fprintf(f, "%8lu %s\n", n, fwd_names[k]);
    }
    pthread_mutex_unlock(&log_lock);
}

// Real EGL function `fn`, implemented by ANGLE as `impl` (e.g. EGL_MakeCurrent).
#define REAL_EGL(ret, fn, impl, args)                                         \
    static ret(*real_##fn) args;                                              \
    static void load_##fn(void) {                                             \
        if (!real_##fn) real_##fn = (ret(*) args)dlsym(angle(), #impl);       \
    }

// Real GL function `fn`.
#define REAL_GL(ret, fn, args)                                                \
    static ret(*real_##fn) args;                                              \
    static void load_##fn(void) {                                             \
        if (!real_##fn) real_##fn = (ret(*) args)dlsym(angle(), #fn);         \
    }

// ---------------------------------------------------------------------------
// GLES

#ifdef SHIM_GLES
REAL_GL(const GLubyte*, glGetString, (GLenum))
REAL_GL(void, glViewport, (GLint, GLint, GLsizei, GLsizei))
REAL_GL(void, glReadPixels, (GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void*))
REAL_GL(void, glBlitFramebuffer, (GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLbitfield, GLenum))

__attribute__((visibility("default"))) const GLubyte* glGetString(GLenum name) {
    load_glGetString();
    if (name == GL_RENDERER) {
        const char* r = getenv("KOLIBRI_GPU_RENDERER");
        if (r && *r) return (const GLubyte*)r;
    }
    if (name == GL_VENDOR) {
        const char* v = getenv("KOLIBRI_GPU_VENDOR");
        if (v && *v) return (const GLubyte*)v;
    }
    return real_glGetString(name);
}

__attribute__((visibility("default"))) void glViewport(GLint x, GLint y, GLsizei w, GLsizei h) {
    static int budget = 400;
    load_glViewport();
    trace(&budget, "glViewport(%d, %d, %d, %d)", x, y, w, h);
    real_glViewport(x, y, w, h);
}

__attribute__((visibility("default"))) void glReadPixels(GLint x, GLint y, GLsizei w, GLsizei h, GLenum format, GLenum type,
                                                         void* data) {
    static int budget = 200;
    load_glReadPixels();
    trace(&budget, "glReadPixels(%d, %d, %d, %d, fmt=0x%x, type=0x%x)", x, y, w, h, format, type);
    real_glReadPixels(x, y, w, h, format, type, data);
}

__attribute__((visibility("default"))) void glBlitFramebuffer(GLint sx0, GLint sy0, GLint sx1, GLint sy1, GLint dx0,
                                                              GLint dy0, GLint dx1, GLint dy1, GLbitfield mask,
                                                              GLenum filter) {
    static int budget = 200;
    load_glBlitFramebuffer();
    trace(&budget, "glBlitFramebuffer(src %d,%d-%d,%d dst %d,%d-%d,%d)", sx0, sy0, sx1, sy1, dx0, dy0, dx1, dy1);
    real_glBlitFramebuffer(sx0, sy0, sx1, sy1, dx0, dy0, dx1, dy1, mask, filter);
}

#endif  // SHIM_GLES

// ---------------------------------------------------------------------------
// EGL

#ifdef SHIM_EGL

REAL_EGL(EGLSurface, eglCreatePbufferSurface, EGL_CreatePbufferSurface, (EGLDisplay, EGLConfig, const EGLint*))
REAL_EGL(EGLSurface, eglCreateWindowSurface, EGL_CreateWindowSurface, (EGLDisplay, EGLConfig, EGLNativeWindowType, const EGLint*))
REAL_EGL(EGLBoolean, eglQuerySurface, EGL_QuerySurface, (EGLDisplay, EGLSurface, EGLint, EGLint*))
REAL_EGL(EGLBoolean, eglMakeCurrent, EGL_MakeCurrent, (EGLDisplay, EGLSurface, EGLSurface, EGLContext))
REAL_EGL(Proc, eglGetProcAddress, EGL_GetProcAddress, (const char*))

static void attribs_str(const EGLint* a, char* out, size_t n) {
    out[0] = 0;
    for (int i = 0; a && a[i] != EGL_NONE && i < 32; i += 2) {
        char item[48];
        snprintf(item, sizeof item, "0x%x=%d ", a[i], a[i + 1]);
        strncat(out, item, n - strlen(out) - 1);
    }
}

__attribute__((visibility("default"))) EGLSurface eglCreatePbufferSurface(EGLDisplay d, EGLConfig c, const EGLint* a) {
    static int budget = 200;
    load_eglCreatePbufferSurface();
    EGLSurface s = real_eglCreatePbufferSurface(d, c, a);
    char buf[512];
    attribs_str(a, buf, sizeof buf);
    trace(&budget, "eglCreatePbufferSurface(%s) -> %p", buf, s);
    return s;
}

__attribute__((visibility("default"))) EGLSurface eglCreateWindowSurface(EGLDisplay d, EGLConfig c, EGLNativeWindowType w,
                                                                         const EGLint* a) {
    static int budget = 200;
    load_eglCreateWindowSurface();
    EGLSurface s = real_eglCreateWindowSurface(d, c, w, a);
    char buf[512];
    attribs_str(a, buf, sizeof buf);
    trace(&budget, "eglCreateWindowSurface(win=%p, %s) -> %p", (void*)w, buf, s);
    return s;
}

__attribute__((visibility("default"))) EGLBoolean eglQuerySurface(EGLDisplay d, EGLSurface s, EGLint attr, EGLint* v) {
    static int budget = 300;
    load_eglQuerySurface();
    EGLBoolean r = real_eglQuerySurface(d, s, attr, v);
    if (attr == EGL_WIDTH || attr == EGL_HEIGHT)
        trace(&budget, "eglQuerySurface(%p, %s) = %d", s, attr == EGL_WIDTH ? "WIDTH" : "HEIGHT", v ? *v : -1);
    return r;
}

__attribute__((visibility("default"))) EGLBoolean eglMakeCurrent(EGLDisplay d, EGLSurface draw, EGLSurface read,
                                                                 EGLContext ctx) {
    static int budget = 300;
    load_eglMakeCurrent();
    trace(&budget, "eglMakeCurrent(draw=%p read=%p ctx=%p)", draw, read, ctx);
    return real_eglMakeCurrent(d, draw, read, ctx);
}

// Hand out our wrappers for functions looked up by name.
__attribute__((visibility("default"))) Proc eglGetProcAddress(const char* name) {
    load_eglGetProcAddress();
    if (!real_eglGetProcAddress) return NULL;
    // Any GL entry point the GLES shim exports (our wrappers and the counted trampolines)
    // is handed out from there, so lookups by name and by eglGetProcAddress agree.
    if (name && !strncmp(name, "gl", 2)) {
        static void* gles;
        if (!gles) {
            Dl_info info;
            dladdr((void*)eglGetProcAddress, &info);
            char path[4096];
            snprintf(path, sizeof path, "%s", info.dli_fname);
            char* slash = strrchr(path, '/');
            if (slash) snprintf(slash + 1, sizeof path - (size_t)(slash + 1 - path), "libGLESv2.dylib");
            gles = dlopen(path, RTLD_NOW | RTLD_LOCAL);
        }
        void* p = gles ? dlsym(gles, name) : NULL;
        if (p) return (Proc)p;
    }
    return real_eglGetProcAddress(name);
}

#endif  // SHIM_EGL
