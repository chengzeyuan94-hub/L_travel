#!/usr/bin/env python3
"""MOTION GATE (reference implementation, motion-layer).

Reads a sampled PNG sequence of a FIXED-CAMERA render and decides whether the
frame is actually alive: how many mutually non-adjacent grid cells change more
than a threshold between samples.

Usage:
  motion_gate.py <dir-with-fNN.png> [--grid 12x7] [--pix 6] [--cell 0.005] [--json out.json]

Definitions (all numbers are the gate's contract):
  * pixel moved      : max(|dR|,|dG|,|dB|) >= PIX (default 6/255)
  * cell changed     : >= CELL fraction of the cell's pixels moved (default 0.5%)
  * live cells       : changed cells, then greedily thinned so that no two kept
                       cells share an edge OR a corner (8-neighbourhood)
  * report           : per frame-pair, and the min across all pairs
"""
import sys, os, json, glob
from PIL import Image
import numpy as np


def load(paths):
    return [np.asarray(Image.open(p).convert("RGB"), dtype=np.int16) for p in paths]


def cell_change(a, b, gx, gy, pix, cell_frac):
    h, w, _ = a.shape
    d = np.abs(a - b).max(axis=2)
    moved = d >= pix
    ys = np.linspace(0, h, gy + 1).astype(int)
    xs = np.linspace(0, w, gx + 1).astype(int)
    grid = np.zeros((gy, gx), dtype=bool)
    frac = np.zeros((gy, gx))
    for j in range(gy):
        for i in range(gx):
            blk = moved[ys[j]:ys[j + 1], xs[i]:xs[i + 1]]
            f = blk.mean()
            frac[j, i] = f
            grid[j, i] = f >= cell_frac
    return grid, frac, moved.mean()


def thin_non_adjacent(grid, frac):
    """Greedy: take the strongest changed cell, drop its 8-neighbours, repeat."""
    gy, gx = grid.shape
    order = sorted(
        [(frac[j, i], j, i) for j in range(gy) for i in range(gx) if grid[j, i]],
        reverse=True,
    )
    taken, blocked = [], set()
    for _, j, i in order:
        if (j, i) in blocked:
            continue
        taken.append((j, i))
        for dj in (-1, 0, 1):
            for di in (-1, 0, 1):
                blocked.add((j + dj, i + di))
    return taken


def main():
    d = sys.argv[1]
    args = sys.argv[2:]

    def opt(name, default, cast=str):
        return cast(args[args.index(name) + 1]) if name in args else default

    gx, gy = (int(v) for v in opt("--grid", "12x7").split("x"))
    pix = opt("--pix", 6, int)
    cellf = opt("--cell", 0.005, float)
    paths = sorted(glob.glob(os.path.join(d, "*.png")))
    imgs = load(paths)
    out = {"dir": d, "frames": [os.path.basename(p) for p in paths],
           "grid": [gx, gy], "pix_threshold": pix, "cell_fraction": cellf, "pairs": []}
    mins = []
    for k in range(len(imgs) - 1):
        grid, frac, moved = cell_change(imgs[k], imgs[k + 1], gx, gy, pix, cellf)
        keep = thin_non_adjacent(grid, frac)
        mins.append(len(keep))
        out["pairs"].append({
            "a": out["frames"][k], "b": out["frames"][k + 1],
            "moved_pixel_fraction": round(float(moved), 5),
            "changed_cells": int(grid.sum()),
            "live_cells_non_adjacent": len(keep),
            "cells": [[int(j), int(i), round(float(frac[j, i]), 4)] for j, i in keep],
            "max_cell_fraction": round(float(frac.max()), 4),
        })
    out["min_live_cells"] = min(mins) if mins else 0
    out["max_live_cells"] = max(mins) if mins else 0
    print(json.dumps(out, indent=1))
    if "--json" in args:
        json.dump(out, open(opt("--json", "gate.json"), "w"), indent=1)


if __name__ == "__main__":
    main()
