#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第四幕「L叔在哪儿」· decision 4 QA: L叔 findability at night without / with the night lamp.

  run      renders every chosen tile in the night preset twice through qa/lshu_qa_capture.gd --findability
           (fixed 1920x1080 MSAA 4x SubViewport, motion frozen): --night-lamp=off (before) and the default (after).
           Strict rule: any log line with ERROR or WARNING, a nonzero exit, a missing PNG / JSON, TIMEOUT or a
           nonzero capture_error is an error.
  summary  one row per tile: lamp decision (mode, reason, prop, spot, ring / angle), ΔE / salience before and after
  sheet    before / after crops around him (needs pillow)

  python3 tools/traveler/lshu/qa/lshu_night_lamp_qa.py run --out=DIR --slot=22 [--tiles=all|night|<id>,<id>] [--variants=off,on]
  python3 tools/traveler/lshu/qa/lshu_night_lamp_qa.py summary --out=DIR [--json=PATH]
  uv run --with pillow --with numpy python tools/traveler/lshu/qa/lshu_night_lamp_qa.py sheet --out=DIR --png=PATH [--tiles=...]
Tile ids come from pool.json only ("night" = the pool tiles whose default light is night).
"""
import json, os, subprocess, sys, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))
GODOT = os.environ.get("GODOT_BIN", "/Applications/Godot.app/Contents/MacOS/Godot")
TARGET_DE = 12.0


def pool():
    return json.load(open(os.path.join(ROOT, "data", "traveler", "lshu", "pool.json"), encoding="utf-8"))


def pick(sel):
    tiles = pool()["tiles"]
    if sel == "all":
        return tiles
    if sel == "night":
        return [t for t in tiles if t.get("light") == "night"]
    want = sel.split(",")
    return [t for t in tiles if t["id"] in want]


def strict_errors(log):
    return [ln.strip() for ln in log.splitlines() if "ERROR" in ln or "WARNING" in ln or ln.strip() == "TIMEOUT"]


def run_one(out, tile, variant, slot, timeout):
    stem = "%s_night_%s" % (tile, variant)
    png = os.path.join(out, stem + ".png")
    for p in (png, png[:-4] + ".json"):
        if os.path.exists(p):
            os.remove(p)
    cmd = [GODOT, "--path", ROOT, "--script", "res://tools/traveler/lshu/qa/lshu_qa_capture.gd", "--",
           "--tile=" + tile, "--light=night", "--motion-freeze", "--park=%d" % slot, "--findability", "--capture=" + png]
    if variant == "off":
        cmd.append("--night-lamp=off")
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
    row = {"tile": tile, "variant": variant, "sec": round(time.time() - t0, 1), "errors": errs}
    j = png[:-4] + ".json"
    if os.path.exists(j):
        d = json.load(open(j, encoding="utf-8"))
        if d.get("capture_error", 0) != 0:
            errs.append("capture_error %s" % d.get("capture_error"))
        f = (d.get("extra") or {}).get("findability") or {}
        row.update(delta_e=f.get("delta_e"), salience=f.get("salience"), delta_l=f.get("delta_l"),
                   p95=(d.get("frame_ms") or {}).get("p95"), draw_calls=d.get("draw_calls"), lamp=d.get("night_lamp"))
        if not f or "error" in f:
            errs.append("findability missing: %s" % f.get("error", "none"))
    else:
        errs.append("NO JSON")
    if not os.path.exists(png):
        errs.append("NO PNG")
    row["error_count"] = len(errs)
    return row


def cmd_run(args):
    out = args["out"]; slot = int(args.get("slot", 22)); timeout = int(args.get("timeout", 150))
    variants = args.get("variants", "off,on").split(",")
    os.makedirs(out, exist_ok=True)
    runs = os.path.join(out, "runs.jsonl")
    total_err = 0
    for t in pick(args.get("tiles", "night")):
        for v in variants:
            r = run_one(out, t["id"], v, slot, timeout)
            total_err += r["error_count"]
            open(runs, "a", encoding="utf-8").write(json.dumps(r, ensure_ascii=False) + "\n")
            lamp = r.get("lamp") or {}
            print("%-6s %-3s %5ss dE=%s sal=%s p95=%s lamp=%s err=%d" % (t["id"], v, r["sec"], _f(r.get("delta_e")), _f(r.get("salience")),
                  _f(r.get("p95")), lamp.get("mode"), r["error_count"]), flush=True)
            for e in r["errors"][:4]:
                print("     ! " + e[:200], flush=True)
    print("RUN_DONE errors=%d" % total_err)
    return 1 if total_err else 0


def _f(v):
    return "-" if v is None else ("%.2f" % v)


def load_rows(out):
    rows = {}
    path = os.path.join(out, "runs.jsonl")
    for ln in open(path, encoding="utf-8"):
        r = json.loads(ln)
        rows[(r["tile"], r["variant"])] = r   # last run wins
    return rows


def cmd_summary(args):
    out = args["out"]
    rows = load_rows(out)
    entries = {t["id"]: t for t in pool()["tiles"]}
    table = []
    for (tile, v), r in sorted(rows.items()):
        if v != "on":
            continue
        off = rows.get((tile, "off"), {})
        lamp = r.get("lamp") or {}
        table.append({"tile": tile, "default_light": entries.get(tile, {}).get("light"), "name": entries.get(tile, {}).get("name"),
                      "lamp_mode": lamp.get("mode"), "reason": lamp.get("reason"), "prop": lamp.get("asset"), "spot": lamp.get("spot"),
                      "ring_m": lamp.get("ring_m"), "angle_to_camera_deg": lamp.get("angle_to_camera_deg"), "relax": lamp.get("relax"),
                      "light_dist_m": lamp.get("light_dist_m"), "setup_ms": lamp.get("ms"),
                      "delta_e_off": off.get("delta_e"), "delta_e_on": r.get("delta_e"), "salience_off": off.get("salience"), "salience_on": r.get("salience"),
                      "p95_on": r.get("p95"), "draw_calls_off": off.get("draw_calls"), "draw_calls_on": r.get("draw_calls"),
                      "errors": off.get("error_count", 0) + r.get("error_count", 0)})
    def stats(sel):
        on = [x["delta_e_on"] for x in sel if x["delta_e_on"] is not None]
        off = [x["delta_e_off"] for x in sel if x["delta_e_off"] is not None]
        return {"tiles": len(sel), "de_on_min": min(on) if on else None, "de_on_median": sorted(on)[len(on) // 2] if on else None,
                "de_off_min": min(off) if off else None, "below_target_on": sum(1 for v in on if v < TARGET_DE),
                "below_target_off": sum(1 for v in off if v < TARGET_DE)}
    lamped = [x for x in table if x["lamp_mode"] not in (None, "none")]
    summary = {"schema": "lshu.night_lamp_qa.v1", "target_delta_e": TARGET_DE, "all": stats(table),
               "night_default_tiles": stats([x for x in table if x["default_light"] == "night"]),
               "lamp_tiles": stats(lamped), "modes": {m: sum(1 for x in table if x["lamp_mode"] == m) for m in sorted({str(x["lamp_mode"]) for x in table})},
               "errors": sum(x["errors"] for x in table), "rows": table}
    text = json.dumps(summary, ensure_ascii=False, indent=1)
    if args.get("json"):
        open(args["json"], "w", encoding="utf-8").write(text + "\n")
    print(json.dumps({k: v for k, v in summary.items() if k != "rows"}, ensure_ascii=False))
    for x in sorted(table, key=lambda x: (x["delta_e_on"] or 0)):
        print("%-6s %-7s %-10s dE %6s -> %6s  sal %5s -> %5s  %s" % (x["tile"], x["default_light"], x["lamp_mode"], _f(x["delta_e_off"]), _f(x["delta_e_on"]),
              _f(x["salience_off"]), _f(x["salience_on"]), (x["reason"] or "")[:60]))
    return 0


def cmd_sheet(args):
    from PIL import Image, ImageDraw, ImageFont
    out = args["out"]
    rows = load_rows(out)
    tiles = args["tiles"].split(",")
    cw, ch = 520, 340
    font = None
    for fp in ("/System/Library/Fonts/PingFang.ttc", "/System/Library/Fonts/STHeiti Light.ttc", "/Library/Fonts/Arial Unicode.ttf"):
        if os.path.exists(fp):
            font = ImageFont.truetype(fp, 20)
            break
    sheet = Image.new("RGB", (cw * 2 + 30, (ch + 40) * len(tiles) + 50), (24, 26, 30))
    d = ImageDraw.Draw(sheet)
    d.text((10, 12), "夜里的营灯（决定 4）· 左：无营灯  右：有营灯 · ΔE = L叔与周围一圈的色差（目标 ≥ 12）", fill=(235, 235, 235), font=font)
    for i, t in enumerate(tiles):
        y = 50 + i * (ch + 40)
        for j, v in enumerate(("off", "on")):
            r = rows.get((t, v), {})
            png = os.path.join(out, "%s_night_%s.png" % (t, v))
            js = os.path.join(out, "%s_night_%s.json" % (t, v))
            if not os.path.exists(png):
                continue
            im = Image.open(png).convert("RGB")
            dd = json.load(open(js, encoding="utf-8"))
            b = dd["character"]["projection"]["bounds_px"]
            cx, cy = (b[0] + b[2]) / 2, (b[1] + b[3]) / 2
            crop = im.crop((int(cx - cw / 2), int(cy - ch / 2), int(cx + cw / 2), int(cy + ch / 2)))
            sheet.paste(crop, (10 + j * (cw + 10), y + 30))
            lamp = r.get("lamp") or {}
            label = "%s %s  ΔE %s" % (t, "无营灯" if v == "off" else "有营灯（%s）" % lamp.get("mode"), _f(r.get("delta_e")))
            d.text((10 + j * (cw + 10), y + 4), label, fill=(235, 235, 235), font=font)
    sheet.save(args["png"])
    print("SHEET", args["png"], sheet.size)
    return 0


def main(argv):
    if not argv:
        print(__doc__); return 2
    cmd = argv[0]
    args = {}
    for a in argv[1:]:
        if a.startswith("--") and "=" in a:
            k, v = a[2:].split("=", 1); args[k] = v
    return {"run": cmd_run, "summary": cmd_summary, "sheet": cmd_sheet}[cmd](args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
