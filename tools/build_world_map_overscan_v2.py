#!/usr/bin/env python3
"""Build the 4096x1755 *terrain-only* formal world-map background.

The input is the high-resolution, unmarked terrain painting.  Cities, city
plaques, route dashes, route stops, pieces and HUD are runtime layers and must
never be composited into this output.  ``world_map_v1.png`` may be supplied as
an audit reference only: it is compared with the central crop to prove that the
flattened board was not pasted back into the terrain.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

from PIL import Image

Image.MAX_IMAGE_PIXELS = None

TARGET_SIZE = (4096, 1755)
DEFAULT_OUTPUT = Path("assets/game/maps/world/world_map_v2_overscan.png")
PLAYABLE_CROP = (0, 184, 4096, 1363)  # x, y, width, height in the overscan map
EXPECTED_FLATTENED_SIZE = (4096, 1363)

# The terrain and the old flattened board differ at nearly every pixel because
# of the separately-rendered gameplay layers.  These intentionally generous
# lower bounds catch an accidental exact/near-exact v1 paste without tying the
# build to a particular city or route layout.
MIN_FLATTENED_DIFF_MEAN = 2.0
MIN_FLATTENED_DIFF_FRACTION = 0.90

# Pixelmator's decoded terrain layer differs slightly from PIL's Lanczos resize
# of the 4x source.  These bounds are only used when --terrain-reference is
# supplied during an asset audit.
MAX_REFERENCE_DIFF_MEAN = 1.0
MAX_REFERENCE_DIFF_P95 = 4.0
MAX_REFERENCE_DIFF_CHANNEL = 20


def sha256_file(path: Path) -> str:
	hash_value = hashlib.sha256()
	with path.open("rb") as source_file:
		for chunk in iter(lambda: source_file.read(1024 * 1024), b""):
			hash_value.update(chunk)
	return hash_value.hexdigest()


def portable_path(path: Path) -> str:
	"""Keep reports reproducible without leaking a developer home path."""
	try:
		return str(path.resolve().relative_to(Path.cwd().resolve()))
	except ValueError:
		return path.name


def pixel_diff_stats(first: Image.Image, second: Image.Image) -> dict:
	if first.size != second.size:
		raise ValueError(f"size mismatch {first.size} vs {second.size}")
	try:
		import numpy as np

		first_pixels = np.asarray(first.convert("RGB"), dtype=np.int16)
		second_pixels = np.asarray(second.convert("RGB"), dtype=np.int16)
		difference = np.abs(first_pixels - second_pixels)
		changed = np.any(difference != 0, axis=2)
		return {
			"mean_abs_rgb": float(difference.mean()),
			"p95_abs_rgb": float(np.percentile(difference, 95)),
			"max_abs_rgb": int(difference.max(initial=0)),
			"mismatched_pixels": int(changed.sum()),
			"pixel_count": int(changed.size),
			"mismatched_fraction": float(changed.mean()),
		}
	except Exception:
		from PIL import ImageChops

		difference = ImageChops.difference(first.convert("RGB"), second.convert("RGB"))
		histogram = difference.histogram()
		pixel_count = first.size[0] * first.size[1]
		channel_count = pixel_count * 3
		value_counts = [sum(histogram[channel * 256 + value] for channel in range(3)) for value in range(256)]
		p95_target = int(channel_count * 0.95)
		cumulative = 0
		p95_value = 0
		for value, count in enumerate(value_counts):
			cumulative += count
			if cumulative >= p95_target:
				p95_value = value
				break
		union = ImageChops.lighter(
			difference.getchannel("R"),
			ImageChops.lighter(difference.getchannel("G"), difference.getchannel("B")),
		)
		mismatched = sum(union.histogram()[1:])
		return {
			"mean_abs_rgb": sum(value * count for value, count in enumerate(value_counts)) / float(channel_count),
			"p95_abs_rgb": float(p95_value),
			"max_abs_rgb": max((value for value, count in enumerate(value_counts) if count), default=0),
			"mismatched_pixels": mismatched,
			"pixel_count": pixel_count,
			"mismatched_fraction": mismatched / float(pixel_count),
		}


def _audit_flattened_board(terrain: Image.Image, flattened_path: Path | None) -> dict | None:
	if flattened_path is None:
		return None
	if not flattened_path.is_file():
		raise FileNotFoundError(f"flattened board audit reference missing: {flattened_path}")
	flattened = Image.open(flattened_path).convert("RGB")
	if flattened.size != EXPECTED_FLATTENED_SIZE:
		raise ValueError(f"flattened board unexpected size: {flattened.size}")
	x, y, width, height = PLAYABLE_CROP
	central_terrain = terrain.crop((x, y, x + width, y + height))
	stats = pixel_diff_stats(central_terrain, flattened)
	passed = (
		stats["mean_abs_rgb"] >= MIN_FLATTENED_DIFF_MEAN
		and stats["mismatched_fraction"] >= MIN_FLATTENED_DIFF_FRACTION
	)
	return {
		"reference": portable_path(flattened_path),
		"reference_sha256": sha256_file(flattened_path),
		"crop_xywh": list(PLAYABLE_CROP),
		"terrain_vs_flattened": stats,
		"min_mean_abs_rgb": MIN_FLATTENED_DIFF_MEAN,
		"min_mismatched_fraction": MIN_FLATTENED_DIFF_FRACTION,
		"pass": passed,
	}


def _audit_terrain_reference(terrain: Image.Image, reference_path: Path | None) -> dict | None:
	if reference_path is None:
		return None
	if not reference_path.is_file():
		raise FileNotFoundError(f"terrain reference missing: {reference_path}")
	reference = Image.open(reference_path).convert("RGB")
	if reference.size != TARGET_SIZE:
		raise ValueError(f"terrain reference unexpected size: {reference.size}")
	stats = pixel_diff_stats(terrain, reference)
	passed = (
		stats["mean_abs_rgb"] <= MAX_REFERENCE_DIFF_MEAN
		and stats["p95_abs_rgb"] <= MAX_REFERENCE_DIFF_P95
		and stats["max_abs_rgb"] <= MAX_REFERENCE_DIFF_CHANNEL
	)
	return {
		"reference": portable_path(reference_path),
		"reference_sha256": sha256_file(reference_path),
		"terrain_vs_reference": stats,
		"limits": {
			"mean_abs_rgb": MAX_REFERENCE_DIFF_MEAN,
			"p95_abs_rgb": MAX_REFERENCE_DIFF_P95,
			"max_abs_rgb": MAX_REFERENCE_DIFF_CHANNEL,
		},
		"pass": passed,
	}


def build(
	source: Path,
	output: Path,
	flattened_board_path: Path | None = None,
	terrain_reference_path: Path | None = None,
) -> dict:
	if not source.is_file():
		raise FileNotFoundError(f"source missing: {source}")
	source_image = Image.open(source)
	source_size = source_image.size
	if source_size[0] <= 0 or source_size[1] <= 0:
		raise ValueError(f"invalid source size: {source_size}")
	source_aspect = source_size[0] / source_size[1]
	target_aspect = TARGET_SIZE[0] / TARGET_SIZE[1]
	if abs(source_aspect - target_aspect) > 1e-3:
		raise ValueError(
			f"source aspect {source_aspect:.6f} != target {target_aspect:.6f}; "
			"refusing non-uniform scale"
		)

	# This is deliberately the only image operation in the production pipeline.
	# Gameplay layers are emitted separately by the runtime presentation.
	terrain = source_image.convert("RGB").resize(TARGET_SIZE, Image.Resampling.LANCZOS)
	flattened_audit = _audit_flattened_board(terrain, flattened_board_path)
	reference_audit = _audit_terrain_reference(terrain, terrain_reference_path)
	if flattened_audit is not None and not flattened_audit["pass"]:
		raise SystemExit("PURE TERRAIN FAIL: output resembles the flattened gameplay board")
	if reference_audit is not None and not reference_audit["pass"]:
		raise SystemExit("PURE TERRAIN FAIL: output does not match the decoded PXD terrain")

	output.parent.mkdir(parents=True, exist_ok=True)
	terrain.save(output, format="PNG", optimize=True, compress_level=9)
	reloaded = Image.open(output).convert("RGB")
	roundtrip = pixel_diff_stats(terrain, reloaded)
	if roundtrip["mismatched_pixels"] != 0:
		raise SystemExit("PURE TERRAIN FAIL: PNG roundtrip changed terrain pixels")

	return {
		"pipeline": "terrain_only_lanczos_resize",
		"source": portable_path(source),
		"source_size": list(source_size),
		"source_sha256": sha256_file(source),
		"output": portable_path(output),
		"output_size": list(TARGET_SIZE),
		"output_sha256": sha256_file(output),
		"filter": "LANCZOS",
		"gameplay_layers_composited": False,
		"png_roundtrip": {**roundtrip, "pass": True},
		"flattened_board_absence_gate": flattened_audit,
		"decoded_pxd_terrain_gate": reference_audit,
		"pass": True,
	}


def main() -> int:
	parser = argparse.ArgumentParser(description=__doc__)
	parser.add_argument("--source", required=True, type=Path, help="Full-resolution terrain PNG")
	parser.add_argument(
		"--output",
		type=Path,
		default=DEFAULT_OUTPUT,
		help=f"Output path (default: {DEFAULT_OUTPUT})",
	)
	parser.add_argument(
		"--v1",
		type=Path,
		default=Path("assets/game/maps/world/world_map_v1.png"),
		help="Flattened v1 board used only to prove it was not pasted into the output",
	)
	parser.add_argument(
		"--terrain-reference",
		type=Path,
		default=None,
		help="Optional decoded PXD pure-terrain PNG for an independent similarity gate",
	)
	parser.add_argument("--report-json", type=Path, default=None)
	args = parser.parse_args()

	report = build(args.source, args.output, args.v1, args.terrain_reference)
	print(json.dumps(report, ensure_ascii=False, indent=2))
	if args.report_json is not None:
		args.report_json.parent.mkdir(parents=True, exist_ok=True)
		args.report_json.write_text(
			json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
		)
	return 0


if __name__ == "__main__":
	sys.exit(main())
