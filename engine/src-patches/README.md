# The bundled Android engine

Kolibri ships an Android Emulator engine built from source (QEMU: GPL-2.0, the rest mostly
Apache-2.0). `SOURCES.txt` lists the exact upstream commits; the two patches here are
Kolibri's changes.

```bash
mkdir emulator-src && cd emulator-src
repo init -u https://android.googlesource.com/platform/manifest -b emu-main-dev
repo sync -c -j8                       # then check out the commits in SOURCES.txt
git -C hardware/google/gfxstream apply <kolibri>/engine/src-patches/gfxstream.patch
git -C external/qemu apply <kolibri>/engine/src-patches/qemu.patch
cd external/qemu
python3 android/build/python/cmake.py --out ../../objs-emu --task configure --target darwin-aarch64
cd ../../objs-emu && ninja -j8
<kolibri>/tools/package-engine.sh .    # trimmed, arm64-only copy for the app bundle
```
