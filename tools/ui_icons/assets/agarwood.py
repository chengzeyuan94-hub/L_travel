import math
c = asset_col(KEY)
wood = mat("agarwood", hexrgb("#6B4128"), rough=0.7)
wood_dk = mat("agarwood_dark", hexrgb("#4A2C1C"), rough=0.7)
resin = mat("amber", hexrgb("#E8A02E"), rough=0.2, emit=hexrgb("#F2A93B"), emit_strength=0.35)
stand = mat("stand_wood", hexrgb("#8A5433"), rough=0.6)
cyl("agar_stand", c, r=0.3, h=0.06, segs=12, m=stand, loc=(0, 0, 0.06))
torus("agar_stand_rim", c, R=0.29, r=0.025, segs=14, rsegs=4, m=stand, loc=(0, 0, 0.12))
for k in range(3):
    a = 2 * math.pi * k / 3 + 0.5
    cyl(f"agar_foot_{k}", c, r=0.045, h=0.06, segs=6, m=stand, loc=(0.21 * math.cos(a), 0.21 * math.sin(a), 0))
ico("agar_chunk", c, radius=0.3, subdiv=1, m=wood, loc=(0, 0, 0.3), scale=(1.3, 0.82, 0.6), rot=(0.1, -0.15, 0.4), jitter=0.3, seed=9)
ico("agar_chunk2", c, radius=0.2, subdiv=1, m=wood_dk, loc=(0.14, 0.06, 0.4), scale=(1.1, 0.8, 0.6), rot=(0.3, 0.2, 0.9), jitter=0.3, seed=13)
# 露在外面的树脂纹：朝镜头一侧（-x -y 上方）
for i, (x, y, z, rz) in enumerate(((-0.22, -0.14, 0.33, 0.6), (-0.05, -0.2, 0.36, 0.9), (0.12, -0.16, 0.42, 0.4), (-0.15, -0.06, 0.45, 1.2))):
    ico(f"agar_resin_{i}", c, radius=0.12, subdiv=1, m=resin, loc=(x, y, z), scale=(0.9, 0.3, 0.22), rot=(0.3, 0.2, rz), jitter=0.2, seed=20 + i)
print(finish(KEY))
