import math
c = asset_col(KEY)
paper = mat("tea_paper", hexrgb("#EFE3C8"), rough=0.85)
twine = mat("twine", hexrgb("#8A5A3B"), rough=0.9)
leaf = mat("leaf_green", hexrgb("#5DA548"), rough=0.5)
seal = mat("seal_red", hexrgb("#C23B2E"), rough=0.6)
cake = lathe("tea_cake", c, [(0.3, 0), (0.4, 0.05), (0.43, 0.15), (0.38, 0.26), (0.24, 0.33), (0.0, 0.355)], segs=12, m=paper, stagger=True)
wobble(cake, 0.012, seed=3)
for i, rz in enumerate((0.0, math.pi / 2)):
    t = torus(f"tea_twine_{i}", c, R=0.42, r=0.016, segs=16, rsegs=4, m=twine, loc=(0, 0, 0.14), rot=(math.pi / 2, 0, rz))
    t.scale = (1.02, 0.52, 1.0) if i == 0 else (1.02, 0.52, 1.0)
ico("tea_knot", c, radius=0.045, subdiv=1, m=twine, loc=(0, 0, 0.37))
for i, (rx, rz) in enumerate(((-0.6, 0.5), (0.55, 2.4))):
    ico(f"tea_leaf_{i}", c, radius=0.16, subdiv=1, m=leaf, loc=(0.06 * math.cos(rz), 0.06 * math.sin(rz), 0.46), scale=(0.45, 1.0, 0.15), rot=(rx, 0, rz))
a = -2.0; r = 0.405
box("tea_seal", c, size=(0.1, 0.012, 0.1), bevel=0.01, m=seal, loc=(r * math.cos(a), r * math.sin(a), 0.2), rot=(0.25, 0, a + math.pi / 2))
print(finish(KEY))
