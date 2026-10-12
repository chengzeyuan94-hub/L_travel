import math
c = asset_col(KEY)
glass = mat("glass_teal", hexrgb("#27B3C9"), rough=0.12)
glass_dk = mat("glass_teal_dark", hexrgb("#13839A"), rough=0.12)
glass_lt = mat("glass_teal_light", hexrgb("#7FDCE3"), rough=0.12)
prof = [(0.15, 0), (0.2, 0.02), (0.3, 0.14), (0.34, 0.3), (0.3, 0.45), (0.17, 0.57), (0.1, 0.64), (0.09, 0.78), (0.12, 0.84), (0.15, 0.87)]
lathe("glass_body", c, prof, segs=10, m=glass, stagger=True, cap_top=False)
lathe("glass_mouth", c, [(0.13, 0.87), (0.08, 0.8)], segs=10, m=glass_dk, cap_top=False)
lathe("glass_foot", c, [(0.19, 0.0), (0.21, 0.02), (0.19, 0.045)], segs=10, m=glass_dk, cap_top=False, cap_bottom=True)
torus("glass_neck_ring", c, R=0.1, r=0.02, segs=10, rsegs=5, m=glass_lt, loc=(0, 0, 0.64))
def rad(z):
    for (r0, z0), (r1, z1) in zip(prof, prof[1:]):
        if z0 <= z <= z1: return r0 + (r1 - r0) * (z - z0) / (z1 - z0) + 0.012
    return 0.3
# 正面一个大涡纹 + 背面一个：阿基米德螺线
for k, a0 in enumerate((-2.13, -2.13 + math.pi)):
    pts = []
    for i in range(34):
        t = i / 33 * 2.4 * math.pi
        rr = 0.015 + 0.03 * t
        pts.append((rr * math.cos(t) - 0.04, 0.3 + rr * math.sin(t) * 0.9))
    pts.append((0.2, 0.2)); pts.append((0.26, 0.2))
    surface_path(f"glass_swirl_{k}", c, glass_lt, pts, a0, rad, bead=0.024)
print(finish(KEY))
