#!/usr/bin/env python3
"""Native-pixel crown measurements. Keeps failed results; never tunes wind."""
import argparse
import json
from pathlib import Path
import numpy as np
from PIL import Image


def measure(report):
    roi = (390, 500, 690, 800)
    records = []
    for index in range(2):
        source = report / f"S2-peak-pair-{index:04d}.png"
        im = Image.open(source).convert("RGB")
        assert im.size == (1920, 1080)
        a = np.asarray(im, dtype=float)
        mask_image = np.asarray(Image.open(report / f"S2-peak-crown-{index:04d}.png"))
        mask = (mask_image[:, :, 0] > 100) & (mask_image[:, :, 1] < 30) & (mask_image[:, :, 2] < 30)
        region = np.zeros(mask.shape, dtype=bool)
        region[roi[1]:roi[3], roi[0]:roi[2]] = True
        mask &= region
        luma = a @ np.array([0.2126, 0.7152, 0.0722])
        weights = luma * mask
        yy, xx = np.indices(mask.shape)
        centroid = [float((weights * axis).sum() / weights.sum()) for axis in (xx, yy)]
        metadata = json.loads(source.with_suffix(".json").read_text())
        crop_path = report / f"S2-crop-{index:04d}.png"
        im.crop(roi).save(crop_path)
        crop_metadata = {**metadata, "image_size": [300, 300], "viewport_size": [1920, 1080],
                         "source": source.name, "source_image_size": [1920, 1080],
                         "crop_xywh": [390, 500, 300, 300], "resampled": False}
        crop_path.with_suffix(".json").write_text(json.dumps(crop_metadata, indent=2))
        records.append({"time_s": metadata["time_s"], "luminance_centroid": centroid,
                        "mask_pixels": int(mask.sum()), "source": source.name})
    dx = abs(records[1]["luminance_centroid"][0] - records[0]["luminance_centroid"][0])
    geometry = json.loads((report / "S2-peak-crown-geometry.json").read_text())
    plants = next(s for s in geometry["surfaces"] if s["material"] == "Atlas_plants")
    woody = [v for v in plants["vertex_colors"].values() if v["rgb"][0] < .20 and v["rgb"][1] < .10]
    top = max(v["max_y"] for v in woody)
    tip = plants["top_local_y"]
    ratio = (top / tip) ** plants["wind_stiff"]
    tip_displacements = {}
    for part, channel in (("canopy", 0), ("trunk", 1)):
        centers = []
        for index in range(2):
            actual = np.asarray(Image.open(report / f"S2-peak-pair-{index:04d}.png").convert("RGB"))
            segmentation = np.asarray(Image.open(report / f"S2-peak-{part}-{index:04d}.png").convert("RGB"))
            mask = (segmentation[:, :, channel] > 100) & (segmentation[:, :, 1-channel] < 30) & (segmentation[:, :, 2] < 30)
            weights = (actual @ np.array([.2126, .7152, .0722])) * mask
            centers.append(float((weights * np.indices(mask.shape)[1]).sum() / weights.sum()))
        tip_displacements[part] = abs(centers[1] - centers[0])
    pixel_ratio = tip_displacements["trunk"] / tip_displacements["canopy"]
    gates = {
        "crown_luminance_centroid_dx_px": {"measured": dx, "threshold": [2.0, 7.0],
                                         "verdict": 2.0 <= dx <= 7.0},
        "trunk_top_to_canopy_tip_centroid_displacement_ratio": {
            "measured": pixel_ratio, "threshold": [.40, .45], "verdict": .40 <= pixel_ratio <= .45,
            "tip_displacements_px": tip_displacements,
            "method": "Top 10% crown and brown upper stem masks, luminance from original scene",
            "caution": "Only 22/23 stem pixels; occlusion and rasterization make this ratio unstable. Not accepted as proof of continuity."}}
    result = {"pass": all(g["verdict"] for g in gates.values()), "gates": gates,
              "frames": records, "crop_xywh": [390, 500, 300, 300],
              "selection": "Same preselected gold tree, instance 6 of T48_gold_detail. Pair chosen at maximum predicted 1.43-second horizontal excursion over 0..60 s; initial t=0 pair also retained.",
              "centroid_method": "Rec.709 display-RGB luminance in original scene, segmented by whole-crown diagnostic mask; no scaling, no brightness adjustment",
              "continuity_limitation": "Upper woody-tip landmark differs from the dispatch's unstated trunk-height assumption; 42% is not height-independent. The narrow trunk raster mask is too small for reliable pixel centroid ratio.",
              "analytic_upper_wood_ratio": {"ratio": ratio, "wood_top_local_y": top, "canopy_tip_local_y": tip,
                                            "stiff": plants["wind_stiff"], "formula": "(wood_top/canopy_tip)^stiff"},
              "geometry": geometry}
    (report / "S2-wind-verdict.json").write_text(json.dumps(result, indent=2))
    print(json.dumps(gates, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("report", type=Path)
    measure(parser.parse_args().report)
