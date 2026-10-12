# 图标总览：透明图标铺在奶油底上，4 种尺寸（256/128/64/48）检查小尺寸可读性
import sys, os
from PIL import Image, ImageDraw, ImageFont
d = "assets/game/ui/lshu_3d/icons"
keys = sys.argv[2].split(",") if len(sys.argv) > 2 else sorted(f[:-4] for f in os.listdir(d) if f.endswith(".png"))
out = sys.argv[1]
f = ImageFont.truetype("/System/Library/Fonts/Hiragino Sans GB.ttc", 18)
W = 256; row = W + 64 + 48 + 40
sheet = Image.new("RGB", (len(keys) * (W + 16) + 16, row + 20), (244, 237, 224))
dr = ImageDraw.Draw(sheet)
for i, k in enumerate(keys):
    im = Image.open(f"{d}/{k}.png").convert("RGBA")
    bb = im.getbbox(); im = im.crop(bb)
    s = max(im.size); sq = Image.new("RGBA", (s, s)); sq.paste(im, ((s - im.size[0]) // 2, (s - im.size[1]) // 2))
    x = 16 + i * (W + 16)
    for size, y in ((W, 10), (64, W + 20), (48, W + 20)):
        t = sq.resize((size, size), Image.LANCZOS)
        xx = x if size != 48 else x + 90
        sheet.paste(t, (xx, y), t)
    dr.text((x, row - 10), k, fill=(58, 42, 34), font=f)
sheet.save(out); print(out, sheet.size)
