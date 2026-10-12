#!/usr/bin/env python3
"""Capture a clean 1920x1080 plate from the real game with Godot (tools/motion/godot/motion_capture.tscn).

    python3 tools/motion/godot/capture.py SHOT.json --out DIR [--home DIR] [--slot auto|N]
                                           [--no-audio] [--retries 1] [--timeout 1800] [--keep-raw]

Writes DIR/frame_00000.png ... (exactly duration*fps frames, clean, no overlays), DIR/audio.wav (the game's own
audio for exactly those frames, when not --no-audio) and DIR/capture.json (manifest: act camera, points of
interest, timings, command). Stdlib only.

Several captures may run at the same time: each takes a free "slot" (a lock file) and its tiny always-on-top
preview window sits at its own place on screen, so windows never cover each other (macOS does not draw a
fully covered window). The shot file format is documented in tools/motion/README.md.
"""
import argparse
import fcntl
import json
import os
import shutil
import subprocess
import sys
import time
import wave

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
GODOT = "/Applications/Godot.app/Contents/MacOS/Godot"
FFMPEG = os.path.expanduser("~/.local/bin/ffmpeg")
SCRATCH = "/private/tmp/claude-501/-Users-chengzeyuan-Developer-SilkRoad/881e8717-f317-4a7f-9cf5-81713e061c3a/scratchpad/motion"
MAX_SLOTS = 5

# the ACTS table in scripts/lshu_ui/lshu_progress.gd: what the game passes when the player enters each act
ACT_ARGS = {
    "changan": ["--view=changan", "--far", "--dusk"],
    "panti": ["--view=panti", "--morning"],
    "baghdad": ["--view=baghdad", "--lookdev=m_grass", "--cycle-auto"],  # --cycle-auto: timeline instead of click states
    "lshu": [],
    "home": [],
    "board": ["--showcase", "--seed=7", "--ai-delay=0.6"],
}
ACT_IDS = {"changan", "panti", "baghdad", "lshu"}


def take_slot(want):
    os.makedirs(os.path.join(SCRATCH, ".locks"), exist_ok=True)
    order = [want] if want is not None else list(range(MAX_SLOTS))
    waited = 0
    while True:
        for s in order:
            f = open(os.path.join(SCRATCH, ".locks", "godot_slot%d.lock" % s), "w")
            try:
                fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return s, f
            except OSError:
                f.close()
        if waited % 30 == 0:
            print("capture: all slots busy, waiting ...", flush=True)
        time.sleep(2)
        waited += 2


def trim_wav(src, dst, first_movie_frame, frames, fps):
    with wave.open(src, "rb") as w:
        rate, ch, sw = w.getframerate(), w.getnchannels(), w.getsampwidth()
        per = rate / fps
        start = int(round(first_movie_frame * per))
        count = int(round(frames * per))
        w.setpos(min(start, w.getnframes()))
        data = w.readframes(count)
    got = len(data) // (ch * sw)
    if got < count:
        data += b"\x00" * ((count - got) * ch * sw)
    with wave.open(dst, "wb") as o:
        o.setnchannels(ch)
        o.setsampwidth(sw)
        o.setframerate(rate)
        o.writeframes(data)
    return {"rate": rate, "channels": ch, "sample_width": sw, "start_sample": start, "samples": count, "padded": max(0, count - got)}


