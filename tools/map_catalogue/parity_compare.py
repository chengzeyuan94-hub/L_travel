"""Compare a headless re-render of a shipped icon with the shipped PNG.

uv run --with pillow --with numpy python tools/map_catalogue/parity_compare.py \
    assets/game/ui/lshu_3d/icons/tea.png /path/to/headless/tea.png /path/to/out/parity-tea.png

Optional 4th argument: label for the middle panel.
Prints alpha / colour difference statistics (JSON) and writes a sheet:
shipped | headless | |difference| x4 (on the same cream as the shipped overview sheets).
"""
import json
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

CREAM = (244, 237, 224, 255)


def load(p):
    return np.asarray(Image.open(p).convert("RGBA")).astype(np.float64)


def main(a_path, b_path, out_path, b_label="headless (run_icon_headless.sh)"):
    A, B = load(a_path), load(b_path)
    assert A.shape == B.shape, (A.shape, B.shape)
    da = np.abs(A[..., 3] - B[..., 3])
    both = (A[..., 3] > 250) & (B[..., 3] > 250)
    # premultiplied colour so edge pixels compare fairly
    pa = A[..., :3] * (A[..., 3:] / 255.0)
    pb = B[..., :3] * (B[..., 3:] / 255.0)
    dc = np.abs(pa - pb).max(axis=2)
    cov_a = (A[..., 3] > 127).sum()
    cov_b = (B[..., 3] > 127).sum()
    ys, xs = np.nonzero(A[..., 3] > 127)
    yb, xb = np.nonzero(B[..., 3] > 127)
    stats = {
        "size": list(A.shape[:2]),
        "identical_rgba_pixels": bool((A == B).all()),
        "alpha_mean_abs_diff": round(float(da.mean()), 4),
        "alpha_pixels_diff_gt_8": int((da > 8).sum()),
        "coverage_px_shipped": int(cov_a), "coverage_px_headless": int(cov_b),
        "bbox_shipped": [int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())],
        "bbox_headless": [int(xb.min()), int(yb.min()), int(xb.max()), int(yb.max())],
        "opaque_rgb_mean_abs_diff": round(float(np.abs(A[both, :3] - B[both, :3]).mean()), 4),
        "opaque_rgb_max_abs_diff": int(np.abs(A[both, :3] - B[both, :3]).max()),
        "opaque_px": int(both.sum()),
        "opaque_px_diff_gt_2": int((np.abs(A[both, :3] - B[both, :3]).max(axis=1) > 2).sum()),
        "opaque_px_diff_gt_8": int((np.abs(A[both, :3] - B[both, :3]).max(axis=1) > 8).sum()),
        "premult_px_diff_gt_16": int((dc > 16).sum()),
    }
    print(json.dumps(stats))

    W = 512
    tiles = []
    for p in (a_path, b_path):
        im = Image.open(p).convert("RGBA").resize((W, W), Image.LANCZOS)
        bg = Image.new("RGBA", (W, W), CREAM)
        bg.alpha_composite(im)
        tiles.append(bg)
    diff = np.clip(np.maximum(dc, da) * 4, 0, 255).astype(np.uint8)
    heat = Image.fromarray(diff, "L").resize((W, W), Image.BOX)
    heat_rgb = Image.merge("RGBA", (heat, heat.point(lambda v: v // 3), Image.new("L", (W, W), 0), Image.new("L", (W, W), 255)))
    tiles.append(heat_rgb)
    sheet = Image.new("RGBA", (W * 3 + 40, W + 70), CREAM)
    dr = ImageDraw.Draw(sheet)
    try:
        f = ImageFont.truetype("/System/Library/Fonts/Hiragino Sans GB.ttc", 20)
    except OSError:
        f = ImageFont.load_default()
    labels = ["shipped (live Blender, 2026-09-25)", b_label, "|difference| x4 (black = same)"]
    for i, (t, lab) in enumerate(zip(tiles, labels)):
        sheet.alpha_composite(t, (10 + i * (W + 10), 10))
        dr.text((14 + i * (W + 10), W + 18), lab, fill=(58, 42, 34), font=f)
    dr.text((14, W + 44), f"alpha mean |d| {stats['alpha_mean_abs_diff']}  |  opaque RGB mean |d| {stats['opaque_rgb_mean_abs_diff']}, "
            f"max {stats['opaque_rgb_max_abs_diff']}, px>8: {stats['opaque_px_diff_gt_8']}/{stats['opaque_px']}", fill=(58, 42, 34), font=f)
    sheet.convert("RGB").save(out_path)


if __name__ == "__main__":
    main(*sys.argv[1:5])
