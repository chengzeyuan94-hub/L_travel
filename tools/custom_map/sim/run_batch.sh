#!/bin/bash
# run_batch.sh <outdir> <tag> <chunks> <seeds_total> <first_seed> [sim_run 参数 key=value ...]
# 把 seeds_total 局切成 chunks 个并行的无头 Godot 进程；每个进程写 <outdir>/<tag>_c<k>.jsonl，日志 <outdir>/<tag>_c<k>.log。
# 每个进程先写一份 <outdir>/<tag>_c<k>.plan（这一块应当跑哪些种子），analyze.py 按它核对：进程崩溃或中途退出少写的局
# 一律算 S1 失败，不会因为配对取交集而悄悄变成小样本。
# 每个进程用自己的 HOME（<outdir>/home/<tag>_c<k>），不碰真实的 ShanheLvren/ 目录。
# 环境变量：SILKROAD_WORKTREE（仓库或 worktree 根，必填）、GODOT（默认 /Applications/Godot.app/Contents/MacOS/Godot）。
set -u
OUT="$1"; TAG="$2"; CH="$3"; TOTAL="$4"; FIRST="$5"; shift 5
WT="${SILKROAD_WORKTREE:?set SILKROAD_WORKTREE to the repo/worktree root}"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
mkdir -p "$OUT/home"
PER=$(( (TOTAL + CH - 1) / CH ))
for ((i=0;i<CH;i++)); do
  START=$(( FIRST + i*PER ))
  N=$PER
  if (( i*PER + PER > TOTAL )); then N=$(( TOTAL - i*PER )); fi
  if (( N <= 0 )); then continue; fi
  echo "tag=$TAG chunk=$i first=$START seeds=$N jsonl=${TAG}_c$i.jsonl" > "$OUT/${TAG}_c$i.plan"
  H="$OUT/home/${TAG}_c$i"; mkdir -p "$H"
  ( cd "$WT" && HOME="$H" "$GODOT" --headless --path . --script res://tools/custom_map/sim/sim_boot.gd -- \
      "$@" seeds=$N first=$START tag=$TAG out="$OUT/${TAG}_c$i.jsonl" > "$OUT/${TAG}_c$i.log" 2>&1 ) &
done
wait
grep -h "SIM_DONE\|SIM_FATAL\|SCRIPT ERROR" "$OUT/${TAG}"_c*.log | sed "s/^/[$TAG] /"
