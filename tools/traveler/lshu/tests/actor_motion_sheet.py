"""第四幕「L叔在哪儿」· actor motion sheet.

Reads the harness output (actor_motion_harness.gd --out=DIR) and lays out one row per tile x sequence
(arrive / bow-or-nod / leave), --frames thumbnails per row, with the row's measured numbers, plus a row for the
double-click camera focus of the first tile.

    ~/.local/bin/uv run -q --with pillow --with numpy python tools/traveler/lshu/tests/actor_motion_sheet.py DIR OUT.png
"""
import json
import os
import sys

from PIL import Image, ImageDraw, ImageFont

THUMB_H = 170
LABEL_W = 330
PAD = 6
BG = (246, 243, 238)
INK = (40, 38, 36)
DIM = (120, 114, 108)
BAD = (178, 60, 40)

SEQ_NAME = {"arrive": "走进来", "bow": "点他", "leave": "走出去"}
POSE_NAME = {"standing": "站姿", "seated": "坐姿", "carrying": "捧物"}


def font(size):
    for path in ("/System/Library/Fonts/PingFang.ttc", "/System/Library/Fonts/STHeiti Medium.ttc",
                 "/Library/Fonts/Arial Unicode.ttf"):
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                pass
    return ImageFont.load_default()


def main():
    src, out = sys.argv[1], sys.argv[2]
    rep = json.load(open(os.path.join(src, "actor_motion_report.json")))
    f_big, f_small = font(20), font(14)
    rows = []
    pop_step = rep.get("pop_step_m", 0.05)
    order = rep.get("tile_order") or list(rep["tiles"].keys())
    for tid in order:
        t = rep["tiles"][tid]
        pose = t.get("pose", "")
        for seq in ("arrive", "bow", "leave"):
            r = t["render"][seq]
            m = t["metrics"][seq]
            thumbs = [Image.open(s["png"]).convert("RGB") for s in sorted(r["saved"], key=lambda s: s["k"])]
            phases = [s.get("phase", "") for s in sorted(r["saved"], key=lambda s: s["k"])]
            name = SEQ_NAME[seq] if seq != "bow" else ("鞠躬" if pose == "standing" else "点头")
            lines = [(f"{tid} · {POSE_NAME.get(pose, pose)} · {name}", f_big, INK)]
            if m["walk_frames"] > 0:
                gap = m["walk_max_planted_gap_m"]
                lines.append((f"着地脚离地/入地 最大 {gap * 100:.1f} cm · 95% 帧 ≤ {m['walk_planted_gap_p95_m'] * 100:.1f} cm",
                              f_small, BAD if gap > 0.03 else INK))
                lines.append((f"超过 3 cm 的帧 {m['walk_frames_gap_over_3cm']}/{m['walk_frames']} · 任一脚最深入地 "
                              f"{-min(0.0, m['walk_min_foot_gap_m']) * 100:.1f} cm", f_small,
                              BAD if m["walk_frames_gap_over_3cm"] else DIM))
            lines.append((f"跳变 {m['pops']} 次（阈值 {pop_step * 100:.1f} cm/帧，最大 {m['max_point_step_m'] * 100:.1f}）",
                          f_small, BAD if m["pops"] else INK))
            lines.append((f"渲染帧差尖峰比 {r['spike_ratio']:.2f}", f_small, DIM))
            rows.append((lines, thumbs, phases))
    first = rep["tiles"].get(order[0], {})
    if first.get("focus_frames"):
        thumbs = []
        for s in first["focus_frames"]:
            im = Image.open(s["png"]).convert("RGB")
            thumbs.append(im)
        f = first["extra"]["focus"]
        lines = [(f"{order[0]} · 双击聚焦", f_big, INK),
                 (f"推近 {f['moved_m']:.1f} m，停 8 秒，回位误差 {f['restored_err_m'] * 1000:.2f} mm", f_small, INK),
                 (f"停住时人高 {f['figure_height_px_hold']:.0f} px", f_small, DIM)]
        rows.append((lines, thumbs, ["开始", "推近中", "停住", "回位"]))
    cols = max(len(r[1]) for r in rows)
    thumb_w = [max(int(im.width * THUMB_H / im.height) for im in r[1]) for r in rows]
    tw = max(thumb_w)
    W = LABEL_W + cols * (tw + PAD) + PAD
    H = len(rows) * (THUMB_H + PAD + 18) + PAD + 40
    sheet = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(sheet)
    d.text((PAD, 8), f"L叔动作 · {len(rep['tiles'])} 块地 · 着地脚最大离地 {rep['max_planted_sole_gap_m'] * 100:.1f} cm",
           font=f_big, fill=INK)
    y = 40
    for lines, thumbs, phases in rows:
        ly = y + 4
        for text, fnt, col in lines:
            d.text((PAD, ly), text, font=fnt, fill=col)
            ly += fnt.size + 6
        x = LABEL_W
        for i, im in enumerate(thumbs):
            w = int(im.width * THUMB_H / im.height)
            sheet.paste(im.resize((w, THUMB_H), Image.LANCZOS), (x, y))
            if i < len(phases):
                d.text((x + 2, y + THUMB_H + 1), str(phases[i]), font=f_small, fill=DIM)
            x += tw + PAD
        y += THUMB_H + PAD + 18
    sheet.save(out)
    print("SHEET", out, sheet.size)


if __name__ == "__main__":
    main()
