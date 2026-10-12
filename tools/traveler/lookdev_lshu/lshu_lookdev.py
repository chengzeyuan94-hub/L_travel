#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""L叔在哪儿 · 地块光影探针跑批器（导演探针，Codex 文件零写入）。

用法：python3 tools/traveler/lookdev_lshu/lshu_lookdev.py [--slot=N] [--recipes=D01,D05] [--lights=day,sunset|showcase|all]
                                                           [--live] [--tag=x] [--timeout=240] <variant> [...]
  - 每个 variant × recipe × light 渲一张 1920×1080（tools/traveler/capture_traveler.gd 的固定 SubViewport，MSAA 4×）：
      docs/reports/traveler-lshu-20260923/<variant>_<recipe>_<light>.png / .json / .log
  - --lights 缺省 = showcase（每块用烘焙时的光照），all = 四档。
  - --slot=N 把窗口缩小并挪到屏幕不同位置（并行时互不遮挡）。
  - 缺省带 --motion-freeze（A/B 可比）；--live 让动作照常走。--tag=x 给文件名加后缀 _x（不覆盖冻结版）。
  - --recipes 缺省只取 D01–D12（样板）；别的烘焙配方要显式列出。
  - 错误计数：SCRIPT ERROR、SHADER ERROR、以 "ERROR:" 开头的行、TIMEOUT。
"""
import json, os, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, os.pardir, os.pardir, os.pardir))
GODOT = os.environ.get("GODOT_BIN", "/Applications/Godot.app/Contents/MacOS/Godot")
OUT_DIR = os.path.join(ROOT, "docs", "reports", "traveler-lshu-20260923")
SCENE_RES = "res://tools/traveler/lookdev_lshu/lshu_tile_viewer.tscn"
LIGHTS = ["morning", "day", "sunset", "night"]


def baked_index():
    p = os.path.join(HERE, "baked", "index.json")
    return {t["id"]: t for t in json.load(open(p, encoding="utf-8"))["tiles"]} if os.path.exists(p) else {}


def is_error(line):
    return ("SCRIPT ERROR" in line or "SHADER ERROR" in line or "TIMEOUT" in line
            or line.startswith("ERROR:"))


def run(variant, recipe, light, slot, extra, timeout, tag=""):
    os.makedirs(OUT_DIR, exist_ok=True)
    stem = "%s_%s_%s" % (variant, recipe, light) + ("_" + tag if tag else "")
    png = os.path.join(OUT_DIR, stem + ".png")
    for p in (png, png[:-4] + ".json"):
        if os.path.exists(p):
            os.remove(p)
    cmd = [GODOT, "--path", ROOT, "--script", "res://tools/traveler/capture_traveler.gd", "--",
           "--capture-scene=" + SCENE_RES, "--recipe=" + recipe, "--light=" + light, "--variant=" + variant,
           "--capture=" + png, "--park=%d" % slot] + extra
    t0 = time.time()
    try:
        pr = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
        log = (pr.stdout or "") + (pr.stderr or "")
    except subprocess.TimeoutExpired as e:
        out = e.stdout.decode("utf-8", "replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        log = out + "\nTIMEOUT"
    open(os.path.join(OUT_DIR, stem + ".log"), "w", encoding="utf-8").write(" ".join(cmd) + "\n\n" + log)
    s = {"stem": stem, "seconds": round(time.time() - t0, 1), "png": os.path.exists(png)}
    j = png[:-4] + ".json"
    if os.path.exists(j):
        d = json.load(open(j, encoding="utf-8"))
        f = d.get("frame_ms", {})
        s["p50"] = round(f.get("p50", 0), 2); s["p95"] = round(f.get("p95", 0), 2); s["draw_calls"] = d.get("draw_calls")
        s["pose"] = d.get("character", {}).get("pose"); s["char_px"] = round(d.get("character", {}).get("projection", {}).get("height_px", 0))
        s["backdrop_err"] = round(d.get("backdrop", {}).get("error_max", 0), 3)
    s["errors"] = [ln for ln in log.splitlines() if is_error(ln)][:8]
    return s


def main(argv):
    slot = 0; lights = "showcase"; recipes = None; extra = ["--motion-freeze"]; variants = []; timeout = 240; tag = ""
    for a in argv:
        if a.startswith("--slot="): slot = int(a.split("=", 1)[1])
        elif a.startswith("--lights="): lights = a.split("=", 1)[1]
        elif a.startswith("--recipes="): recipes = [r for r in a.split("=", 1)[1].split(",") if r]
        elif a.startswith("--timeout="): timeout = int(a.split("=", 1)[1])
        elif a.startswith("--tag="): tag = a.split("=", 1)[1]
        elif a == "--live": extra = [x for x in extra if x != "--motion-freeze"]
        elif a.startswith("--"): extra.append(a)
        else: variants.append(a)
    if not variants:
        raise SystemExit(__doc__)
    idx = baked_index()
    recipes = recipes or sorted(r for r in idx if r.startswith("D"))
    total_err = 0; rows = []
    for v in variants:
        for r in recipes:
            if lights == "showcase":
                ls = [idx.get(r, {}).get("light", "day")]
            elif lights == "all":
                ls = LIGHTS
            else:
                ls = lights.split(",")
            for light in ls:
                s = run(v, r, light, slot, extra, timeout, tag)
                rows.append(s); total_err += len(s["errors"])
                print("%-32s %5ss png=%s p50=%s p95=%s dc=%s pose=%s char_px=%s bd_err=%s errs=%d" % (
                    s["stem"], s["seconds"], s["png"], s.get("p50"), s.get("p95"), s.get("draw_calls"),
                    s.get("pose"), s.get("char_px"), s.get("backdrop_err"), len(s["errors"])), flush=True)
                for e in s["errors"]:
                    print("      ! " + e[:220])
    p95 = [r["p95"] for r in rows if r.get("p95") is not None]
    print("SUMMARY runs=%d png_ok=%d errors=%d worst_p95=%s" % (len(rows), sum(1 for r in rows if r["png"]), total_err, max(p95) if p95 else None))


if __name__ == "__main__":
    main(sys.argv[1:])
