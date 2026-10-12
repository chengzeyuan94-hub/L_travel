#!/bin/zsh
# 第四幕「L叔在哪儿」· full offline chain: props (optional) -> pool tiles -> Godot import -> precompute.
#   tools/traveler/lshu/bake/run_bake.sh            bake every pool tile
#   tools/traveler/lshu/bake/run_bake.sh --assets   also re-convert the 140 prop GLBs first
#   tools/traveler/lshu/bake/run_bake.sh --pool=<id>,<id>
#   tools/traveler/lshu/bake/run_bake.sh --pool --pool-file=/path/staged_pool.json
#       bake a staged pool list (make_pool.py --out=...) and install it as data/traveler/lshu/pool.json only after
#       every step passed, so the live pool never names a tile that is not baked yet
#   --log-dir=DIR   also keep the full log of every step as DIR/bake_step<N>.log
# Strict: any ERROR / WARNING line or nonzero exit stops the chain.
set -u
ROOT="${0:A:h}/../../../.."
cd "$ROOT" || exit 1
NODE="${NODE_BIN:-$HOME/.local/bin/node}"
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
POOL="--pool"; ASSETS=""; TILES=""; POOL_FILE=""; LOG_DIR=""; STEP_N=0
for a in "$@"; do
  case "$a" in
    --assets) ASSETS="--assets" ;;
    --pool=*) POOL="$a"; TILES="--tiles=${a#--pool=}" ;;
    --pool-file=*) POOL_FILE="${a#--pool-file=}"; POOL_FILE="${POOL_FILE:A}" ;;
    --log-dir=*) LOG_DIR="${a#--log-dir=}"; LOG_DIR="${LOG_DIR:A}"; mkdir -p "$LOG_DIR" ;;
  esac
done
PF=()
[[ -n "$POOL_FILE" ]] && PF=("--pool-file=$POOL_FILE")
# The editor-side --import reopens the scenes of the user's editor layout; one of them raises
# "Attempting to parent and popup a dialog that already has a parent" (window.cpp), unrelated to act 4.
# That single known editor line is reported but not counted; every other ERROR / WARNING line fails the step.
KNOWN_EDITOR_LINE='Attempting to parent and popup a dialog that already has a parent'
step() {
  local log; log="$("$@" 2>&1)"; local rc=$?
  STEP_N=$((STEP_N + 1))
  [[ -n "$LOG_DIR" ]] && print -r -- "\$ $*"$'\n'"$log"$'\n'"exit $rc" > "$LOG_DIR/bake_step$STEP_N.log"
  print -r -- "$log" | grep -v '^\s*$' | tail -40
  if print -r -- "$log" | grep -q "$KNOWN_EDITOR_LINE"; then print "NOTE: known editor-layout line seen (not counted): $KNOWN_EDITOR_LINE"; fi
  if [[ $rc -ne 0 ]] || print -r -- "$log" | grep -v "$KNOWN_EDITOR_LINE" | grep -q 'ERROR\|WARNING'; then print "STEP FAILED ($rc): $*"; exit 1; fi
}
step "$NODE" tools/traveler/lshu/bake/bake_recipes.cjs $ASSETS "$POOL" $PF
step "$GODOT" --headless --path . --import
step "$GODOT" --headless --path . --script res://tools/traveler/lshu/bake/precompute_tiles.gd -- $TILES $PF
if [[ -n "$POOL_FILE" ]]; then
  cp "$POOL_FILE" data/traveler/lshu/pool.json.tmp && mv data/traveler/lshu/pool.json.tmp data/traveler/lshu/pool.json || { print "STEP FAILED: install $POOL_FILE"; exit 1; }
  print "POOL_INSTALLED $POOL_FILE -> data/traveler/lshu/pool.json"
fi
print "BAKE_CHAIN_OK"
