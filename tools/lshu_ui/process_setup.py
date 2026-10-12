"""商旅设置页「出发前准备」的素材：从 image 2.5 生成图里裁边、切分，存进 assets/game/ui/lshu_setup/。
输入目录（生成图，不进仓库）需要：
  bg_map.png        去掉界面后的玩具世界地图背景（2048×1152，不透明）
  panel_satchel.png 空白挎包面板（透明底）
  ai_kids.png       电脑小伙伴 7 / 12 / 16 岁三张头像（透明底，一行三个）
  icons_small.png   铅笔、闹钟、打勾、两个人、定位针（透明底，一行五个）
  lshu_map.png      L叔 拿地图全身像；icon_camel.png / icon_ship.png 交通小图标
  concept_a.png     定稿概念图 A（2048×1152）：生成额度用完时，标题牌、「出发！」字样、四色圆章从这里抠
输出 setup.json 记九宫格边距。用法（仓库根目录）：
  uv run --with pillow --with numpy --with scipy python tools/lshu_ui/process_setup.py <生成图目录>"""
import json
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter
from scipy import ndimage as ndi

SRC = sys.argv[1]
DST = "assets/game/ui/lshu_setup"
os.makedirs(DST, exist_ok=True)
meta = {}


def rgba(name):
    return Image.open(os.path.join(SRC, name)).convert("RGBA")


def clean(im, thr=24):
    a = np.asarray(im).copy()
    a[a[..., 3] <= thr, 3] = 0
    im = Image.fromarray(a)
    return im.crop(im.getchannel("A").getbbox())


def fit_h(im, h):
    return im.resize((round(im.width * h / im.height), h), Image.LANCZOS)


def split(name, min_area, order="x"):
    im = rgba(name)
    a = np.asarray(im)[..., 3]
    lab, n = ndi.label(ndi.binary_dilation(a > 24, iterations=6))
    parts = []
    for i, sl in enumerate(ndi.find_objects(lab)):
        if int((lab[sl] == i + 1).sum()) < min_area:
            continue
        parts.append((sl[1].start, sl[0].start, sl[1].stop, sl[0].stop))
    parts.sort(key=lambda b: b[0] if order == "x" else b[1])
    return [clean(im.crop(b)) for b in parts]


def save(im, name, **extra):
    im.save(os.path.join(DST, name + ".png"))
    rec = {"size": [im.width, im.height]}
    rec.update(extra)
    meta[name] = rec
    print(name, rec)


# 背景：直接存 JPG
Image.open(os.path.join(SRC, "bg_map.png")).convert("RGB").save(os.path.join(DST, "bg_map.jpg"), quality=92)

# 挎包面板：按两倍设计尺寸存，九宫格边距按皮边厚度（约高的 9%）
panel = clean(rgba("panel_satchel.png"))
panel = fit_h(panel, 1200)
m = round(1200 * 0.1)
save(panel, "panel_satchel", nine=[m, m, m, m])

# L叔、交通图标
save(fit_h(clean(rgba("lshu_map.png")), 1100), "lshu_map")
save(fit_h(clean(rgba("icon_camel.png")), 240), "icon_camel")
save(fit_h(clean(rgba("icon_ship.png")), 240), "icon_ship")

