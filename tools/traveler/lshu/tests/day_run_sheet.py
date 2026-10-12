"""第四幕「L叔在哪儿」· day-run contact sheet: the 48 frames of tools/traveler/lshu/tests/day_run.gd in an 8 x 6 grid,
each labelled with the simulated local time, the stop on screen, the loop substate, what L叔 is doing and the lamp /
fire state, plus a header with the run's numbers.

    uv run --with pillow python tools/traveler/lshu/tests/day_run_sheet.py <run dir> <out png>
"""
import json
import os
import sys

from PIL import Image, ImageDraw, ImageFont

COLS = 8
TW, TH = 400, 225
LABEL_H = 46
HEAD_H = 92
PAD = 6
BG = (238, 234, 228)
INK = (40, 38, 36)
DIM = (110, 104, 98)
ACCENT = (190, 90, 40)
FONT_PATHS = ["/System/Library/Fonts/PingFang.ttc", "/System/Library/Fonts/STHeiti Light.ttc", "/System/Library/Fonts/Hiragino Sans GB.ttc"]

PHASE_ZH = {"kit": "在做事", "stand": "站着看", "walk": "走路", "hidden": "不在", "tent": "帐篷里", "xfade": "起身", "fade": "淡入淡出",
            "turn": "转身", "bow": "鞠躬", "nod": "点头", "doze": "打盹", "": "-"}
STATE_ZH = {"STAY": "停留", "HOME": "在家", "ARRIVE": "到站", "LEAVE": "离开", "ROAD": "在路上", "NIGHT": "过夜"}


def font(size):
    for p in FONT_PATHS:
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except OSError:
                continue
    return ImageFont.load_default()


def main():
    run_dir, out_png = sys.argv[1], sys.argv[2]
    rep = json.load(open(os.path.join(run_dir, "day_run_report.json"), encoding="utf-8"))
    frames = rep["frames"]
    rows = (len(frames) + COLS - 1) // COLS
    W = COLS * (TW + PAD) + PAD
    H = HEAD_H + rows * (TH + LABEL_H + PAD) + PAD
    sheet = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(sheet)
    f_title, f_head, f_lab, f_small = font(26), font(17), font(16), font(14)
    fm = rep.get("frame_ms", {})
    allf, sw = fm.get("all_but_captures", {}), fm.get("switch_and_staging", {})
    st = rep.get("director_stats", {})
    d.text((PAD + 4, 10), "L叔在哪儿 · 加速一天（%sx，%s %s 起 %s 小时，每 %s 分钟一帧）" % (int(rep["scale"]), rep["date"], rep["start"], int(rep["hours"]), int(rep["every_min"])), fill=INK, font=f_title)
    line = "到站 %d · 离开 %d · 在路上的帧 %d · 夜里有营灯的帧 %d/%d · 明信片 %d 张（含鞠躬照 %d）· 帧耗 p95 %.1f ms · 换地/预载时最大 %.1f ms · 失败项 %d" % (
        rep["arrivals"], rep["departures"], rep["road_frames"], rep["lamp_frames"], rep["night_frames"], len(rep.get("postcard_files", [])),
        rep.get("snap_records", 0), allf.get("p95", 0), sw.get("max", 0), rep.get("failed", 0))
    d.text((PAD + 4, 48), line, fill=DIM, font=f_head)
    for i, fr in enumerate(frames):
        cx = PAD + (i % COLS) * (TW + PAD)
        cy = HEAD_H + (i // COLS) * (TH + LABEL_H + PAD)
        path = os.path.join(run_dir, fr["file"])
        if os.path.exists(path):
            im = Image.open(path).convert("RGB").resize((TW, TH), Image.LANCZOS)
            sheet.paste(im, (cx, cy))
        state = STATE_ZH.get(fr.get("substate", ""), fr.get("substate", ""))
        if fr.get("substate") == "NIGHT" and fr.get("night_phase") == "tent":
            state = "过夜·帐篷"
        name = fr.get("stage_name", "") or ""
        d.text((cx + 2, cy + TH + 3), "%s  %s" % (fr.get("local", ""), name), fill=INK, font=f_lab)
        bits = [state, PHASE_ZH.get(fr.get("motion_phase", ""), fr.get("motion_phase", ""))]
        if fr.get("lamp_lit"):
            bits.append("营灯")
        fl = float(fr.get("fire_level", 1.0))
        if fl < 0.99:
            bits.append("火 %.0f%%" % (fl * 100))
        if not fr.get("in_sync", True):
            bits.append("舞台落后")
        d.text((cx + 2, cy + TH + 24), " · ".join(b for b in bits if b), fill=ACCENT if fr.get("lamp_lit") else DIM, font=f_small)
    sheet.save(out_png, optimize=True)
    print("LSHU_DAY_SHEET", out_png, sheet.size)


if __name__ == "__main__":
    main()
