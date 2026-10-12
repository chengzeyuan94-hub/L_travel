#!/usr/bin/env python3
"""Assemble continuous 12fps GIF from visual-smoke frame strips (REV1)."""

from __future__ import annotations

import json
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("FAIL: Pillow required (pip install pillow)", file=sys.stderr)
    sys.exit(2)


def load_frames(dir_path: Path) -> list[Image.Image]:
    paths = sorted(dir_path.glob("*.png"))
    frames: list[Image.Image] = []
    for p in paths:
        im = Image.open(p).convert("RGBA")
        frames.append(im)
    return frames


def main() -> int:
    out_dir = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/task_world_map_runtime_002_rev1")
    manifest_path = out_dir / "gif_manifest.json"
    if not manifest_path.is_file():
        print(f"FAIL: missing {manifest_path}", file=sys.stderr)
        return 1
    manifest = json.loads(manifest_path.read_text())
    fps = int(manifest.get("fps", 12))
    duration_ms = int(round(1000 / max(fps, 1)))
    all_frames: list[Image.Image] = []
    for seq in manifest.get("sequences", []):
        d = Path(seq["dir"])
        if not d.is_dir():
            print(f"WARN: missing sequence dir {d}")
            continue
        frames = load_frames(d)
        print(f"SEQ {seq.get('name')} frames={len(frames)}")
        if len(frames) < 4:
            print(f"FAIL: sequence too short: {seq.get('name')}", file=sys.stderr)
            return 1
        all_frames.extend(frames)
    if len(all_frames) < 20:
        print(f"FAIL: not enough frames for continuous GIF ({len(all_frames)})", file=sys.stderr)
        return 1
    # Normalize size to first frame.
    w, h = all_frames[0].size
    norm = [f if f.size == (w, h) else f.resize((w, h), Image.Resampling.BILINEAR) for f in all_frames]
    out_gif = Path(manifest.get("out_gif", out_dir / "preview_walkthrough.gif"))
    # Quantize for a stable animated GIF (RGBA dumps can confuse some readers).
    q = []
    for f in norm:
        q.append(f.convert("RGB").convert("P", palette=Image.Palette.ADAPTIVE, colors=128))
    q[0].save(
        out_gif,
        save_all=True,
        append_images=q[1:],
        duration=[duration_ms] * len(q),
        loop=0,
        optimize=False,
        disposal=2,
    )
    print(
        f"OK gif={out_gif} frames={len(norm)} fps={fps} "
        f"duration_s={len(norm) / fps:.2f} (continuous strip, not slideshow)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
