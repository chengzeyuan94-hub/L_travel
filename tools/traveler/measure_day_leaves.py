#!/usr/bin/env python3
"""Native-pixel S6 leaf masks. Sparse 8-neighbor components; no clustering."""
import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image


def components(mask):
    """Sparse flood fill avoids requiring scipy in the bundled runtime."""
    ys, xs = np.nonzero(mask)
    remaining = set(zip(xs.tolist(), ys.tolist()))
    result = []
    while remaining:
        first = remaining.pop()
        stack = [first]
        points = []
        while stack:
            point = stack.pop()
            points.append(point)
            x, y = point
            for dx, dy in ((-1,-1),(0,-1),(1,-1),(-1,0),(1,0),(-1,1),(0,1),(1,1)):
                neighbor = (x+dx, y+dy)
                if neighbor in remaining:
                    remaining.remove(neighbor)
                    stack.append(neighbor)
        xx, yy = zip(*points)
        x, y = min(xx), min(yy)
        w, h = max(xx)-x+1, max(yy)-y+1
        result.append({"bbox_xywh": [x,y,w,h], "height_px": h, "width_px": w,
                       "area_px": len(points), "touches_image_edge": x==0 or y==0 or x+w==1920 or y+h==1080})
    return sorted(result, key=lambda item: (item["bbox_xywh"][1], item["bbox_xywh"][0]))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--masks", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--original-dir", type=Path)
    args = parser.parse_args()
    evidence_path = args.masks/"leaf-mask-evidence.json"
    evidence = json.loads(evidence_path.read_text())
    paths = sorted(args.masks.glob("f[0-9][0-9][0-9][0-9].png"))
    assert len(paths)==11, f"Expected t=0..10 inclusive, got {len(paths)}"
    output = args.out.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    records, all_heights, counts = [], [], []
    for index, path in enumerate(paths):
        image = Image.open(path).convert("RGB")
        assert image.size==(1920,1080), (path, image.size)
        pixels = np.asarray(image)
        # All-white mask with linear exposure1; fixed threshold, never adapted to output.
        blobs = components(pixels.max(axis=2)>=128)
        kept = [blob for blob in blobs if blob["area_px"]>=3]
        rejected = [blob for blob in blobs if blob["area_px"]<3]
        heights = [blob["height_px"] for blob in kept]
        counts.append(len(kept))
        all_heights.extend(heights)
        record = {"time_s": index, "mask": str(path.resolve()), "component_count": len(kept),
                  "height_median_px": float(np.median(heights)) if heights else None,
                  "height_range_px": [min(heights),max(heights)] if heights else None,
                  "components": kept, "rejected_tiny_fragments": rejected}
        if args.original_dir and heights:
            original_path = args.original_dir/path.name
            if original_path.is_file():
                original = Image.open(original_path).convert("RGB")
                assert original.size==(1920,1080)
                median = float(np.median(heights))
                chosen = min(kept,key=lambda item: abs(item["height_px"]-median))
                x,y,w,h = chosen["bbox_xywh"]
                left = max(0,min(1920-128,x+w//2-64))
                top = max(0,min(1080-128,y+h//2-64))
                destination = output.parent/f"leaf-original-t{index:02d}-median-crop.png"
                original.crop((left,top,left+128,top+128)).save(destination)
                record["original_crop"] = {"file": str(destination), "source": str(original_path.resolve()),
                                           "crop_xywh": [left,top,128,128], "selected_mask_component": chosen,
                                           "resampled": False}
        records.append(record)
    median = float(np.median(all_heights)) if all_heights else None
    params = evidence["leaf_evidence"]["parameters"]
    lo,hi = params["mesh"]["pixel_height_median_target"]
    result = {
        "schema": "traveler.s6.leaf-pixel-measurement.v1",
        "source_evidence": str(evidence_path.resolve()), "image_size": [1920,1080],
        "segmentation": {"method": "8-neighbor connected components of white-emission diagnostic max RGB>=128/255",
                         "pixel_threshold_255": 128, "minimum_area_px": 3,
                         "rejection": "Only components smaller than 3 pixels are rejected as tiny raster fragments; all rejection boxes retained. No height-based exclusion or clustering."},
        "pooled_component_height_median_px": median,
        "pooled_component_count": len(all_heights),
        "height_gate": {"measured": median, "threshold_inclusive": [lo,hi],
                        "pass": median is not None and lo<=median<=hi},
        "visible_component_count": {"min": min(counts), "median": float(np.median(counts)),
                                    "max": max(counts), "design_target_only": params["visible_count_target"]},
        "instance_pool_count": params["amount"],
        "pool_density_per_emission_volume_u3": params["amount"]/evidence["emission_box_volume_u3"],
        "depth_evidence": {"emission_camera_depth_range_u": evidence["emission_camera_depth_range_u"],
                           "render_clip_camera_depth_u": params["render"]["clear_depth_clip_u"],
                           "particle_depth_readback": False, "method": evidence["depth_proof"]},
        "limitations": ["Diagnostic components approximate visible individual leaves. Occlusion can truncate a leaf or separate its parts; overlap can merge leaves.",
                        "These are screen-space bbox heights after current DOF and MSAA, not unprojected mesh dimensions.",
                        "Component observations across frames are pooled without tracking identity; this is not the number of unique particles.",
                        "Black-occluder diagnostic establishes pixel geometry; original frames establish the actual leaf colors and contrast."],
        "frames": records,
    }
    output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+"\n")
    print(json.dumps({"output": str(output), "height_gate": result["height_gate"],
                      "visible_component_count": result["visible_component_count"],
                      "instance_pool_count": params["amount"]},indent=2))


if __name__=="__main__":
    main()
