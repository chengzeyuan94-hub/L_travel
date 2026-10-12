import math
c = asset_col(KEY)
wick = mat("wicker", hexrgb("#C28A4E"), rough=0.8)
wick_dk = mat("wicker_dark", hexrgb("#9C6A38"), rough=0.8)
date = mat("date", hexrgb("#6E1E17"), rough=0.35)
b = lathe("dates_basket", c, [(0.24, 0), (0.34, 0.08), (0.4, 0.2), (0.42, 0.26)], segs=12, m=wick, stagger=True, cap_top=False)
lathe("dates_inner", c, [(0.4, 0.26), (0.3, 0.12)], segs=12, m=wick_dk, cap_top=True)
for i, z in enumerate((0.06, 0.13, 0.2)):
    torus(f"dates_weave_{i}", c, R=0.27 + z * 0.62, r=0.016, segs=12, rsegs=4, m=wick_dk, loc=(0, 0, z))
torus("dates_rim", c, R=0.42, r=0.035, segs=14, rsegs=5, m=wick_dk, loc=(0, 0, 0.26))
pile("dates_date", c, date, 13, (0, 0, 0.27), 0.3, 0.16, r_item=0.085, scale=(1.5, 0.85, 0.85), seed=7, subdiv=2)
print(finish(KEY))
