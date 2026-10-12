import math
c = asset_col(KEY)
brass = mat("brass", hexrgb("#C99A3C"), rough=0.35, metal=0.7)
dark = mat("keyhole", hexrgb("#3A2A22"), rough=0.6)
box("lock_body", c, size=(0.56, 0.24, 0.46), bevel=0.14, segs=3, m=brass, loc=(0, 0, 0.23))
t = torus("lock_shackle", c, R=0.17, r=0.05, segs=14, rsegs=6, m=brass, loc=(0, 0, 0.5), rot=(math.pi / 2, 0, 0))
t.scale = (1, 1.15, 1)
for s in (-1, 1):
    box(f"lock_lens_{s}", c, size=(0.12, 0.02, 0.09), bevel=0.025, segs=2, m=dark, loc=(0.075 * s, -0.12, 0.22))
box("lock_bridge", c, size=(0.05, 0.02, 0.02), bevel=0.006, m=dark, loc=(0, -0.12, 0.245))
for i, (x, z) in enumerate(((-0.2, 0.37), (0.2, 0.37), (-0.2, 0.08), (0.2, 0.08))):
    ico(f"lock_rivet_{i}", c, radius=0.022, subdiv=1, m=brass, loc=(x, -0.118, z))
print(finish(KEY))
