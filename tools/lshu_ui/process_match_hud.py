"""对局界面（2026-09-26「旅行L叔」重设计）零件：art-src/match-hud-v1/kit 里 image 2.5 生成的透明零件
（参考 ui-concepts-lshu-20260925 的 04_turn / 05_trade / 06_win / 09_uikit）→ 裁透明边、按设计像素（1920×1080 下 1:1）缩放，
写进 assets/game/ui/match_hud/，九宫格边距写进 match_hud.json（贴图像素 = 设计像素）。
另从空口袋格抹掉加号，派生普通口袋格 pocket.png。
用法（仓库根目录）：uv run --with pillow --with numpy python3 tools/lshu_ui/process_match_hud.py"""
import json
import os
import numpy as np
from PIL import Image

SRC = "art-src/match-hud-v1/kit"
DST = "assets/game/ui/match_hud"
# 名字: (目标高度, 九宫格边距 [左,上,右,下] 占高度的比例；None = 整图缩放不做九宫格)
SPEC = {
    "pill": (72, (0.62, 0.3, 0.62, 0.3)),
    "stepbar": (64, (0.62, 0.3, 0.62, 0.3)),
    "chip": (100, (1.0, 0.3, 0.3, 0.3)),
    "satchel": (230, (0.95, 0.25, 0.3, 0.25)),
    "row": (104, (0.45, 0.35, 0.45, 0.35)),
    "row_sel": (104, (0.45, 0.35, 0.45, 0.35)),
    "winner_row": (96, (0.6, 0.3, 0.6, 0.3)),
    "plain_row": (96, (0.6, 0.3, 0.6, 0.3)),
    "badge_step": (56, (0.95, 0.3, 0.5, 0.3)),
    "pocket_empty": (140, None),
    "pocket_sel": (140, None),
    "tile": (150, None),
    "mat": (150, None),
    "icon_dice": (64, None),
    "icon_walk": (64, None),
    "icon_trade": (64, None),
    "icon_flag": (64, None),
    "rank_1": (96, None),
    "rank_2": (96, None),
    "rank_3": (96, None),
    "rank_4": (96, None),
}


def trim(im: Image.Image) -> Image.Image:
    a = np.asarray(im)[..., 3]
    ys, xs = np.where(a > 24)
    return im.crop((xs.min(), ys.min(), xs.max() + 1, ys.max() + 1)) if len(xs) else im


def pocket_from_empty(im: Image.Image) -> Image.Image:
    """口袋内部中段（加号所在）按列在上下两行之间线性插值，保留皮面的明暗渐变。"""
    a = np.asarray(im).astype(np.float32).copy()
    h, w = a.shape[:2]
    y0, y1 = int(h * 0.30), int(h * 0.74)
    x0, x1 = int(w * 0.24), int(w * 0.76)
    top = a[y0 - 1, x0:x1]
    bot = a[y1, x0:x1]
    for i, y in enumerate(range(y0, y1)):
        t = (i + 1) / (y1 - y0 + 1)
        a[y, x0:x1] = top * (1 - t) + bot * t
    return Image.fromarray(np.clip(a, 0, 255).astype(np.uint8))


def main() -> None:
    os.makedirs(DST, exist_ok=True)
    meta = {}
    for name, (h, nine) in SPEC.items():
        im = trim(Image.open(os.path.join(SRC, name + ".png")).convert("RGBA"))
        w = round(im.width * h / im.height)
        im = im.resize((w, h), Image.Resampling.LANCZOS)
        im.save(os.path.join(DST, name + ".png"), optimize=True)
        entry = {"size": [w, h]}
        if nine:
            entry["nine"] = [round(nine[0] * h), round(nine[1] * h), round(nine[2] * h), round(nine[3] * h)]
        meta[name] = entry
        if name == "pocket_empty":
            p = pocket_from_empty(im)
            p.save(os.path.join(DST, "pocket.png"), optimize=True)
            meta["pocket"] = {"size": [w, h]}
    # 已有 L叔 零件的 1× 副本：市集大面板（lshu_setup/panel_satchel 2×）、对话泡泡（lshu_title/bubble 2×）
    for src, name, nine2x in [
        ("assets/game/ui/lshu_setup/panel_satchel.png", "panel_satchel", [120, 120, 120, 120]),
        ("assets/game/ui/lshu_title/bubble.png", "bubble", [100, 60, 60, 96]),
    ]:
        im = Image.open(src).convert("RGBA")
        im = im.resize((im.width // 2, im.height // 2), Image.Resampling.LANCZOS)
        im.save(os.path.join(DST, name + ".png"), optimize=True)
        meta[name] = {"size": [im.width, im.height], "nine": [v // 2 for v in nine2x]}
    with open(os.path.join(DST, "match_hud.json"), "w") as f:
        json.dump(meta, f, ensure_ascii=False, indent=1)
    print(json.dumps(meta, ensure_ascii=False))


if __name__ == "__main__":
    main()
