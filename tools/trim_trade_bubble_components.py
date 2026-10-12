#!/usr/bin/env python3
"""Trim trade bubble component PNGs by alpha bbox.

Source files are large 1254×1254 canvases with transparent padding.
This tool crops to alpha>0 bounds (+2px margin) without redrawing,
rotating, recoloring, or resampling source pixels.

Example:
  python3 tools/trim_trade_bubble_components.py \\
    --src "/Users/carlos/Downloads/千年丝路_独立气泡组件 (1)" \\
    --out assets/game/ui/trade_bubble
"""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image


MARGIN = 2

FILES = {
	"speech_bubble_frame.png": "trade_bubble_frame_v1.png",
	"arrow_up.png": "trade_bubble_arrow_up_v1.png",
	"arrow_down.png": "trade_bubble_arrow_down_v1.png",
	"arrow_left.png": "trade_bubble_arrow_left_v1.png",
	"arrow_right.png": "trade_bubble_arrow_right_v1.png",
}


def alpha_bbox(im: Image.Image) -> tuple[int, int, int, int]:
	"""Return inclusive-exclusive bbox of pixels with alpha > 0."""
	if im.mode != "RGBA":
		im = im.convert("RGBA")
	alpha = im.getchannel("A")
	bbox = alpha.getbbox()
	if bbox is None:
		raise ValueError("image is fully transparent")
	return bbox


def trim(path: Path, margin: int = MARGIN) -> Image.Image:
	im = Image.open(path).convert("RGBA")
	l, t, r, b = alpha_bbox(im)
	l = max(0, l - margin)
	t = max(0, t - margin)
	r = min(im.width, r + margin)
	b = min(im.height, b + margin)
	return im.crop((l, t, r, b))


def main() -> int:
	ap = argparse.ArgumentParser(description=__doc__)
	ap.add_argument("--src", type=Path, required=True, help="Directory with source PNGs")
	ap.add_argument("--out", type=Path, required=True, help="Output directory under assets/")
	ap.add_argument("--margin", type=int, default=MARGIN, help="Transparent padding around bbox")
	args = ap.parse_args()

	src: Path = args.src
	out: Path = args.out
	if not src.is_dir():
		raise SystemExit(f"source dir not found: {src}")
	out.mkdir(parents=True, exist_ok=True)

	for src_name, out_name in FILES.items():
		src_path = src / src_name
		if not src_path.is_file():
			raise SystemExit(f"missing source file: {src_path}")
		trimmed = trim(src_path, args.margin)
		dest = out / out_name
		trimmed.save(dest)
		print(f"{src_name} → {out_name}  {trimmed.size[0]}×{trimmed.size[1]}")

	print(f"done → {out}")
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
