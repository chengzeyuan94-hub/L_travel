#!/bin/zsh
# run_icon_headless.sh <key> [--asset <asset.py>] [--out <dir>] [--match-live]
#
# Headless equivalent of tools/ui_icons/run_asset.sh: one background Blender process
# (--factory-startup, never the live Blender on localhost:9876) runs the unmodified
# tools/ui_icons/setup_studio.py + lib_lowpoly.py + <asset.py> + render_asset.py.
#
# Default (a custom-map specialty):
#   asset  art-src/custom-map-catalogue/specialties/<key>/asset.py
#   icon   assets/game/ui/lshu_3d/icons/<key>.png        (lshu_icons.gd good() picks it up)
#   ortho  art-src/custom-map-catalogue/specialties/<key>/03-blender-ortho.png
#   glb    art-src/custom-map-catalogue/specialties/<key>/<key>.glb
#   blend  art-src/custom-map-catalogue/specialties/<key>/<key>.blend  (editable source)
# --out <dir> sends ALL outputs (icon included) to <dir> instead, e.g. for the parity check:
#   zsh tools/map_catalogue/run_icon_headless.sh tea --asset tools/ui_icons/assets/tea.py --out /tmp/x
# --match-live reproduces the live-Blender placement quirk so that re-render is pixel-identical
# to the shipped PNG (see icon_headless.py); never use it for new assets.
set -e
setopt no_nomatch
ROOT=${0:A:h:h:h}
BLENDER=${BLENDER:-/Users/chengzeyuan/Applications/Blender-5.2.1.app/Contents/MacOS/Blender}
k=$1; shift
[[ -z "$k" ]] && { echo "usage: $0 <key> [--asset path] [--out dir]"; exit 2 }
ASSET=$ROOT/art-src/custom-map-catalogue/specialties/$k/asset.py
OUT=""; EXTRA=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --asset) ASSET=${2:A}; shift 2;;
    --out) OUT=${2:A}; shift 2;;
    --match-live) EXTRA+=(--match-live); shift;;
    *) echo "unknown arg $1"; exit 2;;
  esac
done
if [[ -n "$OUT" ]]; then
  ICON=$OUT/$k.png; DOC=$OUT; GLB=$OUT/$k.glb; BLEND=$OUT/$k.blend
else
  D=$ROOT/art-src/custom-map-catalogue/specialties/$k
  ICON=$ROOT/assets/game/ui/lshu_3d/icons/$k.png; DOC=$D; GLB=$D/$k.glb; BLEND=$D/$k.blend
fi
mkdir -p $DOC
LOG=$DOC/.blender-$k.log
"$BLENDER" -b --factory-startup --python-exit-code 1 --python $ROOT/tools/map_catalogue/icon_headless.py -- \
  --key $k --asset $ASSET --out-icon $ICON --out-doc $DOC --out-glb $GLB --out-blend $BLEND $EXTRA > $LOG 2>&1 || {
  echo "Blender failed, log: $LOG"; tail -30 $LOG; exit 1 }
grep "^{'key'\|^ICON_HEADLESS_RESULT" $LOG
rm -f $LOG
