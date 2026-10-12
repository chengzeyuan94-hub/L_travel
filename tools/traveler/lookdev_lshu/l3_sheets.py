#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""L3 (L叔 integration & life) report sheets + metrics table. Reads captures in docs/reports/traveler-lshu-20260923/.

  ~/.local/bin/uv run -q --with pillow --with numpy python tools/traveler/lookdev_lshu/l3_sheets.py
Outputs: l3_before_after.png (baseline vs l3_final, L叔 crops at 2x native), l3_closeups.png (debug close-ups),
         l3_life_live.png (live motion close-ups), l3_metrics.json (p95 / size / findability per capture).
"""
import glob, json, os
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, os.pardir, os.pardir, os.pardir))
OUT = os.path.join(ROOT, "docs", "reports", "traveler-lshu-20260923")


def font(size):
    for p in ["/System/Library/Fonts/PingFang.ttc", "/System/Library/Fonts/STHeiti Medium.ttc"]:
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except Exception:
                pass
    return ImageFont.load_default()


F = font(22)


def label(im, text):
    d = ImageDraw.Draw(im)
    w = d.textlength(text, font=F)
    d.rectangle([0, 0, w + 12, 30], fill=(0, 0, 0))
    d.text((6, 2), text, font=F, fill=(255, 255, 255))
    return im


def char_crop(stem, pad=95, scale=2.0):
    j = json.load(open(os.path.join(OUT, stem + ".json")))
    b = j["character"]["projection"]["bounds_px"]
    cx, cy = (b[0] + b[2]) / 2, (b[1] + b[3]) / 2
    im = Image.open(os.path.join(OUT, stem + ".png")).convert("RGB")
    box = (int(cx - pad * 1.25), int(cy - pad), int(cx + pad * 1.25), int(cy + pad))
    return im.crop(box).resize((int(pad * 2.5 * scale), int(pad * 2 * scale)), Image.LANCZOS)


def grid(cells, cols, path):
    w, h = cells[0].size
    rows = (len(cells) + cols - 1) // cols
    sheet = Image.new("RGB", (w * cols, h * rows), (24, 24, 24))
    for i, c in enumerate(cells):
        sheet.paste(c, ((i % cols) * w, (i // cols) * h))
    sheet.save(path)
    print("SHEET", path, sheet.size)


def before_after():
    tiles = [("D01", "night"), ("D04", "day"), ("D05", "sunset"), ("D08", "day"), ("D11", "sunset"), ("J218", "night"), ("J467", "night"), ("J891", "day")]
    cells = []
    for r, l in tiles:
        cells.append(label(char_crop("baseline_%s_%s" % (r, l)), "%s %s · baseline" % (r, l)))
        cells.append(label(char_crop("l3_final_%s_%s" % (r, l)), "%s %s · l3_final" % (r, l)))
    grid(cells, 4, os.path.join(OUT, "l3_before_after.png"))


def closeups():
    cells = []
    for r, l in [("D01", "night"), ("D04", "day"), ("D08", "day"), ("D11", "sunset"), ("J467", "night")]:
        for v in ["l3_probe_zoom", "l3_final_zoom"]:
            im = Image.open(os.path.join(OUT, "%s_%s_%s.png" % (v, r, l))).convert("RGB").crop((460, 90, 1460, 990)).resize((600, 540), Image.LANCZOS)
            cells.append(label(im, "%s %s · %s" % (r, l, "baseline（近景）" if "probe" in v else "l3_final（近景）")))
    grid(cells, 4, os.path.join(OUT, "l3_closeups.png"))


def live():
    cells = []
    for r, l in [("D08", "day"), ("J218", "night"), ("D01", "night")]:
        im = Image.open(os.path.join(OUT, "l3_final_zoom_%s_%s_live.png" % (r, l))).convert("RGB").crop((460, 240, 1460, 1040)).resize((600, 480), Image.LANCZOS)
        cells.append(label(im, "%s %s · 动态（近景）" % (r, l)))
    im = Image.open(os.path.join(OUT, "l3_final_D01_night_live.png")).convert("RGB").crop((960, 60, 1260, 300)).resize((600, 480), Image.LANCZOS)
    cells.append(label(im, "D01 night · 烟囱烟（1080p 2x）"))
    grid(cells, 4, os.path.join(OUT, "l3_life_live.png"))


def metrics():
    rows = []
    for f in sorted(glob.glob(os.path.join(OUT, "*.json"))):
        stem = os.path.basename(f)[:-5]
        variant = None
        for v in ("l3_final", "l3_probe", "l3_merge_test", "l3_r1", "l3_r2", "l3_r3"):
            rest = stem[len(v) + 1:]
            if stem.startswith(v + "_") and len(rest.split("_")) == 2 and rest.split("_")[0][0] in "DJ":
                variant = v
        if variant is None:
            continue
        d = json.load(open(f))
        e = d.get("extra", {}).get("l3", {})
        fz = e.get("findability", {})
        g = e.get("ground_check", {})
        rows.append({"variant": variant, "recipe": d["recipe"], "light": d["light"], "pose": d["character"]["pose"],
                     "p50_ms": d["frame_ms"]["p50"], "p95_ms": d["frame_ms"]["p95"], "draw_calls": d["draw_calls"],
                     "char_height_px": round(d["character"]["projection"].get("height_px", 0), 1),
                     "frame_height_frac": round(fz.get("frame_height_frac", 0), 4) if fz else None,
                     "delta_e": round(fz["delta_e"], 2) if "delta_e" in fz else None, "delta_l": round(fz["delta_l"], 2) if "delta_l" in fz else None,
                     "edge_contrast_l": round(fz["edge_contrast_l"], 2) if "edge_contrast_l" in fz else None,
                     "ring_l_std": round(fz["ring_l_std"], 2) if "ring_l_std" in fz else None, "salience": round(fz["salience"], 3) if "salience" in fz else None,
                     "toe_base_above_terrain_m": round(g["toe_base_min_above_terrain_m"], 3) if "toe_base_min_above_terrain_m" in g else None,
                     "rim_key": e.get("rim_key", {}).get("source")})
    json.dump({"schema": "lshu.l3.metrics.v1", "note": "findability: character mask = frame(with L叔, no shadow) - frame(without); stats on the normal frame; ring = pixels within ~12% of body height outside the mask; L*a*b* D65.", "rows": rows},
              open(os.path.join(OUT, "l3_metrics.json"), "w"), ensure_ascii=False, indent=1)
    print("METRICS", len(rows))


if __name__ == "__main__":
    before_after(); closeups(); live(); metrics()
