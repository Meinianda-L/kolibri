#!/bin/bash
# Build Kolibri.app from the SwiftPM product and embed the engine tools.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Kolibri"
APP="build/Kolibri.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Kolibri"
rsync -a --exclude '__pycache__' ../engine/ "$APP/Contents/Resources/engine/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # from Resources/AppIcon.svg
mkdir -p "$APP/Contents/Resources/guest/wallpaper"                 # kolibrictl looks next to engine/
cp ../guest/wallpaper/*.png "$APP/Contents/Resources/guest/wallpaper/"
# Prebuilt Vulkan shim, so users don't need a compiler.
mkdir -p "$APP/Contents/Resources/engine/glshim/prebuilt"
clang -O2 -dynamiclib -arch arm64 -fvisibility=hidden -install_name "@loader_path/libkolibrivk.dylib" \
    -o "$APP/Contents/Resources/engine/glshim/prebuilt/libkolibrivk.dylib" ../engine/glshim/vkshim.c
codesign --force --sign - "$APP/Contents/Resources/engine/glshim/prebuilt/libkolibrivk.dylib" >/dev/null
# Kolibri Launcher (guest home app); built by guest/launcher/build.sh.
if [ -f ../guest/launcher/out/KolibriLauncher.apk ]; then
    mkdir -p "$APP/Contents/Resources/guest/launcher/out"
    cp ../guest/launcher/install.sh "$APP/Contents/Resources/guest/launcher/"
    cp ../guest/launcher/out/KolibriLauncher.apk "$APP/Contents/Resources/guest/launcher/out/"
else
    echo "warning: guest/launcher/out/KolibriLauncher.apk missing; phones keep the stock home" >&2
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Kolibri</string>
  <key>CFBundleDisplayName</key><string>Kolibri 蜂鸟模拟器</string>
  <key>CFBundleIdentifier</key><string>dev.kolibri.app</string>
  <key>CFBundleExecutable</key><string>Kolibri</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION:-0.1.0}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>GCSupportsControllerUserInteraction</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><false/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "built $APP"
