#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""盘橐旅人 · 光影探针跑批器（导演探针，Codex 文件零写入）。

用法：python3 tools/traveler/lookdev_panti/panti_lookdev.py [--slot=N] [--periods=morning,midnight] <variant> [...]
  1. 从 scripts/traveler/panti/panti_viewer.gd 克隆 lookdev_viewer.gd，只在 PANTI_READY 之前挂 panti_overlay.gd；
     生成 panti_probe.tscn。机位、数据文件、Codex 的全部脚本照旧读取、不改。
  2. 每个 variant 按时段各渲一张 1920×1080：<variant>_morning.png / <variant>_midnight.png（+ .json / .log）。
     --periods=morning,midnight,blend50 还会渲过渡权重 0.50 的中间帧 <variant>_blend50.png。
  3. --slot=N 把窗口缩小并挪到屏幕不同位置（并行时互不遮挡）。
"""
import json, os, re, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, os.pardir, os.pardir, os.pardir))
GODOT = os.environ.get("GODOT_BIN", "/Applications/Godot.app/Contents/MacOS/Godot")
VIEWER = os.path.join(ROOT, "scripts", "traveler", "panti", "panti_viewer.gd")
OUT_DIR = os.path.join(ROOT, "docs", "reports", "traveler-panti-light-20260923")
SCENE_RES = "res://tools/traveler/lookdev_panti/panti_probe.tscn"


def clone():
    code = open(VIEWER, encoding="utf-8").read()
    needle = "\trefresh_frozen_viewport()\n\tprint(\"PANTI_READY \""
    if code.count(needle) != 1:
        raise SystemExit("panti_viewer.gd 里找不到唯一的 PANTI_READY 入口，克隆点需要重新适配")
    hook = "\tload(\"res://tools/traveler/lookdev_panti/panti_overlay.gd\").new().apply(self)\n"
    code = code.replace(needle, hook + needle)
    banner = ("# 自动生成，不要手改。由 tools/traveler/lookdev_panti/panti_lookdev.py 从\n"
              "# scripts/traveler/panti/panti_viewer.gd 克隆，只在 PANTI_READY 前挂上 panti_overlay.gd。\n")
    open(os.path.join(HERE, "lookdev_viewer.gd"), "w", encoding="utf-8").write(banner + code)
    tscn = open(os.path.join(ROOT, "scenes", "traveler", "panti_main.tscn"), encoding="utf-8").read()
    tscn = tscn.replace('path="res://scripts/traveler/panti/panti_viewer.gd"', 'path="res://tools/traveler/lookdev_panti/lookdev_viewer.gd"')
    assert "lookdev_viewer.gd" in tscn
    open(os.path.join(HERE, "panti_probe.tscn"), "w", encoding="utf-8").write(tscn)


def _period_args(period):
    # "blend50" = 从清晨出发、把过渡权重定在 0.50 的中间帧（验证点篝火切换）
    if period.startswith("blend"):
        return ["--morning", "--blend=%.2f" % (int(period[5:]) / 100.0)]
    return ["--" + period]


def run(variant, period, slot, extra):
    os.makedirs(OUT_DIR, exist_ok=True)
    stem = "%s_%s" % (variant, period)
    png = os.path.join(OUT_DIR, stem + ".png")
    for p in (png, png[:-4] + ".json"):
        if os.path.exists(p):
            os.remove(p)
    cmd = [GODOT, "--path", ROOT, "--script", "res://tools/traveler/capture_traveler.gd", "--",
           "--capture-scene=" + SCENE_RES, "--view=panti"] + _period_args(period) + [
           "--capture=" + png, "--lookdev=" + variant, "--park=%d" % slot] + extra
    t0 = time.time()
    try:
        pr = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=240)
        log = (pr.stdout or "") + (pr.stderr or "")
    except subprocess.TimeoutExpired as e:
        log = ((e.stdout or b"").decode("utf-8", "replace") if isinstance(e.stdout, bytes) else (e.stdout or "")) + "\nTIMEOUT"
    open(os.path.join(OUT_DIR, stem + ".log"), "w", encoding="utf-8").write(" ".join(cmd) + "\n\n" + log)
    s = {"stem": stem, "seconds": round(time.time() - t0, 1), "png": os.path.exists(png)}
    j = png[:-4] + ".json"
    if os.path.exists(j):
        d = json.load(open(j))
        f = d.get("frame_ms", {}) or d.get("performance", {})
        s["p50"] = f.get("p50"); s["p95"] = f.get("p95"); s["draw_calls"] = d.get("draw_calls")
    # 引擎级 "ERROR: ..."（例如材质为空）也算错误，不只脚本 / shader 报错
    s["errors"] = [ln for ln in log.splitlines() if "SCRIPT ERROR" in ln or "SHADER ERROR" in ln or "TIMEOUT" in ln or ln.startswith("ERROR:")][:8]
    return s


def main(argv):
    slot = 0; periods = ["morning", "midnight"]; extra = []; variants = []
    for a in argv:
        if a.startswith("--slot="): slot = int(a.split("=", 1)[1])
        elif a.startswith("--periods="): periods = a.split("=", 1)[1].split(",")
        elif a == "--no-clone": pass
        elif a.startswith("--"): extra.append(a)
        else: variants.append(a)
    if "--no-clone" not in argv:
        clone()
    for v in variants:
        for per in periods:
            s = run(v, per, slot, extra)
            print("%-30s %5ss png=%s p50=%s p95=%s dc=%s errs=%d" % (s["stem"], s["seconds"], s["png"], s.get("p50"), s.get("p95"), s.get("draw_calls"), len(s["errors"])))
            for e in s["errors"]:
                print("      ! " + e[:220])


if __name__ == "__main__":
    main(sys.argv[1:])
