# 元宝：椭圆船形底，两头高高翘起，中间鼓起一个圆顶
import math
c = asset_col(KEY)
silver = mat("silver", hexrgb("#CBD1DA"), rough=0.2, metal=0.9)
body = ico("silver_boat", c, radius=0.5, subdiv=3, m=silver)
for v in body.data.vertices:
    x, y, z = v.co
    x *= 1.05; y *= 0.6; z *= 0.34
    t = max(0.0, abs(x) - 0.12) / 0.4
    if z > -0.02:
        z += 0.36 * t ** 1.8 * (1 - 0.5 * abs(y) / 0.3)   # 两头翘起的船舷
        y *= 1 - 0.25 * t
    else:
        z *= 0.5                                         # 平底
    v.co = (x, y, z)
lathe("silver_dome", c, [(0.23, 0.0), (0.24, 0.08), (0.2, 0.17), (0.11, 0.24), (0.0, 0.26)], segs=12, m=silver, stagger=True, loc=(0, 0, 0.02), scale=(1, 0.86, 1))
for o in list(c.objects):
    o.rotation_euler.z += math.radians(-28)
print(finish(KEY))
