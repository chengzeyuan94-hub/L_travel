#!/bin/zsh
set -e
baghdad_story_repo="$(cd -- "$(dirname -- "$0")/.." && pwd)"
exec /Applications/Godot.app/Contents/MacOS/Godot \
  --path "$baghdad_story_repo" \
  --script res://tools/traveler/baghdad/foreground/review_ab_story.gd \
  --audio-driver Dummy -- --view=baghdad --ab-live \
  --ab-output=res://docs/reports/traveler-baghdad-001/ab-story-20260923/live
