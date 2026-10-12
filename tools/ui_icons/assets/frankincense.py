import math
c = asset_col(KEY)
sack = mat("burlap", hexrgb("#A9804F"), rough=0.9)
sack_dk = mat("burlap_dark", hexrgb("#7E5A34"), rough=0.9)
resin = mat("resin", hexrgb("#F2C75A"), rough=0.35, emit=hexrgb("#F2C75A"), emit_strength=0.08)
s = lathe("frank_sack", c, [(0.22, 0), (0.34, 0.07), (0.38, 0.22), (0.33, 0.38), (0.24, 0.46), (0.25, 0.5), (0.33, 0.56), (0.35, 0.6)], segs=11, m=sack, stagger=True, cap_top=False)
wobble(s, 0.025, seed=5)
lathe("frank_sack_in", c, [(0.34, 0.6), (0.2, 0.5)], segs=11, m=sack_dk, cap_top=True)
torus("frank_rope", c, R=0.245, r=0.028, segs=11, rsegs=5, m=sack_dk, loc=(0, 0, 0.47))
pile("frank_resin", c, resin, 16, (0, 0, 0.52), 0.26, 0.12, r_item=0.06, seed=21)
for i, (x, y) in enumerate(((0.42, -0.28), (0.5, -0.14), (0.3, -0.42), (0.55, -0.32))):
    ico(f"frank_loose_{i}", c, radius=0.055, subdiv=1, m=resin, loc=(x, y, 0.04), jitter=0.15, seed=60 + i)
print(finish(KEY))
