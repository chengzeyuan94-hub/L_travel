#!/bin/zsh
# 旅人模式第三幕「巴格达旅人」· 和开场「进入」开的完全一样：巴格达循环（下雨 → 点土豆开花发光 → 点土豆晚霞 → 点土豆下雨），有环境声，
# 左上角「‹ 返回」/ Esc 退出，底部一行提示（H 关掉 / 打开）。
# 要审片键（R 回到下雨、P 暂停、1 2 3 跳段）就在最后加 --lshu-dev；要老的单张 baghdad_main 预览用 capture_traveler.gd。
# （2026-09-27 夜测 TRV-14：以前这里开的是另一个旧场景，和开场里的不一样）
set -e
repo="$(cd -- "$(dirname -- "$0")/.." && pwd)"
exec /Applications/Godot.app/Contents/MacOS/Godot --path "$repo" res://tools/merchant_board_claude_play.tscn -- --lshu-act=baghdad --view=baghdad --lookdev=m_grass "$@"
