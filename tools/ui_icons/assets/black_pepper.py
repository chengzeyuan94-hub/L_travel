import math
c = asset_col(KEY)
clay = mat("terracotta", hexrgb("#C8744A"), rough=0.75)
clay_lt = mat("terracotta_light", hexrgb("#E2A07A"), rough=0.75)
pep = mat("peppercorn", hexrgb("#2A211C"), rough=0.6)
lathe("pepper_bowl", c, [(0.2, 0), (0.33, 0.07), (0.4, 0.2), (0.41, 0.27), (0.38, 0.28), (0.33, 0.16)], segs=11, m=clay, stagger=True)
lathe("pepper_band", c, [(0.385, 0.16), (0.402, 0.19), (0.41, 0.22)], segs=11, m=clay_lt, cap_top=False, cap_bottom=False)
pile("pepper_top", c, pep, 34, (0, 0, 0.26), 0.31, 0.1, r_item=0.048, seed=11, subdiv=2)
for i, (x, y) in enumerate(((0.44, -0.22), (0.52, -0.1), (0.36, -0.36))):
    ico(f"pepper_loose_{i}", c, radius=0.04, subdiv=1, m=pep, loc=(x, y, 0.035), jitter=0.12, seed=40 + i)
print(finish(KEY))
