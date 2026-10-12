#!/bin/zsh
# 《山河旅人》商旅模式 · Claude 3D 棋盘对局（玩家 vs 电脑）。参数：--quick 跳过选色；--showcase 四色电脑自动对局
set -e
TASK_TOOLS_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
TASK_PROJECT_DIR="$(dirname -- "$TASK_TOOLS_DIR")"
exec /Applications/Godot.app/Contents/MacOS/Godot --path "$TASK_PROJECT_DIR" res://tools/merchant_board_claude_play.tscn -- "$@"
