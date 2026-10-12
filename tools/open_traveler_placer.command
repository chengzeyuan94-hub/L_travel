#!/bin/zsh
# 旅人场景摆放编辑器。双击即可打开。
set -e
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
exec "$GODOT" --path "$ROOT" res://scenes/traveler/traveler_placer.tscn -- --view=changan --dusk --far
