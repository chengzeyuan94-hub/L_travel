"""Small-size distinctness strip for a new goods icon next to shipped ones.

uv run --with pillow python tools/map_catalogue/compare_strip.py kaolin \
    porcelain,ivory,tea,silver,ginseng,agarwood,frankincense,glass,silk out.png

Each icon is scaled as a whole 1024 frame (no crop), the way lshu_match_hud.gd `_tile` shows it
(TextureRect, keep-aspect-centred). Rows: 96 px on the market tile (assets/game/ui/match_hud/tile.png),
96 px on the cream page colour, 96 px greyscale (shape/value only), 48 px on cream.
The new icon is the first column and is marked; it may be given as a .png path (e.g. a scratch render).
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont, ImageOps

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ICONS = os.path.join(ROOT, "assets/game/ui/lshu_3d/icons")
TILE = os.path.join(ROOT, "assets/game/ui/match_hud/tile.png")
CREAM = (244, 237, 224, 255)
INK = (58, 42, 34)


def icon(key, px):
    path = key if key.endswith(".png") else os.path.join(ICONS, key + ".png")
    return Image.open(path).convert("RGBA").resize((px, px), Image.LANCZOS)


def tile_bg(w, h):
    """Nine-patch the 150 px tile to w x h with 36 px margins (as _tile does)."""
    t = Image.open(TILE).convert("RGBA")
    m = 36
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    src = [(0, m), (m, 150 - m), (150 - m, 150)]
    dst_x = [(0, m), (m, w - m), (w - m, w)]
    dst_y = [(0, m), (m, h - m), (h - m, h)]
    for iy in range(3):
        for ix in range(3):
            box = (src[ix][0], src[iy][0], src[ix][1], src[iy][1])
            dw, dh = dst_x[ix][1] - dst_x[ix][0], dst_y[iy][1] - dst_y[iy][0]
            if dw > 0 and dh > 0:
                out.alpha_composite(t.crop(box).resize((dw, dh), Image.LANCZOS), (dst_x[ix][0], dst_y[iy][0]))
    return out


def main(new_key, others, out_path):
    keys = [new_key] + others.split(",")
    cell = 132
    font_path = "/System/Library/Fonts/Hiragino Sans GB.ttc"
    f = ImageFont.truetype(font_path, 15) if os.path.exists(font_path) else ImageFont.load_default()
    rows = ["96 px on market tile", "96 px on cream", "96 px greyscale", "48 px on cream"]
    lw = 150
    sheet = Image.new("RGBA", (lw + cell * len(keys), 26 + cell * 3 + 80), CREAM)
    dr = ImageDraw.Draw(sheet)
    for i, k in enumerate(keys):
        x = lw + i * cell
        name = os.path.basename(k)[:-4] if k.endswith(".png") else k
        dr.text((x + 8, 6), name + ("  (new)" if k == new_key else ""), fill=(180, 60, 40) if k == new_key else INK, font=f)
        y = 26
        t = tile_bg(120, 124)
        t.alpha_composite(icon(k, 96), (12, 8))
        sheet.alpha_composite(t, (x + 6, y + 4))
        y += cell
        sheet.alpha_composite(icon(k, 96), (x + 18, y + 18))
        y += cell
        g = icon(k, 96)
        grey = ImageOps.grayscale(g.convert("RGB")).convert("RGBA")
        grey.putalpha(g.getchannel("A"))
        sheet.alpha_composite(grey, (x + 18, y + 18))
        y += cell
        sheet.alpha_composite(icon(k, 48), (x + 42, y + 14))
        if k == new_key:
            dr.rectangle((x + 1, 24, x + cell - 2, sheet.height - 2), outline=(180, 60, 40), width=2)
    for r, lab in enumerate(rows):
        dr.text((8, 26 + r * cell + (cell // 2 - 8 if r < 3 else 30)), lab, fill=INK, font=f)
    sheet.convert("RGB").save(out_path)
    print(out_path, sheet.size)


if __name__ == "__main__":
    main(*sys.argv[1:4])
