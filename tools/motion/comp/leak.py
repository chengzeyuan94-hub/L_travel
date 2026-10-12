#!/usr/bin/env python3
"""Procedural light leaks / lens glows on black, for a screen blend (mc.py grade --leak DIR or comp --layer DIR:screen:0.6).

    uv run -q --offline --with numpy --with pillow python tools/motion/comp/leak.py --out DIR --duration 15
        [--fps 30] [--seed 3] [--palette dusk|lantern|snow|parchment] [--size 480x270] [--intensity 1.0]
        [--flash 2.0,7.5]   # optional bright "burn" swells at these seconds (cut punctuation)

Frames are small (default 480x270, leaks are soft) and ffmpeg scales them to 1080p at blend time.
Deterministic: same seed + options -> same frames.
"""
import argparse
import os

import numpy as np
from PIL import Image

PALETTES = {
    "dusk": [(255, 140, 50), (255, 90, 60), (255, 200, 110), (200, 80, 150)],
    "lantern": [(255, 120, 30), (255, 170, 60), (255, 70, 30), (255, 220, 150)],
    "snow": [(140, 190, 255), (255, 210, 160), (190, 220, 255), (255, 240, 220)],
    "parchment": [(255, 214, 150), (240, 170, 100), (255, 236, 190), (220, 150, 110)],
}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True)
    ap.add_argument("--duration", type=float, required=True)
    ap.add_argument("--fps", type=float, default=30)
    ap.add_argument("--seed", type=int, default=3)
    ap.add_argument("--palette", default="dusk", choices=sorted(PALETTES))
    ap.add_argument("--size", default="480x270")
    ap.add_argument("--intensity", type=float, default=1.0)
    ap.add_argument("--flash", default="")
    a = ap.parse_args()
    w, h = (int(x) for x in a.size.split("x"))
    os.makedirs(a.out, exist_ok=True)
    rng = np.random.default_rng(a.seed)
    pal = np.array(PALETTES[a.palette], dtype=np.float32) / 255.0
    nb = 5
    blobs = [dict(c=pal[i % len(pal)], x0=rng.uniform(-0.2, 1.2), y0=rng.uniform(-0.1, 1.1), vx=rng.uniform(-0.05, 0.05), vy=rng.uniform(-0.02, 0.02),
                  r=rng.uniform(0.25, 0.6), ph=rng.uniform(0, 6.28), sp=rng.uniform(0.15, 0.5), edge=rng.choice([0, 1])) for i in range(nb)]
    flashes = [float(x) for x in a.flash.split(",") if x.strip()]
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    xx /= w
    yy /= h
    n = int(round(a.duration * a.fps))
    for i in range(n):
        t = i / a.fps
        img = np.zeros((h, w, 3), np.float32)
        for b in blobs:
            # leaks live near the frame edges (like light entering the gate) and breathe slowly
            x = b["x0"] + b["vx"] * t
            y = b["y0"] + b["vy"] * t
            if b["edge"]:
                x = -0.15 + 0.1 * np.sin(t * b["sp"] + b["ph"]) if b["x0"] < 0.5 else 1.15 + 0.1 * np.sin(t * b["sp"] + b["ph"])
            amp = 0.35 + 0.35 * (0.5 + 0.5 * np.sin(t * b["sp"] * 1.7 + b["ph"]))
            d2 = ((xx - x) * 1.6) ** 2 + (yy - y) ** 2
            img += b["c"][None, None, :] * (amp * np.exp(-d2 / (b["r"] ** 2)))[..., None]
        for f in flashes:
            k = np.exp(-((t - f) / 0.18) ** 2)
            if k > 1e-3:
                img += pal[0][None, None, :] * k * (0.25 + 0.6 * np.exp(-((xx - 0.85) ** 2 + (yy - 0.3) ** 2) / 0.2))[..., None]
        img = 1 - np.exp(-img * a.intensity * 1.3)  # soft tone-map, never clips hard
        Image.fromarray((np.clip(img, 0, 1) * 255 + 0.5).astype(np.uint8)).save(os.path.join(a.out, "frame_%05d.png" % i))
    print("%d frames -> %s" % (n, a.out))


if __name__ == "__main__":
    main()
