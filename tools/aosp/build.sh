#!/bin/bash
# Build Kolibri's Android image inside the Lima VM (tools/aosp/lima-aosp.yaml).
#   limactl shell aosp bash "$PWD/tools/aosp/build.sh" [jobs]     (from the repo root; ~ is mounted)
# Source: $HOME/aosp, a copy of /Volumes/aosp (AOSP android-12.1.0_r27) on the VM disk. Output: $HOME/out.
set -eo pipefail
JOBS="${1:-6}"
# The source tree walk at startup (soong's finder over virtiofs) opens many files at once.
ulimit -n "$(ulimit -Hn)"
SRC="$HOME/aosp"   # copied from /Volumes/aosp (virtiofs hits macOS file limits)
HERE="$(cd "$(dirname "$0")" && pwd)"
rsync -a --delete "$HERE/device/kolibri/" "$SRC/device/kolibri/"
cd "$SRC"
# Host dex2oat needs its heap below 4 GB. On x86_64 ART asks for that with MAP_32BIT, which
# the arm64 kernel under Rosetta ignores (dex2oat aborts: "ref <= 0xFFFFFFFFU"); use ART's
# linear-scan low-4GB allocator instead, as it already does on arm64 and macOS hosts.
MEMMAP=art/libartbase/base/mem_map.h
grep -q 'defined(__APPLE__) || defined(__x86_64__)' "$MEMMAP" || \
    sed -i 's/(defined(__aarch64__) || defined(__APPLE__))/(defined(__aarch64__) || defined(__APPLE__) || defined(__x86_64__))/' "$MEMMAP"
export OUT_DIR="$HOME/out"
source build/envsetup.sh
lunch kolibri_arm64-userdebug
# The emulator image zip (system-images layout: system.img, vendor.img, kernel, ramdisk, ...).
# Rosetta now and then fails to translate a tool under load ("Failed to map AOT header");
# ninja resumes where it stopped, so a failed run is simply retried.
for try in 1 2 3 4 5 6 7 8; do
    if m -j"$JOBS" && m -j"$JOBS" emu_img_zip; then ok=1; break; fi
    echo "#### build attempt $try failed, retrying ####"
    sleep 5
done
[ -n "$ok" ] || { echo "#### build failed after retries ####"; exit 1; }
ls -la "$OUT_DIR/target/product/emulator64_arm64/"*.img "$OUT_DIR"/host/linux-x86/sdk_addon/*img*.zip 2>/dev/null || \
    find "$OUT_DIR" -maxdepth 4 -name "*img*.zip"
