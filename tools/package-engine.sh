#!/bin/bash
# Package the engine built from source (engine/src-patches) for the app bundle: only what a
# headless arm64 Kolibri phone needs, thinned to arm64, stripped and ad-hoc signed.
#   tools/package-engine.sh [objs-emu dir] [dest]
set -euo pipefail
SRC="${1:-$HOME/emulator-src/objs-emu}"
DEST="${2:-$(cd "$(dirname "$0")/.." && pwd)/app/build/engine-bin}"
rm -rf "$DEST"; mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"   # absolute: the steps below cd around
for e in emulator emulator-check lib lib64 bin64 resources crashpad_handler netsimd mksdcard qemu-img source.properties; do
    [ -e "$SRC/$e" ] && cp -R "$SRC/$e" "$DEST/$e"
done
mkdir -p "$DEST/qemu/darwin-aarch64"
cp "$SRC/qemu/darwin-aarch64/qemu-system-aarch64-headless" "$DEST/qemu/darwin-aarch64/"
# Not used by Kolibri: software renderers and their LLVM, the windowed UI (Qt), host-side ANGLE
# (host-GLES mode), Vulkan validation layers, test modules.
cd "$DEST/lib64"
rm -rf gles_swiftshader gles_angle qt crashpad_snapshot_test_module*.so libemugl_test_shared_library.dylib libprotoc*
cd vulkan
rm -rf layers libLLVM.dylib libvulkan_lvp.dylib lvp_icd.json libvulkan_kosmickrisp.dylib libkosmickrisp_icd.json \
       libvk_swiftshader.dylib vk_swiftshader_icd.json libz3*.dylib glslangValidator
cd "$DEST"
# arm64 only, no symbols, re-signed (Apple Silicon refuses modified, unsigned code).
# Keep each binary's entitlements: qemu needs com.apple.security.hypervisor, or HVF says HV_DENIED.
ENT="$(mktemp)"
find . -type f | while read -r f; do
    file -b "$f" | grep -q "Mach-O" || continue
    codesign -d --entitlements :- "$f" > "$ENT" 2>/dev/null || : > "$ENT"
    if lipo -archs "$f" 2>/dev/null | grep -q " "; then lipo "$f" -thin arm64 -output "$f.thin" && mv "$f.thin" "$f"; fi
    strip -x "$f" 2>/dev/null || true
    if [ -s "$ENT" ]; then codesign --force --sign - --entitlements "$ENT" "$f" >/dev/null
    else codesign --force --sign - "$f" >/dev/null 2>&1 || true; fi
done
rm -f "$ENT"
echo "packaged $(du -sh "$DEST" | cut -f1) into $DEST"
