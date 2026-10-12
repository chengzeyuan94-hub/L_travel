#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第四幕「L叔在哪儿」· postcard camera contact sheets from postcard_cam_harness.gd's report.

  ~/.local/bin/uv run -q --with pillow --with numpy python tools/traveler/lshu/tests/postcard_cam_sheet.py [REPORT_DIR]

REPORT_DIR defaults to docs/reports/traveler-lshu-integrate-20260924. Reads postcard_cam_report.json and writes:
  postcards_sheet.png   the 12 postcards (4 x 3), each labelled: tile name, light, requested -> used rule, L叔 share of
                        the frame height, visible fraction; his projected box is outlined in the corner inset
  postcard_snaps.png    the snaps and the two timeout-retry postcards
Prints LSHU_POSTCARD_SHEET postcards=N snaps=M.
"""
import json, os, sys
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))
FONTS = ["/System/Library/Fonts/Hiragino Sans GB.ttc", "/System/Library/Fonts/STHeiti Medium.ttc", "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"]
LIGHT_ZH = {"morning": "晨", "day": "昼", "sunset": "昏", "night": "夜"}
RULE_ZH = {"far": "远景", "mid": "中景", "back": "背影", "snap": "点他"}


def font(size):
    for f in FONTS:
        if os.path.exists(f):
            return ImageFont.truetype(f, size)
    return ImageFont.load_default()


def tile_name(tile):
    p = os.path.join(ROOT, "data", "traveler", "lshu", "tiles", tile + ".json")
    try:
        return json.load(open(p, encoding="utf-8")).get("name", tile)
    except Exception:
        return tile


def card(entry, tw, th, f1, f2):
    res = entry["result"]
    rep = entry.get("report", {})
    im = Image.new("RGB", (tw, th + 64), (246, 241, 232))
    path = res.get("path") or ""
    if path and os.path.exists(path):
        pc = Image.open(path).convert("RGB")
        sx, sy = tw / pc.width, th / pc.height
        im.paste(pc.resize((tw, th), Image.LANCZOS), (0, 0))
        r = rep.get("his_rect_px") or []
        if len(r) == 4 and r[3] > 0:
            d = ImageDraw.Draw(im)
            x0, y0, w, h = r[0] * sx, r[1] * sy, r[2] * sx, r[3] * sy
            d.rectangle([x0 - 3, y0 - 3, x0 + w + 3, y0 + h + 3], outline=(230, 60, 40), width=2)
    d = ImageDraw.Draw(im)
    rule = res.get("rule") or "-"
    req = entry.get("requested", "")
    arrow = RULE_ZH.get(rule, rule) if rule == req else "%s→%s" % (RULE_ZH.get(req, req), RULE_ZH.get(rule, rule))
    tag = entry.get("label") or ("#%d" % entry["index"])
    line1 = "%s %s · %s · %s" % (tag, tile_name(entry["tile"]), LIGHT_ZH.get(entry["light"], entry["light"]), arrow)
    frac = rep.get("his_frame_fraction", 0.0) or 0.0
    vis = rep.get("visible_fraction", 0.0) or 0.0
    cam = rep.get("camera", {})
    det = cam.get("detail", {})
    extra = ""
    if rule == "mid":
        extra = " · 后退%.1fm 抬高%.1fm" % (det.get("back_m", 0), det.get("up_m", 0))
    elif rule == "back":
        extra = " · 偏离正后方%.0f°" % abs(det.get("turn_from_straight_behind_deg", 0))
    elif rule == "far":
        extra = " · 俯角%.0f° fov%.1f°" % (det.get("pitch_deg", 0), det.get("fov_deg", 0))
    line2 = "L叔占画高 %.1f%% · 可见 %d/5%s" % (frac * 100.0, round(vis * 5), extra)
    d.text((10, th + 6), line1, fill=(40, 34, 28), font=f1)
    d.text((10, th + 36), line2, fill=(95, 84, 70), font=f2)
    return im


def sheet(entries, cols, tw, th, title, out):
    f0, f1, f2 = font(30), font(22), font(18)
    rows = (len(entries) + cols - 1) // cols
    pad = 16
    W = cols * tw + (cols + 1) * pad
    H = 60 + rows * (th + 64) + (rows + 1) * pad
    im = Image.new("RGB", (W, H), (226, 219, 206))
    d = ImageDraw.Draw(im)
    d.text((pad, 14), title, fill=(40, 34, 28), font=f0)
    for i, e in enumerate(entries):
        c = card(e, tw, th, f1, f2)
        im.paste(c, (pad + (i % cols) * (tw + pad), 60 + pad + (i // cols) * (th + 64 + pad)))
    im.save(out)


def main(argv):
    rdir = argv[0] if argv else os.path.join(ROOT, "docs", "reports", "traveler-lshu-integrate-20260924")
    rep = json.load(open(os.path.join(rdir, "postcard_cam_report.json"), encoding="utf-8"))
    pcs = [e for e in rep["entries"] if e["kind"] == "postcard"]
    snaps = [e for e in rep["entries"] if e["kind"] == "snap"]
    used = {}
    for e in pcs:
        used[e["result"].get("rule")] = used.get(e["result"].get("rule"), 0) + 1
    title = "L叔在哪儿 · 明信片取景 12 张（1500×1000，红框 = L叔投影框）  远景 %d · 中景 %d · 背影 %d" % (used.get("far", 0), used.get("mid", 0), used.get("back", 0))
    sheet(pcs, 4, 450, 300, title, os.path.join(rdir, "postcards_sheet.png"))
    extra = list(snaps)
    pdir = os.path.join(rdir, "postcard_cam", "postcards")
    labels = {"pc_harness_timeout": "超时后补渲", "pc_harness_loopoff_fresh": "停绘时新建视口", "pc_harness_minimized": "窗口最小化"}
    for i, (pid, label) in enumerate(labels.items()):
        jpg = os.path.join(pdir, pid + ".jpg")
        js = os.path.join(pdir, pid + ".json")
        if os.path.exists(jpg):
            r = json.load(open(js, encoding="utf-8")) if os.path.exists(js) else {}
            extra.append({"index": 100 + i, "tile": r.get("tile", pcs[-1]["tile"]), "light": r.get("light", pcs[-1]["light"]), "requested": r.get("requested", r.get("rule", "")),
                          "kind": label, "label": label, "result": {"path": jpg, "rule": r.get("rule", "")}, "report": r})
    if extra:
        sheet(extra, 3, 450, 300, "点他鞠躬 snap（前两张）与超时 / 停绘路径补渲的明信片", os.path.join(rdir, "postcard_snaps.png"))
    print("LSHU_POSTCARD_SHEET postcards=%d snaps=%d" % (len(pcs), len(snaps)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
