#!/bin/bash
# Install or update Kolibri from the latest GitHub release.
#   curl -fsSL https://raw.githubusercontent.com/Meinianda-L/kolibri/main/install.sh | bash
# Files fetched with curl carry no quarantine flag, so macOS opens the app without the
# "unidentified developer" prompt that a browser download gets.
set -euo pipefail

REPO="Meinianda-L/kolibri"
[ "$(uname -s)" = Darwin ] || { echo "Kolibri runs on macOS only." >&2; exit 1; }
[ "$(uname -m)" = arm64 ] || { echo "Kolibri needs an Apple Silicon Mac (M1 or later)." >&2; exit 1; }
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 15 ] || { echo "Kolibri needs macOS 15 or later." >&2; exit 1; }

url="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" |
       grep -o '"browser_download_url": *"[^"]*macOS-arm64\.zip"' | head -1 | cut -d'"' -f4)"
[ -n "$url" ] || { echo "Couldn't find the latest release of $REPO." >&2; exit 1; }

dest=/Applications
[ -w "$dest" ] || dest="$HOME/Applications"
mkdir -p "$dest"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Downloading $(basename "$url")..."
curl -fL --progress-bar "$url" -o "$tmp/kolibri.zip"
ditto -x -k "$tmp/kolibri.zip" "$tmp"

osascript -e 'quit app "Kolibri"' >/dev/null 2>&1 || true
rm -rf "$dest/Kolibri.app"
mv "$tmp/Kolibri.app" "$dest/"
xattr -dr com.apple.quarantine "$dest/Kolibri.app" 2>/dev/null || true

echo "Installed $dest/Kolibri.app"
open "$dest/Kolibri.app"
