#!/usr/bin/env python3
"""Contact sheet: one frame per second (or --every S) tiled with timecodes, for reviewing a cut at a glance.

    uv run -q --offline --with pillow python tools/motion/review/contact_sheet.py INPUT [-o sheet.jpg]
        [--every 1.0] [--offset 0] [--cols 5] [--width 384] [--fps 30] [--title TEXT]

INPUT is a frame directory (frame_00000.png ... or any sorted *.png / *.jpg) or a video file (mp4 / mov / ogv).
Each tile is labelled with its timecode (s:ff at --fps) and frame number. Default output: <INPUT>_sheet.jpg.
"""
import argparse
import glob
import os
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFont

FFMPEG = os.path.expanduser("~/.local/bin/ffmpeg")
FONT_CANDIDATES = [
    "/System/Library/AssetsV2/com_apple_MobileAsset_Font8/86ba2c91f017a3749571a82f2c6d890ac7ffb2fb.asset/AssetData/PingFang.ttc",
    "/Library/Fonts/Arial Unicode.ttf",
    "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
]


def font(size):
    for p in FONT_CANDIDATES + glob.glob("/System/Library/AssetsV2/com_apple_MobileAsset_Font*/*/AssetData/PingFang.ttc"):
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except OSError:
                pass
    return ImageFont.load_default()


def frames_from_dir(d):
    files = sorted(glob.glob(os.path.join(d, "frame_*.png")))
    if not files:
        files = sorted(glob.glob(os.path.join(d, "*.png")) + glob.glob(os.path.join(d, "*.jpg")))
    return files


def probe_fps(path):
    try:
        out = subprocess.check_output([FFMPEG, "-hide_banner", "-i", path], stderr=subprocess.STDOUT).decode("utf8", "replace")
    except subprocess.CalledProcessError as e:
        out = e.output.decode("utf8", "replace")
    import re
    m = re.search(r"([\d.]+) fps", out)
    return float(m.group(1)) if m else None


def frames_from_video(path, every, fps, offset, tmp):
    # select every N-th frame exactly (no resampling), N = every * fps
    n = max(1, int(round(every * fps)))
    first = int(round(offset * fps))
    subprocess.check_call([FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-i", path, "-vf",
                           "select='gte(n\\,%d)*not(mod(n-%d\\,%d))'" % (first, first, n), "-vsync", "0",
                           os.path.join(tmp, "s_%05d.png")])
    files = sorted(glob.glob(os.path.join(tmp, "s_*.png")))
    return [(first + i * n, f) for i, f in enumerate(files)]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input")
    ap.add_argument("-o", "--out")
    ap.add_argument("--every", type=float, default=1.0, help="seconds between tiles (default 1)")
    ap.add_argument("--offset", type=float, default=0.0, help="first tile time in seconds")
    ap.add_argument("--cols", type=int, default=5)
    ap.add_argument("--width", type=int, default=384, help="tile width in px")
    ap.add_argument("--fps", type=float, default=None, help="frame rate (default: probed for videos, 30 for frame dirs)")
    ap.add_argument("--title", default=None)
    a = ap.parse_args()
    src = os.path.abspath(a.input.rstrip("/"))
    out = a.out or src + "_sheet.jpg"
    tmp = tempfile.mkdtemp(prefix="sheet_")
    if os.path.isdir(src):
        fps = a.fps or 30.0
        files = frames_from_dir(src)
        n = max(1, int(round(a.every * fps)))
        first = int(round(a.offset * fps))
        picks = [(i, files[i]) for i in range(first, len(files), n)]
        total = len(files)
    else:
        fps = a.fps or probe_fps(src) or 30.0
        picks = frames_from_video(src, a.every, fps, a.offset, tmp)
        total = None
    if not picks:
        print("no frames found in", src, file=sys.stderr)
        return 1
    im0 = Image.open(picks[0][1])
    tw = a.width
    th = int(round(tw * im0.height / im0.width))
    cols = min(a.cols, len(picks))
    rows = (len(picks) + cols - 1) // cols
    pad, head, lab = 6, 44, 22
    sheet = Image.new("RGB", (cols * (tw + pad) + pad, head + rows * (th + lab + pad) + pad), (24, 21, 19))
    d = ImageDraw.Draw(sheet)
    f_title, f_lab = font(22), font(15)
    title = a.title or os.path.basename(src)
    info = "%s   %d tiles, every %.2fs @ %.3g fps%s" % (title, len(picks), a.every, fps, ("   %d frames = %.2fs" % (total, total / fps)) if total else "")
    d.text((pad + 4, 12), info, fill=(240, 226, 200), font=f_title)
    for k, (fi, path) in enumerate(picks):
        r, c = divmod(k, cols)
        x = pad + c * (tw + pad)
        y = head + r * (th + lab + pad)
        im = Image.open(path).convert("RGB").resize((tw, th), Image.LANCZOS)
        sheet.paste(im, (x, y))
        secs = fi / fps
        tc = "%02d:%02d:%02d" % (int(secs // 60), int(secs % 60), int(round((secs - int(secs)) * fps)) % int(round(fps)))
        d.text((x + 2, y + th + 3), "%s   #%d" % (tc, fi), fill=(214, 196, 160), font=f_lab)
    sheet.save(out, quality=90)
    print(out, sheet.size)
    return 0


if __name__ == "__main__":
    sys.exit(main())
