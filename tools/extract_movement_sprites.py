#!/usr/bin/env python3
"""Extract 8-direction camel/ship walk frames from MP4s into RGBA spritesheets.

Source paths are CLI args only — never hardcode user home into runtime game code.

Example:
  python3 tools/extract_movement_sprites.py \\
    --camel-dir /path/to/camel_videos \\
    --ship-dir /path/to/ship_videos \\
    --camel-ref /path/to/camel_static \\
    --ship-ref /path/to/ship_static \\
    --out assets/game/pieces \\
    --swift tools/extract_video_frames.swift
"""

from __future__ import annotations

import argparse
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image


CAMEL_DIRS = {
	"n": "9973",
	"ne": "4250",
	"e": "2983",
	"se": "6566",
	"s": "9630",
	"sw": "4572",
	"w": "2754",
	"nw": "5402",
}

SHIP_DIRS = {
	"n": "9001",
	"ne": "1248",
	"e": "8833",
	"se": "3779",
	"s": "8900",
	"sw": "8992",
	"w": "9047",
	"nw": "3069",
}

FRAME_COUNT = 8
CELL = 256
SHEET_W = CELL * FRAME_COUNT
SHEET_H = CELL


def find_video(directory: Path, token: str) -> Path:
	matches = sorted(directory.glob(f"*{token}*.mp4"))
	if not matches:
		raise FileNotFoundError(f"No mp4 containing '{token}' in {directory}")
	return matches[0]


def extract_frames(swift_tool: Path, video: Path, out_dir: Path) -> list[Path]:
	out_dir.mkdir(parents=True, exist_ok=True)
	cmd = [
		"/usr/bin/swift",
		str(swift_tool),
		str(video),
		str(out_dir),
		str(FRAME_COUNT),
		"0.28",
		"0.76",
	]
	subprocess.check_call(cmd)
	frames = sorted(out_dir.glob("frame_*.png"))
	if len(frames) != FRAME_COUNT:
		raise RuntimeError(f"Expected {FRAME_COUNT} frames from {video}, got {len(frames)}")
	return frames


def estimate_magenta(rgb: np.ndarray) -> np.ndarray:
	"""Estimate background magenta from edge samples."""
	h, w, _ = rgb.shape
	edge = np.concatenate(
		[
			rgb[0, :, :],
			rgb[-1, :, :],
			rgb[:, 0, :],
			rgb[:, -1, :],
		],
		axis=0,
	).astype(np.float32)
	# Prefer high-magenta / high-value edge pixels.
	r, g, b = edge[:, 0], edge[:, 1], edge[:, 2]
	score = r + b - 1.5 * g
	keep = score > np.percentile(score, 55)
	if keep.sum() < 20:
		keep = np.ones(len(edge), dtype=bool)
	return edge[keep].mean(axis=0)


def flood_remove_magenta(rgba: np.ndarray, magenta: np.ndarray, tol: float = 55.0) -> np.ndarray:
	"""Remove only magenta regions connected to the image border."""
	h, w, _ = rgba.shape
	rgb = rgba[:, :, :3].astype(np.float32)
	diff = np.linalg.norm(rgb - magenta[None, None, :], axis=2)
	mask = diff <= tol
	# Also catch near-white pink spill.
	r, g, b = rgb[:, :, 0], rgb[:, :, 1], rgb[:, :, 2]
	pinkish = (r > 180) & (b > 140) & (g < r - 20) & (g < b + 40)
	mask |= pinkish & (diff <= tol * 1.35)

	visited = np.zeros((h, w), dtype=bool)
	stack: list[tuple[int, int]] = []
	for x in range(w):
		if mask[0, x]:
			stack.append((0, x))
		if mask[h - 1, x]:
			stack.append((h - 1, x))
	for y in range(h):
		if mask[y, 0]:
			stack.append((y, 0))
		if mask[y, w - 1]:
			stack.append((y, w - 1))

	bg = np.zeros((h, w), dtype=bool)
	while stack:
		y, x = stack.pop()
		if y < 0 or y >= h or x < 0 or x >= w:
			continue
		if visited[y, x] or not mask[y, x]:
			continue
		visited[y, x] = True
		bg[y, x] = True
		stack.extend([(y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)])

	out = rgba.copy()
	out[bg, 3] = 0
	# 1px decontamination on remaining edge against transparent neighbors.
	alpha = out[:, :, 3] > 0
	# Remove baked purple ground shadow: dark purple near bottom connected-ish blobs that are not black outline.
	shadow = (
		alpha
		& (r > 60)
		& (r < 170)
		& (b > 80)
		& (g < r - 15)
		& (g < b - 10)
		& (rgb.mean(axis=2) < 150)
	)
	# Only clear shadow if near bottom third and not strong outline (low saturation black kept).
	ys = np.arange(h)[:, None]
	shadow &= ys > int(h * 0.55)
	# Don't erase red cloth: red cloth has high R and low B.
	red_cloth = (r > 140) & (g < 90) & (b < 90)
	shadow &= ~red_cloth
	out[shadow, 3] = 0

	# Edge spill: if opaque pixel adjacent to transparent and close to magenta, clear it.
	for _ in range(1):
		alpha = out[:, :, 3] > 0
		transparent = ~alpha
		neighbors = np.zeros_like(alpha)
		neighbors[1:] |= transparent[:-1]
		neighbors[:-1] |= transparent[1:]
		neighbors[:, 1:] |= transparent[:, :-1]
		neighbors[:, :-1] |= transparent[:, 1:]
		spill = alpha & neighbors & (np.linalg.norm(rgb - magenta[None, None, :], axis=2) < tol * 1.1)
		out[spill, 3] = 0
	return out


