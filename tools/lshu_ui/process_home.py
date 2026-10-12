"""默认开场「旅行L叔」的分层素材：从 image 2.5 生成的原画和几张编辑图里拆出可动的图层。

输入目录（生成图，不进仓库）里需要：
  master_a.png   原画 2048×1152（有 L叔、热气球、纸飞机、鸟、驼队）
  plate.png      同一张画去掉上面这些之后补全的背景
  lshu_cut.png   只留 L叔 的编辑图（透明底，尺寸和位置会有偏差，只拿来当遮罩）
  sprites_cut.png 只留热气球、纸飞机、鸟、驼队的编辑图（透明底，位置和原画一致）
  blink.png / laugh.png  原画上只改 L叔 表情的编辑图（闭眼 / 大笑）
  clouds.png / petals.png  配套的云和花瓣小图（透明底）
  avatar.png / point.png   L叔 头像、指路全身像（透明底）
输出：assets/game/ui/lshu_home/ 下的各层 PNG / JPG 和 home.json（所有坐标都是原画像素），
      assets/game/title_cg/home.jpg（静帧，截图兜底和缩略图用），assets/game/ui/lshu_title/lshu_avatar2.png、lshu_point.png。
用法（仓库根目录）：uv run --with pillow --with numpy --with scipy python tools/lshu_ui/process_home.py <生成图目录>
"""
import json
import os
import sys

import numpy as np
from PIL import Image
from scipy import ndimage as ndi

SRC = sys.argv[1]
DST = "assets/game/ui/lshu_home"
os.makedirs(DST, exist_ok=True)
W, H = 2048, 1152


def rgba(name):
    return Image.open(os.path.join(SRC, name)).convert("RGBA")


def arr(name, mode="RGB"):
    return np.asarray(Image.open(os.path.join(SRC, name)).convert(mode)).astype(np.float32)


master = arr("master_a.png")
plate = arr("plate.png")
meta = {"size": [W, H]}


def align(src_crop: Image.Image, target: np.ndarray, center, s_values, weight=None, radius=40, step=4):
    """把 src_crop（RGBA）缩放后平移，找和 target 颜色最接近的位置。返回 (误差, 缩放, x, y, w, h)。"""
    best = (1e9, None)
    for s in s_values:
        w, h = round(src_crop.width * s), round(src_crop.height * s)
        c = np.asarray(src_crop.resize((w, h), Image.BILINEAR)).astype(np.float32)
        wa = c[..., 3] > 220
        if weight is not None:
            wa &= np.asarray(Image.fromarray(weight).resize((w, h), Image.NEAREST)) > 0
        rgb = c[..., :3]
        for dy in range(-radius, radius + 1, step):
            for dx in range(-radius, radius + 1, step):
                x0 = round(center[0] - w / 2) + dx
                y0 = round(center[1] - h / 2) + dy
                if x0 < 0 or y0 < 0 or x0 + w > target.shape[1] or y0 + h > target.shape[0]:
                    continue
                e = np.abs(target[y0:y0 + h, x0:x0 + w] - rgb).mean(-1)[wa].mean()
                if e < best[0]:
                    best = (e, (s, x0, y0, w, h))
    return best


def refine(src_crop, target, first, weight=None):
    e, (s, x0, y0, w, h) = first
    return align(src_crop, target, (x0 + w / 2, y0 + h / 2), np.arange(s - 0.006, s + 0.0061, 0.002), weight, radius=4, step=1)


# ---------------------------------------------------------------- 背景
Image.fromarray(plate.astype(np.uint8)).save(os.path.join(DST, "plate.jpg"), quality=93)

# ---------------------------------------------------------------- L叔：像素取原画，遮罩取对齐后的抠图
cut = rgba("lshu_cut.png")
ca = np.asarray(cut)[..., 3]
bb = Image.fromarray(((ca > 200) * 255).astype(np.uint8)).getbbox()
crop = cut.crop(bb)
first = align(crop, master, (1240, 650), np.arange(0.80, 0.93, 0.01))
e, (s, X, Y, Wc, Hc) = refine(crop, master, first)
print("lshu align err %.1f scale %.3f at %d,%d" % (e, s, X, Y))
A = np.zeros((H, W), np.float32)
A[Y:Y + Hc, X:X + Wc] = np.asarray(crop.getchannel("A").resize((Wc, Hc), Image.BILINEAR)) / 255.0
core = ndi.binary_fill_holes(A > 0.5)
lab, n = ndi.label(core)
sizes = ndi.sum(core, lab, range(1, n + 1))
keep = np.zeros_like(core)
for i, sz in enumerate(sizes):
    if sz > 200:
        keep |= lab == (i + 1)
