#!/bin/zsh
# run_asset.sh <key>：先发函数库，再发 tools/ui_icons/assets/<key>.py 建模，再渲染核对并导出。
set -e
ROOT=/Users/chengzeyuan/Developer/SilkRoad
k=$1
T=$(mktemp -t lshu_icon).py
{ cat $ROOT/tools/ui_icons/lib_lowpoly.py; echo; echo "KEY = '$k'"; cat $ROOT/tools/ui_icons/assets/$k.py; } > $T
python3 $ROOT/tools/ui_icons/bl.py $T --timeout 300 > /dev/null
{ echo "KEY = '$k'"; echo "OUT_ICON = '$ROOT/assets/game/ui/lshu_3d/icons/$k.png'"; echo "OUT_DOC = '$ROOT/docs/design/shanhe-luren/ui-3d-assets-20260925/$k'"; echo "OUT_GLB = '$ROOT/assets/game/ui/lshu_3d/source/glb/$k.glb'"; cat $ROOT/tools/ui_icons/render_asset.py; } > $T
python3 $ROOT/tools/ui_icons/bl.py $T --timeout 600 | grep "^{'key'"
rm -f $T