def run_once(shot_path, shot, out, home, slot, audio, timeout, extra_mc, keep_raw):
    target = shot["target"]
    raw = os.path.join(out, "_raw")
    shutil.rmtree(raw, ignore_errors=True)
    os.makedirs(raw, exist_ok=True)
    for f in os.listdir(out):
        if f.startswith("frame_") and f.endswith(".png"):
            os.remove(os.path.join(out, f))
    manifest = os.path.join(raw, "manifest.json")
    args = list(shot.get("args", ACT_ARGS.get(target, []))) + list(shot.get("args_extra", []))
    if target in ACT_IDS and not shot.get("no_act_flag", False) and not any(a.startswith("--lshu-act") for a in args):
        args.insert(0, "--lshu-act=" + target)   # the act exactly as the title screen opens it
    fps = int(shot.get("fps", 30))
    cmd = ["perl", "-e", "alarm shift; exec @ARGV", str(timeout), GODOT, "--path", PROJECT]
    if audio:
        # MJPEG .avi: Movie Maker insists on encoding a 1280x720 frame per iteration; JPEG is ~10x cheaper than PNG.
        # Only its audio track is kept (the frames come from the plate).
        cmd += ["--write-movie", os.path.join(raw, "mm.avi")]
    else:
        cmd += ["--audio-driver", "Dummy"]
    cmd += ["--fixed-fps", str(fps), "--disable-vsync", "--resolution", "320x180", "--always-on-top",
            "res://tools/motion/godot/motion_capture.tscn", "--"] + args + [
            "--mc-shot=" + os.path.abspath(shot_path), "--mc-out=" + os.path.abspath(out),
            "--mc-manifest=" + manifest, "--mc-slot=%d" % slot] + extra_mc
    env = dict(os.environ, HOME=home)
    os.makedirs(home, exist_ok=True)
    t0 = time.time()
    log_path = os.path.join(raw, "godot.log")
    with open(log_path, "w") as log:
        rc = subprocess.call(cmd, env=env, stdout=log, stderr=subprocess.STDOUT, cwd=raw)
    wall = time.time() - t0
    m = {}
    if os.path.exists(manifest):
        with open(manifest) as f:
            m = json.load(f)
    m["exit_code"] = rc
    m["wall_total_s"] = round(wall, 2)
    m["command"] = cmd[4:]
    frames = [f for f in os.listdir(out) if f.startswith("frame_") and f.endswith(".png")]
    m["frames_on_disk"] = len(frames)
    ok = rc == 0 and not m.get("error") and not m.get("stalls") and len(frames) == int(m.get("frames", -1))
    if ok and audio and os.path.exists(os.path.join(raw, "mm.avi")):
        subprocess.call([FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-i", os.path.join(raw, "mm.avi"), "-vn",
                         "-c:a", "pcm_s16le", os.path.join(raw, "mm.wav")])
    if ok and audio and os.path.exists(os.path.join(raw, "mm.wav")):
        # measured with --sync-test (README "A/V sync"): movie frame index = process frame index
        m["audio"] = trim_wav(os.path.join(raw, "mm.wav"), os.path.join(out, "audio.wav"),
                              int(m["first_process_frame"]) + int(shot.get("audio_offset_frames", 0)), int(m["frames"]), fps)
    if not ok:
        with open(log_path) as f:
            tail = f.read()[-3000:]
        m["log_tail"] = tail
    if not keep_raw and ok:
        shutil.rmtree(raw, ignore_errors=True)
    return ok, m


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("shot")
    ap.add_argument("--out", required=True)
    ap.add_argument("--home", default=None, help="HOME for Godot (default: %s/home_capture_slot<N>)" % SCRATCH)
    ap.add_argument("--slot", default="auto")
    ap.add_argument("--no-audio", action="store_true", help="no Movie Maker / WAV (a little faster)")
    ap.add_argument("--retries", type=int, default=1)
    ap.add_argument("--timeout", type=int, default=1800, help="seconds before Godot is killed")
    ap.add_argument("--keep-raw", action="store_true")
    ap.add_argument("--debug-counter", action="store_true")
    ap.add_argument("--sync-test", action="store_true")
    a = ap.parse_args()
    with open(a.shot) as f:
        shot = json.load(f)
    out = os.path.abspath(a.out)
    os.makedirs(out, exist_ok=True)
    slot, lock = take_slot(None if a.slot == "auto" else int(a.slot))
    home = a.home or os.path.join(SCRATCH, "home_capture_slot%d" % slot)
    extra = (["--mc-debug-counter"] if a.debug_counter else []) + (["--mc-sync-test"] if a.sync_test else [])
    try:
        for attempt in range(a.retries + 1):
            ok, m = run_once(a.shot, shot, out, home, slot, not a.no_audio, a.timeout, extra, a.keep_raw)
            m["attempt"] = attempt
            m["slot"] = slot
            with open(os.path.join(out, "capture.json"), "w") as f:
                json.dump(m, f, indent=2, ensure_ascii=False)
            ws = m.get("wall_s", {})
            print("capture %s: %s  frames=%s  stalls=%d  wall=%.1fs (ready %.1fs, capture %.1fs = %.0f ms/frame)" % (
                shot.get("target"), "OK" if ok else "FAILED", m.get("frames_on_disk"), len(m.get("stalls", []) or []),
                m.get("wall_total_s", 0), ws.get("boot_to_ready", 0), ws.get("capture", 0), ws.get("ms_per_clean_frame", 0)), flush=True)
            if ok:
                return 0
            print(m.get("log_tail", "")[-1500:], file=sys.stderr)
        return 1
    finally:
        lock.close()


if __name__ == "__main__":
    sys.exit(main())
