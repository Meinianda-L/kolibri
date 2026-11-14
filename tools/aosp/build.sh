#!/bin/bash
# Build Kolibri's Android image inside the Lima VM (tools/aosp/lima-aosp.yaml).
#   tools/aosp/build.sh [jobs]     (on the Mac; it stages files, then builds in the VM)
# Source: $HOME/aosp, a copy of /Volumes/aosp (AOSP android-12.1.0_r27) on the VM disk. Output: $HOME/out.
set -eo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEVSRC="$HERE/device/kolibri/arm64"
if [ "$(uname)" = Darwin ]; then
    # On the Mac: stage what the image takes from the rest of the repo (the VM only mounts
    # tools/aosp), then run this script inside the VM.
    REPO="$(cd "$HERE/../.." && pwd)"
    # No build machine's user/host/date in the image's fingerprint and build props.
    BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d)}"
    mkdir -p "$DEVSRC/prebuilt" "$DEVSRC/media"
    rsync -a "$REPO/guest/launcher/out/KolibriLauncher.apk" "$DEVSRC/prebuilt/"
    rsync -a "$REPO/guest/wallpaper/kolibri-wallpaper-2560x1440.png" "$DEVSRC/media/kolibri_wallpaper.png"
    python3 "$HERE/gen-profiles.py" "$REPO" "$DEVSRC/profiles" SP2A.220505.008 "$BUILD_NUMBER"
    exec limactl shell aosp env BUILD_NUMBER="$BUILD_NUMBER" bash "$HERE/build.sh" "$@"
fi
JOBS="${1:-6}"
# The source tree walk at startup (soong's finder) opens many files at once.
ulimit -n "$(ulimit -Hn)"
SRC="$HOME/aosp"   # copied from /Volumes/aosp (virtiofs hits macOS file limits)
rsync -a --delete "$HERE/device/kolibri/" "$SRC/device/kolibri/"
export BUILD_USERNAME=kolibri BUILD_HOSTNAME=kolibri BUILD_NUMBER
cd "$SRC"
# The board's product.prop (picked up from the device dir) carries the boot-time profile import.
DEV="$SRC/device/kolibri/arm64"
cmp -s "$DEV/product.prop" device/generic/goldfish/emulator64_arm64/product.prop || \
    cp "$DEV/product.prop" device/generic/goldfish/emulator64_arm64/product.prop
# Host dex2oat needs its heap below 4 GB. On x86_64 ART asks for that with MAP_32BIT, which
# the arm64 kernel under Rosetta ignores (dex2oat aborts: "ref <= 0xFFFFFFFFU"); use ART's
# linear-scan low-4GB allocator instead, as it already does on arm64 and macOS hosts.
MEMMAP=art/libartbase/base/mem_map.h
grep -q 'defined(__APPLE__) || defined(__x86_64__)' "$MEMMAP" || \
    sed -i 's/(defined(__aarch64__) || defined(__APPLE__))/(defined(__aarch64__) || defined(__APPLE__) || defined(__x86_64__))/' "$MEMMAP"
# A changed upstream line would leave the patch silently unapplied and dex2oat failing hours in.
grep -q 'defined(__APPLE__) || defined(__x86_64__)' "$MEMMAP" || { echo "ART low-4GB patch did not apply to $MEMMAP"; exit 1; }
export OUT_DIR="$HOME/out"
# Partition build.props don't depend on BUILD_NUMBER; drop them so every image carries this one.
P="$OUT_DIR/target/product/emulator64_arm64"
rm -f "$P/system/build.prop" "$P/system_ext/etc/build.prop" "$P/product/etc/build.prop" \
      "$P/vendor/build.prop" "$P/odm/etc/build.prop" "$P/vendor/odm/etc/build.prop" \
      "$P/vendor/vendor_dlkm/etc/build.prop" "$P/vendor/odm_dlkm/etc/build.prop" \
      "$P/ramdisk/system/etc/ramdisk/build.prop"
source build/envsetup.sh
lunch kolibri_arm64-userdebug
# The emulator image zip (system-images layout: system.img, vendor.img, kernel, ramdisk, ...).
# Rosetta now and then crashes a translated tool under load (seen: "Failed to map AOT header",
# a clang segfault, a JVM rejecting its own options); ninja resumes where it stopped, so such
# a run is retried. Any other failure is a real build error: stop at once.
GLITCH='Failed to map AOT header|rosetta error|Segmentation fault|Bus error|Unrecognized option: -$'
for try in 1 2 3 4 5 6 7 8; do
    if { m -j"$JOBS" && m -j"$JOBS" emu_img_zip; } 2>&1 | tee "$OUT_DIR/attempt.log"; then ok=1; break; fi
    grep -qE "$GLITCH" "$OUT_DIR/attempt.log" || { echo "#### build failed (not a Rosetta glitch) ####"; exit 1; }
    echo "#### build attempt $try hit a Rosetta glitch, retrying ####"
    sleep 5
done
[ -n "$ok" ] || { echo "#### build failed after retries ####"; exit 1; }
ls -la "$OUT_DIR/target/product/emulator64_arm64/"*.img "$OUT_DIR"/host/linux-x86/sdk_addon/*img*.zip 2>/dev/null || \
    find "$OUT_DIR" -maxdepth 4 -name "*img*.zip"
