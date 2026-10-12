#!/bin/zsh
# 「旅行L叔」 map-editor catalogue — archetype MODEL chain, steps 3-4 (after 01-concept.png and 02-fourview.png exist
# and art-src/custom-map-catalogue/archetypes/<id>/build.py has been written against the four-view).
#
#   zsh tools/map_catalogue/archetype_chain.sh <id>            # model + Blender renders + Godot check
#   zsh tools/map_catalogue/archetype_chain.sh <id> model      # only step 3 (Blender)
#   zsh tools/map_catalogue/archetype_chain.sh <id> godot      # only step 4 (Godot)
#
# Blender runs headless and fresh (--factory-startup): it never talks to the Blender window on localhost:9876.
# Godot needs a real renderer (a --headless run saves blank images), so it opens a small window for ~10 s, with the
# dummy audio driver and HOME pointed at a scratch folder (user:// data, editor settings stay out of ~/Library).
# Only the Godot process started here is ever stopped.
set -u
ID=${1:?usage: archetype_chain.sh <archetype id> [model|godot]}
STEP=${2:-all}
ROOT=${0:A:h:h:h}
BLENDER=${BLENDER:-/Users/chengzeyuan/Applications/Blender-5.2.1.app/Contents/MacOS/Blender}
GODOT=${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}
# MAP_CATALOGUE_SCRATCH should be the session's scratchpad (Godot's HOME and the logs go there); the fallback is
# only for a quick manual run.
SCRATCH=${MAP_CATALOGUE_SCRATCH:-${TMPDIR:-/tmp}/map_catalogue_scratch}
mkdir -p $SCRATCH/godot_home
LOG=$SCRATCH/archetype_$ID

if [[ $STEP == all || $STEP == model ]]; then
  $BLENDER -b --factory-startup --python $ROOT/tools/map_catalogue/run_archetype_model.py -- $ID > $LOG.blender.log 2>&1
  grep -E "^\[archetype\] (built|exported|RESULT|ACCEPT_OK|ACCEPT_FAIL)" $LOG.blender.log
  if grep -qE "Traceback|Error:" $LOG.blender.log; then
    grep -E -A12 "Traceback" $LOG.blender.log | head -40
    echo "BLENDER FAILED, log: $LOG.blender.log"; exit 1
  fi
  ACCEPT_FAILED=0
  grep -q "^\[archetype\] ACCEPT_FAIL" $LOG.blender.log && ACCEPT_FAILED=1
fi

if [[ $STEP == all || $STEP == godot ]]; then
  HOME=$SCRATCH/godot_home $GODOT --path $ROOT --audio-driver Dummy --resolution 480x270 \
      res://tools/map_catalogue/godot_ortho_check.tscn -- --id=$ID > $LOG.godot.log 2>&1 &
  PID=$!
  for i in $(seq 1 120); do sleep 1; kill -0 $PID 2>/dev/null || break; done
  if kill -0 $PID 2>/dev/null; then kill $PID; echo "GODOT TIMED OUT (killed pid $PID, the one started here)"; fi
  grep -E "GODOT_ORTHO_CHECK_DONE|SCRIPT ERROR|ERROR:|Parse Error" $LOG.godot.log | head -20
  grep -q GODOT_ORTHO_CHECK_DONE $LOG.godot.log || { echo "GODOT CHECK FAILED, log: $LOG.godot.log"; exit 1; }
fi
if [[ ${ACCEPT_FAILED:-0} == 1 ]]; then
  echo "MODEL ACCEPTANCE FAILED (aspect / plinth / night-glow materials): see acceptance in $ROOT/art-src/custom-map-catalogue/archetypes/$ID/model-report.json"
  exit 1
fi
