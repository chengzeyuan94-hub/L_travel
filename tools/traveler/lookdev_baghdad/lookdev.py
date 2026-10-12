#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""巴格达晚霞质感探针的跑批器。

用法：python3 tools/traveler/lookdev_baghdad/lookdev.py v1_dusk v2_dusk_rim ...
  1. 从 Codex **当前**的 baghdad_viewer.gd 克隆一份 lookdev_viewer.gd：
     - 数据路径换成 data/traveler/baghdad_scene.lookdev.json（Carlos 副本的快照）
     - 在 ready_for_capture=true 之前插入一行：调用 lookdev_overlay.gd
     Codex 的文件零写入。
  2. 对每个 variant 用 capture_traveler.gd 实机渲一张 1920×1080，
     输出到 docs/reports/traveler-baghdad-001/lookdev-sunset-20260923/<variant>.png + .json + .log
  3. 打一张摘要表（p50/p95/draw calls/太阳落点）。
"""
import json
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, os.pardir, os.pardir, os.pardir))
GODOT = os.environ.get("GODOT_BIN", "/Applications/Godot.app/Contents/MacOS/Godot")
VIEWER = os.path.join(ROOT, "scripts", "traveler", "baghdad", "baghdad_viewer.gd")
LIVE_DATA = "res://data/traveler/baghdad_scene.json"
LOOKDEV_DATA = "res://data/traveler/baghdad_scene.lookdev.json"
OUT_DIR = os.path.join(ROOT, "docs", "reports", "traveler-baghdad-001", "lookdev-sunset-20260923")
SCENE_RES = "res://tools/traveler/lookdev_baghdad/lookdev_baghdad.tscn"


def clone():
    with open(VIEWER, "r", encoding="utf-8") as f:
        code = f.read()
    if LIVE_DATA not in code:
        raise SystemExit("viewer 里找不到 %s，Codex 可能改了读取方式" % LIVE_DATA)
    code = code.replace(LIVE_DATA, LOOKDEV_DATA)
    needle = "\tready_for_capture=true\n"
    if code.count(needle) != 1:
        raise SystemExit("viewer 里 ready_for_capture=true 不唯一/不存在，克隆点需要重新适配")
    hook = "\tload(\"res://tools/traveler/lookdev_baghdad/lookdev_overlay.gd\").new().apply(self)\n"
    code = code.replace(needle, hook + needle)
    banner = ("# 自动生成，不要手改。由 tools/traveler/lookdev_baghdad/lookdev.py 每次跑批前\n"
              "# 从 scripts/traveler/baghdad/baghdad_viewer.gd 克隆：数据路径换成 lookdev 快照，\n"
              "# 并在 ready_for_capture 之前挂上 lookdev_overlay.gd。Codex 的文件零写入。\n")
    with open(os.path.join(HERE, "lookdev_viewer.gd"), "w", encoding="utf-8") as f:
        f.write(banner + code)
    with open(os.path.join(HERE, "lookdev_baghdad.tscn"), "w", encoding="utf-8") as f:
        f.write('[gd_scene load_steps=2 format=3]\n\n'
                '[ext_resource type="Script" path="res://tools/traveler/lookdev_baghdad/lookdev_viewer.gd" id="1"]\n\n'
                '[node name="LookdevRoot" type="Node3D"]\n'
                'script = ExtResource("1")\n')


def run(variant, flags):
    os.makedirs(OUT_DIR, exist_ok=True)
    out_png = os.path.join(OUT_DIR, variant + ".png")
    for p in (out_png, out_png[:-4] + ".json"):
        if os.path.exists(p):
            os.remove(p)
    cmd = [GODOT, "--path", ROOT, "--script", "res://tools/traveler/capture_traveler.gd", "--",
           "--capture-scene=" + SCENE_RES, "--view=baghdad", "--capture=" + out_png,
           "--lookdev=" + variant] + list(flags)
    t0 = time.time()
    pr = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=300)
    log = (pr.stdout or "") + (pr.stderr or "")
    with open(os.path.join(OUT_DIR, variant + ".log"), "w", encoding="utf-8") as f:
        f.write(" ".join(cmd) + "\n\n" + log)
    summary = {"variant": variant, "seconds": round(time.time() - t0, 1), "png": os.path.exists(out_png)}
    m = re.search(r"LOOKDEV_OVERLAY (\{.*\})", log)
    if m:
        try:
            summary["overlay"] = json.loads(m.group(1))
        except ValueError:
            summary["overlay_raw"] = m.group(1)[:300]
    m = re.search(r"BAGHDAD_CAPTURE (\{.*\})", log)
    if m:
        try:
            cap = json.loads(m.group(1))
            summary["p50"] = cap.get("p50")
            summary["p95"] = cap.get("p95")
            summary["draw_calls"] = cap.get("draw_calls")
        except ValueError:
            pass
    errs = [ln for ln in log.splitlines() if "ERROR" in ln or "SCRIPT ERROR" in ln or "error" in ln.lower() and "shader" in ln.lower()]
    summary["errors"] = errs[:8]
    return summary


def run_video(variant, flags, seconds=8.0, fps=30):
    """--fixed-fps 录逐帧 PNG，再用 ffmpeg 合成 mp4（H.264, yuv420p, crf 18）。"""
    os.makedirs(OUT_DIR, exist_ok=True)
    frames_dir = os.path.join(OUT_DIR, "_frames", variant)
    if os.path.isdir(frames_dir):
        for f in os.listdir(frames_dir):
            os.remove(os.path.join(frames_dir, f))
    n = int(round(seconds * fps))
    cmd = [GODOT, "--path", ROOT, "--fixed-fps", str(fps), "--script", "res://tools/traveler/capture_traveler.gd", "--",
           "--capture-scene=" + SCENE_RES, "--view=baghdad", "--lookdev=" + variant,
           "--record-dir=" + frames_dir, "--record-frames=%d" % n] + list(flags)
    t0 = time.time()
    pr = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=1800)
    log = (pr.stdout or "") + (pr.stderr or "")
    with open(os.path.join(OUT_DIR, variant + ".video.log"), "w", encoding="utf-8") as f:
        f.write(" ".join(cmd) + "\n\n" + log)
    got = len([f for f in os.listdir(frames_dir) if f.endswith(".png")]) if os.path.isdir(frames_dir) else 0
    mp4 = os.path.join(OUT_DIR, variant + ".mp4")
    ff = shutil.which("ffmpeg") or os.path.expanduser("~/.local/bin/ffmpeg")
    if got:
        subprocess.run([ff, "-y", "-loglevel", "error", "-framerate", str(fps), "-i", os.path.join(frames_dir, "f_%04d.png"),
                        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18", "-movflags", "+faststart", mp4],
                       check=False)
    m = re.search(r'LOOKDEV_RECORD_DONE (\{.*\})', log)
    if m:
        try:
            rep = json.loads(m.group(1)).get("repeated_frames", 0)
            if rep:
                print("      ! %d 帧与上一帧完全相同（窗口可能被遮挡、停止绘制）" % rep)
        except ValueError:
            pass
    errs = [ln for ln in log.splitlines() if "SCRIPT ERROR" in ln or "SHADER ERROR" in ln]
    print("%-24s video %5.1fs frames=%d/%d mp4=%s errs=%d rc=%s" % (variant, time.time() - t0, got, n, os.path.exists(mp4), len(errs), pr.returncode))
    if got < n:
        print("      ! 录制不完整：Godot 提前退出（rc=%s）。日志尾：%s" % (pr.returncode, " | ".join(log.strip().splitlines()[-3:])[:400]))
    for e in errs[:6]:
        print("      ! " + e[:200])
    return mp4


def main(argv):
    # Codex 2026-09-23 00:35 起：viewer 默认挂 storm look（scripts/traveler/baghdad/baghdad_storm_look.gd），
    # 只有带 --clear-weather 才走原来的 cinematic-sunset 光照。探针要的是晚霞线，所以默认带上它；
    # 想看 Codex 的风暴线就传 --storm。
    flags = ["--cinematic-sunset", "--clear-weather"]
    if "--storm" in argv:
        flags = ["--cinematic-sunset"]
        argv = [a for a in argv if a != "--storm"]
    variants = [a for a in argv if not a.startswith("--")]
    for a in argv:
        if a.startswith("--") and a != "--no-clone" and a not in flags:
            flags = [a] if a in ("--studio",) else flags + [a]
    if "--no-clone" not in argv:
        clone()
    if "--video" in argv:
        secs = 8.0
        for a in argv:
            if a.startswith("--seconds="):
                secs = float(a.split("=", 1)[1])
        vflags = [f for f in flags if f not in ("--video",) and not f.startswith("--seconds=")]
        for v in variants:
            run_video(v, vflags, secs)
        return
    rows = []
    for v in variants:
        s = run(v, flags)
        rows.append(s)
        sun = (s.get("overlay") or {}).get("sun") or {}
        print("%-22s %5ss png=%s p50=%s p95=%s dc=%s sun_px=%s el=%s errs=%d" % (
            v, s["seconds"], s["png"], s.get("p50"), s.get("p95"), s.get("draw_calls"),
            [round(x) for x in sun.get("pixel", [0, 0])], round(sun.get("elevation_deg", 0), 1) if sun else None,
            len(s["errors"])))
        for e in s["errors"]:
            print("      ! " + e[:200])
    with open(os.path.join(OUT_DIR, "summary.json"), "w", encoding="utf-8") as f:
        json.dump(rows, f, ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main(sys.argv[1:])
