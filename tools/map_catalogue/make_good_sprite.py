"""128 px fallback goods sprite for a new specialty, normalised exactly like the shipped ones.

uv run --with pillow python tools/map_catalogue/make_good_sprite.py kaolin

The 15 shipped assets/game/goods/good_<id>_128.png were made by tools/import_yf064_goods_assets.py
(build_runtime_icon): crop the master to its alpha>32 bounds, Lanczos-scale so the longest side is
99 px, centre on a transparent 128x128 canvas, clean saturated-magenta resampling fringe, save PNG
with optimize=True. Their masters were an external 2D pack (silk-road-goods-pack/icons_384) that is
not in the repo and has no new items, so the master here is the 3D icon
assets/game/ui/lshu_3d/icons/<id>.png; the normalisation step is the shipped function itself,
imported unchanged.
"""
import json
import os
import sys
from pathlib import Path

sys.dont_write_bytecode = True  # importing the shipped tool must not leave tools/__pycache__ behind

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
from import_yf064_goods_assets import build_runtime_icon, sha256_file  # noqa: E402


def main(key):
    src = ROOT / "assets/game/ui/lshu_3d/icons" / f"{key}.png"
    out = ROOT / "assets/game/goods" / f"good_{key}_128.png"
    metrics = build_runtime_icon(src, out)
    print(json.dumps({"good_id": key, "sprite": f"res://assets/game/goods/good_{key}_128.png",
                      "source_asset": os.path.relpath(src, ROOT), "source_sha256": sha256_file(src),
                      "runtime_sha256": sha256_file(out), **metrics}))


if __name__ == "__main__":
    main(sys.argv[1])
