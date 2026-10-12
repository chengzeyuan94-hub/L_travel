import sys, os
from PIL import Image, ImageDraw, ImageFont
d = "assets/game/ui/lshu_3d/icons"
out = sys.argv[1]; keys = sys.argv[2].split(","); cols = int(sys.argv[3]) if len(sys.argv) > 3 else 4
W = 380; f = ImageFont.truetype("/System/Library/Fonts/Hiragino Sans GB.ttc", 22)
rows = (len(keys) + cols - 1) // cols
sheet = Image.new("RGB", (cols * W, rows * (W + 30)), (244, 237, 224)); dr = ImageDraw.Draw(sheet)
for i, k in enumerate(keys):
    im = Image.open(f"{d}/{k}.png").convert("RGBA"); im = im.crop(im.getbbox())
    s = int(max(im.size) * 1.1); sq = Image.new("RGBA", (s, s)); sq.paste(im, ((s - im.size[0]) // 2, (s - im.size[1]) // 2))
    sq = sq.resize((W, W), Image.LANCZOS); x = (i % cols) * W; y = (i // cols) * (W + 30)
    sheet.paste(sq, (x, y + 30), sq); dr.text((x + 8, y + 4), k, fill=(58, 42, 34), font=f)
sheet.save(out); print(out)
