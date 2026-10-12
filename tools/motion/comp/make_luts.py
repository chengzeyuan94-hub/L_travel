#!/usr/bin/env python3
"""Built-in 3D LUT looks for the motion films (display-referred sRGB in, sRGB out; .cube, 33^3).

    uv run -q --offline --with numpy python tools/motion/comp/make_luts.py [--out tools/motion/comp/luts] [--preview FRAME.png]

Looks (all start from the game's own palette — warm dusk gold, lantern orange, snow blue, parchment cream):
  lshu_dusk       golden highlights, violet-plum shadows, gentle S-curve, oranges richer   (长安 dusk, 巴格达 dusk)
  lshu_night      moonlit blue shadows, warm highlights kept for fire / lanterns, darker   (盘橐 night, rain)
  lshu_morning    clean cool-cyan shadows, soft warm highlights, airy                        (盘橐 morning, snow)
  lshu_parchment  storybook: lifted cream blacks, sepia split, lower saturation             (postcards, travel book)
  lshu_bleach     silver-retention punch: contrast up, saturation down                        (dramatic beats, titles)
--preview writes <FRAME>_luts.jpg with the frame through every look (needs ffmpeg).
"""
import argparse
import os
import subprocess

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
N = 33

LOOKS = {
    # contrast: S-curve strength around pivot; lift/gamma/gain: per channel; split: (shadow rgb, highlight rgb, amount)
    "lshu_dusk": dict(contrast=0.22, pivot=0.42, lift=(0.012, 0.0, 0.025), gamma=(0.97, 1.0, 1.03), gain=(1.03, 0.995, 0.95),
                      split=((0.30, 0.10, 0.45), (1.0, 0.72, 0.38), 0.10), sat=1.08, warm_sat=1.12),
    "lshu_night": dict(contrast=0.18, pivot=0.35, lift=(0.0, 0.01, 0.035), gamma=(1.06, 1.02, 0.95), gain=(0.95, 0.97, 1.02),
                       split=((0.10, 0.22, 0.55), (1.0, 0.70, 0.40), 0.14), sat=0.92, warm_sat=1.15, exposure=0.92),
    "lshu_morning": dict(contrast=0.10, pivot=0.5, lift=(0.0, 0.012, 0.022), gamma=(1.0, 0.99, 0.98), gain=(1.02, 1.01, 0.99),
                         split=((0.35, 0.62, 0.80), (1.0, 0.90, 0.72), 0.08), sat=1.02, warm_sat=1.0, exposure=1.03),
    "lshu_parchment": dict(contrast=0.08, pivot=0.5, lift=(0.075, 0.06, 0.035), gamma=(0.98, 1.0, 1.06), gain=(0.99, 0.965, 0.88),
                           split=((0.45, 0.30, 0.18), (1.0, 0.93, 0.78), 0.16), sat=0.72, warm_sat=1.0),
    "lshu_bleach": dict(contrast=0.38, pivot=0.45, lift=(0.0, 0.0, 0.0), gamma=(1.0, 1.0, 1.0), gain=(1.0, 1.0, 1.0),
                        split=((0.2, 0.25, 0.3), (1.0, 0.95, 0.88), 0.05), sat=0.62, warm_sat=1.0),
}


def luma(c):
    return c[..., 0] * 0.2126 + c[..., 1] * 0.7152 + c[..., 2] * 0.0722


def apply_look(c, p):
    c = c * p.get("exposure", 1.0)
    lift, gamma, gain = np.array(p["lift"]), np.array(p["gamma"]), np.array(p["gain"])
    c = np.clip(c * gain + lift * (1 - c), 0, 1) ** gamma
    # S-curve (smooth, keeps 0 and 1 fixed)
    k, piv = p["contrast"], p["pivot"]
    x = c
    s = np.where(x < piv, piv * (x / piv) ** (1 + k), 1 - (1 - piv) * ((1 - x) / (1 - piv)) ** (1 + k))
    c = s
    y = luma(c)[..., None]
    sh, hi, amt = p["split"]
    ws = (1 - y) ** 2
    wh = y ** 2
    c = c + amt * (ws * (np.array(sh) - 0.5) + wh * (np.array(hi) - 0.5)) * 0.8
    # saturation, with a separate push for warm hues (oranges / golds: r > g > b)
    y = luma(c)[..., None]
    warm = np.clip((c[..., 0:1] - c[..., 2:3]) * 2.0, 0, 1) * np.clip(1 - np.abs(c[..., 1:2] - (c[..., 0:1] + c[..., 2:3]) / 2) * 2, 0, 1)
    sat = p["sat"] * (1 + (p["warm_sat"] - 1) * warm)
    c = y + (c - y) * sat
    return np.clip(c, 0, 1)


def write_cube(path, name, p):
    g = np.linspace(0, 1, N)
    b, gg, r = np.meshgrid(g, g, g, indexing="ij")          # r fastest in the file
    c = np.stack([r, gg, b], axis=-1).reshape(-1, 3)
    out = apply_look(c, p)
    with open(path, "w") as f:
        f.write('TITLE "%s"\nLUT_3D_SIZE %d\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n' % (name, N))
        np.savetxt(f, out, fmt="%.6f")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=os.path.join(HERE, "luts"))
    ap.add_argument("--preview")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    for name, p in LOOKS.items():
        write_cube(os.path.join(a.out, name + ".cube"), name, p)
        print(os.path.join(a.out, name + ".cube"))
    if a.preview:
        ff = os.path.expanduser("~/.local/bin/ffmpeg")
        names = ["none"] + list(LOOKS)
        chains, labels = ["[0:v]scale=640:360,split=%d%s" % (len(names), "".join("[s%d]" % i for i in range(len(names))))], []
        for i, n in enumerate(names):
            f = "null" if n == "none" else "lut3d=file='%s':interp=tetrahedral" % os.path.join(a.out, n + ".cube")
            chains.append("[s%d]%s,drawtext=fontfile='/Library/Fonts/Arial Unicode.ttf':text='%s':x=12:y=12:fontsize=26:fontcolor=white:borderw=3:bordercolor=black[t%d]" % (i, f, n, i))
            labels.append("[t%d]" % i)
        chains.append("%sxstack=inputs=%d:layout=0_0|w0_0|w0+w1_0|0_h0|w0_h0|w0+w1_h0[o]" % ("".join(labels), len(names)))
        out = os.path.splitext(a.preview)[0] + "_luts.jpg"
        subprocess.check_call([ff, "-hide_banner", "-loglevel", "error", "-y", "-i", a.preview, "-filter_complex", ";".join(chains), "-map", "[o]", "-frames:v", "1", out])
        print(out)


if __name__ == "__main__":
    main()
