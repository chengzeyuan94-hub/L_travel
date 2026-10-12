#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第四幕「L叔在哪儿」· batch capture with the strict error rule.

Renders scenes/traveler/lshu_main.tscn through tools/traveler/capture_traveler.gd (fixed 1920x1080 SubViewport,
MSAA 4x) and writes <out>/<tile>_<light>[_live][_tag].png/.json/.log, plus one JSON line per run to
<out>/runs[_tag].jsonl.

Strict rule: any log line containing ERROR or WARNING, a nonzero exit code, a missing PNG/JSON, TIMEOUT or a
nonzero capture_error counts as an error.

  python3 tools/traveler/lshu/qa/lshu_batch.py --out=DIR --slot=1 [--tiles=all|D01,J315] [--lights=all|showcase|day,night]
                                              [--modes=freeze,live] [--tag=x] [--timeout=240] [--tiles-group=showcase]
"""
import json, os, subprocess, sys, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))
GODOT = os.environ.get("GODOT_BIN", "/Applications/Godot.app/Contents/MacOS/Godot")
SCENE = "res://scenes/traveler/lshu_main.tscn"
LIGHTS = ["morning", "day", "sunset", "night"]


def pool():
    return json.load(open(os.path.join(ROOT, "data", "traveler", "lshu", "pool.json"), encoding="utf-8"))


def strict_errors(log):
    return [ln.strip() for ln in log.splitlines() if "ERROR" in ln or "WARNING" in ln or ln.strip() == "TIMEOUT"]


def run(out, tile, light, mode, slot, timeout, tag):
    stem = "%s_%s%s%s" % (tile, light, "_live" if mode == "live" else "", ("_" + tag) if tag else "")
    png = os.path.join(out, stem + ".png")
    for p in (png, png[:-4] + ".json"):
        if os.path.exists(p):
            os.remove(p)
    cmd = [GODOT, "--path", ROOT, "--script", "res://tools/traveler/capture_traveler.gd", "--",
           "--capture-scene=" + SCENE, "--tile=" + tile, "--light=" + light, "--capture=" + png, "--park=%d" % slot]
    if mode == "freeze":
        cmd.append("--motion-freeze")
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
    s = {"stem": stem, "tile": tile, "light": light, "mode": mode, "tag": tag, "sec": round(time.time() - t0, 1),
         "png": os.path.exists(png), "rc": rc, "errors": errs}
    j = png[:-4] + ".json"
    if os.path.exists(j):
        d = json.load(open(j, encoding="utf-8"))
        f = d.get("frame_ms", {})
        ch = d.get("character", {})
        if d.get("capture_error", 0) != 0:
            errs.append("capture_error %s" % d.get("capture_error"))
        s.update(p50=round(f.get("p50", 0), 3), p95=round(f.get("p95", 0), 3), max=round(f.get("max", 0), 3), dc=d.get("draw_calls"),
                 pose=ch.get("pose"), char_px=round((ch.get("projection") or {}).get("height_px", 0)),
                 sole_gap_m=((ch.get("life") or {}).get("ground_check") or {}).get("sole_gap_m"),
                 image_size=d.get("image_size"))
    else:
        errs.append("NO JSON")
    if not s["png"]:
        errs.append("NO PNG")
    s["error_count"] = len(errs)
    return s


def main(argv):
    out = None; slot = 1; tiles = "all"; lights = "all"; modes = ["freeze"]; tag = ""; timeout = 240; group = None
    for a in argv:
        if a.startswith("--out="): out = a.split("=", 1)[1]
        elif a.startswith("--slot="): slot = int(a.split("=", 1)[1])
        elif a.startswith("--tiles="): tiles = a.split("=", 1)[1]
        elif a.startswith("--tiles-group="): group = a.split("=", 1)[1]
        elif a.startswith("--lights="): lights = a.split("=", 1)[1]
        elif a.startswith("--modes="): modes = a.split("=", 1)[1].split(",")
        elif a.startswith("--tag="): tag = a.split("=", 1)[1]
        elif a.startswith("--timeout="): timeout = int(a.split("=", 1)[1])
    if not out:
        raise SystemExit("--out=DIR required")
    os.makedirs(out, exist_ok=True)
    entries = pool()["tiles"]
    if group:
        entries = [t for t in entries if t.get("group") == group]
    if tiles != "all":
        want = tiles.split(",")
        entries = [t for t in entries if t["id"] in want]
    rows = []
    summ = os.path.join(out, "runs%s.jsonl" % (("_" + tag) if tag else ""))
    for t in entries:
        ls = LIGHTS if lights == "all" else ([t["light"]] if lights == "showcase" else lights.split(","))
        for l in ls:
            for m in modes:
                s = run(out, t["id"], l, m, slot, timeout, tag)
                rows.append(s)
                open(summ, "a", encoding="utf-8").write(json.dumps(s, ensure_ascii=False) + "\n")
                print("%-26s %5ss png=%s p50=%s p95=%s max=%s dc=%s pose=%s px=%s err=%d" % (
                    s["stem"], s["sec"], s["png"], s.get("p50"), s.get("p95"), s.get("max"), s.get("dc"), s.get("pose"),
                    s.get("char_px"), s["error_count"]), flush=True)
                for e in s["errors"][:6]:
                    print("     ! " + e[:240], flush=True)
    p95s = [r.get("p95", 0) for r in rows if r.get("p95")]
    print("SUMMARY runs=%d png=%d errors=%d worst_p95=%s median_p95=%s" % (
        len(rows), sum(r["png"] for r in rows), sum(r["error_count"] for r in rows), max(p95s or [0]),
        sorted(p95s)[len(p95s) // 2] if p95s else 0), flush=True)
    return 1 if sum(r["error_count"] for r in rows) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
