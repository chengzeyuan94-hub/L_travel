#!/bin/zsh
# godot_import_icons.sh <key> [<key> ...]
#
# Imports assets/game/ui/lshu_3d/icons/<key>.png and assets/game/goods/good_<key>_128.png into the
# Godot project so that lshu_icons.gd good() / GameData's fallback find them (ResourceLoader.exists
# needs the .import sidecar), with the SAME import settings as the shipped icons (mipmaps on — the
# HUD draws the 1024 px icon at 48–120 px, so without mipmaps it aliases).
#
# Godot has no single-file import from the command line: `--import` scans the whole project, and in
# this worktree that also writes ~230 .import/.uid sidecars next to untracked files that were never
# imported here (art-src/motion/**, tools/motion/**, tests/*.gd). Those are removed again afterwards
# (only sidecars that appeared during this run and are not ours); the list goes to the log.
set -e
setopt no_nomatch
ROOT=${0:A:h:h:h}
GODOT=${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}
SCRATCH=${SCRATCH:-${TMPDIR:-/tmp}/map_catalogue_godot}
mkdir -p $SCRATCH/home
cd $ROOT
[[ $# -eq 0 ]] && { echo "usage: $0 <key> [<key> ...]"; exit 2 }
ours=()
for k in "$@"; do
  ours+=("assets/game/ui/lshu_3d/icons/$k.png.import" "assets/game/goods/good_${k}_128.png.import")
done
STAMP=$SCRATCH/stamp; : > $STAMP; sleep 1
git -c core.quotePath=false status --porcelain --untracked-files=all | sed 's/^?? //' | sort > $SCRATCH/before.txt

run_import() { HOME=$SCRATCH/home "$GODOT" --headless --audio-driver Dummy --path . --import > $SCRATCH/import.log 2>&1 }
run_import
again=0
for f in $ours; do
  [[ -f $f ]] || { echo "missing $f after import (is the PNG there?)"; exit 1 }
  if grep -q '^mipmaps/generate=false' $f; then
    sed -i '' 's/^mipmaps\/generate=false$/mipmaps\/generate=true/' $f; again=1
  fi
done
[[ $again -eq 1 ]] && run_import

git -c core.quotePath=false status --porcelain --untracked-files=all | sed 's/^?? //' | sort > $SCRATCH/after.txt
: > $SCRATCH/removed_sidecars.txt
comm -13 $SCRATCH/before.txt $SCRATCH/after.txt | while read -r f; do
  [[ $f == *.import || $f == *.uid ]] || continue
  [[ ${ours[(Ie)$f]} -gt 0 ]] && continue
  [[ $f == tools/map_catalogue/* ]] && continue
  [[ $f -nt $STAMP ]] || continue
  rm -f -- "$f"; echo "$f" >> $SCRATCH/removed_sidecars.txt
done
echo "imported: $ours"
grep -h '^mipmaps/generate' $ours | sort | uniq -c
echo "removed $(wc -l < $SCRATCH/removed_sidecars.txt | tr -d ' ') stray sidecars (list: $SCRATCH/removed_sidecars.txt)"
