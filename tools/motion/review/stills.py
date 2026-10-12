#!/usr/bin/env python3
"""Pull full-resolution stills out of a frame directory or a video, for reviews and style frames.

    python3 tools/motion/review/stills.py INPUT --at 0,1.5,7.25 [--frames] [--fps 30] [-o OUTDIR] [--jpg]

--at takes seconds (default) or frame numbers (--frames). Writes OUTDIR/still_<ss.ff>.png (default OUTDIR:
<INPUT>_stills). Stdlib + ffmpeg only. Frame-accurate for frame directories; for videos ffmpeg decodes from
the previous keyframe and picks the exact frame (select by n), so it is exact too, just slower on long files.
"""
import argparse
import glob
import os
import shutil
import subprocess
import sys

FFMPEG = os.path.expanduser("~/.local/bin/ffmpeg")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input")
    ap.add_argument("--at", required=True, help="comma list of seconds (or frames with --frames)")
    ap.add_argument("--frames", action="store_true")
    ap.add_argument("--fps", type=float, default=30.0)
    ap.add_argument("-o", "--out")
    ap.add_argument("--jpg", action="store_true", help="write JPEG (q=2) instead of PNG")
    a = ap.parse_args()
    src = os.path.abspath(a.input.rstrip("/"))
    out = a.out or src + "_stills"
    os.makedirs(out, exist_ok=True)
    ext = "jpg" if a.jpg else "png"
    for tok in a.at.split(","):
        tok = tok.strip()
        if not tok:
            continue
        n = int(tok) if a.frames else int(round(float(tok) * a.fps))
        secs = n / a.fps
        name = os.path.join(out, "still_%06.2f_f%05d.%s" % (secs, n, ext))
        if os.path.isdir(src):
            files = sorted(glob.glob(os.path.join(src, "frame_*.png"))) or sorted(glob.glob(os.path.join(src, "*.png")))
            if n >= len(files):
                print("skip %s: only %d frames" % (tok, len(files)), file=sys.stderr)
                continue
            if ext == "png":
                shutil.copyfile(files[n], name)
            else:
                subprocess.check_call([FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-i", files[n], "-q:v", "2", name])
        else:
            subprocess.check_call([FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-ss", "%.3f" % max(0.0, secs - 2.0), "-i", src,
                                   "-vf", "select='eq(n\\,%d)'" % int(round(min(secs, 2.0) * a.fps)), "-vsync", "0", "-frames:v", "1"]
                                  + (["-q:v", "2"] if ext == "jpg" else []) + [name])
        print(name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
