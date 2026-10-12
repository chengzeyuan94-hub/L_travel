import math
c = asset_col(KEY)
white = mat("porcelain_white", hexrgb("#F4F1EA"), rough=0.25)
blue = mat("porcelain_blue", hexrgb("#2F5DB8"), rough=0.3)
prof = [(0.17, 0), (0.2, 0.03), (0.2, 0.06), (0.3, 0.22), (0.34, 0.38), (0.3, 0.55), (0.18, 0.68), (0.13, 0.76), (0.15, 0.84), (0.19, 0.9)]
lathe("porcelain_body", c, prof, segs=10, m=white, stagger=True, cap_top=False)
lathe("porcelain_inner", c, [(0.17, 0.9), (0.12, 0.8)], segs=10, m=blue, cap_top=False)
lathe("porcelain_band_foot", c, [(0.205, 0.035), (0.215, 0.075), (0.2, 0.09)], segs=10, m=blue, cap_top=False, cap_bottom=False)
lathe("porcelain_band_neck", c, [(0.19, 0.64), (0.175, 0.69), (0.155, 0.72)], segs=10, m=blue, cap_top=False, cap_bottom=False)
lathe("porcelain_band_lip", c, [(0.155, 0.86), (0.2, 0.905), (0.18, 0.92)], segs=10, m=blue, cap_top=False, cap_bottom=False)
def rad(z):
    for (r0, z0), (r1, z1) in zip(prof, prof[1:]):
        if z0 <= z <= z1: return r0 + (r1 - r0) * (z - z0) / (z1 - z0) + 0.006
    return 0.3
for k, a0 in enumerate((-2.13, -2.13 + 2.1, -2.13 - 2.1)):
    zc = 0.38; rc = rad(zc)
    decal(f"porcelain_flower_c{k}", c, blue, (rc * math.cos(a0), rc * math.sin(a0), zc), (math.cos(a0), math.sin(a0), 0), size=(0.035, 0.035), thick=0.012)
    for p in range(5):
        b = 2 * math.pi * p / 5 + 0.3
        z = zc + 0.065 * math.sin(b); r = rad(z); a = a0 + 0.065 * math.cos(b) / r
        decal(f"porcelain_petal_{k}_{p}", c, blue, (r * math.cos(a), r * math.sin(a), z), (math.cos(a), math.sin(a), 0), size=(0.04, 0.045), thick=0.01)
    for s in (-1, 1):
        z = zc - 0.1; r = rad(z); a = a0 + s * 0.13 / r
        decal(f"porcelain_leaf_{k}_{s}", c, blue, (r * math.cos(a), r * math.sin(a), z), (math.cos(a), math.sin(a), 0), size=(0.05, 0.026), thick=0.01)
print(finish(KEY))
