#!/usr/bin/env python3
"""Independently match the 16 source city icons against the baked world map.

The runtime hover calibration is *not* accepted as truth here: it is only a
search seed.  RGB pixels from each high-alpha source icon are resized and
matched against the final baked map.  The emitted rect/score lets Godot tests
prove that the runtime calibration agrees with the actual shipped bitmap.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def alpha_bbox(image: Image.Image, threshold: int = 32) -> tuple[int, int, int, int]:
    alpha = np.asarray(image, dtype=np.uint8)[:, :, 3]
    ys, xs = np.where(alpha > threshold)
    if len(xs) == 0:
        raise ValueError("source icon has no visible pixels")
    return int(xs.min()), int(ys.min()), int(xs.max() + 1), int(ys.max() + 1)


def candidate_score(map_rgb: np.ndarray, icon: Image.Image, x: int, y: int) -> float:
    rgba = np.asarray(icon, dtype=np.uint8)
    h, w = rgba.shape[:2]
    if x < 0 or y < 0 or y + h > map_rgb.shape[0] or x + w > map_rgb.shape[1]:
        return float("inf")
    # Opaque core pixels are independent of the unknown terrain underneath the
    # anti-aliased edge.  A 60% trimmed mean rejects small animated decorations.
    mask = rgba[:, :, 3] > 240
    if int(mask.sum()) < 64:
        return float("inf")
    diff = np.abs(map_rgb[y : y + h, x : x + w].astype(np.int16) - rgba[:, :, :3].astype(np.int16))
    per_pixel = diff.mean(axis=2)[mask]
    keep = max(1, int(len(per_pixel) * 0.60))
    return float(np.partition(per_pixel, keep - 1)[:keep].mean())


def search_city(
    map_rgb: np.ndarray, source: Image.Image, seed: list[float]
) -> dict[str, object]:
    crop = source.crop(alpha_bbox(source))
    seed_w = int(round(seed[2]))
    seed_center_x = float(seed[0]) + float(seed[2]) * 0.5
    seed_bottom = float(seed[1]) + float(seed[3])
    best: tuple[float, int, int, int, int] | None = None

    def consider(widths: range, dxs: range, dys: range, center_x: float, bottom: float) -> None:
        nonlocal best
        for width in widths:
            height = max(1, int(round(width * crop.height / crop.width)))
            resized = crop.resize((width, height), Image.Resampling.LANCZOS)
            base_x = int(round(center_x - width * 0.5))
            base_y = int(round(bottom - height))
            for dy in dys:
                for dx in dxs:
                    x = base_x + dx
                    y = base_y + dy
                    score = candidate_score(map_rgb, resized, x, y)
                    row = (score, width, height, x, y)
                    if best is None or row < best:
                        best = row

    # Coarse search catches a materially bad calibration; fine search removes
    # the two-pixel sampling grid from the final measurement.
    consider(range(max(8, seed_w - 20), seed_w + 21, 2), range(-12, 13, 2), range(-12, 13, 2), seed_center_x, seed_bottom)
    if best is None:
        raise RuntimeError("no match candidates")
    _, coarse_w, coarse_h, coarse_x, coarse_y = best
    coarse_center = coarse_x + coarse_w * 0.5
    coarse_bottom = coarse_y + coarse_h
    consider(range(max(8, coarse_w - 2), coarse_w + 3), range(-2, 3), range(-2, 3), coarse_center, coarse_bottom)
    assert best is not None
    score, width, height, x, y = best
    return {
        "matched_visible_rect_px": [x, y, width, height],
        "trimmed_mean_rgb_error": round(score, 6),
        "seed_visible_rect_px": [round(float(v), 6) for v in seed],
        "seed_edge_error_px": round(
            max(
                abs(x - float(seed[0])),
                abs(y - float(seed[1])),
                abs(x + width - (float(seed[0]) + float(seed[2]))),
                abs(y + height - (float(seed[1]) + float(seed[3]))),
            ),
            6,
        ),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--presentation", type=Path, default=Path("data/rulesets/lshu_configurable_v1/presentation/world_map_v1.json"))
    parser.add_argument("--calibration", type=Path, default=Path("data/rulesets/lshu_configurable_v1/presentation/world_city_hover_calibration_v1.json"))
    parser.add_argument("--map", dest="map_path", type=Path, default=Path("assets/game/maps/world/world_map_v1.png"))
    parser.add_argument("--output", type=Path, default=Path("docs/reports/world-map-runtime-002-rev3/static_city_pixel_audit.json"))
    args = parser.parse_args()

    presentation = json.loads(args.presentation.read_text(encoding="utf-8"))
    calibration = json.loads(args.calibration.read_text(encoding="utf-8"))["cities"]
    map_rgb = np.asarray(Image.open(args.map_path).convert("RGB"), dtype=np.uint8)
    rows: dict[str, object] = {}
    source_hashes: dict[str, str] = {}
    for city in presentation["cities"]:
        city_id = str(city["city_id"])
        source_path = Path(str(city["static_texture"]).replace("res://", "", 1))
        source_hashes[city_id] = sha256_file(source_path)
        source = Image.open(source_path).convert("RGBA")
        seed = calibration[city_id]["static_visible_rect_px"]
        rows[city_id] = search_city(map_rgb, source, seed)
        print(city_id, rows[city_id])

    payload = {
        "schema": "world_city_static_pixel_audit_v1",
        "method": "opaque RGB template match against final baked world_map_v1.png",
        "map_path": str(args.map_path),
        "map_sha256": sha256_file(args.map_path),
        "calibration_path": str(args.calibration),
        "calibration_sha256": sha256_file(args.calibration),
        "source_texture_sha256": source_hashes,
        "city_count": len(rows),
        "cities": rows,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
