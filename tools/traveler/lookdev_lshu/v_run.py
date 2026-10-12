#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Verifier (v_) runner: renders the DELIVERED variant (default m_final, unmodified) and writes
docs/reports/traveler-lshu-20260923/v_<recipe>_<light>[_tag].png/.json/.log.
Stricter log scan than lshu_lookdev.py: any line containing ERROR (SCRIPT/SHADER/USER/engine), 'Parse Error',
TIMEOUT or a non-zero exit is an error; any line containing WARNING is counted separately.
  python3 v_run.py --slot=5 --recipes=D01,D03 --lights=all [--live] [--tag=x] [--variant=m_final]
"""
import json, os, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, os.pardir, os.pardir, os.pardir))
GODOT = "/Applications/Godot.app/Contents/MacOS/Godot"
OUT = os.path.join(ROOT, "docs", "reports", "traveler-lshu-20260923")
SCENE = "res://tools/traveler/lookdev_lshu/lshu_tile_viewer.tscn"
LIGHTS = ["morning", "day", "sunset", "night"]

def classify(log):
    err, warn = [], []
    for ln in log.splitlines():
        u = ln.strip()
        if ("ERROR" in u) or ("Parse Error" in u) or u == "TIMEOUT":
            err.append(u)
        elif "WARNING" in u:
            warn.append(u)
    return err, warn

def run(variant, recipe, light, slot, extra, timeout, tag):
    stem = "v_%s_%s" % (recipe, light) + ("_" + tag if tag else "")
    png = os.path.join(OUT, stem + ".png")
    for p in (png, png[:-4] + ".json"):
        if os.path.exists(p): os.remove(p)
    cmd = [GODOT, "--path", ROOT, "--script", "res://tools/traveler/capture_traveler.gd", "--",
           "--capture-scene=" + SCENE, "--recipe=" + recipe, "--light=" + light, "--variant=" + variant,
           "--capture=" + png, "--park=%d" % slot] + extra
    t0 = time.time(); rc = None
    try:
        pr = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
        log = (pr.stdout or "") + (pr.stderr or ""); rc = pr.returncode
    except subprocess.TimeoutExpired as e:
        out = e.stdout.decode("utf-8", "replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        log = out + "\nTIMEOUT"
    open(os.path.join(OUT, stem + ".log"), "w", encoding="utf-8").write(" ".join(cmd) + "\n\n" + log)
    err, warn = classify(log)
    if rc not in (0, None): err.append("EXIT %s" % rc)
    s = {"stem": stem, "variant": variant, "recipe": recipe, "light": light, "tag": tag, "sec": round(time.time() - t0, 1),
         "png": os.path.exists(png), "rc": rc, "errors": err, "warnings": warn}
    j = png[:-4] + ".json"
    if os.path.exists(j):
        d = json.load(open(j, encoding="utf-8")); f = d.get("frame_ms", {})
        s.update(p50=round(f.get("p50", 0), 2), p95=round(f.get("p95", 0), 2), max=round(f.get("max", 0), 2),
                 dc=d.get("draw_calls"), pose=d.get("character", {}).get("pose"),
                 char_px=round(d.get("character", {}).get("projection", {}).get("height_px", 0)),
                 cfg_variant=d.get("config", {}).get("name"))
    else:
        s["errors"].append("NO JSON")
    return s

def main(argv):
    slot = 5; lights = "all"; recipes = []; extra = ["--motion-freeze"]; timeout = 300; tag = ""; variant = "m_final"
    for a in argv:
        if a.startswith("--slot="): slot = int(a.split("=", 1)[1])
        elif a.startswith("--lights="): lights = a.split("=", 1)[1]
        elif a.startswith("--recipes="): recipes = [r for r in a.split("=", 1)[1].split(",") if r]
        elif a.startswith("--tag="): tag = a.split("=", 1)[1]
        elif a.startswith("--variant="): variant = a.split("=", 1)[1]
        elif a == "--live": extra = [x for x in extra if x != "--motion-freeze"]
        elif a.startswith("--"): extra.append(a)
    ls = LIGHTS if lights == "all" else lights.split(",")
    rows = []
    summ = os.path.join(OUT, "v_runs%s.jsonl" % ("_" + tag if tag else ""))
    for r in recipes:
        for l in ls:
            s = run(variant, r, l, slot, extra, timeout, tag)
            rows.append(s)
            open(summ, "a", encoding="utf-8").write(json.dumps(s, ensure_ascii=False) + "\n")
            print("%-24s %5ss png=%s p50=%s p95=%s max=%s dc=%s pose=%s px=%s err=%d warn=%d" % (
                s["stem"], s["sec"], s["png"], s.get("p50"), s.get("p95"), s.get("max"), s.get("dc"), s.get("pose"),
                s.get("char_px"), len(s["errors"]), len(s["warnings"])), flush=True)
            for e in (s["errors"] + s["warnings"])[:6]: print("     ! " + e[:240], flush=True)
    print("SUMMARY runs=%d png=%d errors=%d warnings=%d worst_p95=%s" % (len(rows), sum(r["png"] for r in rows),
          sum(len(r["errors"]) for r in rows), sum(len(r["warnings"]) for r in rows), max([r.get("p95", 0) for r in rows] or [0])), flush=True)

if __name__ == "__main__":
    main(sys.argv[1:])
