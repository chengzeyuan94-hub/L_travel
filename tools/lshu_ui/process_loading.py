"""开局加载页「商队整装中…」的素材：从 image 2.5 生成图裁边、缩放，存进 assets/game/ui/lshu_loading/。
输入目录（生成图，不进仓库）需要：txt_loading_title / strip_blank / flag_start / lshu_walk / flowers_pair（均为透明底 PNG）。
背景地图、骆驼、电脑小伙伴头像、四色圆章沿用 assets/game/ui/lshu_setup/ 里的。
用法（仓库根目录）：uv run --with pillow --with numpy --with scipy python tools/lshu_ui/process_loading.py <生成图目录>"""
import json
import os
import sys

import numpy as np
from PIL import Image
from scipy import ndimage as ndi

SRC = sys.argv[1]
DST = "assets/game/ui/lshu_loading"
os.makedirs(DST, exist_ok=True)
meta = {}


def rgba(name):
    return Image.open(os.path.join(SRC, name + ".png")).convert("RGBA")


def clean(im, thr=24):
    a = np.asarray(im).copy()
    a[a[..., 3] <= thr, 3] = 0
    im = Image.fromarray(a)
    return im.crop(im.getchannel("A").getbbox())


def fit_h(im, h):
    return im.resize((round(im.width * h / im.height), h), Image.LANCZOS)


def save(im, name, **extra):
    im.save(os.path.join(DST, name + ".png"))
    rec = {"size": [im.width, im.height]}
    rec.update(extra)
    meta[name] = rec
    print(name, rec)


save(fit_h(clean(rgba("txt_loading_title")), 200), "txt_loading_title")
strip = fit_h(clean(rgba("strip_blank")), 360)
m = round(360 * 0.42)
save(strip, "strip_blank", nine=[m, m, m, m])
save(fit_h(clean(rgba("flag_start")), 320), "flag_start")
save(fit_h(clean(rgba("lshu_walk")), 1000), "lshu_walk")

# 花苞 / 开花：按连通块切成两张，底部（茎）对齐到同一高度的画布上
im = rgba("flowers_pair")
a = np.asarray(im)[..., 3]
lab, n = ndi.label(ndi.binary_dilation(a > 24, iterations=6))
parts = []
for i, sl in enumerate(ndi.find_objects(lab)):
    if int((lab[sl] == i + 1).sum()) < 5000:
        continue
    parts.append((sl[1].start, sl[0].start, sl[1].stop, sl[0].stop))
parts.sort()
bud, bloom = [clean(im.crop(b)) for b in parts[:2]]
H = 200
bloom_s = fit_h(bloom, H)
scale = H / bloom.height
bud_s = bud.resize((round(bud.width * scale), round(bud.height * scale)), Image.LANCZOS)
for img, name in [(bud_s, "flower_bud"), (bloom_s, "flower_bloom")]:
    canvas = Image.new("RGBA", (max(bud_s.width, bloom_s.width), H), (0, 0, 0, 0))
    canvas.alpha_composite(img, ((canvas.width - img.width) // 2, H - img.height))
    save(canvas, name)

json.dump(meta, open(os.path.join(DST, "loading.json"), "w"), indent=1)
