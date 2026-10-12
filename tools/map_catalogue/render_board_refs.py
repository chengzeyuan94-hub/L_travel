# Render the DERIVED (building-only) look of shipped board cities as style references for the archetype chain.
#
#   Blender -b --factory-startup --python tools/map_catalogue/render_board_refs.py -- chenla changan [...]
#   Blender -b --factory-startup --python tools/map_catalogue/render_board_refs.py -- all
#
# Reads assets/merchant_board_claude/cities/<city>.glb (the shipped building-only GLBs) and writes
# art-src/custom-map-catalogue/refs/derived/<city>.png, 800x600, with the exact camera and light of the original
# DERIVED renders (art-src/merchant-board-claude/cities/*/render_preview.py "q34": front-left, 35 deg, ortho,
# grey 0.62 world, one sun). A fresh render of chenla is pixel-identical to
# docs/design/merchant-board-claude-20260923/cities/chenla.png, which lives only in the main checkout.
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import lib_city_lowpoly as L

ALL = ["rome", "constantinople", "cairo", "jeddah", "aden", "baghdad", "panti", "yumenguan", "delhi", "simhala",
       "changan", "dagon", "chenla", "quanzhou", "geumseong", "heijokyo"]
args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
cities = ALL if args == ["all"] else args
out_dir = os.path.join(ROOT, "art-src/custom-map-catalogue/refs/derived")
for c in cities:
    L.import_glb(os.path.join(ROOT, "assets/merchant_board_claude/cities", f"{c}.glb"))
    info = L.render_view(os.path.join(out_dir, f"{c}.png"), "q34", 800, 600)
    print("REF", c, info["ortho_scale"], flush=True)
