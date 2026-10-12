import math
c = asset_col(KEY)
coat = mat("horse_coat", hexrgb("#B46A3C"), rough=0.6)
dark = mat("horse_mane", hexrgb("#5A3322"), rough=0.7)
muzzle = mat("horse_muzzle", hexrgb("#E7C3A1"), rough=0.6)
red = mat("saddle_red", hexrgb("#C8322E"), rough=0.6)
gold = mat("gold", hexrgb("#D9A441"), rough=0.35, metal=0.65)
eye = mat("eye", hexrgb("#1E1612"), rough=0.3)
ico("horse_body", c, radius=0.5, subdiv=2, m=coat, loc=(0.05, 0, 0.5), scale=(0.5, 0.28, 0.28))
for i, (x, y) in enumerate(((-0.1, -0.08), (-0.1, 0.08), (0.2, -0.08), (0.2, 0.08))):
    cyl(f"horse_leg_{i}", c, r=0.048, h=0.36, segs=7, m=coat, loc=(x, y, 0.07), r_top=0.058)
    cyl(f"horse_hoof_{i}", c, r=0.054, h=0.075, segs=7, m=dark, loc=(x, y, 0.0))
sweep("horse_neck", c, [(-0.13, 0, 0.54), (-0.22, 0, 0.7), (-0.29, 0, 0.84)], [0.095, 0.085, 0.078], segs=8, m=coat)
box("horse_head", c, size=(0.28, 0.17, 0.17), bevel=0.07, segs=2, m=coat, loc=(-0.37, 0, 0.9), rot=(0, 0.45, 0))
box("horse_muzzle", c, size=(0.13, 0.16, 0.13), bevel=0.05, segs=2, m=muzzle, loc=(-0.49, 0, 0.82), rot=(0, 0.45, 0))
for s in (-1, 1):
    ico(f"horse_ear_{s}", c, radius=0.05, subdiv=1, m=coat, loc=(-0.29, 0.055 * s, 1.02), scale=(0.6, 0.5, 1.4))
    ico(f"horse_eye_{s}", c, radius=0.022, subdiv=1, m=eye, loc=(-0.41, 0.088 * s, 0.94))
for i in range(4):
    t = i / 3
    box(f"horse_mane_{i}", c, size=(0.07, 0.05, 0.11), bevel=0.02, m=dark, loc=(-0.24 + 0.12 * t, 0, 0.88 - 0.22 * t), rot=(0, -0.55, 0))
box("horse_forelock", c, size=(0.07, 0.06, 0.06), bevel=0.02, m=dark, loc=(-0.33, 0, 1.0))
sweep("horse_tail", c, [(0.3, 0, 0.58), (0.4, 0, 0.56), (0.45, 0, 0.44), (0.44, 0, 0.3)], [0.05, 0.055, 0.045, 0.015], segs=7, m=dark)
box("horse_saddle", c, size=(0.22, 0.26, 0.025), bevel=0.01, m=red, loc=(0.05, 0, 0.645))
for s in (-1, 1):
    box(f"horse_saddle_side_{s}", c, size=(0.2, 0.012, 0.13), bevel=0.006, m=red, loc=(0.05, 0.142 * s, 0.56))
    decal(f"horse_saddle_mark_{s}", c, gold, (0.05, 0.15 * s, 0.56), (0, s, 0), size=(0.035, 0.035), thick=0.005)
print(finish(KEY))
