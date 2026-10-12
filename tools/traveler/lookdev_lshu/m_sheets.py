#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""L叔在哪儿 · merger sheets for m_final.

  ~/.local/bin/uv run -q --with pillow python tools/traveler/lookdev_lshu/m_sheets.py [variant=m_final]

Writes to docs/reports/traveler-lshu-20260923/:
  final_sheet.png   12 showcases at their showcase light (frozen image; label p95 = unfrozen *_live capture)
  final_lights.png  D01 / D05 / D06 / D11 x morning / day / sunset / night (frozen; label p95 from *_live)
  before_after.png  web preview | Godot baseline | Godot final, 6 showcases at their showcase light
Images are the --motion-freeze captures (A/B comparable); p95 numbers come from the --live --tag=live runs.
"""
import json, os, sys
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from make_sheets import OUT, LIGHTS, font, index, label  # noqa: E402

LIGHT_TILES = ["D01", "D05", "D06", "D11"]
BEFORE_AFTER = ["D01", "D05", "D06", "D08", "D10", "D11"]


def meta(variant, rid, light, tag=""):
    p = os.path.join(OUT, "%s_%s_%s%s.json" % (variant, rid, light, "_" + tag if tag else ""))
    return json.load(open(p, encoding="utf-8")) if os.path.exists(p) else None


def frame(variant, rid, light, w, h):
    p = os.path.join(OUT, "%s_%s_%s.png" % (variant, rid, light))
    if not os.path.exists(p):
        im = Image.new("RGB", (w, h), (60, 0, 0)); label(im, "missing " + os.path.basename(p), font(18)); return im
    return Image.open(p).convert("RGB").resize((w, h), Image.LANCZOS)


def p95_text(variant, rid, light):
    live = meta(variant, rid, light, "live")
    frozen = meta(variant, rid, light)
    m = live or frozen
    if not m:
        return "p95 ?"
    return "p95 %.1fms%s · dc %s" % (m["frame_ms"]["p95"], "" if live else " (frozen)", m.get("draw_calls"))


def sheet(variant):
    idx = index(); f = font(20); w, h = 640, 360
    recipes = sorted(r for r in idx if r.startswith("D"))
    canvas = Image.new("RGB", (4 * w, 3 * h), (20, 20, 20))
    for i, r in enumerate(recipes):
        light = idx[r]["light"]
        im = frame(variant, r, light, w, h)
        label(im, "%s %s · %s · %s · %s" % (r, idx[r].get("name", ""), light, idx[r].get("pose", ""), p95_text(variant, r, light)), f)
        canvas.paste(im, ((i % 4) * w, (i // 4) * h))
    out = os.path.join(OUT, "final_sheet.png"); canvas.save(out); print("SHEET", out, canvas.size)


def lights(variant):
    idx = index(); f = font(20); w, h = 640, 360
    canvas = Image.new("RGB", (4 * w, len(LIGHT_TILES) * h), (20, 20, 20))
    for ri, r in enumerate(LIGHT_TILES):
        for li, light in enumerate(LIGHTS):
            im = frame(variant, r, light, w, h)
            label(im, "%s %s · %s · %s" % (r, idx[r].get("name", ""), light, p95_text(variant, r, light)), f)
            canvas.paste(im, (li * w, ri * h))
    out = os.path.join(OUT, "final_lights.png"); canvas.save(out); print("SHEET", out, canvas.size)


def before_after(variant):
    idx = index(); f = font(22); h = 540; ww = 564; gw = 960; head = 44
    canvas = Image.new("RGB", (ww + 2 * gw, head + len(BEFORE_AFTER) * h), (20, 20, 20))
    d = ImageDraw.Draw(canvas); fh = font(26)
    for x, t in [(0, "web 预览 (Lshu_Travel_960)"), (ww, "Godot baseline（搬进来，基本对齐 web）"), (ww + gw, "Godot %s（L1 光影 + L2 表面 + L3 L叔与生命感）" % variant)]:
        d.text((x + 12, 8), t, fill=(235, 235, 235), font=fh)
    for i, r in enumerate(BEFORE_AFTER):
        light = idx[r]["light"]; y = head + i * h
        wp = os.path.join(HERE, "web_src", "previews", "sample_%02d.png" % int(r[1:]))
        web = Image.open(wp).convert("RGB")
        s = min(ww / web.width, h / web.height)
        web = web.resize((int(web.width * s), int(web.height * s)), Image.LANCZOS)
        cell = Image.new("RGB", (ww, h), web.getpixel((2, 2))); cell.paste(web, ((ww - web.width) // 2, (h - web.height) // 2))
        label(cell, "%s %s · web · %s" % (r, idx[r].get("name", ""), light), f)
        base = frame("baseline", r, light, gw, h); label(base, "%s baseline · %s" % (r, light), f)
        fin = frame(variant, r, light, gw, h); label(fin, "%s %s · %s · %s" % (r, variant, light, p95_text(variant, r, light)), f)
        canvas.paste(cell, (0, y)); canvas.paste(base, (ww, y)); canvas.paste(fin, (ww + gw, y))
    out = os.path.join(OUT, "before_after.png"); canvas.save(out); print("SHEET", out, canvas.size)


if __name__ == "__main__":
    v = sys.argv[1] if len(sys.argv) > 1 else "m_final"
    sheet(v); lights(v); before_after(v)
