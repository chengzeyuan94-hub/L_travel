"""把 image 2.5 生成的开场界面元素裁边、缩放，存进 assets/game/ui/lshu_title/。
按透明度 > 24 求包围盒（忽略几乎透明的阴影余量），四周留 6px，再按目标高度缩放。
驼黄、牛仔蓝按钮不单独生成：从奶油按钮按亮度重新着色，三种按钮形状完全一致，按下贴图也对得齐。
九宫格边距（贴图像素）写进 kit.json，给 Godot 端 NinePatch 用。
用法（仓库根目录）：uv run --with pillow --with numpy python tools/lshu_ui/process_kit.py <生成图目录>"""
import json, os, sys
import numpy as np
from PIL import Image

SRC = sys.argv[1]
DST = "assets/game/ui/lshu_title"
os.makedirs(DST, exist_ok=True)

BTN_NINE = (0.5, 0.3, 0.5, 0.3)
# name: (目标高度px, 九宫格边距 [左,上,右,下] 占目标高度的比例；None=不做九宫格)
SPEC = {
    "logo": (420, None),
    "btn_ochre": (216, BTN_NINE), "btn_cream": (216, BTN_NINE), "btn_denim": (216, BTN_NINE),
    "btn_ochre_pressed": (216, BTN_NINE), "btn_cream_pressed": (216, BTN_NINE), "btn_denim_pressed": (216, BTN_NINE),
    "panel_leather": (400, (0.16, 0.24, 0.24, 0.16)),
    "bubble": (200, (0.5, 0.3, 0.3, 0.48)),
    "badge_on": (200, None), "badge_off": (200, None),
    "lens_music": (200, None), "lens_gear": (200, None),
    "icon_suitcase": (200, None), "icon_mountain": (200, None), "icon_glasses": (120, None),
    "picker_bg": (1024, None), "card_blank": (1380, (0.08, 0.08, 0.08, 0.08)), "clip": (160, None),
    "btn_back": (220, None), "stamp_current": (280, None), "txt_picker": (200, None),
    "txt_merchant": (120, None), "txt_load": (120, None), "txt_traveler": (120, None), "txt_subtitle": (96, None),
}
# 从奶油按钮换色：概念图 01_title 上取的按钮面色与底唇色
RECOLOR = {
    "ochre": ((245, 182, 86), (189, 116, 44)),
    "denim": ((117, 150, 203), (75, 108, 160)),
}
LUM = np.array([0.299, 0.587, 0.114], np.float32)


def recolor(im: Image.Image, face, lip) -> Image.Image:
    a = np.asarray(im.convert("RGBA")).astype(np.float32)
    rgb = a[..., :3]
    lum = rgb @ LUM
    face = np.array(face, np.float32)
    lip = np.array(lip, np.float32)
    hi = np.minimum(face * 1.1 + 12, 255)
    # 奶油按钮：底唇亮度约 196，按钮面约 234，高光约 250；按亮度分段映射到新颜色
    xs, ys = [120, 196, 234, 252], [lip * 0.78, lip, face, hi]
    out = np.stack([np.interp(lum, xs, [y[c] for y in ys]) for c in range(3)], -1)
    # 深棕描边（亮度 < 95）保持原样，之间平滑过渡
    w = np.clip((lum - 95) / (170 - 95), 0, 1)[..., None]
    res = rgb * (1 - w) + out * w
    return Image.fromarray(np.dstack([np.clip(res, 0, 255), a[..., 3]]).astype(np.uint8))


def source(name: str) -> Image.Image | None:
    for kind, (face, lip) in RECOLOR.items():
        if name.startswith("btn_" + kind):
            base = os.path.join(SRC, name.replace(kind, "cream") + ".png")
            return recolor(Image.open(base), face, lip) if os.path.exists(base) else None
    p = os.path.join(SRC, name + ".png")
    return Image.open(p).convert("RGBA") if os.path.exists(p) else None


out = {}
for name, (h, nine) in SPEC.items():
    im = source(name)
    if im is None:
        print("missing", name)
        continue
    arr = np.asarray(im).copy()
    arr[arr[..., 3] <= 24, 3] = 0  # 去掉生成图里几乎透明的光晕，贴在按钮上会成一圈脏边
    im = Image.fromarray(arr)
    bb = im.getchannel("A").getbbox()
    pad = 6
    bb = (max(0, bb[0] - pad), max(0, bb[1] - pad), min(im.width, bb[2] + pad), min(im.height, bb[3] + pad))
    im = im.crop(bb)
    w = round(im.width * h / im.height)
    im = im.resize((w, h), Image.LANCZOS)
    im.save(os.path.join(DST, name + ".png"))
    rec = {"size": [w, h]}
    if nine:
        rec["nine"] = [round(nine[0] * h), round(nine[1] * h), round(nine[2] * h), round(nine[3] * h)]
    out[name] = rec
    print(name, rec)
json.dump(out, open(os.path.join(DST, "kit.json"), "w"), indent=1)
