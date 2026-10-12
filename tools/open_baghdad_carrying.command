#!/bin/zsh
set -e
baghdad_carrying_repo="$(cd -- "$(dirname -- "$0")/.." && pwd)"
exec /Applications/Godot.app/Contents/MacOS/Godot \
  --path "$baghdad_carrying_repo" \
  --script res://tools/traveler/baghdad/foreground/review_carrying.gd \
  --audio-driver Dummy -- \
  --view=baghdad --carrying-live \
  --carrying-output=res://docs/reports/traveler-baghdad-001/carrying-20260923/blossom-live