# 电脑小伙伴三张头像：统一成正方形（头顶对齐，宽不够的左右补透明）
for im, nm in zip(split("ai_kids.png", 20000), ["kid_7", "kid_12", "kid_16"]):
    side = max(im.width, im.height)
    sq = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    sq.alpha_composite(im, ((side - im.width) // 2, side - im.height))
    save(sq.resize((320, 320), Image.LANCZOS), nm)

# 小图标
for im, nm in zip(split("icons_small.png", 3000), ["icon_pencil", "icon_clock", "icon_check", "icon_people", "icon_pin"]):
    save(fit_h(im, 128), nm)

# ---------------------------------------------------------------- 从概念图抠（生成额度用完时的办法）
concept = Image.open(os.path.join(SRC, "concept_a.png")).convert("RGBA")


def rounded_mask(size, box, radius, feather=1.5):
    mk = Image.new("L", size, 0)
    ImageDraw.Draw(mk).rounded_rectangle(box, radius=radius, fill=255)
    return mk.filter(ImageFilter.GaussianBlur(feather))


# 标题牌「出发前准备」：连皮牌一起抠，圆角矩形遮罩
tab = concept.crop((955, 30, 1660, 210))
tab.putalpha(rounded_mask(tab.size, (14, 20, tab.width - 10, tab.height - 8), (tab.height - 28) // 2))  # 两头半圆的胶囊形
save(clean(tab, 8), "title_tab")

# 「出发！」字样：深棕字压在橙黄按钮上，按亮度抠出字
go = concept.crop((1490, 960, 1680, 1048))
g = np.asarray(go).astype(np.float32)
lum = g[..., :3] @ np.array([0.299, 0.587, 0.114], np.float32)
alpha = np.clip((150.0 - lum) / 55.0, 0, 1)
alpha = ndi.gaussian_filter(alpha, 0.6)
out = np.dstack([g[..., :3], alpha * 255])  # 边缘带一点橙黄，正好压在同色的按钮上
save(clean(Image.fromarray(out.astype(np.uint8), "RGBA"), 10), "txt_go")

# 四色圆章：取绿色那枚（没被眼镜框挡住），圆形遮罩抠出，再按数据里的玩家颜色重新着色
cx, cy, r_out, r_in = 1085, 422, 54, 43
tok = concept.crop((cx - r_out - 4, cy - r_out - 4, cx + r_out + 4, cy + r_out + 4))
mk = Image.new("L", tok.size, 0)
ImageDraw.Draw(mk).ellipse((4, 4, tok.width - 4, tok.height - 4), fill=255)
tok.putalpha(mk.filter(ImageFilter.GaussianBlur(1.2)))
ta = np.asarray(tok).astype(np.float32)
yy, xx = np.mgrid[0:tok.height, 0:tok.width]
dist = np.hypot(xx - tok.width / 2, yy - tok.height / 2)
disc = np.clip((r_in + 1 - dist) / 2.0, 0, 1)[..., None]
L = ta[..., :3] @ np.array([0.299, 0.587, 0.114], np.float32)
Lm = float(np.median(L[dist < r_in - 6]))
PLAYER = {"red": "A54A3F", "blue": "3F6D8C", "green": "3F7D63", "yellow": "C58B32"}
for cid, hx in PLAYER.items():
    target = np.array([int(hx[i:i + 2], 16) for i in (0, 2, 4)], np.float32) * 1.12
    ratio = (L / Lm)[..., None]
    shade = np.where(ratio <= 1.0, target * ratio, target + (255 - target) * np.clip((ratio - 1.0) / 0.9, 0, 1))
    rgb = ta[..., :3] * (1 - disc) + np.clip(shade, 0, 255) * disc
    im = Image.fromarray(np.dstack([rgb, ta[..., 3]]).astype(np.uint8), "RGBA").resize((200, 200), Image.LANCZOS)
    save(im, "token_" + cid)

json.dump(meta, open(os.path.join(DST, "setup.json"), "w"), indent=1)

# L叔 脚下的岩台：从背景左下角切出来（上沿、右沿做柔边），放在 Stage 里跟着 L叔 走。
# 16:9 时和背景像素完全重合；超宽或 4:3 时背景按屏幕铺，岩台仍垫在他脚下，不会站到湖里。
bg = Image.open(os.path.join(SRC, "bg_map.png")).convert("RGBA")
LX0, LY0, LX1, LY1 = 0, 860, 720, 1152
ledge = bg.crop((LX0, LY0, LX1, LY1))
w, h = ledge.size
yy, xx = np.mgrid[0:h, 0:w]
# 上沿、右沿柔边；左沿和下沿也羽化一点，超宽 / 4:3 时它们落在屏幕里面，不能是硬切口
a = np.clip((yy - 10) / 80.0, 0, 1) * np.clip((w - 20 - xx) / 150.0, 0, 1) * np.clip(xx / 80.0, 0, 1) * np.clip((h - 1 - yy) / 30.0, 0, 1)
arr = np.asarray(ledge).copy()
arr[..., 3] = (a * 255).astype(np.uint8)
save(Image.fromarray(arr, "RGBA"), "ledge", src_box=[LX0, LY0, LX1, LY1])
json.dump(meta, open(os.path.join(DST, "setup.json"), "w"), indent=1)