def content_bbox(alpha: np.ndarray) -> tuple[int, int, int, int]:
	ys, xs = np.where(alpha > 0)
	if len(xs) == 0:
		return 0, 0, 1, 1
	return int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1


def foot_anchor(alpha: np.ndarray) -> tuple[float, float]:
	"""Camel foot center: bottom-most opaque mass center-x."""
	h, w = alpha.shape
	ys, xs = np.where(alpha > 0)
	if len(xs) == 0:
		return w * 0.5, h * 0.85
	y_max = ys.max()
	band = (ys >= y_max - 6) & (ys <= y_max)
	ax = float(xs[band].mean())
	ay = float(y_max)
	return ax, ay


def waterline_anchor(alpha: np.ndarray) -> tuple[float, float]:
	"""Ship waterline: mid-x of lower opaque band."""
	h, w = alpha.shape
	ys, xs = np.where(alpha > 0)
	if len(xs) == 0:
		return w * 0.5, h * 0.72
	y0, y1 = ys.min(), ys.max()
	# Waterline around lower 25% of content height.
	target = y0 + 0.78 * (y1 - y0)
	band = (ys >= target - 4) & (ys <= target + 4)
	if band.sum() == 0:
		band = ys >= (y1 - 8)
	ax = float(xs[band].mean())
	ay = float(ys[band].mean())
	return ax, ay


def process_frame(path: Path, unit: str) -> tuple[Image.Image, dict]:
	img = Image.open(path).convert("RGBA")
	arr = np.array(img)
	magenta = estimate_magenta(arr[:, :, :3])
	keyed = flood_remove_magenta(arr, magenta)
	alpha = keyed[:, :, 3]
	x0, y0, x1, y1 = content_bbox(alpha)
	# Crop with padding then fit into 256 cell preserving anchor.
	pad = 8
	x0 = max(0, x0 - pad)
	y0 = max(0, y0 - pad)
	x1 = min(arr.shape[1], x1 + pad)
	y1 = min(arr.shape[0], y1 + pad)
	crop = keyed[y0:y1, x0:x1]
	c_alpha = crop[:, :, 3]
	if unit == "camel":
		ax, ay = foot_anchor(c_alpha)
	else:
		ax, ay = waterline_anchor(c_alpha)
	# Place into 256 canvas with anchor at (128, 220) camel / (128, 190) ship.
	target_anchor = (128.0, 220.0) if unit == "camel" else (128.0, 190.0)
	# Scale so content height ~ 200px.
	ch, cw = crop.shape[0], crop.shape[1]
	scale = min(200.0 / max(ch, 1), 200.0 / max(cw, 1), 1.0)
	new_w = max(1, int(round(cw * scale)))
	new_h = max(1, int(round(ch * scale)))
	scaled = Image.fromarray(crop, "RGBA").resize((new_w, new_h), Image.Resampling.NEAREST)
	sax, say = ax * scale, ay * scale
	canvas = Image.new("RGBA", (CELL, CELL), (0, 0, 0, 0))
	ox = int(round(target_anchor[0] - sax))
	oy = int(round(target_anchor[1] - say))
	canvas.alpha_composite(scaled, (ox, oy))
	meta = {
		"bbox": [x0, y0, x1, y1],
		"anchor_local": [target_anchor[0], target_anchor[1]],
		"magenta": [float(magenta[0]), float(magenta[1]), float(magenta[2])],
	}
	return canvas, meta


