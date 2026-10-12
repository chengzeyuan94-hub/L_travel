#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""L1 lighting line - before/after boards for the report (reads captures in docs/reports/traveler-lshu-20260923/).

  ~/.local/bin/uv run -q --with pillow python tools/traveler/lookdev_lshu/l1_compare.py [final_variant]
Writes l1_before_after.png, l1_crops.png, l1_rounds.png, l1_option_float.png.
"""
import os, sys
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, os.pardir, os.pardir, os.pardir))
OUT = os.path.join(ROOT, "docs", "reports", "traveler-lshu-20260923")


def font(size):
    for p in ["/System/Library/Fonts/PingFang.ttc", "/System/Library/Fonts/STHeiti Medium.ttc", "/System/Library/Fonts/Hiragino Sans GB.ttc"]:
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except Exception:
                pass
    return ImageFont.load_default()


def label(img, text, f):
    d = ImageDraw.Draw(img)
    w = d.textlength(text, font=f)
    d.rectangle([0, 0, w + 16, f.size + 12], fill=(0, 0, 0))
    d.text((8, 5), text, fill=(255, 255, 255), font=f)


def cap(v, r, l):
    p = os.path.join(OUT, "%s_%s_%s.png" % (v, r, l))
    return Image.open(p).convert("RGB") if os.path.exists(p) else Image.new("RGB", (1920, 1080), (60, 0, 0))


def board(pairs, cell, cols_labels, out, f):
    w, h = cell
    canvas = Image.new("RGB", (w * len(cols_labels), h * len(pairs)), (20, 20, 20))
    for ri, row in enumerate(pairs):
        for ci, (v, r, l, box, text) in enumerate(row):
            im = cap(v, r, l)
            if box:
                im = im.crop(box)
            im = im.resize((w, h), Image.LANCZOS)
            label(im, text, f)
            canvas.paste(im, (ci * w, ri * h))
    canvas.save(out)
    print("BOARD", out, canvas.size)


def main(argv):
    fin = argv[0] if argv else "l1_final"
    f = font(22)
    shots = [("D05", "sunset", "长安石窟"), ("D01", "night", "雪林来信"), ("D06", "day", "刺桐海港"),
             ("D03", "sunset", "红岩古道"), ("D10", "morning", "真腊塔庙"), ("J218", "night", "孤塔烽燧")]
    board([[("baseline", r, l, None, "before · baseline %s %s %s" % (r, n, l)), (fin, r, l, None, "after · %s %s %s %s" % (fin, r, n, l))] for r, l, n in shots],
          (960, 540), ["before", "after"], os.path.join(OUT, "l1_before_after.png"), f)
    crops = [("D05", "sunset", (420, 420, 1000, 760), "D05 夕照 · 地面颗粒/阴影"), ("D01", "night", (480, 300, 1240, 750), "D01 夜 · 窗光/火光"),
             ("D06", "day", (300, 560, 1100, 1060), "D06 日 · 侧裙/台面阴影/移轴"), ("J218", "night", (560, 380, 1260, 800), "J218 夜 · 营火光池")]
    board([[("baseline", r, l, box, "before · " + t), (fin, r, l, box, "after · " + t)] for r, l, box, t in crops],
          (960, 600), ["before", "after"], os.path.join(OUT, "l1_crops.png"), f)
    rounds = ["baseline", "l1_r1", "l1_r2", "l1_r3", fin]
    board([[(v, r, l, None, "%s %s %s" % (v, r, l)) for v in rounds] for r, l in [("D05", "sunset"), ("D01", "night"), ("D06", "day")]],
          (640, 360), rounds, os.path.join(OUT, "l1_rounds.png"), font(18))
    board([[(fin, "D05", "sunset", None, "A 贴台面（%s，推荐）D05 夕照" % fin), ("l1_opt_float", "D05", "sunset", None, "B 悬浮 1.3 m（l1_opt_float）D05 夕照")],
           [(fin, "D06", "day", None, "A 贴台面 D06 日"), ("l1_opt_float", "D06", "day", None, "B 悬浮 1.3 m D06 日")]],
          (960, 540), ["A", "B"], os.path.join(OUT, "l1_option_float.png"), f)


if __name__ == "__main__":
    main(sys.argv[1:])
