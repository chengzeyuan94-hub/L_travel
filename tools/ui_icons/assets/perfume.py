# 香水：钻石切割水滴瓶身 + 金色花边领口、颈圈、花瓣托、洋葱顶瓶塞（总高 = 1，按四视图量）
import math
c = asset_col(KEY)
gold = mat("gold", hexrgb("#D9A441"), rough=0.35, metal=0.65)
glass = mat("glass_pink", hexrgb("#F6B8C6"), rough=0.06, alpha=0.42)
liquid = mat("liquid_pink", hexrgb("#E8718D"), rough=0.25)
body = [(0.13, 0.0), (0.2, 0.035), (0.245, 0.12), (0.255, 0.22), (0.24, 0.31), (0.2, 0.40), (0.15, 0.48), (0.115, 0.54)]
lathe("perfume_glass", c, body, segs=12, m=glass, scale=(1, 0.82, 1), stagger=True)
liq = [(0.11, 0.02), (0.18, 0.05), (0.225, 0.12), (0.235, 0.22), (0.222, 0.30), (0.2, 0.36)]
lathe("perfume_liquid", c, liq, segs=12, m=liquid, scale=(1, 0.82, 1), stagger=True)
lathe("perfume_collar", c, [(0.14, 0.525), (0.1, 0.6)], segs=12, m=gold)
for i in range(10):
    a = 2 * math.pi * i / 10
    ico("perfume_scallop_%d" % i, c, radius=0.034, subdiv=1, m=gold, loc=(0.125 * math.cos(a), 0.125 * math.sin(a), 0.535), scale=(1, 1, 0.55))
cyl("perfume_neck", c, r=0.09, h=0.065, segs=12, m=gold, loc=(0, 0, 0.6))
for i in range(5):
    a = 2 * math.pi * i / 5 + 0.3
    ico("perfume_petal_%d" % i, c, radius=0.058, subdiv=1, m=gold, loc=(0.062 * math.cos(a), 0.062 * math.sin(a), 0.7), scale=(1.0, 0.7, 0.8), rot=(0, 0, a))
lathe("perfume_finial", c, [(0.05, 0.7), (0.1, 0.745), (0.118, 0.79), (0.1, 0.845), (0.06, 0.91), (0.0, 1.0)], segs=8, m=gold, stagger=True)
print(finish(KEY))
