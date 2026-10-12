#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Verifier (v_) contact sheets from v_run.py output.
  v_sheets.py lights OUTNAME D01,D03,...   rows = tiles, cols = morning/day/sunset/night (frozen m_final)
  v_sheets.py web OUTNAME D01,D02,...      cols = web preview | baseline | m_final, showcase light
  v_sheets.py char OUTNAME D01,D03,...     L叔 close-ups (4x) per tile, 4 lights
"""
import json, os, sys
from PIL import Image, ImageDraw, ImageFont
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, os.pardir, os.pardir, os.pardir))
R = os.path.join(ROOT, "docs", "reports", "traveler-lshu-20260923")
WEB = os.path.join(HERE, "web_src", "previews")
LIGHTS = ["morning", "day", "sunset", "night"]
try:
    FONT = ImageFont.truetype("/System/Library/Fonts/PingFang.ttc", 22)
except Exception:
    FONT = ImageFont.load_default()

def label(im, text):
    d = ImageDraw.Draw(im); d.rectangle((0, 0, im.width, 30), fill=(0, 0, 0)); d.text((6, 3), text, fill=(255, 255, 255), font=FONT)
    return im

def meta(stem):
    p = os.path.join(R, stem + ".json")
    return json.load(open(p)) if os.path.exists(p) else {}

def p95(stem):
    m = meta(stem + "_live") or meta(stem)
    return m.get("frame_ms", {}).get("p95", 0)

def lights(out, tiles, w=640):
    h = w * 9 // 16
    sheet = Image.new("RGB", (w * 4, h * len(tiles)), (0, 0, 0))
    for r, t in enumerate(tiles):
        for c, l in enumerate(LIGHTS):
            stem = "v_%s_%s" % (t, l)
            p = os.path.join(R, stem + ".png")
            if not os.path.exists(p): continue
            im = Image.open(p).convert("RGB").resize((w, h), Image.LANCZOS)
            sheet.paste(label(im, "%s %s p95 %.1fms" % (t, l, p95(stem))), (c * w, r * h))
    sheet.save(out)

def showcase_light(t):
    m = meta("v_%s_day" % t)
    return (m.get("place") and None) or json.load(open(os.path.join(HERE, "baked", t + ".json"))).get("light", "day")

def web(out, tiles, h=540):
    wg = h * 16 // 9; ww = int(h * 1044 / 1000)
    sheet = Image.new("RGB", (ww + wg * 2, h * len(tiles)), (0, 0, 0))
    for r, t in enumerate(tiles):
        l = showcase_light(t)
        wp = os.path.join(WEB, "sample_%s.png" % t[1:])
        if os.path.exists(wp):
            sheet.paste(label(Image.open(wp).convert("RGB").resize((ww, h), Image.LANCZOS), "%s web %s" % (t, l)), (0, r * h))
        for c, (stem, name) in enumerate([("v_%s_%s_base" % (t, l), "baseline"), ("v_%s_%s" % (t, l), "m_final")]):
            p = os.path.join(R, stem + ".png")
            if os.path.exists(p):
                sheet.paste(label(Image.open(p).convert("RGB").resize((wg, h), Image.LANCZOS), "%s %s %s" % (t, name, l)), (ww + c * wg, r * h))
    sheet.save(out)

def char(out, tiles, cw=420, ch=300):
    sheet = Image.new("RGB", (cw * 4, ch * len(tiles)), (0, 0, 0))
    for r, t in enumerate(tiles):
        for c, l in enumerate(LIGHTS):
            stem = "v_%s_%s" % (t, l); m = meta(stem)
            if not m: continue
            b = m["character"]["projection"]["bounds_px"]
            cx, cy = (b[0] + b[2]) / 2, (b[1] + b[3]) / 2
            hh = 105 / 2 * 1.0 + 20
            box = (int(cx - hh * cw / ch), int(cy - hh), int(cx + hh * cw / ch), int(cy + hh))
            im = Image.open(os.path.join(R, stem + ".png")).convert("RGB").crop(box).resize((cw, ch), Image.LANCZOS)
            sheet.paste(label(im, "%s %s" % (t, l)), (c * cw, r * ch))
    sheet.save(out)

if __name__ == "__main__":
    mode, name, tiles = sys.argv[1], sys.argv[2], sys.argv[3].split(",")
    out = os.path.join(R, "v_%s.png" % name)
    {"lights": lights, "web": web, "char": char}[mode](out, tiles)
    print(out)
