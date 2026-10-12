#!/bin/zsh
# 旅人模式第一幕「长安旅人」· 实机窗口，默认日暮。
# 点长安城门一带：白天 ↔ 夕照 切换（也可以点底部「日光 / 夕照」按钮）；H 隐藏界面；Esc 退出。
# 这是带 Atlas 开发面板的审片窗口；和开场「进入」一样的玩家版：tools/merchant_board_claude_play.tscn -- --lshu-act=changan --view=changan --far --dusk
set -e
repo="$(cd -- "$(dirname -- "$0")/.." && pwd)"
exec /Applications/Godot.app/Contents/MacOS/Godot --path "$repo" res://scenes/traveler/traveler_main.tscn -- --view=changan --far --dusk
