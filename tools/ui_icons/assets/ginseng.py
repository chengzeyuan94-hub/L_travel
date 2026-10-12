import math
c = asset_col(KEY)
root = mat("ginseng_root", hexrgb("#E6CFA3"), rough=0.7)
green = mat("leaf_green", hexrgb("#5DA548"), rough=0.5)
berry = mat("berry_red", hexrgb("#D22B2B"), rough=0.3)
body = sweep("gin_body", c, [(0, 0, 0.18), (0, 0, 0.3), (0.01, 0, 0.45), (0, 0, 0.58)], [0.07, 0.12, 0.12, 0.07], segs=8, m=root)
wobble(body, 0.012, seed=2, keep_bottom=False)
for k in range(5):
    a = 2 * math.pi * k / 5 + 0.3; sp = 0.2 + 0.04 * (k % 2)
    pts = [(0.05 * math.cos(a), 0.05 * math.sin(a), 0.26), (sp * 0.6 * math.cos(a), sp * 0.6 * math.sin(a), 0.14), (sp * math.cos(a), sp * math.sin(a), 0.05), (sp * 1.2 * math.cos(a), sp * 1.2 * math.sin(a), 0.0)]
    sweep(f"gin_leg_{k}", c, pts, [0.055, 0.042, 0.03, 0.014], segs=6, m=root)
cyl("gin_stem", c, r=0.018, h=0.3, segs=6, m=green, loc=(0, 0, 0.58))
for k in range(5):
    a = 2 * math.pi * k / 5
    ico(f"gin_leaf_{k}", c, radius=0.13, subdiv=1, m=green, loc=(0.14 * math.cos(a), 0.14 * math.sin(a), 0.84), scale=(1.2, 0.55, 0.12), rot=(0, -0.35, a))
for k in range(7):
    a = 2 * math.pi * k / 7
    ico(f"gin_berry_{k}", c, radius=0.03, subdiv=1, m=berry, loc=(0.035 * math.cos(a), 0.035 * math.sin(a), 0.93 + 0.02 * (k % 2)))
ico("gin_berry_top", c, radius=0.032, subdiv=1, m=berry, loc=(0, 0, 0.98))
print(finish(KEY))
