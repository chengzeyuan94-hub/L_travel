import math
c = asset_col(KEY)
ivory = mat("ivory", hexrgb("#F1E6CC"), rough=0.35)
wood = mat("stand_dark", hexrgb("#5E3A28"), rough=0.6)
gold = mat("gold", hexrgb("#D9A441"), rough=0.35, metal=0.65)
def tz(t): return 0.34 + 0.3 * t ** 2.4
def tr(t): return 0.12 * (1 - t) ** 0.75 + 0.008
pts = []; rad = []
for i in range(12):
    t = i / 11; pts.append((-0.42 + 0.86 * t, 0, tz(t))); rad.append(tr(t))
sweep("ivory_tusk", c, pts, rad, segs=9, m=ivory)
for i, t in enumerate((0.08, 0.14)):
    torus(f"ivory_band_{i}", c, R=tr(t) + 0.004, r=0.013, segs=10, rsegs=4, m=gold, loc=(-0.42 + 0.86 * t, 0, tz(t)), rot=(0, math.pi / 2, 0))
box("ivory_base", c, size=(0.66, 0.24, 0.06), bevel=0.02, m=wood, loc=(0, 0, 0.03))
for t in (0.22, 0.62):
    x = -0.42 + 0.86 * t; top = tz(t) - tr(t) + 0.01
    box(f"ivory_post_{t}", c, size=(0.07, 0.16, top - 0.06), bevel=0.015, m=wood, loc=(x, 0, 0.06 + (top - 0.06) / 2))
    box(f"ivory_cradle_{t}", c, size=(0.12, 0.2, 0.045), bevel=0.018, m=wood, loc=(x, 0, top))
print(finish(KEY))
