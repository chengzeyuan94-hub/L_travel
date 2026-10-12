#!/usr/bin/env python3
"""Restore the three static lookdev clouds before Godot's import step.

These are the frozen backdrop, not the deferred cloud-motion layer.
The existing Atlas GLBs are never touched.
"""
from pathlib import Path
import hashlib
import json
import shutil

ROOT = Path(__file__).resolve().parents[2]


def main():
    source = ROOT / "docs/design/terrain-library-018/exports"
    target = ROOT / "generated/traveler/lookdev"
    target.mkdir(parents=True, exist_ok=True)
    records = []
    for name in ("cloud_bank.glb", "cloud_cumulus.glb", "cloud_drifter.glb"):
        src, dst = source / name, target / name
        digest = hashlib.sha256(src.read_bytes()).hexdigest()
        if not dst.exists() or hashlib.sha256(dst.read_bytes()).hexdigest() != digest:
            shutil.copyfile(src, dst)
        records.append({"source": str(src.relative_to(ROOT)),
                        "target": str(dst.relative_to(ROOT)), "sha256": digest})
    print(json.dumps(records, indent=2))


if __name__ == "__main__":
    main()
