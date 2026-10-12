import math
c = asset_col(KEY)
ruby = mat("ruby", hexrgb("#D8293A"), rough=0.08)
sapph = mat("sapphire", hexrgb("#2A5FD6"), rough=0.08)
emer = mat("emerald", hexrgb("#2FA84A"), rough=0.08)
gem = [(0.0, 0.0), (0.2, 0.14), (0.26, 0.24), (0.2, 0.32), (0.0, 0.34)]
lathe("gems_ruby", c, gem, segs=7, m=ruby, stagger=True, loc=(0, 0.05, 0.0), rot=(0.25, 0.1, 0), scale=(1.35, 1.35, 1.5))
lathe("gems_sapphire", c, gem, segs=6, m=sapph, stagger=True, loc=(-0.36, -0.12, 0.0), rot=(0.2, -0.5, 0.4), scale=(0.9, 0.9, 1.0))
em = box("gems_emerald", c, size=(0.18, 0.12, 0.3), bevel=0.05, segs=1, m=emer, loc=(0.34, -0.1, 0.13), rot=(0.1, 0.5, 0.3))
print(finish(KEY))
