#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""L1 lighting line - region measurements for lookdev captures (no Godot needed).

  ~/.local/bin/uv run -q --with pillow --with numpy python tools/traveler/lookdev_lshu/l1_measure.py <variant> [<variant> ...] \
        [--recipes=D01,D05] [--lights=morning,day,sunset,night]

The tile mask is geometric and shared by every variant/light of a recipe (the camera rule and the frozen
pose make the framing identical): it is taken from the recipe's *baseline* capture, whose backdrop is one flat
colour and whose floor shadow is that colour times a constant - so "tile" = pixels whose RGB is NOT a scalar
multiple (0.68-1.02) of the flat backdrop colour, eroded 3 px. Backdrop numbers use the left/right 8 % margins.
Reports:
  tile_L      mean luminance (0-255, Rec.709 on sRGB values) inside the tile mask
  tile_std    luminance standard deviation inside the tile (global contrast)
  p5/p95      luminance percentiles inside the tile (dynamic range)
  tile_sat    mean HSV saturation inside the tile
  local_c     mean local contrast: std of luminance in 16 px blocks, averaged over tile blocks (form/detail)
  bd_L/bd_top/bd_bot  backdrop luminance overall / top row band / bottom row band
  sep         |tile_L - backdrop_L| (figure/ground separation)
  hf          high-frequency noise: std of (image - 3x3 box blur) in tile blocks whose block std < 6 (flat areas)
"""
import json, os, sys
import numpy as np
from numpy.lib.stride_tricks import sliding_window_view as sw
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, os.pardir, os.pardir, os.pardir))
OUT = os.path.join(ROOT, "docs", "reports", "traveler-lshu-20260923")
LIGHTS = ["morning", "day", "sunset", "night"]


def lum(a):
    return 0.2126 * a[..., 0] + 0.7152 * a[..., 1] + 0.0722 * a[..., 2]


_MASKS = {}


def tile_mask(recipe):
    """Geometric tile mask from the recipe's baseline capture (flat backdrop, see module doc)."""
    if recipe in _MASKS:
        return _MASKS[recipe]
    from numpy.lib.stride_tricks import sliding_window_view as sw
    cands = [f for f in sorted(os.listdir(OUT)) if f.startswith("baseline_%s_" % recipe) and f.endswith(".png") and f.count("_") == 2]
    if not cands:
        _MASKS[recipe] = None
        return None
    a = np.asarray(Image.open(os.path.join(OUT, cands[0])).convert("RGB")).astype(np.float32)
    bd = a[12, 12]
    r = a / np.maximum(bd[None, None, :], 1.0)
    spread = r.max(axis=2) - r.min(axis=2)
    backdrop = (spread < 0.035) & (r.mean(axis=2) > 0.68) & (r.mean(axis=2) < 1.02)
    mask = ~backdrop
    # erode 3 px (drops anti-aliased rims) then remove isolated specks
    pad = np.pad(mask, 3, constant_values=False)
    mask = sw(pad, (7, 7)).min(axis=(2, 3))
    _MASKS[recipe] = mask
    return mask


def measure(path, recipe):
    a = np.asarray(Image.open(path).convert("RGB")).astype(np.float32)
    h, w, _ = a.shape
    m = int(w * 0.08)
    side = np.concatenate([a[:, :m], a[:, w - m:]], axis=1)
    bd = np.median(side, axis=1)  # per-row backdrop estimate
    mask = tile_mask(recipe)
    if mask is None:
        diff = np.abs(a - bd[:, None, :]).max(axis=2)
        mask = diff > 6.0
        mask[:, :m] = False; mask[:, w - m:] = False
    L = lum(a)
    t = L[mask]
    mx = a.max(axis=2); mn = a.min(axis=2)
    sat = np.where(mx > 0, (mx - mn) / np.maximum(mx, 1e-3), 0.0)
    # local contrast + flat-area noise in 16 px blocks fully inside the mask
    bs = 16
    lc = []; hf = []
    blur = np.pad(L, 1, mode="edge")
    box = sw(blur, (3, 3)).mean(axis=(2, 3))
    hfimg = L - box
    for y in range(0, h - bs, bs):
        for x in range(0, w - bs, bs):
            if mask[y:y + bs, x:x + bs].all():
                s = L[y:y + bs, x:x + bs].std()
                lc.append(s)
                if s < 6.0:
                    hf.append(hfimg[y + 1:y + bs - 1, x + 1:x + bs - 1].std())
    bdL = lum(bd)
    return {
        "tile_L": float(t.mean()), "tile_std": float(t.std()), "p5": float(np.percentile(t, 5)), "p95": float(np.percentile(t, 95)),
        "tile_sat": float(sat[mask].mean()), "local_c": float(np.mean(lc)) if lc else 0.0,
        "bd_L": float(bdL.mean()), "bd_top": float(bdL[: h // 10].mean()), "bd_bot": float(bdL[-h // 10:].mean()),
        "sep": float(abs(t.mean() - bdL.mean())), "hf": float(np.mean(hf)) if hf else 0.0, "tile_frac": float(mask.mean()),
    }


def main(argv):
    variants = [a for a in argv if not a.startswith("--")]
    recipes = None; lights = LIGHTS
    for a in argv:
        if a.startswith("--recipes="): recipes = a.split("=", 1)[1].split(",")
        if a.startswith("--lights="): lights = a.split("=", 1)[1].split(",")
    recipes = recipes or ["D01", "D03", "D05", "D06", "D10", "D11", "J218"]
    keys = ["tile_L", "tile_std", "p5", "p95", "tile_sat", "local_c", "bd_L", "bd_top", "bd_bot", "sep", "hf"]
    print("%-10s %-5s %-8s " % ("variant", "tile", "light") + " ".join("%8s" % k for k in keys) + "   p95ms")
    for r in recipes:
        for l in lights:
            for v in variants:
                p = os.path.join(OUT, "%s_%s_%s.png" % (v, r, l))
                if not os.path.exists(p):
                    continue
                d = measure(p, r)
                j = p[:-4] + ".json"
                ms = json.load(open(j)).get("frame_ms", {}).get("p95", 0) if os.path.exists(j) else 0
                print("%-10s %-5s %-8s " % (v[:10], r, l) + " ".join("%8.2f" % d[k] for k in keys) + "   %5.1f" % ms)


if __name__ == "__main__":
    main(sys.argv[1:])
