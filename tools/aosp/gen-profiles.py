#!/usr/bin/env python3
"""Write one <profile>.prop per engine/profiles/*.json for the image's product partition.

    gen-profiles.py <repo> <out-dir> <build-id> <incremental>

The props are kolibrictl's own profile_props(), so a boot-time profile matches what
`kolibrictl provision` used to append to build.prop. Files are rewritten only when they
change, which keeps the build from recopying them."""
import importlib.machinery
import importlib.util
import json
import sys
from pathlib import Path

repo, out, build_id, incremental = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4]
loader = importlib.machinery.SourceFileLoader("kolibrictl", str(repo / "engine/kolibrictl"))
spec = importlib.util.spec_from_loader("kolibrictl", loader)
ctl = importlib.util.module_from_spec(spec)
loader.exec_module(ctl)

out.mkdir(parents=True, exist_ok=True)
for f in sorted((repo / "engine/profiles").glob("*.json")):
    p = json.loads(f.read_text())
    lines = [] if p.get("stock") or f.stem == "stock" else \
        [l for l in ctl.profile_props(p, build_id, incremental, "12") if not l.startswith("#")]
    text = "".join(l + "\n" for l in lines)
    dest = out / f"{f.stem}.prop"
    if not dest.exists() or dest.read_text() != text:
        dest.write_text(text)
print(f"profiles: {len(list(out.glob('*.prop')))} in {out}")
