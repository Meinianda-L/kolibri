#!/bin/bash
# Build the Kolibri Vulkan ICD shim into an engine clone's lib64/vulkan ($1) and point
# MoltenVK_icd.json at it. The real libMoltenVK.dylib stays next to it, unchanged.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DIR="${1:?usage: build_vk.sh <lib64/vulkan dir of an engine clone>}"
if [ -f "$HERE/prebuilt/libkolibrivk.dylib" ]; then
    # Release builds ship the shim (no compiler needed on the user's Mac).
    cp "$HERE/prebuilt/libkolibrivk.dylib" "$DIR/libkolibrivk.dylib"
else
    clang -O2 -dynamiclib -arch arm64 -fvisibility=hidden -o "$DIR/libkolibrivk.dylib" "$HERE/vkshim.c" \
        -install_name "@loader_path/libkolibrivk.dylib"
    codesign --force --sign - "$DIR/libkolibrivk.dylib" >/dev/null
fi
python3 - "$DIR/MoltenVK_icd.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["ICD"]["library_path"] = "./libkolibrivk.dylib"
json.dump(d, open(p, "w"), indent=4)
PY
echo "built $DIR/libkolibrivk.dylib"
