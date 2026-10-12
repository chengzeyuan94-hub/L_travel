#!/bin/zsh
# run_good_icon.sh <key>：自制地图新特产的图标（docs/design/map-editor-20260930/DESIGN.md 3.13.5「特产图标」）。
# 照 tools/ui_icons/run_asset.sh 的做法：先发函数库 lib_lowpoly.py，再发 tools/custom_map/goods/<key>.py 建模，再渲染核对并导出。
# 与 run_asset.sh 的区别只有路径：
#   - ROOT 取本脚本所在的仓库（worktree）根目录，不写死主检出 /Users/chengzeyuan/Developer/SilkRoad，产物不会写错地方；
#   - 建模脚本读 tools/custom_map/goods/<key>.py；
#   - 图标写 assets/custom_map/goods/<key>.png（1024² 透明底，与 lshu_3d/icons 同一套灯光和相机），
#     核对图和 GLB 写 art-src/custom-map/goods/<key>/。
# 前提（DESIGN 3.13.5 / 5.4）：Carlos 开着 Blender，blender-mcp 在 localhost:9876 监听（tools/ui_icons/bl.py 连它）；
# 先有概念图和四视图，再建模。render_asset.py 只导出 icon_<key> 集合里的对象。
set -e
ROOT=${0:A:h:h:h}
k=$1
if [[ -z "$k" ]]; then
  echo "usage: $0 <specialty key>" >&2
  exit 2
fi
if [[ ! -f "$ROOT/project.godot" || ! -f "$ROOT/tools/ui_icons/bl.py" ]]; then
  echo "ROOT=$ROOT 不像本仓库的根目录（找不到 project.godot 或 tools/ui_icons/bl.py）" >&2
  exit 2
fi
if [[ ! -f "$ROOT/tools/custom_map/goods/$k.py" ]]; then
  echo "找不到建模脚本 $ROOT/tools/custom_map/goods/$k.py" >&2
  exit 2
fi
mkdir -p "$ROOT/assets/custom_map/goods" "$ROOT/art-src/custom-map/goods/$k"
T=$(mktemp -t lshu_good_icon).py
{ cat $ROOT/tools/ui_icons/lib_lowpoly.py; echo; echo "KEY = '$k'"; cat $ROOT/tools/custom_map/goods/$k.py; } > $T
python3 $ROOT/tools/ui_icons/bl.py $T --timeout 300 > /dev/null
{ echo "KEY = '$k'"; echo "OUT_ICON = '$ROOT/assets/custom_map/goods/$k.png'"; echo "OUT_DOC = '$ROOT/art-src/custom-map/goods/$k'"; echo "OUT_GLB = '$ROOT/art-src/custom-map/goods/$k/$k.glb'"; cat $ROOT/tools/ui_icons/render_asset.py; } > $T
python3 $ROOT/tools/ui_icons/bl.py $T --timeout 600 | grep "^{'key'"
rm -f $T