def corner_alpha_ok(img: Image.Image) -> bool:
	arr = np.array(img)
	corners = [arr[0, 0, 3], arr[0, -1, 3], arr[-1, 0, 3], arr[-1, -1, 3]]
	return all(int(c) == 0 for c in corners)


def magenta_residue(img: Image.Image, thresh: float = 40.0) -> float:
	arr = np.array(img).astype(np.float32)
	a = arr[:, :, 3] > 0
	if a.sum() == 0:
		return 0.0
	rgb = arr[:, :, :3]
	# Count opaque pixels that look like pure magenta bg.
	r, g, b = rgb[:, :, 0], rgb[:, :, 1], rgb[:, :, 2]
	mag = a & (r > 180) & (b > 160) & (g < 120) & (abs(r - b) < 40)
	return float(mag.sum()) / float(a.sum())


def build_sheet(frames: list[Image.Image]) -> Image.Image:
	sheet = Image.new("RGBA", (SHEET_W, SHEET_H), (0, 0, 0, 0))
	for i, fr in enumerate(frames):
		sheet.alpha_composite(fr, (i * CELL, 0))
	return sheet


def anchor_spread(metas: list[dict]) -> float:
	ys = [m["anchor_local"][1] for m in metas]
	xs = [m["anchor_local"][0] for m in metas]
	return max(max(ys) - min(ys), max(xs) - min(xs))


def process_unit(
	unit: str,
	mapping: dict[str, str],
	video_dir: Path,
	out_dir: Path,
	swift_tool: Path,
	work: Path,
	fps: float,
) -> list[dict]:
	entries = []
	for direction, token in mapping.items():
		video = find_video(video_dir, token)
		frame_dir = work / f"{unit}_{direction}"
		raw_frames = extract_frames(swift_tool, video, frame_dir)
		processed = []
		metas = []
		for fp in raw_frames:
			im, meta = process_frame(fp, unit)
			processed.append(im)
			metas.append(meta)
		sheet = build_sheet(processed)
		name = f"{unit}_{direction}_{'walk' if unit == 'camel' else 'sail'}_8f.png"
		out_path = out_dir / unit / name
		out_path.parent.mkdir(parents=True, exist_ok=True)
		sheet.save(out_path)
		residue = magenta_residue(sheet)
		entry = {
			"unit": unit,
			"direction": direction,
			"source_video_id": token,
			"source_video": str(video.name),
			"spritesheet": f"res://assets/game/pieces/{unit}/{name}",
			"frame_count": FRAME_COUNT,
			"fps": fps,
			"cell_size": [CELL, CELL],
			"sheet_size": [SHEET_W, SHEET_H],
			"layout": "8x1",
			"anchor": [128.0, 220.0 if unit == "camel" else 190.0],
			"anchor_kind": "foot" if unit == "camel" else "waterline",
			"anchor_frame_spread_px": round(anchor_spread(metas), 3),
			"corner_alpha_zero": corner_alpha_ok(sheet),
			"magenta_residue_ratio": round(residue, 6),
			"rgba": True,
		}
		entries.append(entry)
		print(f"[{unit}/{direction}] {out_path} residue={residue:.5f} spread={entry['anchor_frame_spread_px']}")
	return entries


def main() -> int:
	ap = argparse.ArgumentParser()
	ap.add_argument("--camel-dir", required=True)
	ap.add_argument("--ship-dir", required=True)
	ap.add_argument("--camel-ref", default="")
	ap.add_argument("--ship-ref", default="")
	ap.add_argument("--out", required=True)
	ap.add_argument("--swift", required=True)
	ap.add_argument("--work", default="")
	args = ap.parse_args()

	out = Path(args.out)
	swift_tool = Path(args.swift)
	work = Path(args.work) if args.work else Path(tempfile.mkdtemp(prefix="move_extract_"))
	work.mkdir(parents=True, exist_ok=True)

	entries: list[dict] = []
	entries += process_unit("camel", CAMEL_DIRS, Path(args.camel_dir), out, swift_tool, work, 9.0)
	entries += process_unit("ship", SHIP_DIRS, Path(args.ship_dir), out, swift_tool, work, 7.0)

	manifest = {
		"version": 1,
		"logical_notes": "Godot Y-down; anchors are pixel coords in 256 cells.",
		"units": entries,
		"direction_order": ["n", "ne", "e", "se", "s", "sw", "w", "nw"],
	}
	manifest_path = out / "movement_manifest.json"
	manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent="\t") + "\n")
	print("manifest", manifest_path)
	print("sheets", len(entries))
	return 0


if __name__ == "__main__":
	sys.exit(main())