matte = ndi.gaussian_filter(ndi.binary_dilation(keep, iterations=3).astype(np.float32), 1.0)
body = Image.fromarray(np.dstack([master, matte * 255]).astype(np.uint8), "RGBA")
bbox = body.getchannel("A").point(lambda v: 255 if v > 2 else 0).getbbox()
body.crop(bbox).save(os.path.join(DST, "lshu_body.png"))
meta["lshu"] = {"pos": [bbox[0], bbox[1]], "size": [bbox[2] - bbox[0], bbox[3] - bbox[1]]}


# ---------------------------------------------------------------- 表情：对齐脸部后只取变化的区域
def face_overlay(name, box, change_box):
    img = rgba(name)
    x0, y0, x1, y1 = box
    region = img.crop(box)
    # 对齐时不看会变的眼睛 / 嘴，只看头发、眼镜框、脸颊
    wmask = np.ones((y1 - y0, x1 - x0), np.uint8)
    cx0, cy0, cx1, cy1 = change_box
    wmask[cy0 - y0:cy1 - y0, cx0 - x0:cx1 - x0] = 0
    f = align(region, master, ((x0 + x1) / 2, (y0 + y1) / 2), np.arange(0.95, 1.051, 0.01), wmask * 255, radius=30, step=3)
    e, (s, fx, fy, fw, fh) = refine(region, master, f, wmask * 255)
    print("%s align err %.1f scale %.3f at %d,%d" % (name, e, s, fx, fy))
    aligned = np.zeros((H, W, 4), np.float32)
    aligned[fy:fy + fh, fx:fx + fw] = np.asarray(region.resize((fw, fh), Image.BILINEAR)).astype(np.float32)
    diff = np.abs(aligned[..., :3] - master).mean(-1)
    m = np.zeros((H, W), bool)
    m[cy0:cy1, cx0:cx1] = True
    m &= ndi.gaussian_filter(diff, 1.5) > 14
    m = ndi.binary_closing(m, iterations=4)
    m = ndi.binary_dilation(m, iterations=5)
    a = ndi.gaussian_filter(m.astype(np.float32), 2.0)
    a[:cy0 - 6, :] = 0
    a[cy1 + 6:, :] = 0
    out = Image.fromarray(np.dstack([aligned[..., :3], a * 255]).astype(np.uint8), "RGBA")
    b = out.getchannel("A").point(lambda v: 255 if v > 2 else 0).getbbox()
    return out.crop(b), [b[0], b[1]]


for key, src, box, change in [
    ("blink", "blink.png", (1080, 300, 1430, 600), (1110, 405, 1400, 522)),
    ("laugh", "laugh.png", (1080, 300, 1430, 620), (1110, 405, 1400, 572)),
]:
    img, pos = face_overlay(src, box, change)
    img.save(os.path.join(DST, "face_%s.png" % key))
    meta["face_" + key] = {"pos": pos, "size": [img.width, img.height]}

# ---------------------------------------------------------------- 天上和路上的小东西（位置与原画一致）
sp = rgba("sprites_cut.png")
spa = np.asarray(sp)[..., 3]
lab, n = ndi.label(ndi.binary_dilation(spa > 24, iterations=4))
items = []
for i, sl in enumerate(ndi.find_objects(lab)):
    area = int((lab[sl] == i + 1).sum())
    if area < 200:
        continue
    items.append((sl[1].start, sl[0].start, sl[1].stop, sl[0].stop, area))
items.sort(key=lambda t: -t[4])


def save_sprite(name, box):
    im = sp.crop(box)
    a = np.asarray(im).copy()
    a[a[..., 3] <= 24, 3] = 0
    im = Image.fromarray(a)
    b = im.getchannel("A").getbbox()
    im = im.crop(b)
    im.save(os.path.join(DST, name + ".png"))
    meta[name] = {"pos": [box[0] + b[0], box[1] + b[1]], "size": [im.width, im.height]}


named = {"balloon": None, "caravan": None, "plane": None, "birds": []}
for x0, y0, x1, y1, area in items:
    if y0 < 260 and (x1 - x0) > 100 and (y1 - y0) > 120:
        named["balloon"] = (x0, y0, x1, y1)
    elif y0 > 500:
        named["caravan"] = (x0, y0, x1, y1)
    elif (x1 - x0) > 80:
        named["plane"] = (x0, y0, x1, y1)
    else:
        named["birds"].append((x0, y0, x1, y1))
save_sprite("balloon", named["balloon"])
save_sprite("plane", named["plane"])
for i, b in enumerate(sorted(named["birds"])):
    save_sprite("bird_%d" % (i + 1), b)
