#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""L叔在哪儿 · 探针拼图（contact sheet / web 对照）。

  ~/.local/bin/uv run -q --with pillow python tools/traveler/lookdev_lshu/make_sheets.py sheet <variant> [--recipes=D01,...] [--light=showcase|day|...] [--out=name.png]
  ~/.local/bin/uv run -q --with pillow python tools/traveler/lookdev_lshu/make_sheets.py lights <variant> --recipes=D05,D06,D01 [--out=name.png]
  ~/.local/bin/uv run -q --with pillow python tools/traveler/lookdev_lshu/make_sheets.py web <variant> [--recipes=...] [--out=name.png]
      web：左 = web 预览（web_src/previews/sample_NN.png，1:1 构图），右 = Godot 同光照截图。
"""
import json, os, sys
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, os.pardir, os.pardir, os.pardir))
OUT = os.path.join(ROOT, "docs", "reports", "traveler-lshu-20260923")
LIGHTS = ["morning", "day", "sunset", "night"]


def font(size):
    for p in ["/System/Library/Fonts/PingFang.ttc", "/System/Library/Fonts/STHeiti Medium.ttc", "/System/Library/Fonts/Hiragino Sans GB.ttc"]:
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except Exception:
                pass
    return ImageFont.load_default()


def index():
    return {t["id"]: t for t in json.load(open(os.path.join(HERE, "baked", "index.json"), encoding="utf-8"))["tiles"]}


def label(img, text, f):
    d = ImageDraw.Draw(img)
    w = d.textlength(text, font=f)
    d.rectangle([0, 0, w + 16, f.size + 12], fill=(0, 0, 0))
    d.text((8, 5), text, fill=(255, 255, 255), font=f)


def load_capture(variant, rid, light, w, h):
    p = os.path.join(OUT, "%s_%s_%s.png" % (variant, rid, light))
    if not os.path.exists(p):
        im = Image.new("RGB", (w, h), (60, 0, 0)); label(im, "missing " + os.path.basename(p), font(18)); return im, None
    j = p[:-4] + ".json"
    meta = json.load(open(j, encoding="utf-8")) if os.path.exists(j) else None
    return Image.open(p).convert("RGB").resize((w, h), Image.LANCZOS), meta


def sheet(variant, recipes, light_mode, out, cols=4):
    idx = index(); f = font(20)
    w, h = 640, 360
    cells = []
    for r in recipes:
        light = idx[r]["light"] if light_mode == "showcase" else light_mode
        im, meta = load_capture(variant, r, light, w, h)
        p = meta.get("frame_ms", {}) if meta else {}
        label(im, "%s %s · %s · %s · p95 %.1fms" % (r, idx[r].get("name", ""), light, idx[r].get("pose", ""), p.get("p95", 0)), f)
        cells.append(im)
    rows = (len(cells) + cols - 1) // cols
    canvas = Image.new("RGB", (cols * w, rows * h), (20, 20, 20))
    for i, c in enumerate(cells):
        canvas.paste(c, ((i % cols) * w, (i // cols) * h))
    canvas.save(out); print("SHEET", out, canvas.size)


def lights_sheet(variant, recipes, out):
    idx = index(); f = font(20); w, h = 640, 360
    canvas = Image.new("RGB", (4 * w, len(recipes) * h), (20, 20, 20))
    for ri, r in enumerate(recipes):
        for li, light in enumerate(LIGHTS):
            im, meta = load_capture(variant, r, light, w, h)
            label(im, "%s %s · %s" % (r, idx[r].get("name", ""), light), f)
            canvas.paste(im, (li * w, ri * h))
    canvas.save(out); print("SHEET", out, canvas.size)


# web app screenshots that show a known recipe (J721 = D05 at day, J793 at day)
APP_PAIRS = [("app_31.png", "D05", "day"), ("app_34.png", "J793", "day")]


def web_sheet(variant, recipes, out):
    idx = index(); f = font(20)
    h = 540; ww = 540; gw = 960
    pairs = []
    for r in recipes:
        n = int(r[1:]) if r.startswith("D") and r[1:].isdigit() else None
        pairs.append(("sample_%02d.png" % n if n else None, r, idx[r]["light"]))
    for web, r, light in APP_PAIRS:
        if os.path.exists(os.path.join(OUT, "%s_%s_%s.png" % (variant, r, light))):
            pairs.append((web, r, light))
    canvas = Image.new("RGB", ((ww + gw) * 2, ((len(pairs) + 1) // 2) * h), (20, 20, 20))
    for i, (webfile, r, light) in enumerate(pairs):
        wp = os.path.join(HERE, "web_src", "previews", webfile) if webfile else None
        if wp and os.path.exists(wp):
            web = Image.open(wp).convert("RGB")
            s = min(ww / web.width, h / web.height)
            web = web.resize((int(web.width * s), int(web.height * s)), Image.LANCZOS)
            cell = Image.new("RGB", (ww, h), web.getpixel((2, 2))); cell.paste(web, ((ww - web.width) // 2, (h - web.height) // 2))
        else:
            cell = Image.new("RGB", (ww, h), (40, 40, 40))
        label(cell, "web %s %s" % (webfile or "-", r), f)
        g, _ = load_capture(variant, r, light, gw, h)
        label(g, "Godot %s %s · %s · %s" % (variant, r, idx[r].get("name", ""), light), f)
        x = (i % 2) * (ww + gw); y = (i // 2) * h
        canvas.paste(cell, (x, y)); canvas.paste(g, (x + ww, y))
    canvas.save(out); print("SHEET", out, canvas.size)


def main(argv):
    mode = argv[0]; variant = argv[1]
    recipes = None; light = "showcase"; out = None
    for a in argv[2:]:
        if a.startswith("--recipes="): recipes = a.split("=", 1)[1].split(",")
        elif a.startswith("--light="): light = a.split("=", 1)[1]
        elif a.startswith("--out="): out = a.split("=", 1)[1]
    recipes = recipes or sorted(r for r in index() if r.startswith("D"))  # default: the 12 showcases
    if mode == "sheet":
        sheet(variant, recipes, light, out or os.path.join(OUT, "%s_sheet.png" % variant))
    elif mode == "lights":
        lights_sheet(variant, recipes, out or os.path.join(OUT, "%s_lights_sheet.png" % variant))
    elif mode == "web":
        web_sheet(variant, recipes, out or os.path.join(OUT, "%s_vs_web.png" % variant))
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
