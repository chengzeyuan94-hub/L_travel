#!/bin/zsh
set -e
EDITOR_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
EDITOR_GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
exec "$EDITOR_GODOT" --path "$EDITOR_ROOT" res://scenes/editor/map_editor.tscn "$@"