# 驼队按列覆盖的低谷切成四头骆驼，各自起伏像在走
x0, y0, x1, y1 = named["caravan"]
col = (spa[y0:y1, x0:x1] > 60).sum(0).astype(np.float32)
col = ndi.uniform_filter1d(col, 5)
cuts = []
span = x1 - x0
for k in range(1, 4):
    lo, hi = int(span * (k / 4 - 0.1)), int(span * (k / 4 + 0.1))
    cuts.append(x0 + lo + int(np.argmin(col[lo:hi])))
edges = [x0] + cuts + [x1]
meta["camels"] = []
for k in range(4):
    save_sprite("camel_%d" % (k + 1), (edges[k], y0, edges[k + 1], y1))
    meta["camels"].append(meta.pop("camel_%d" % (k + 1)))


# ---------------------------------------------------------------- 云、花瓣：按连通块切开
def split_sheet(name, prefix, min_area, max_h):
    im = rgba(name)
    a = np.asarray(im)[..., 3]
    lab, n = ndi.label(ndi.binary_dilation(a > 20, iterations=6))
    out = []
    for i, sl in enumerate(ndi.find_objects(lab)):
        if int((lab[sl] == i + 1).sum()) < min_area:
            continue
        box = (sl[1].start, sl[0].start, sl[1].stop, sl[0].stop)
        c = im.crop(box)
        ca = np.asarray(c).copy()
        ca[ca[..., 3] <= 16, 3] = 0
        c = Image.fromarray(ca)
        if c.height > max_h:
            c = c.resize((round(c.width * max_h / c.height), max_h), Image.LANCZOS)
        out.append((box[1] // 200, box[0], c))
    out.sort(key=lambda t: (t[0], t[1]))
    names = []
    for k, (_, _, c) in enumerate(out):
        nm = "%s_%d" % (prefix, k + 1)
        c.save(os.path.join(DST, nm + ".png"))
        names.append({"name": nm, "size": [c.width, c.height]})
    return names


meta["clouds"] = split_sheet("clouds.png", "cloud", 5000, 400)
meta["petals"] = split_sheet("petals.png", "petal", 800, 96)

# ---------------------------------------------------------------- 草地摇摆遮罩：前景的草和花，避开行李箱、路牌、石头
yy, xx = np.mgrid[0:H, 0:W]
r, g, b = plate[..., 0], plate[..., 1], plate[..., 2]
lum = 0.299 * r + 0.587 * g + 0.114 * b
green = (g > r * 0.82) & (g > b * 1.12)
white = (np.minimum(np.minimum(r, g), b) > 190)
veg = (green | white).astype(np.float32)
band = np.clip((yy - 850) / 150.0, 0, 1)
side = ((yy > 840) & ((xx < 960) | (xx > 1480))).astype(np.float32) * np.clip((yy - 840) / 120.0, 0, 1)
w = np.maximum(band, side) * veg
w[(xx > 950) & (xx < 1500) & (yy < 1080)] = 0          # 行李箱
w[(xx > 830) & (xx < 925) & (yy < 990)] = 0            # 路牌柱
grey = (np.abs(r - g) < 22) & (np.abs(g - b) < 28) & (lum > 80) & (lum < 200)
w[grey & (yy > 950)] = 0                               # 石头
w = ndi.gaussian_filter(w, 5)
w = np.clip(w * 1.6, 0, 1)
Image.fromarray((w * 255).astype(np.uint8)).resize((512, 288), Image.BILINEAR).save(os.path.join(DST, "sway_mask.png"))

# ---------------------------------------------------------------- 静帧、头像、全身像
poster = Image.fromarray(master.astype(np.uint8)).resize((1920, 1080), Image.LANCZOS)
poster.save("assets/game/title_cg/home.jpg", quality=92)
poster.resize((640, 360), Image.LANCZOS).save("assets/game/title_cg/home_thumb.jpg", quality=90)
for src, dst, h in [("avatar.png", "lshu_avatar2.png", 360), ("point.png", "lshu_point.png", 720)]:
    im = rgba(src)
    a = np.asarray(im).copy()
    a[a[..., 3] <= 24, 3] = 0
    im = Image.fromarray(a)
    im = im.crop(im.getchannel("A").getbbox())
    im = im.resize((round(im.width * h / im.height), h), Image.LANCZOS)
    im.save(os.path.join("assets/game/ui/lshu_title", dst))

json.dump(meta, open(os.path.join(DST, "home.json"), "w"), indent=1)
print(json.dumps(meta, indent=1)[:3000])
