#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""长安旅人 · 日暮光影探针跑批器（导演探针，Codex 文件零写入）。

用法：python3 tools/traveler/lookdev_changan/changan_lookdev.py [--slot=N] <variant> [...]
  1. 从 scripts/traveler/atlas_viewer.gd 克隆 lookdev_viewer.gd，只在 _ready 里"截图之前"插一行调用 changan_overlay.gd；
     生成 changan_probe.tscn（与 traveler_main.tscn 相同，只换脚本）。机位、世界、数据文件全部照旧。
  2. 用 capture_traveler.gd 渲 1920×1080：--view=changan --dusk --far --lookdev=<variant>。
  3. --slot=N 把窗口缩小并挪到屏幕不同位置（并行跑时互不遮挡，macOS 上被完全挡住的窗口会停止绘制）。
输出：docs/reports/traveler-changan-dusk-20260923/<variant>.png / .json / .log
"""
import json, os, re, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, os.pardir, os.pardir, os.pardir))
GODOT = os.environ.get("GODOT_BIN", "/Applications/Godot.app/Contents/MacOS/Godot")
VIEWER = os.path.join(ROOT, "scripts", "traveler", "atlas_viewer.gd")
OUT_DIR = os.path.join(ROOT, "docs", "reports", "traveler-changan-dusk-20260923")
SCENE_RES = "res://tools/traveler/lookdev_changan/changan_probe.tscn"


def clone():
    code = open(VIEWER, encoding="utf-8").read()
    needle = "\tif not capture_path.is_empty():\n\t\tui.visible=capture_hud\n"
    if code.count(needle) != 1:
        raise SystemExit("atlas_viewer.gd 里找不到唯一的截图入口，克隆点需要重新适配")
    hook = "\tload(\"res://tools/traveler/lookdev_changan/changan_overlay.gd\").new().apply(self)\n"
    code = code.replace(needle, hook + needle)
    banner = ("# 自动生成，不要手改。由 tools/traveler/lookdev_changan/changan_lookdev.py 从\n"
              "# scripts/traveler/atlas_viewer.gd 克隆，只在截图入口前挂上 changan_overlay.gd。\n")
    open(os.path.join(HERE, "lookdev_viewer.gd"), "w", encoding="utf-8").write(banner + code)
    tscn = open(os.path.join(ROOT, "scenes", "traveler", "traveler_main.tscn"), encoding="utf-8").read()
    tscn = tscn.replace('path="res://scripts/traveler/atlas_viewer.gd"', 'path="res://tools/traveler/lookdev_changan/lookdev_viewer.gd"')
    if "lookdev_viewer.gd" not in tscn:
        raise SystemExit("traveler_main.tscn 结构变了")
    open(os.path.join(HERE, "changan_probe.tscn"), "w", encoding="utf-8").write(tscn)


def run(variant, slot, extra):
    os.makedirs(OUT_DIR, exist_ok=True)
    png = os.path.join(OUT_DIR, variant + ".png")
    for p in (png, png[:-4] + ".json"):
        if os.path.exists(p):
            os.remove(p)
    cmd = [GODOT, "--path", ROOT, "--script", "res://tools/traveler/capture_traveler.gd", "--",
           "--capture-scene=" + SCENE_RES, "--view=changan", "--dusk", "--far",
           "--capture=" + png, "--lookdev=" + variant, "--park=%d" % slot] + extra
    t0 = time.time()
    pr = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=240)
    log = (pr.stdout or "") + (pr.stderr or "")
    open(os.path.join(OUT_DIR, variant + ".log"), "w", encoding="utf-8").write(" ".join(cmd) + "\n\n" + log)
    s = {"variant": variant, "seconds": round(time.time() - t0, 1), "png": os.path.exists(png)}
    j = png[:-4] + ".json"
    if os.path.exists(j):
        d = json.load(open(j))
        s["p50"] = d.get("frame_ms", {}).get("p50")
        s["p95"] = d.get("frame_ms", {}).get("p95")
        s["draw_calls"] = d.get("draw_calls")
    m = re.search(r"CHANGAN_OVERLAY (\{.*\})", log)
    if m:
        try:
            s["overlay"] = json.loads(m.group(1))
        except ValueError:
            pass
    s["errors"] = [ln for ln in log.splitlines() if "SCRIPT ERROR" in ln or "SHADER ERROR" in ln][:8]
    return s


def main(argv):
    slot = 0
    extra = []
    variants = []
    for a in argv:
        if a.startswith("--slot="):
            slot = int(a.split("=", 1)[1])
        elif a == "--no-clone":
            pass
        elif a.startswith("--"):
            extra.append(a)
        else:
            variants.append(a)
    if "--no-clone" not in argv:
        clone()
    for v in variants:
        s = run(v, slot, extra)
        sun = (s.get("overlay") or {}).get("sun", {})
        print("%-26s %5ss png=%s p50=%s p95=%s dc=%s sun_px=%s errs=%d" % (
            v, s["seconds"], s["png"], s.get("p50"), s.get("p95"), s.get("draw_calls"),
            [round(x) for x in sun.get("pixel", [])] if sun else None, len(s["errors"])))
        for e in s["errors"]:
            print("      ! " + e[:200])


if __name__ == "__main__":
    main(sys.argv[1:])
