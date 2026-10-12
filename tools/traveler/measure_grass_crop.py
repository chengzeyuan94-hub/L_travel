#!/usr/bin/env python3
"""S0: unaltered native-pixel grass crop changes, plus GPU raster tip evidence."""
import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--audit", type=Path, required=True)
    parser.add_argument("--a", type=Path, required=True)
    parser.add_argument("--b", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    audit = json.loads(args.audit.read_text())
    x, y, w, h = audit["crop_xywh"]
    assert (w, h) == (300, 300)
    output = args.out.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    result = {
        "schema": "traveler.s0.grass-crop.v1",
        "source_audit": str(args.audit.resolve()),
        "crop_xywh": [x, y, w, h],
        "crop_selection": audit["crop_selection"],
        "image_size": [300, 300],
        "source_image_size": [1920, 1080],
        "pixel_threshold_255": 6,
        "pixel_metric": "max(abs(dR),abs(dG),abs(dB)) >= 6, unchanged stable gate threshold",
        "crop_caution": "Crop fractions include every pixel in the original scene, including nearby foliage; grass-specific displacement is the separate depth-tested GPU raster tip diagnostic.",
        "wiring": {key: audit[key] for key in (
            "grass_node", "source_multimesh", "material", "shader", "material_registered",
            "director_index", "director_original_amplitude", "wind_amp", "wind_stiff",
            "use_custom_data", "custom_data_ranges", "instance_count", "highest_mesh_vertex")},
        "raster_peak_to_peak_displacement_px": audit["raster_peak_to_peak_displacement_px"],
        "raster_peak_pair_seconds": audit["raster_peak_pair_seconds"],
        "raster_tip_centroids": audit["raster_tip_centroids"],
        "raster_caution": audit["raster_caution"],
        "selected_instance": audit["selected_instance"],
        "modes": {},
    }
    for mode, directory in (("A", args.a), ("B", args.b)):
        frames = sorted(directory.glob("f[0-9][0-9][0-9][0-9].png"))
        assert len(frames) == 61, (directory, len(frames))
        pairs = []
        playback = []
        previous = None
        for index, path in enumerate(frames):
            image = Image.open(path).convert("RGB")
            assert image.size == (1920, 1080), (path, image.size)
            crop = image.crop((x, y, x+w, y+h))
            if mode == "A":
                playback.append(crop)
            pixels = np.asarray(crop, dtype=np.int16)
            if previous is not None:
                delta = np.abs(pixels-previous)
                pairs.append({"a_s": index-1, "b_s": index,
                              "moved_pixel_fraction": float((delta.max(axis=2) >= 6).mean()),
                              "mean_abs_diff_255": float(delta.mean())})
            previous = pixels
            if index in {0, *audit["raster_peak_pair_seconds"]}:
                destination = output.parent/f"grass-original-{mode}-t{index:02d}.png"
                crop.save(destination)
                destination.with_suffix(".json").write_text(json.dumps({
                    "source": str(path.resolve()), "image_size": [300, 300],
                    "viewport_size": [1920, 1080], "crop_xywh": [x, y, w, h],
                    "resampled": False, "time_s": index,
                }, indent=2)+"\n")
        fractions = [p["moved_pixel_fraction"] for p in pairs]
        result["modes"][mode] = {"pairs": pairs, "pair_count": len(pairs),
                                  "moved_fraction_min": min(fractions),
                                  "moved_fraction_median": float(np.median(fractions)),
                                  "moved_fraction_max": max(fractions)}
        if mode == "A":
            playback[0].save(output.parent/"grass-original-A-1fps.gif", save_all=True,
                             append_images=playback[1:], duration=1000, loop=0, optimize=False)
    centroids = audit["raster_tip_centroids"]
    raster_steps = []
    for a, b in zip(centroids, centroids[1:]):
        valid = a["weight"] > 0 and b["weight"] > 0
        raster_steps.append({"a_s": a["time_s"], "b_s": b["time_s"], "valid": valid,
                             "centroid_displacement_px": float(np.linalg.norm(np.array(a["centroid_px"])-b["centroid_px"])) if valid else None})
    result["raster_per_pair_displacements"] = raster_steps
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2)+"\n")
    print(json.dumps({"output": str(output), "crop_xywh": audit["crop_xywh"],
                      "wiring_registered": audit["material_registered"],
                      "use_custom_data": audit["use_custom_data"],
                      "raster_peak_to_peak_displacement_px": audit["raster_peak_to_peak_displacement_px"],
                      "A_fraction_range": [result["modes"]["A"]["moved_fraction_min"], result["modes"]["A"]["moved_fraction_max"]],
                      "B_fraction_range": [result["modes"]["B"]["moved_fraction_min"], result["modes"]["B"]["moved_fraction_max"]]}, indent=2))


if __name__ == "__main__":
    main()
