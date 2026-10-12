#!/bin/zsh
# 旅人模式第二幕「盘橐旅人」· 实机窗口，默认清晨。
# 点篝火：清晨 ↔ 深夜 8 秒过渡（也可以按 1 / 2）；空格暂停动作。
set -e
repo="$(cd -- "$(dirname -- "$0")/.." && pwd)"
exec /Applications/Godot.app/Contents/MacOS/Godot --path "$repo" res://scenes/traveler/panti_main.tscn -- --view=panti --morning
