#!/bin/zsh
# 「旅行L叔」商旅预览：从新开场点「商旅模式」进入新的「出发前准备」页，点「出发！」经过开局加载页「商队整装中…」进对局。
# 走的是预览入口 scenes/lshu_ui/lshu_preview_main.tscn（main.tscn 的副本，只把设置页换成新的），正式入口 main.tscn 不变。
# 按赢了 12 局显示开场（只是预览，不写存档）。
set -e
repo="$(cd -- "$(dirname -- "$0")/.." && pwd)"
exec /Applications/Godot.app/Contents/MacOS/Godot --path "$repo" res://scenes/lshu_ui/lshu_preview_main.tscn -- --lshu-wins=12
