#!/bin/zsh
# 「旅行L叔」开场预览：默认开场是会动的旅行插画（点 L叔 试试）。
# 按赢了 12 局显示（只是预览，不写存档）；左下「换一个」可以在旅行L叔 / 长安 / 盘橐之间切。
# 想看全部解锁，把 --lshu-wins=12 换成 --lshu-unlock-all。
set -e
repo="$(cd -- "$(dirname -- "$0")/.." && pwd)"
exec /Applications/Godot.app/Contents/MacOS/Godot --path "$repo" -- --lshu-wins=12
