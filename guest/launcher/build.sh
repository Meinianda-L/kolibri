#!/usr/bin/env bash
# Build Kolibri Launcher (a Lawnchair fork) into out/KolibriLauncher.apk.
#
#   guest/launcher/build.sh            # clone/reset src, apply patches, build
#   SKIP_RESET=1 guest/launcher/build.sh   # rebuild src as-is (while iterating on patches)
#
# Env overrides: ANDROID_HOME, JAVA_HOME, GRADLE_USER_HOME, LAWNCHAIR_REV, GRADLE_ARGS.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/src"
OUT="$HERE/out"

LAWNCHAIR_URL="https://github.com/LawnchairLauncher/lawnchair"
# Tag v15.0.0-beta3.0 (Launcher3 15 base; runs as a third-party home on API 36).
LAWNCHAIR_TAG="v15.0.0-beta3.0"
LAWNCHAIR_REV="${LAWNCHAIR_REV:-505dbc40e6154c05158b5d0271c45f6a885a411b}"

GRADLE_TASK=":assembleLawnWithQuickstepKolibriRelease"
APK_GLOB="build/outputs/apk/lawnWithQuickstepKolibri/release/*.apk"

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
[ -d "$ANDROID_HOME" ] || { echo "Android SDK not found at $ANDROID_HOME" >&2; exit 1; }

# --- JDK -------------------------------------------------------------------
# Gradle 9.3 runs on JDK 17..25 and the project targets Java 17 bytecode.
jdk_major() { "$1/bin/java" -version 2>&1 | sed -n 's/.*version "\([0-9]*\).*/\1/p' | head -1; }
jdk_ok() { local v; v="$(jdk_major "$1" 2>/dev/null)"; [ -n "$v" ] && [ "$v" -ge 17 ] && [ "$v" -le 25 ]; }

pick_jdk() {
    if [ -n "${JAVA_HOME:-}" ] && jdk_ok "$JAVA_HOME"; then echo "$JAVA_HOME"; return; fi
    for v in 21 17 25; do
        local h
        h="$(/usr/libexec/java_home -v "$v" 2>/dev/null || true)"
        if [ -n "$h" ] && jdk_ok "$h"; then echo "$h"; return; fi
    done
    local local_jdk="$HERE/.jdk/Contents/Home"
    if [ ! -x "$local_jdk/bin/java" ]; then
        local arch; arch="$(uname -m)"; [ "$arch" = arm64 ] && arch=aarch64; [ "$arch" = x86_64 ] && arch=x64
        echo "No JDK 17-25 found; downloading Eclipse Temurin 21 ($arch) into $HERE/.jdk" >&2
        rm -rf "$HERE/.jdk" "$HERE/.jdk.tmp"; mkdir -p "$HERE/.jdk.tmp"
        curl -fsSL "https://api.adoptium.net/v3/binary/latest/21/ga/mac/$arch/jdk/hotspot/normal/eclipse" \
            -o "$HERE/.jdk.tmp/jdk.tar.gz"
        tar -xzf "$HERE/.jdk.tmp/jdk.tar.gz" -C "$HERE/.jdk.tmp"
        mv "$HERE"/.jdk.tmp/jdk-21*/ "$HERE/.jdk"
        rm -rf "$HERE/.jdk.tmp"
    fi
    echo "$local_jdk"
}
export JAVA_HOME="$(pick_jdk)"
echo "Using JDK $(jdk_major "$JAVA_HOME") at $JAVA_HOME"

# --- Source ----------------------------------------------------------------
if [ ! -d "$SRC/.git" ]; then
    git clone --depth 1 --branch "$LAWNCHAIR_TAG" "$LAWNCHAIR_URL" "$SRC"
fi
cd "$SRC"
if [ "${SKIP_RESET:-0}" != 1 ]; then
    if ! git cat-file -e "$LAWNCHAIR_REV^{commit}" 2>/dev/null; then
        git fetch --depth 1 origin "$LAWNCHAIR_REV"
    fi
    # Reset tracked files and drop untracked ones (overlay copies); keep ignored build dirs.
    git checkout -q -f --detach "$LAWNCHAIR_REV"
    git clean -q -fd
    git submodule update --init --depth 1

    for p in "$HERE"/patches/*.patch; do
        echo "Applying $(basename "$p")"
        git apply --whitespace=nowarn "$p"
    done
    # New files (layout XML, strings, icon, trampoline activity) live in overlay/.
    cp -R "$HERE/overlay/." "$SRC/"
fi

echo "sdk.dir=$ANDROID_HOME" > "$SRC/local.properties"

# Isolated Gradle home: a user-level ~/.gradle/init.gradle that adds repositories (e.g.
# mirrors) breaks Lawnchair's FAIL_ON_PROJECT_REPOS setting and makes builds host-dependent.
export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$HERE/.gradle-home}"

# --- Build -----------------------------------------------------------------
# shellcheck disable=SC2086
./gradlew --no-configuration-cache $GRADLE_TASK ${GRADLE_ARGS:-}

mkdir -p "$OUT"
# shellcheck disable=SC2086
APK="$(ls -t $APK_GLOB | head -1)"
cp "$APK" "$OUT/KolibriLauncher.apk"
echo "Built $OUT/KolibriLauncher.apk (from $APK, Lawnchair $LAWNCHAIR_REV)"
