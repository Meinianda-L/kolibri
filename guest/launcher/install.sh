#!/usr/bin/env bash
# Install Kolibri Launcher on a guest and make it the home app with a fresh default layout.
#
#   guest/launcher/install.sh <adb-serial> [--disable-stock] [apk]
#
# --disable-stock  always `pm disable-user` the stock home apps (by default they are only
#                  disabled if the home role does not move to Kolibri Launcher otherwise).
#                  Note: on Pixel-style images the stock launcher also provides Recents,
#                  so disabling it removes the overview screen.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="dev.kolibri.launcher"
HOME_ACTIVITY="$PKG/app.lawnchair.LawnchairLauncher"
STOCK_HOMES="com.google.android.apps.nexuslauncher com.android.launcher3 com.android.launcher"

SERIAL="${1:?usage: install.sh <adb-serial> [--disable-stock] [apk]}"; shift
DISABLE_STOCK=0
APK="$HERE/out/KolibriLauncher.apk"
for a in "$@"; do
    case "$a" in
        --disable-stock) DISABLE_STOCK=1 ;;
        *) APK="$a" ;;
    esac
done
[ -f "$APK" ] || { echo "APK not found: $APK (run build.sh first)" >&2; exit 1; }

ADB="${ADB:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}/platform-tools/adb}"
adb_() { "$ADB" -s "$SERIAL" "$@"; }
sh_() { adb_ shell "$@" | tr -d '\r'; }
current_home() { sh_ cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME | tail -1; }

adb_ wait-for-device
echo "Installing $APK"
adb_ install -r "$APK"

# Wipe launcher state so the default workspace (default_workspace_4x5_kolibri) loads.
# (Clearing data also drops the package's preferred-activity entries, so set home after.)
sh_ pm clear "$PKG" >/dev/null

disable_stock() {
    for p in $STOCK_HOMES; do
        if sh_ pm list packages -e "$p" | grep -qx "package:$p"; then
            echo "Disabling stock home $p"
            sh_ pm disable-user --user 0 "$p" >/dev/null
        fi
    done
}
[ "$DISABLE_STOCK" = 1 ] && disable_stock

sh_ cmd package set-home-activity --user 0 "$HOME_ACTIVITY" >/dev/null || true
if [ "$(current_home)" != "$HOME_ACTIVITY" ]; then
    sh_ cmd role add-role-holder --user 0 android.app.role.HOME "$PKG" >/dev/null || true
fi
if [ "$(current_home)" != "$HOME_ACTIVITY" ] && [ "$DISABLE_STOCK" = 0 ]; then
    disable_stock
    sh_ cmd package set-home-activity --user 0 "$HOME_ACTIVITY" >/dev/null || true
fi

HOME_NOW="$(current_home)"
if [ "$HOME_NOW" != "$HOME_ACTIVITY" ]; then
    echo "error: home resolves to '$HOME_NOW', expected $HOME_ACTIVITY" >&2
    exit 1
fi

for p in $STOCK_HOMES; do sh_ am force-stop "$p" >/dev/null 2>&1 || true; done
sh_ am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null
echo "Home is now $HOME_ACTIVITY"
