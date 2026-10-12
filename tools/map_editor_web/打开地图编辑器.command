#!/bin/zsh
# 盘橐城 · 网页地图编辑器。双击这个文件即可，不用命令行。
set -e
ROOT="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
PY="$(command -v python3 || echo /usr/bin/python3)"
PORT="${PORT:-8791}"
"$PY" "$ROOT/tools/map_editor_web/serve.py" &
SRV=$!
sleep 1.2
open "http://127.0.0.1:$PORT"
echo ""
echo "编辑器开在 http://127.0.0.1:$PORT"
echo "用完把这个终端窗口关掉就行。"
wait $SRV
