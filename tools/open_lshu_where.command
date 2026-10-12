#!/bin/zsh
# 旅人模式第四幕「L叔在哪儿」· 正常玩（真实时钟，真实存档）。
# 放着就行：他按自己的钟换地方，偶尔寄明信片。
# 操作：点右下角小邮票看明信片（点卡片翻面，点空白处或 Esc 收起）；按 L 翻旅行本；
#      点 L叔 他会鞠躬并拍一张；双击画面镜头凑近他 8 秒。
# 存档：~/Library/Application Support/ShanheLvren/lshu_where/（明信片 JPG 在 postcards/ 里）
set -e
repo="$(cd -- "$(dirname -- "$0")/.." && pwd)"
exec /Applications/Godot.app/Contents/MacOS/Godot --path "$repo" res://scenes/traveler/lshu_main.tscn
