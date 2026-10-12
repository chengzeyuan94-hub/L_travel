#!/bin/zsh
set -e
TASK_TOOLS_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
TASK_PROJECT_DIR="$(dirname -- "$TASK_TOOLS_DIR")"
exec /Applications/Godot.app/Contents/MacOS/Godot \
  --path "$TASK_PROJECT_DIR" \
  res://tools/merchant_tripo_integration_review_20260923.tscn
