import math
c = asset_col(KEY)
red = mat("lacquer_red", hexrgb("#C6222A"), rough=0.18)
black = mat("lacquer_black", hexrgb("#1E1714"), rough=0.3)
gold = mat("gold", hexrgb("#D9A441"), rough=0.35, metal=0.65)
lathe("lacq_base", c, [(0.3, 0), (0.37, 0.03), (0.39, 0.18)], segs=12, m=red, stagger=True)
lathe("lacq_band", c, [(0.392, 0.17), (0.4, 0.245)], segs=12, m=black, cap_top=False, cap_bottom=False)
torus("lacq_gold_lo", c, R=0.398, r=0.011, segs=14, rsegs=4, m=gold, loc=(0, 0, 0.175))
torus("lacq_gold_hi", c, R=0.4, r=0.011, segs=14, rsegs=4, m=gold, loc=(0, 0, 0.24))
lathe("lacq_lid", c, [(0.4, 0.245), (0.4, 0.28), (0.34, 0.39), (0.2, 0.45), (0.0, 0.47)], segs=12, m=red, stagger=True)
cyl("lacq_knob", c, r=0.06, h=0.05, segs=8, m=red, loc=(0, 0, 0.46), r_top=0.05)
for k in range(6):
    a = 2 * math.pi * k / 6
    decal(f"lacq_motif_{k}", c, gold, (0.402 * math.cos(a), 0.402 * math.sin(a), 0.2075), (math.cos(a), math.sin(a), 0), size=(0.045, 0.02), thick=0.01)
print(finish(KEY))
