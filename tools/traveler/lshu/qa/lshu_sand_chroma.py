#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第四幕「L叔在哪儿」· fix #5 evidence: how much of the daytime chroma the sand ground keeps at night (report only).

Sand mask = visible ground pixels whose ground class is sand (weight >= 0.9), from the two mask frames written by
qa/lshu_ground_class_capture.gd (<mask>/<tile>_a.png, _b.png: same camera as the normal capture), eroded 3 px.
Colour statistics on the normal frozen captures: CIELAB (D65) L*, C*ab, hue of the mean (a*, b*);
keep = mean C* at night / mean C* by day on the same pixels.

  measure  MASKDIR DAY NIGHT TILES [--json=OUT.json]
  sheet    OUT.png MASKDIR DAY BEFORE AFTER TILES     rows = tiles, cols = day / night before / night after
DAY / NIGHT / BEFORE / AFTER are either a directory (<dir>/<tile>_day.png, <dir>/<tile>_night.png) or a path pattern
with {tile}, e.g. DIR/{tile}_night_before.png.
Run with: ~/.local/bin/uv run -q --with pillow --with numpy python tools/traveler/lshu/qa/lshu_sand_chroma.py ...
"""
import json, os, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont

FONT = None
for _f in ("/System/Library/Fonts/PingFang.ttc", "/System/Library/Fonts/Hiragino Sans GB.ttc", "/System/Library/Fonts/STHeiti Medium.ttc"):
    try:
        FONT = ImageFont.truetype(_f, 24)
        break
    except Exception:
        pass
FONT = FONT or ImageFont.load_default()


def rgb(p):
    return np.asarray(Image.open(p).convert("RGB")).astype(np.float64) / 255.0


def lab(img):
    c = np.where(img <= 0.04045, img / 12.92, ((img + 0.055) / 1.055) ** 2.4)
    m = np.array([[0.4124564, 0.3575761, 0.1804375], [0.2126729, 0.7151522, 0.0721750], [0.0193339, 0.1191920, 0.9503041]])
    xyz = c @ m.T / np.array([0.95047, 1.0, 1.08883])
    f = np.where(xyz > 216 / 24389, np.cbrt(xyz), (24389 / 27 * xyz + 16) / 116)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], axis=-1)


def sand_mask(mask_dir, tile, erode=3):
    a = rgb(os.path.join(mask_dir, tile + "_a.png"))
    b = rgb(os.path.join(mask_dir, tile + "_b.png"))
    ground = (a[..., 1] > 0.97) & (a[..., 2] < 0.03) & (b[..., 1] < 0.03) & (b[..., 2] > 0.97)
    m = ground & (a[..., 0] > 0.955) & (b[..., 0] > 0.955)          # sRGB 0.955 ~ linear sand weight 0.9
    for _ in range(erode):
        m = m & np.roll(m, 1, 0) & np.roll(m, -1, 0) & np.roll(m, 1, 1) & np.roll(m, -1, 1)
    return m, ground


def stats(img_path, m):
    L = lab(rgb(img_path))[m]
    c = np.hypot(L[:, 1], L[:, 2])
    return {"L": round(float(L[:, 0].mean()), 2), "C": round(float(c.mean()), 2), "C_p50": round(float(np.median(c)), 2),
            "hue_deg": round(float(np.degrees(np.arctan2(L[:, 2].mean(), L[:, 1].mean())) % 360), 1),
            "a": round(float(L[:, 1].mean()), 2), "b": round(float(L[:, 2].mean()), 2)}


def path(spec, tile, light):
    return spec.format(tile=tile) if "{tile}" in spec else os.path.join(spec, "%s_%s.png" % (tile, light))


def measure(mask_dir, day_dir, night_dir, tiles):
    rows = []
    for t in tiles:
        m, ground = sand_mask(mask_dir, t)
        d = stats(path(day_dir, t, "day"), m)
        n = stats(path(night_dir, t, "night"), m)
        rows.append({"tile": t, "sand_px": int(m.sum()), "ground_px": int(ground.sum()), "day": d, "night": n,
                     "keep": round(n["C"] / max(d["C"], 1e-6), 3)})
    keeps = [r["keep"] for r in rows]
    return {"rows": rows, "keep_mean": round(float(np.mean(keeps)), 3), "keep_min": min(keeps), "keep_max": max(keeps)}


def label(im, text):
    d = ImageDraw.Draw(im)
    d.rectangle((0, 0, im.width, 36), fill=(0, 0, 0))
    d.text((8, 4), text, fill=(255, 255, 255), font=FONT)
    return im


def crop_box(m, pad=40, pad_top=260):
    ys, xs = np.nonzero(m)
    x0, x1, y0, y1 = xs.min() - pad, xs.max() + pad, ys.min() - pad_top, ys.max() + pad
    w, h = x1 - x0, y1 - y0                      # widen to 16:9 around the tile
    if w * 9 < h * 16:
        extra = (h * 16 // 9 - w) // 2; x0 -= extra; x1 += extra
    else:
        extra = (w * 9 // 16 - h) // 2; y0 -= extra; y1 += extra
    w, h = int(x1 - x0), int(y1 - y0)
    x0 = min(max(int(x0), 0), max(1920 - w, 0)); y0 = min(max(int(y0), 0), max(1080 - h, 0))
    return (x0, y0, min(x0 + w, 1920), min(y0 + h, 1080))


def sheet(out, mask_dir, day_dir, before_dir, after_dir, tiles, w=800):
    h = w * 9 // 16
    bm = measure(mask_dir, day_dir, before_dir, tiles)
    am = measure(mask_dir, day_dir, after_dir, tiles)
    img = Image.new("RGB", (w * 3, h * len(tiles)), (0, 0, 0))
    for r, t in enumerate(tiles):
        m, ground = sand_mask(mask_dir, t, erode=0)
        box = crop_box(ground)
        rb, ra = bm["rows"][r], am["rows"][r]
        cols = [(path(day_dir, t, "day"), "%s 昼  沙地 C*=%.1f" % (t, rb["day"]["C"])),
                (path(before_dir, t, "night"), "夜 改前  C*=%.1f  保留 %d%%" % (rb["night"]["C"], round(rb["keep"] * 100))),
                (path(after_dir, t, "night"), "夜 改后  C*=%.1f  保留 %d%%" % (ra["night"]["C"], round(ra["keep"] * 100)))]
        for c, (p, text) in enumerate(cols):
            im = Image.open(p).convert("RGB").crop(box).resize((w, h), Image.LANCZOS)
            img.paste(label(im, text), (c * w, r * h))
    img.save(out)
    res = {"before": bm, "after": am}
    json.dump(res, open(out[:-4] + ".json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    return res


def main(argv):
    if argv and argv[0] == "measure":
        md, dd, nd, tiles = argv[1], argv[2], argv[3], argv[4].split(",")
        res = measure(md, dd, nd, tiles)
        for a in argv[5:]:
            if a.startswith("--json="):
                json.dump(res, open(a.split("=", 1)[1], "w", encoding="utf-8"), ensure_ascii=False, indent=1)
        for r in res["rows"]:
            print("%-5s sand_px=%7d  day L=%5.1f C=%5.2f h=%5.1f | night L=%5.1f C=%5.2f h=%5.1f | keep=%.3f" % (
                r["tile"], r["sand_px"], r["day"]["L"], r["day"]["C"], r["day"]["hue_deg"], r["night"]["L"], r["night"]["C"],
                r["night"]["hue_deg"], r["keep"]))
        print("keep mean=%.3f min=%.3f max=%.3f" % (res["keep_mean"], res["keep_min"], res["keep_max"]))
    elif argv and argv[0] == "sheet":
        res = sheet(argv[1], argv[2], argv[3], argv[4], argv[5], argv[6].split(","))
        print(json.dumps({k: {"keep_mean": v["keep_mean"], "keep_min": v["keep_min"], "keep_max": v["keep_max"]} for k, v in res.items()}))
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
