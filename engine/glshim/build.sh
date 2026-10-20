#!/bin/bash
# Build the Kolibri GLES shim into the gles_angle/ dir of an engine clone ($1).
# The engine's ANGLE libGLESv2 is copied unchanged to real/angle_GLESv2.dylib; the shims
# libEGL.dylib / libGLESv2.dylib forward every export to it (EGL eglFoo -> EGL_Foo).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?usage: build.sh <gles_angle dir of an engine clone>}"
SDK="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
ANGLE="${ANGLE_SRC:-$SDK/emulator/lib64/gles_angle}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

rm -rf "$OUT/real"
mkdir -p "$OUT/real"
cp -f "$ANGLE/libGLESv2.dylib" "$OUT/real/angle_GLESv2.dylib"

exports() { nm -gU "$1" | awk '$2 == "T" {sub(/^_/, "", $3); print $3}'; }

# libGLESv2: every ANGLE export, same name.
GLES_OVERRIDES=glGetString,glViewport,glReadPixels,glBlitFramebuffer
python3 "$HERE/gen_trampolines.py" "$TMP/gles.s" "$TMP/gles_tab.c" fwd "$GLES_OVERRIDES" \
    $(exports "$ANGLE/libGLESv2.dylib")
# libEGL: ANGLE's libEGL export list, each eglFoo implemented by EGL_Foo in libGLESv2.
EGL_OVERRIDES=eglCreatePbufferSurface,eglCreateWindowSurface,eglQuerySurface,eglMakeCurrent,eglGetProcAddress
python3 "$HERE/gen_trampolines.py" "$TMP/egl.s" "$TMP/egl_tab.c" fwd "$EGL_OVERRIDES" \
    $(exports "$ANGLE/libEGL.dylib" | grep '^egl' | sed -E 's/^egl(.*)$/egl\1=EGL_\1/')

build() {  # name define asm table
    clang -O2 -dynamiclib -arch arm64 -fvisibility=hidden -D"$2" \
        -o "$OUT/$1.dylib" "$HERE/glshim.c" "$3" "$4" -install_name "@loader_path/$1.dylib"
    codesign --force --sign - "$OUT/$1.dylib" >/dev/null
}
build libGLESv2 SHIM_GLES "$TMP/gles.s" "$TMP/gles_tab.c"
build libEGL SHIM_EGL "$TMP/egl.s" "$TMP/egl_tab.c"
echo "built $OUT ($(exports "$OUT/libGLESv2.dylib" | wc -l | tr -d ' ') GLES + $(exports "$OUT/libEGL.dylib" | wc -l | tr -d ' ') EGL exports)"
