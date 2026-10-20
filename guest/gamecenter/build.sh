#!/usr/bin/env bash
# Build the Game Center APK into out/GameCenter.apk.
#   ./build.sh            release build (minified, signed with the local debug key)
#   ./build.sh debug      debug build
#   ./build.sh install    release build, then adb install -r
set -euo pipefail
cd "$(dirname "$0")"

VARIANT=release
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    debug) VARIANT=debug ;;
    release) VARIANT=release ;;
    install) INSTALL=1 ;;
    *) echo "usage: $0 [debug|release] [install]" >&2; exit 2 ;;
  esac
done

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
[ -d "$ANDROID_HOME/platforms/android-36" ] || {
  echo "Android SDK platform 36 not found in $ANDROID_HOME" >&2; exit 1; }
echo "sdk.dir=$ANDROID_HOME" > local.properties

# AGP 9 runs on JDK 17+; prefer an LTS JDK (21, then 17) over whatever is newest.
# (`java_home -v 21` silently returns a newer JDK when 21 isn't registered, so check the version.)
jdk_major() { "$1/bin/java" -version 2>&1 | sed -nE '1s/.*version "([0-9]+).*/\1/p'; }
if [ -z "${JAVA_HOME:-}" ]; then
  for want in 21 17; do
    for candidate in \
        "$(/usr/libexec/java_home -v "$want" 2>/dev/null || true)" \
        "/opt/homebrew/opt/openjdk@$want/libexec/openjdk.jdk/Contents/Home" \
        "/Applications/Android Studio.app/Contents/jbr/Contents/Home"; do
      if [ -n "$candidate" ] && [ -x "$candidate/bin/java" ] && [ "$(jdk_major "$candidate")" = "$want" ]; then
        JAVA_HOME="$candidate"; break 2
      fi
    done
  done
fi
[ -n "${JAVA_HOME:-}" ] || { echo "No JDK 17/21 found; set JAVA_HOME" >&2; exit 1; }
export JAVA_HOME
echo "Using JAVA_HOME=$JAVA_HOME"

TASK="assemble$(tr '[:lower:]' '[:upper:]' <<< "${VARIANT:0:1}")${VARIANT:1}"
./gradlew --no-daemon "$TASK"

mkdir -p out
cp "build/outputs/apk/$VARIANT/GameCenter-$VARIANT.apk" out/GameCenter.apk
echo "Built $(pwd)/out/GameCenter.apk"

if [ "$INSTALL" = 1 ]; then
  "$ANDROID_HOME/platform-tools/adb" install -r out/GameCenter.apk
fi
