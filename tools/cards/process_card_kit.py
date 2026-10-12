"""城市卡 / 事件卡背 v2 零件（2026-09-26，按已认可的 L叔 界面概念图 02_picker / 07_unlock / 09_uikit 用 image 2.5 生成）。
把 art-src/cards-v2/kit/ 里选定的生成图裁掉透明边、缩到运行尺寸，写入 assets/game/ui/city_cards/v2/ 和 assets/game/ui/event_cards_v2/。
用法（仓库根目录）：uv run --with pillow --with numpy python3 tools/cards/process_card_kit.py"""
import os
import numpy as np
from PIL import Image

SRC = "art-src/cards-v2/kit"
CITY = "assets/game/ui/city_cards/v2"
EVENT = "assets/game/ui/event_cards_v2"
# 源文件 -> (目标路径, 目标宽, 目标高；None = 按宽等比)
SPEC = {
    "ribbon_b": (f"{CITY}/ribbon.png", 900, None),
    "ribbon_denim_b": (f"{CITY}/ribbon_denim.png", 900, None),
    "highlight_a": (f"{CITY}/highlight.png", 720, None),
    "tag_olive_a": (f"{CITY}/tag_olive.png", 240, None),
    "tag_camel_a": (f"{CITY}/tag_camel.png", 240, None),
    "postmark_b": (f"{CITY}/postmark.png", 300, None),
    "stamp_a": (f"{CITY}/stamp.png", 200, None),
    "badge_b": (f"{CITY}/badge.png", 160, None),
    "divider_a": (f"{CITY}/divider.png", 900, None),
    "paper_clean_city_a": (f"{CITY}/paper_1086x1448.png", 1086, 1448),
    "paper_clean_event_a": (f"{EVENT}/event_paper_768x1024.png", 768, 1024),
    "back_map_a": (f"{EVENT}/event_card_back_map_768x1024.png", 768, 1024),
}


def trim(im: Image.Image, pad: int = 4) -> Image.Image:
    a = np.asarray(im)[..., 3]
    ys, xs = np.where(a > 24)
    if len(xs) == 0:
        return im
    x0, y0 = max(0, xs.min() - pad), max(0, ys.min() - pad)
    x1, y1 = min(im.width, xs.max() + 1 + pad), min(im.height, ys.max() + 1 + pad)
    return im.crop((x0, y0, x1, y1))


def main() -> None:
    for name, (dst, w, h) in SPEC.items():
        im = trim(Image.open(os.path.join(SRC, name + ".png")).convert("RGBA"), 0 if h else 4)
        if h is None:
            h = round(im.height * w / im.width)
        im = im.resize((w, h), Image.Resampling.LANCZOS)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        im.save(dst, optimize=True)
        print(dst, im.size)


if __name__ == "__main__":
    main()
