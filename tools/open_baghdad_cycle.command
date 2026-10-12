#!/bin/zsh
# 巴格达旅人 · 循环实机窗口：下雨 → 开花发光 → 黄昏晚霞 → 下雨。
# 按键：R 从头播  P 暂停  1–4 跳段  H 隐藏标题栏时间。
set -e
repo="$(cd -- "$(dirname -- "$0")/.." && pwd)"
exec /Applications/Godot.app/Contents/MacOS/Godot \
  --path "$repo" \
  --script res://tools/traveler/baghdad/cycle/review_cycle.gd \
  --audio-driver Dummy -- --view=baghdad --lookdev=m_grass --no-ambience
