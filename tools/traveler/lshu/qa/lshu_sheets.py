#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第四幕「L叔在哪儿」· contact sheets and pixel comparisons (report only; art numbers never gate).

  parity  OUT.png DIR TAG      production (DIR/<tile>_<light>[_<TAG>].png, TAG "-" = none) next to the approved probe render
                               (docs/reports/traveler-lshu-20260923/v_<probe id>_<light>.png) and a x4 difference,
                               one row per showcase at its showcase light; writes OUT.json with the mean |diff|/255
  lights  OUT.png DIR TILES    rows = tiles, cols = morning/day/sunset/night (DIR/<tile>_<light>[_SUFFIX].png)
  matrix  OUT.png DIR          every PNG in DIR (sorted) in a 5-column grid with labels
  diff    A.png B.png          mean / max |diff| of two images (JSON line)
Run with: ~/.local/bin/uv run -q --with pillow --with numpy python tools/traveler/lshu/qa/lshu_sheets.py ...
"""
import glob, json, os, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))
PROBE = os.path.join(ROOT, "docs", "reports", "traveler-lshu-20260923")
LIGHTS = ["morning", "day", "sunset", "night"]
try:
    FONT = ImageFont.truetype("/System/Library/Fonts/PingFang.ttc", 22)
except Exception:
    FONT = ImageFont.load_default()


def label(im, text):
    d = ImageDraw.Draw(im)
    d.rectangle((0, 0, im.width, 30), fill=(0, 0, 0))
    d.text((6, 3), text, fill=(255, 255, 255), font=FONT)
    return im


def arr(p):
    return np.asarray(Image.open(p).convert("RGB")).astype(np.int16)


def diff_stats(a, b):
    d = np.abs(arr(a) - arr(b))
    return {"mean": float(d.mean()), "max": int(d.max()), "px_over_8": float((d.max(axis=2) > 8).mean())}


def pool():
    return json.load(open(os.path.join(ROOT, "data", "traveler", "lshu", "pool.json"), encoding="utf-8"))


def parity(out, d, tag, w=640):
    h = w * 9 // 16
    tiles = [t for t in pool()["tiles"] if t.get("group") == "showcase"]
    sheet = Image.new("RGB", (w * 3, h * len(tiles)), (0, 0, 0))
    rows = []
    for r, t in enumerate(tiles):
        prod = os.path.join(d, "%s_%s%s.png" % (t["id"], t["light"], ("_" + tag) if tag not in ("", "-") else ""))
        probe = os.path.join(PROBE, "v_%s_%s.png" % (t["id"], t["light"]))
        if not (os.path.exists(prod) and os.path.exists(probe)):
            rows.append({"tile": t["id"], "light": t["light"], "missing": [p for p in (prod, probe) if not os.path.exists(p)]})
            continue
        st = diff_stats(prod, probe)
        rows.append(dict(tile=t["id"], light=t["light"], **st))
        a, b = arr(prod), arr(probe)
        dif = np.clip(np.abs(a - b) * 4, 0, 255).astype(np.uint8)
        ims = [Image.fromarray(a.astype(np.uint8)), Image.fromarray(b.astype(np.uint8)), Image.fromarray(dif)]
        texts = ["%s %s 正式版" % (t["id"], t["light"]), "%s 探针 m_final" % t["id"], "差 ×4  平均 %.3f/255" % st["mean"]]
        for c, (im, tx) in enumerate(zip(ims, texts)):
            sheet.paste(label(im.resize((w, h), Image.LANCZOS), tx), (c * w, r * h))
    sheet.save(out)
    means = [r["mean"] for r in rows if "mean" in r]
    rep = {"rows": rows, "mean_of_means": sum(means) / len(means) if means else None, "max_mean": max(means) if means else None,
           "note": "mean |production - probe| per pixel per channel, 0-255 scale; report only"}
    json.dump(rep, open(out[:-4] + ".json", "w"), indent=1, ensure_ascii=False)
    print(json.dumps(rep, ensure_ascii=False))


def lights(out, d, tiles, suffix="", w=640):
    h = w * 9 // 16
    sheet = Image.new("RGB", (w * 4, h * len(tiles)), (0, 0, 0))
    for r, t in enumerate(tiles):
        for c, l in enumerate(LIGHTS):
            p = os.path.join(d, "%s_%s%s.png" % (t, l, suffix))
            if not os.path.exists(p):
                continue
            meta = p[:-4] + ".json"
            p95 = json.load(open(meta)).get("frame_ms", {}).get("p95", 0) if os.path.exists(meta) else 0
            im = Image.open(p).convert("RGB").resize((w, h), Image.LANCZOS)
            sheet.paste(label(im, "%s %s p95 %.1fms" % (t, l, p95)), (c * w, r * h))
    sheet.save(out)
    print(out)


def matrix(out, d, cols=5, w=384):
    h = w * 9 // 16
    files = sorted(glob.glob(os.path.join(d, "*.png")))
    rows = (len(files) + cols - 1) // cols
    sheet = Image.new("RGB", (w * cols, h * max(rows, 1)), (0, 0, 0))
    for i, p in enumerate(files):
        im = Image.open(p).convert("RGB").resize((w, h), Image.LANCZOS)
        sheet.paste(label(im, os.path.basename(p)[:-4]), ((i % cols) * w, (i // cols) * h))
    sheet.save(out)
    print(out, len(files))


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "parity":
        parity(sys.argv[2], sys.argv[3], sys.argv[4])
    elif mode == "lights":
        lights(sys.argv[2], sys.argv[3], sys.argv[4].split(","), sys.argv[5] if len(sys.argv) > 5 else "")
    elif mode == "matrix":
        matrix(sys.argv[2], sys.argv[3])
    elif mode == "diff":
        print(json.dumps(diff_stats(sys.argv[2], sys.argv[3])))
    else:
        raise SystemExit(__doc__)
