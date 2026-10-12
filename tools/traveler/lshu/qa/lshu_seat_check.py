#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第四幕「L叔在哪儿」· P0 fix #1 check: seated L叔's feet on the ground, on every seated pool tile.

Seated tiles are found from the data (tile JSON character.action -> look.json character.pose_map == "seated").
Each run renders through tools/traveler/lshu/qa/lshu_seat_capture.gd (fixed 1920x1080 MSAA 4x, the independent
feet scan qa/lshu_seat_scan.gd in the warm-up) with the strict error rule of lshu_batch.py:
  after   fit on, frozen, every light in --lights (default all 4), plus --live-lights live
  before  --seat-fit=off, frozen, the tile's own pool light (the unfitted look, same code otherwise)
Writes <out>/<tile>_<light>[_live][_before].png/.json/.log, <out>/seat_check.json, and with --sheet=PNG the
before / after close-up sheet (pool light).

  python3 tools/traveler/lshu/qa/lshu_seat_check.py --out=DIR [--slot=2] [--lights=all|day,night] [--live-lights=pool]
         [--no-before] [--sheet=PNG] [--sheet-only]
Exit 1 on any strict error or a gate miss (after: cycle sole gap outside [-0.005, 0.03] m, either foot higher than
0.03 m above what is under it at any phase of the idle, or a sole inside the seat).
"""
import json, os, subprocess, sys, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))
GODOT = os.environ.get("GODOT_BIN", "/Applications/Godot.app/Contents/MacOS/Godot")
HARNESS = "res://tools/traveler/lshu/qa/lshu_seat_capture.gd"
LIGHTS = ["morning", "day", "sunset", "night"]
GATE_MAX_M = 0.03
GATE_MIN_M = -0.005


def seated_tiles():
    pool = json.load(open(os.path.join(ROOT, "data", "traveler", "lshu", "pool.json"), encoding="utf-8"))
    look = json.load(open(os.path.join(ROOT, "data", "traveler", "lshu", "look.json"), encoding="utf-8"))
    pose_map = look["common"]["character"].get("pose_map", {})
    out = []
    for t in pool["tiles"]:
        if t["id"] in pool.get("blocklist", []):
            continue
        tile = json.load(open(os.path.join(ROOT, "data", "traveler", "lshu", "tiles", t["id"] + ".json"), encoding="utf-8"))
        if pose_map.get(str(tile.get("character", {}).get("action", "look")), "standing") == "seated":
            out.append(t)
    return out


def strict_errors(log):
    return [ln.strip() for ln in log.splitlines() if "ERROR" in ln or "WARNING" in ln or ln.strip() == "TIMEOUT"]


def run(out, tile, light, live, before, slot, timeout):
    stem = "%s_%s%s%s" % (tile, light, "_live" if live else "", "_before" if before else "")
    png = os.path.join(out, stem + ".png")
    for p in (png, png[:-4] + ".json"):
        if os.path.exists(p):
            os.remove(p)
    cmd = [GODOT, "--path", ROOT, "--script", HARNESS, "--", "--tile=" + tile, "--light=" + light,
           "--capture=" + png, "--park=%d" % slot]
    if not live:
        cmd.append("--motion-freeze")
    if before:
        cmd.append("--seat-fit=off")
    t0 = time.time(); rc = None
    try:
        pr = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
        log = (pr.stdout or "") + (pr.stderr or ""); rc = pr.returncode
    except subprocess.TimeoutExpired as e:
        o = e.stdout.decode("utf-8", "replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        log = o + "\nTIMEOUT"
    open(png[:-4] + ".log", "w", encoding="utf-8").write(" ".join(cmd) + "\n\n" + log)
    errs = strict_errors(log)
    if rc != 0:
        errs.append("EXIT %s" % rc)
    r = {"stem": stem, "tile": tile, "light": light, "live": live, "before": before, "sec": round(time.time() - t0, 1),
         "png": os.path.exists(png), "rc": rc}
    j = png[:-4] + ".json"
    if os.path.exists(j):
        d = json.load(open(j, encoding="utf-8"))
        if d.get("capture_error", 0) != 0:
            errs.append("capture_error %s" % d.get("capture_error"))
        f = d.get("frame_ms", {})
        scan = (d.get("extra") or {}).get("seat_scan")
        life = (d.get("character") or {}).get("life") or {}
        fit = life.get("seat_fit") or {}
        r.update(p50=round(f.get("p50", 0), 3), p95=round(f.get("p95", 0), 3), draw_calls=d.get("draw_calls"),
                 projection=(d.get("character") or {}).get("projection", {}).get("bounds_px"))
        if scan is None:
            errs.append("NO seat_scan")
        else:
            now = scan["at_anim_t"]; cyc = scan["cycle"]
            r.update(sole_gap_m=now["sole_gap_m"], foot_gap_m=now["foot_gap_m"], gap_vs_ground_only_m=now["sole_gap_vs_ground_only_m"],
                     inside_seat=now["queries_inside_seat"], on_seat_parts=now["queries_over_seat_parts"],
                     cycle_min_m=cyc["min_gap_m"], cycle_max_m=cyc["max_gap_m"], cycle_max_foot_m=cyc["max_foot_gap_m"],
                     cycle_inside_seat=max(cyc["lowest_phase"].get("queries_inside_seat", 0), cyc["highest_phase"].get("queries_inside_seat", 0)),
                     seat_top_minus_anchor_m=(scan.get("seat") or {}).get("mesh_top_minus_anchor_m"),
                     seat_scale_y=((scan.get("seat") or {}).get("holder_scale") or [0, 0, 0])[1])
        r["fit"] = {k: fit.get(k) for k in ("slide_m", "scale_y", "drop_m", "seat_height_m", "seat_height_after_m", "sole_gap_before_m",
                                             "sole_gap_after_m", "sole_gap_vs_terrain_after_m", "sole_points_on_seat_parts",
                                             "sole_points_blocked_after", "fit_ms", "seat_grid_ms", "note") if k in fit}
        if not before and scan is not None:
            if not (GATE_MIN_M <= r["cycle_min_m"] and r["cycle_max_m"] <= GATE_MAX_M):
                errs.append("GATE sole gap over the idle %.4f..%.4f m outside [%.3f, %.3f]" % (r["cycle_min_m"], r["cycle_max_m"], GATE_MIN_M, GATE_MAX_M))
            # each foot, not only the lower one (P0 verifier round 1)
            if r["cycle_max_foot_m"] > GATE_MAX_M:
                errs.append("GATE higher foot over the idle %.4f m > %.3f" % (r["cycle_max_foot_m"], GATE_MAX_M))
            if r["inside_seat"] or r["cycle_inside_seat"]:
                errs.append("GATE sole inside the seat (%d / %d points)" % (r["inside_seat"], r["cycle_inside_seat"]))
            if r["p95"] > 33.3:
                errs.append("GATE p95 %.2f ms > 33.3" % r["p95"])
    else:
        errs.append("NO JSON")
    if not r["png"]:
        errs.append("NO PNG")
    r["errors"] = errs
    return r


def sheet(out, rows, path):
    from PIL import Image, ImageDraw, ImageFont
    font_path = next((p for p in ("/System/Library/Fonts/STHeiti Medium.ttc", "/System/Library/Fonts/Hiragino Sans GB.ttc") if os.path.exists(p)), None)
    font = ImageFont.truetype(font_path, 22) if font_path else ImageFont.load_default()
    small = ImageFont.truetype(font_path, 18) if font_path else ImageFont.load_default()
    pairs = []
    by = {r["stem"]: r for r in rows}
    for t in seated_tiles():
        b = by.get("%s_%s_before" % (t["id"], t["light"])); a = by.get("%s_%s" % (t["id"], t["light"]))
        if b and a and b.get("projection") and a.get("png") and b.get("png"):
            pairs.append((t, b, a))
    side = 460; cap = 86; pad = 12
    img = Image.new("RGB", (pad + 2 * (side + pad), 58 + len(pairs) * (side + cap + pad)), (24, 24, 28))
    dr = ImageDraw.Draw(img)
    dr.text((pad, 14), "修复 1 · 坐姿脚着地（左 修前：同版代码关掉坐具适配；右 修后；定帧）", font=font, fill=(235, 235, 235))
    y = 58
    for t, b, a in pairs:
        pb = b["projection"]; pa = a["projection"]
        cx = (pb[0] + pb[2] + pa[0] + pa[2]) / 4.0
        cy = (min(pb[1], pa[1]) + max(pb[3], pa[3])) / 2.0 + 12
        half = max(pb[3] - pb[1], pa[3] - pa[1]) * 1.05
        box = (int(cx - half), int(cy - half), int(cx + half), int(cy + half))
        for k, r in enumerate((b, a)):
            im = Image.open(os.path.join(out, r["stem"] + ".png")).convert("RGB").crop(box).resize((side, side), Image.LANCZOS)
            x = pad + k * (side + pad)
            img.paste(im, (x, y))
            if k == 0:
                line1 = "%s %s · 修前" % (t["id"], r["light"])
                line2 = "脚底离地面 %.3f m，鞋底嵌进坐具 %d 个采样点" % (r["gap_vs_ground_only_m"], r["inside_seat"])
                line3 = "坐具高 %.2f m（原样）" % (a["fit"].get("seat_height_m") or 0.0)
            else:
                f = r["fit"]
                line1 = "%s %s · 修后" % (t["id"], r["light"])
                line2 = "脚下支撑间隙 %.3f m（待机 %.3f–%.3f），嵌入 %d" % (r["sole_gap_m"], r["cycle_min_m"], r["cycle_max_m"], r["inside_seat"] + r["cycle_inside_seat"])
                line3 = "坐具高 %.2f→%.2f m，前移 %.2f m，离地面 %.3f m" % (f.get("seat_height_m", 0), f.get("seat_height_after_m", 0),
                                                                f.get("slide_m", 0), r["gap_vs_ground_only_m"])
            dr.text((x, y + side + 4), line1, font=small, fill=(250, 220, 150))
            dr.text((x, y + side + 30), line2, font=small, fill=(225, 225, 225))
            dr.text((x, y + side + 56), line3, font=small, fill=(190, 190, 190))
        y += side + cap + pad
    img.save(path)
    print("SHEET %s (%d tiles)" % (path, len(pairs)))


def main(argv):
    out = None; slot = 2; lights = "all"; live_lights = "pool"; before = True; sheet_path = None; timeout = 240; sheet_only = False
    for a in argv:
        if a.startswith("--out="): out = os.path.abspath(a.split("=", 1)[1])
        elif a.startswith("--slot="): slot = int(a.split("=", 1)[1])
        elif a.startswith("--lights="): lights = a.split("=", 1)[1]
        elif a.startswith("--live-lights="): live_lights = a.split("=", 1)[1]
        elif a == "--no-before": before = False
        elif a.startswith("--sheet="): sheet_path = os.path.abspath(a.split("=", 1)[1])
        elif a == "--sheet-only": sheet_only = True
        elif a.startswith("--timeout="): timeout = int(a.split("=", 1)[1])
    if not out:
        raise SystemExit("--out=DIR required")
    os.makedirs(out, exist_ok=True)
    summary_path = os.path.join(out, "seat_check.json")
    if sheet_only:
        rows = json.load(open(summary_path, encoding="utf-8"))["runs"]
        sheet(out, rows, sheet_path)
        return 0
    rows = []
    tiles = seated_tiles()
    print("seated tiles: %s" % ", ".join(t["id"] for t in tiles), flush=True)
    for t in tiles:
        plan = []
        if before:
            plan.append((t["light"], False, True))
        for l in (LIGHTS if lights == "all" else lights.split(",")):
            plan.append((l, False, False))
        for l in ([t["light"]] if live_lights == "pool" else ([] if live_lights == "none" else live_lights.split(","))):
            plan.append((l, True, False))
        for light, live, bef in plan:
            r = run(out, t["id"], light, live, bef, slot, timeout)
            rows.append(r)
            print("%-24s %5ss p50=%s p95=%s dc=%s gap=%s cycle=%s..%s foot_max=%s ground=%s inside=%s slide=%s scale=%s err=%d" % (
                r["stem"], r["sec"], r.get("p50"), r.get("p95"), r.get("draw_calls"),
                *["%.4f" % r[k] if isinstance(r.get(k), float) else r.get(k) for k in ("sole_gap_m", "cycle_min_m", "cycle_max_m", "cycle_max_foot_m", "gap_vs_ground_only_m")],
                r.get("inside_seat"), r["fit"].get("slide_m"), r["fit"].get("scale_y"), len(r["errors"])), flush=True)
            for e in r["errors"][:6]:
                print("     ! " + e[:240], flush=True)
    after = [r for r in rows if not r["before"] and "cycle_max_m" in r]
    rep = {"schema": "lshu.seat-check.v1", "gate_m": [GATE_MIN_M, GATE_MAX_M], "tiles": [t["id"] for t in tiles], "runs": rows,
           "after": {"runs": len(after), "errors": sum(len(r["errors"]) for r in rows),
                     "sole_gap_cycle_min_m": min([r["cycle_min_m"] for r in after] or [None]),
                     "sole_gap_cycle_max_m": max([r["cycle_max_m"] for r in after] or [None]),
                     "max_foot_gap_m": max([r["cycle_max_foot_m"] for r in after] or [None]),
                     "inside_seat_points": sum(r["inside_seat"] + r["cycle_inside_seat"] for r in after),
                     "p95_max_ms": max([r["p95"] for r in after] or [None]), "p50_median_ms": sorted([r["p50"] for r in after])[len(after) // 2] if after else None}}
    json.dump(rep, open(summary_path, "w", encoding="utf-8"), indent=1, ensure_ascii=False)
    print("SUMMARY runs=%d errors=%d after: gap %s..%s m, foot max %s m, inside %s, p95 max %s ms" % (
        len(rows), rep["after"]["errors"], rep["after"]["sole_gap_cycle_min_m"], rep["after"]["sole_gap_cycle_max_m"],
        rep["after"]["max_foot_gap_m"], rep["after"]["inside_seat_points"], rep["after"]["p95_max_ms"]), flush=True)
    if sheet_path:
        sheet(out, rows, sheet_path)
    return 1 if rep["after"]["errors"] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
