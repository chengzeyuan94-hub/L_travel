#!/bin/zsh
# 旅人模式第四幕「L叔在哪儿」· 60 倍速预览：8 分钟看完一整天。
# 用单独的调试存档（~/Library/Application Support/ShanheLvren/lshu_where_scaled/），不影响正式存档。
# 开发键：F1 切光照（跟时钟 / 晨 / 昼 / 昏 / 夜），F2 冻结动作，F3 / F4 预览池里下一块 / 上一块。
set -e
repo="$(cd -- "$(dirname -- "$0")/.." && pwd)"
exec /Applications/Godot.app/Contents/MacOS/Godot --path "$repo" res://scenes/traveler/lshu_main.tscn -- --lshu-clock-scale=60 --lshu-dev
