# 土豆花：STAGE 0 种子 / 1 花苞 / 2 开花 / 3 发光
import math
c = asset_col(KEY)
skin = mat("potato_skin", hexrgb("#C99A5B"), rough=0.8)
eyem = mat("potato_eye", hexrgb("#8E6536"), rough=0.8)
soil = mat("soil", hexrgb("#6E4A30"), rough=0.95)
green = mat("sprout_green", hexrgb("#6DB553"), rough=0.5)
petal = mat("petal_white", hexrgb("#FBF7EA"), rough=0.4, emit=hexrgb("#FFF6D6"), emit_strength=(2.2 if STAGE == 3 else 0.0))
yolk = mat("petal_yolk", hexrgb("#F4C84A"), rough=0.4, emit=hexrgb("#FFD86A"), emit_strength=(1.5 if STAGE == 3 else 0.0))
ico("potato_body", c, radius=0.3, subdiv=2, m=skin, loc=(0, 0, 0.26), scale=(1.15, 0.95, 0.85), jitter=0.07, seed=4)
for i, (a, z) in enumerate(((-2.1, 0.3), (-1.4, 0.18), (-2.6, 0.16), (-1.8, 0.4))):
    decal(f"potato_eye_{i}", c, eyem, (0.33 * math.cos(a), 0.29 * math.sin(a), z), (math.cos(a), math.sin(a), 0.3), size=(0.025, 0.02), thick=0.008)
for i in range(9):
    a = 2 * math.pi * i / 9
    ico(f"potato_soil_{i}", c, radius=0.07, subdiv=1, m=soil, loc=(0.33 * math.cos(a), 0.3 * math.sin(a), 0.03), scale=(1.2, 1, 0.6), jitter=0.2, seed=30 + i)
if STAGE >= 1:
    h = 0.32 if STAGE == 1 else 0.42
    sweep("potato_stem", c, [(0, 0, 0.45), (0.01, 0, 0.45 + h * 0.5), (0, 0, 0.45 + h)], [0.02, 0.018, 0.015], segs=6, m=green)
    for s in (-1, 1):
        ico(f"potato_leaf_{s}", c, radius=0.09, subdiv=1, m=green, loc=(0.08 * s, 0, 0.45 + h * 0.4), scale=(1.1, 0.45, 0.12), rot=(0, -0.5 * s, 0))
    top = 0.45 + h
    if STAGE == 1:
        ico("potato_bud", c, radius=0.05, subdiv=1, m=green, loc=(0, 0, top + 0.02), scale=(0.8, 0.8, 1.3))
        ico("potato_bud_tip", c, radius=0.032, subdiv=1, m=petal, loc=(0, 0, top + 0.07), scale=(0.8, 0.8, 1.2))
    else:
        heads = [(0, 0, top + 0.04), (-0.17, 0.02, top - 0.09), (0.17, -0.02, top - 0.12)]
        for j, hp in enumerate(heads):
            if j > 0:
                sweep(f"potato_twig_{j}", c, [(0, 0, top - 0.15), hp], [0.012, 0.01], segs=5, m=green)
            ico(f"potato_yolk_{j}", c, radius=0.04, subdiv=1, m=yolk, loc=hp)
            for p in range(5):
                a = 2 * math.pi * p / 5
                ico(f"potato_petal_{j}_{p}", c, radius=0.07, subdiv=1, m=petal, loc=(hp[0] + 0.07 * math.cos(a), hp[1] + 0.07 * math.sin(a), hp[2]), scale=(1.1, 0.8, 0.3), rot=(0.35, 0, a))
if STAGE == 3:
    halo = mat("halo_glow", hexrgb("#FFE7A3"), rough=1.0, emit=hexrgb("#FFE39A"), emit_strength=1.2, alpha=0.18)
    ico("potato_halo", c, radius=0.3, subdiv=2, m=halo, loc=(0, 0, 0.45 + 0.42 - 0.02), scale=(1.1, 1.1, 0.8))
    for i in range(6):
        a = 2 * math.pi * i / 6 + 0.4
        ico(f"potato_spark_{i}", c, radius=0.018, subdiv=1, m=yolk, loc=(0.3 * math.cos(a), 0.3 * math.sin(a), 0.75 + 0.12 * math.sin(a * 2)))
print(finish(KEY))
