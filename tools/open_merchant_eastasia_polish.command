#!/bin/zsh
set -e
TASK_TOOLS_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
TASK_PROJECT_DIR="$(dirname -- "$TASK_TOOLS_DIR")"
# Double-click opens the polished presentation; explicit arguments keep script defaults.
if (( $# == 0 )); then
  set -- --presentation --light-contrast --relief-lighting
fi
exec /Applications/Godot.app/Contents/MacOS/Godot \
  --path "$TASK_PROJECT_DIR" \
  res://tools/merchant_eastasia_polish_review_20260923.tscn -- "$@"
