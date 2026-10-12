#!/usr/bin/env python3
"""Measure native character silhouettes and produce a same-process style comparison.

Requires Pillow and NumPy. All inputs and outputs live in --out; existing
capture metadata is preserved when raster measurements are appended. Optional
mask-before.png enables an independent raster measurement of the previous size.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw


EXPECTED_SIZE = (1920, 1080)


def load_rgb(path: Path) -> np.ndarray:
    image = Image.open(path).convert("RGB")
    if image.size != EXPECTED_SIZE:
        raise ValueError(f"{path}: expected {EXPECTED_SIZE}, got {image.size}")
    return np.asarray(image, dtype=np.float64) / 255.0


def bbox(mask: np.ndarray) -> list[int] | None:
    yy, xx = np.nonzero(mask)
    if not len(xx):
        return None
    return [int(xx.min()), int(yy.min()), int(xx.max()) + 1, int(yy.max()) + 1]


def contour_segments(coverage: np.ndarray, level: float = 0.5) -> np.ndarray:
    """Marching squares on pixel centres, with interpolated level crossings."""
    a, b = coverage[:-1, :-1], coverage[:-1, 1:]
    c, d = coverage[1:, 1:], coverage[1:, :-1]
    lo = np.minimum.reduce((a, b, c, d))
    hi = np.maximum.reduce((a, b, c, d))
    yy, xx = np.nonzero((lo < level) & (hi >= level))
    segments = []
    for y, x in zip(yy, xx):
        values = (a[y, x], b[y, x], c[y, x], d[y, x])
        vertices = np.array(((x, y), (x + 1, y), (x + 1, y + 1), (x, y + 1)), dtype=float)
        points = {}
        for edge in range(4):
            nxt = (edge + 1) % 4
            if (values[edge] >= level) == (values[nxt] >= level):
                continue
            fraction = (level - values[edge]) / (values[nxt] - values[edge])
            points[edge] = vertices[edge] + fraction * (vertices[nxt] - vertices[edge])
        edges = list(points)
        if len(edges) == 2:
            segments.append((points[edges[0]], points[edges[1]]))
        elif len(edges) == 4:
            # Resolve diagonal cells by the bilinear centre value.
            centre_inside = sum(values) / 4 >= level
            pairs = ((0, 1), (2, 3)) if (values[0] >= level) == centre_inside else ((0, 3), (1, 2))
            segments.extend((points[first], points[second]) for first, second in pairs)
    if not segments:
        raise ValueError("No 0.5 silhouette contour found; masks must have a black background and white character.")
    return np.asarray(segments, dtype=float)


def silhouette(rgb: np.ndarray) -> tuple[dict, np.ndarray, np.ndarray]:
    # PNG stores sRGB-encoded display values. With the diagnostic masks' linear
    # tonemapping and unshaded white/black materials, decode to linear light
    # before interpreting antialiased boundary brightness as pixel coverage.
    linear_rgb = np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)
    coverage = linear_rgb.mean(axis=2)
    occupied = coverage >= 0.5
    bounds = bbox(occupied)
    if bounds is None:
        raise ValueError("Empty character silhouette at 0.5 coverage.")
    if bounds[0] == 0 or bounds[1] == 0 or bounds[2] == 1920 or bounds[3] == 1080:
        raise ValueError("Character silhouette touches the image border; cannot measure full height.")
    segments = contour_segments(coverage)
    points = segments.reshape(-1, 2)
    lower, upper = points.min(axis=0), points.max(axis=0)
    return {
        "coverage_threshold": 0.5,
        "coverage_space": "Linear RGB mean after IEC 61966-2-1 sRGB decoding of PNG values",
        "coverage_assumption": "Diagnostic captures use an unshaded white character, black background and linear tonemapping; linear-light intensity therefore represents antialiased white coverage.",
        "bbox_px_xyxy_exclusive": bounds,
        "height_px_integer": bounds[3] - bounds[1],
        "width_px_integer": bounds[2] - bounds[0],
        "height_px_subpixel": float(upper[1] - lower[1]),
        "width_px_subpixel": float(upper[0] - lower[0]),
        "contour_bounds_px": [float(lower[0]), float(lower[1]), float(upper[0]), float(upper[1])],
        "area_px_at_half_coverage": int(occupied.sum()),
    }, segments, occupied


def sample_segments(segments: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    samples, weights = [], []
    for start, end in segments:
        length = float(np.linalg.norm(end - start))
        if length <= 1e-10:
            continue
        count = max(1, int(np.ceil(length / 0.25)))
        fractions = (np.arange(count) + 0.5) / count
        samples.append(start + fractions[:, None] * (end - start))
        weights.append(np.full(count, length / count))
    return np.concatenate(samples), np.concatenate(weights)


def nearest_segment_distance(points: np.ndarray, segments: np.ndarray) -> np.ndarray:
    # Character contours are small enough for exact distances to every segment.
    # Chunk samples to keep memory bounded and avoid an extra SciPy dependency.
    starts, ends = segments[:, 0], segments[:, 1]
    vectors = ends - starts
    lengths_squared = np.einsum("ki,ki->k", vectors, vectors)
    result = []
    for begin in range(0, len(points), 128):
        chunk = points[begin:begin + 128]
        fractions = np.einsum("nki,ki->nk", chunk[:, None] - starts, vectors) / np.maximum(lengths_squared, 1e-20)
        closest = starts + np.clip(fractions, 0, 1)[:, :, None] * vectors
        result.append(np.linalg.norm(chunk[:, None] - closest, axis=2).min(axis=1))
    return np.concatenate(result)


def weighted_quantile(values: np.ndarray, weights: np.ndarray, q: float) -> float:
    order = np.argsort(values)
    ordered, w = values[order], weights[order]
    centres = (np.cumsum(w) - w / 2) / w.sum()
    return float(np.interp(q, centres, ordered))


def outline_measure(body_segments: np.ndarray, outlined_segments: np.ndarray,
                    body: np.ndarray, outlined: np.ndarray) -> dict:
    points, weights = sample_segments(outlined_segments)
    distances = nearest_segment_distance(points, body_segments)
    return {
        "method": "Decode PNG sRGB to linear RGB with IEC 61966-2-1; extract linear-RGB-mean 0.5 coverage isocontours by linearly interpolated marching squares; sample the outlined contour at <=0.25 px spacing and measure shortest distance to the body contour; statistics weighted by contour arc length.",
        "median_expansion_px": weighted_quantile(distances, weights, 0.5),
        "p10_expansion_px": weighted_quantile(distances, weights, 0.1),
        "p90_expansion_px": weighted_quantile(distances, weights, 0.9),
        "mean_expansion_px": float(np.average(distances, weights=weights)),
        "max_expansion_px": float(distances.max()),
        "sample_count": len(distances),
        "outlined_contour_length_px": float(weights.sum()),
        "added_area_px_at_half_coverage": int((outlined & ~body).sum()),
        "missing_body_area_px_at_half_coverage": int((body & ~outlined).sum()),
        "limitations": "This measures visible raster silhouette expansion in this pose, including narrow gaps and concavities. It is not a uniform stroke width or a direct measurement of model-space grow; antialiasing, surface normals, foreshortening and contour topology affect it. Camera projection estimates must be reported separately.",
    }


def diff_stats(before: np.ndarray, after: np.ndarray, body_box: list[int], region: list[int]) -> dict:
    difference = np.abs(after - before)
    peak = difference.max(axis=2)
    outside_body = np.ones(peak.shape, dtype=bool)
    x0, y0, x1, y1 = body_box
    outside_body[y0:y1, x0:x1] = False
    outside_region = np.ones(peak.shape, dtype=bool)
    x0, y0, x1, y1 = region
    outside_region[y0:y1, x0:x1] = False
    results = {}
    for name, selected in (("whole_image", np.ones(peak.shape, dtype=bool)),
                           ("outside_after_character_bbox", outside_body),
                           ("outside_padded_character_crop", outside_region)):
        entry = {"region_pixel_count": int(selected.sum()), "mean_abs_rgb_255": float(difference[selected].mean() * 255),
                 "max_channel_diff_255": float(peak[selected].max() * 255)}
        for threshold in (0, 1, 3):
            changed = selected & (peak > (threshold + 0.01) / 255)
            entry[f"pixels_diff_gt_{threshold}_255"] = int(changed.sum())
            entry[f"change_fraction_gt_{threshold}_255"] = float(changed.sum() / selected.sum())
            entry[f"changed_bbox_gt_{threshold}_255"] = bbox(changed)
        results[name] = entry
    return {
        "metric": "Absolute per-channel difference in decoded PNG RGB; changed pixel uses maximum RGB channel difference.",
        "padded_character_crop_xyxy_exclusive": region,
        "regions": results,
        "interpretation": "Descriptive evidence, not an automatic world-change verdict. The character's changed scale also changes its shadow outside the silhouette, and screen-space/postprocessing effects can affect surrounding pixels. Inspect spatial extent alongside frozen scene settings.",
    }


def write_json(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def update_metadata(path: Path, additions: dict) -> None:
    metadata = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    previous = metadata.get("raster_measurements", {})
    metadata["raster_measurements"] = {**previous, **additions}
    write_json(path, metadata)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path, help="Absolute directory containing rendered inputs and receiving measurement evidence.")
    args = parser.parse_args()
    out = args.out
    if not out.is_absolute():
        parser.error("--out must be an absolute path")
    if not out.is_dir():
        parser.error(f"Input directory does not exist: {out}")
    capture_path = out / "capture.json"
    capture = json.loads(capture_path.read_text(encoding="utf-8"))
    before, after = load_rgb(out / "day-before.png"), load_rgb(out / "day-after.png")
    body_result, body_segments, body = silhouette(load_rgb(out / "mask-body.png"))
    outlined_rgb = load_rgb(out / "mask-outline.png")
    outlined_result, outlined_segments, outlined = silhouette(outlined_rgb)
    outline = outline_measure(body_segments, outlined_segments, body, outlined)
    before_result = None
    # Keep the native comparison framing independent of the coverage measurement
    # convention. This encoded-brightness bbox is only a visual crop anchor.
    boxes = [bbox(outlined_rgb.mean(axis=2) >= 0.5)]
    if (out / "mask-before.png").exists():
        before_rgb = load_rgb(out / "mask-before.png")
        before_result, _, _ = silhouette(before_rgb)
        boxes.append(bbox(before_rgb.mean(axis=2) >= 0.5))
    padding = 48
    region = [max(0, min(b[0] for b in boxes) - padding), max(0, min(b[1] for b in boxes) - padding),
              min(1920, max(b[2] for b in boxes) + padding), min(1080, max(b[3] for b in boxes) + padding)]
    difference = diff_stats(before, after, outlined_result["bbox_px_xyxy_exclusive"], region)
    result = {
        "schema": "silkroad.character-style-raster-measurements.v1",
        "image_size": list(EXPECTED_SIZE),
        "capture_metadata": str(capture_path),
        "capture_top_level_keys": sorted(capture),
        "inputs": {name: str(out / name) for name in ("day-before.png", "day-after.png", "mask-body.png", "mask-outline.png")},
        "before_body": before_result,
        "after_body": body_result,
        "after_with_outline": outlined_result,
        "outline": outline,
        "same_process_image_difference": difference,
        "comparison_crop": {"file": str(out / "before-after-detail.png"), "source_rect_px_xyxy_exclusive": region,
                            "framing": "Encoded-brightness 0.5 bounding box plus 48 px padding; framing only, not a coverage measurement.",
                            "scale": "1 source pixel = 1 output pixel; each panel has a 30 px title band."},
    }
    if before_result is None:
        result["before_height_limitation"] = "No mask-before.png supplied; the previous character height is not independently raster-measured. Preserve any projection-based value in capture metadata as a separate metric."
    write_json(out / "measurements.json", result)
    update_metadata(out / "day-before.json", {"image_size": list(EXPECTED_SIZE), "body": before_result,
                                             "height_status": "measured_from_mask_before" if before_result else "no_independent_before_mask",
                                             "comparison_measurements": str(out / "measurements.json")})
    update_metadata(out / "day-after.json", {"image_size": list(EXPECTED_SIZE), "body": body_result,
                                            "with_outline": outlined_result, "outline": outline,
                                            "comparison_measurements": str(out / "measurements.json")})
    crops = []
    for stem in ("day-before", "day-after"):
        crop = Image.open(out / f"{stem}.png").convert("RGB").crop(tuple(region))
        crop.save(out / f"{stem}-detail.png")
        crops.append(crop)
    width, height = crops[0].size
    board = Image.new("RGB", (width * 2 + 12, height + 30), (28, 26, 27))
    draw = ImageDraw.Draw(board)
    for index, (title, crop) in enumerate(zip(("BEFORE / native 1:1", "AFTER / native 1:1"), crops)):
        offset = index * (width + 12)
        draw.text((offset + 8, 8), title, fill=(240, 233, 222))
        board.paste(crop, (offset, 30))
    board.save(out / "before-after-detail.png")
    print(json.dumps({"after_body_height_px": body_result["height_px_subpixel"],
                      "after_outline_height_px": outlined_result["height_px_subpixel"],
                      "median_outline_expansion_px": outline["median_expansion_px"],
                      "measurement_file": str(out / "measurements.json")}, ensure_ascii=False))


if __name__ == "__main__":
    main()
