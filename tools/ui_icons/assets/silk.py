import math
c = asset_col(KEY)
silk = mat("silk_red", hexrgb("#D63A57"), rough=0.3)
silk_dk = mat("silk_red_dark", hexrgb("#A8243F"), rough=0.3)
gold = mat("gold", hexrgb("#D9A441"), rough=0.35, metal=0.65)
L = 0.6; R = 0.2
lathe("silk_roll", c, [(R, 0), (R + 0.01, 0.02), (R + 0.01, L - 0.02), (R, L)], segs=12, m=silk, stagger=True, loc=(-L / 2, 0, R + 0.01), rot=(0, math.pi / 2, 0))
for j, rr in enumerate((0.16, 0.11, 0.06)):
    torus(f"silk_end_ring_{j}", c, R=rr, r=0.012, segs=12, rsegs=4, m=silk_dk, loc=(-L / 2 - 0.004, 0, R + 0.01), rot=(0, math.pi / 2, 0))
# 布头：从卷底前沿垂下来，平铺到地面向前
box("silk_drape_a", c, size=(0.36, 0.03, 0.2), bevel=0.012, m=silk, loc=(0.08, -R - 0.005, 0.12), rot=(0.12, 0, 0))
box("silk_drape_b", c, size=(0.36, 0.26, 0.03), bevel=0.012, m=silk, loc=(0.08, -R - 0.12, 0.015), rot=(0, 0, 0))
for i, (x, y) in enumerate(((0.0, -0.3), (0.16, -0.26))):
    decal(f"silk_cloud_b{i}", c, gold, (x, y, 0.033), (0, 0, 1), size=(0.05, 0.03), thick=0.006)
torus("silk_band", c, R=R + 0.015, r=0.02, segs=12, rsegs=4, m=gold, loc=(0.05, 0, R + 0.01), rot=(0, math.pi / 2, 0))
for s in (-1, 1):
    t = torus(f"silk_bow_{s}", c, R=0.07, r=0.022, segs=10, rsegs=4, m=gold, loc=(0.05 + 0.075 * s, -0.1, R * 2 - 0.01), rot=(0.5, 0.25 * s, 0))
    t.scale = (1.0, 0.6, 1.0)
    box(f"silk_tail_{s}", c, size=(0.05, 0.02, 0.15), bevel=0.008, m=gold, loc=(0.05 + 0.05 * s, -0.19, 0.3), rot=(0.5, 0.35 * s, 0))
ico("silk_bow_knot", c, radius=0.035, subdiv=1, m=gold, loc=(0.05, -0.13, R * 2 - 0.01))
for i, (x, a) in enumerate(((-0.2, -2.0), (0.2, -1.2), (-0.05, -2.6))):
    decal(f"silk_cloud_{i}", c, gold, (x, (R + 0.012) * math.cos(a), R + 0.01 + (R + 0.012) * math.sin(a) * -1), (0, math.cos(a), -math.sin(a)), size=(0.05, 0.03), thick=0.007)
print(finish(KEY))
