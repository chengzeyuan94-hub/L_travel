#!/bin/bash
# plan_smoke.sh <outdir> — WP2 集成前的冒烟（DESIGN 4.4 的驱动先做好，正式模拟留到集成后）：
# 内存覆盖层（mode=memory），B1 / B3 / B7 三张图 × 三种真人代理 × 2 人 36 轮，每组约 50 局，加原版同种子对照；
# 另跑少量 3 人 24 轮、4 人 18 轮、三档电脑同桌、S6 万里对手、不限时（正式 AI、不死等 AI）各一小组，只为验证每个指标都算得出来。
# 样本远小于 4.4 的要求，不作验收，也不写白名单。
# 最后跑 analyze.py（--smoke）：出报告，并做代理自检——原版上三种代理逐局相同；地图上 avoid_new 的「真人回合原地结束」
# 比例不超过 proxy_same + 5 个百分点。自检或 S1 不过时退出码非 0。
set -u
OUT="$1"; mkdir -p "$OUT"
HERE="$(cd "$(dirname "$0")" && pwd)"
export SILKROAD_WORKTREE="${SILKROAD_WORKTREE:-$(cd "$HERE/../../.." && pwd)}"
python3 "$HERE/emit_nostall.py" "$OUT/ai_policy_nostall.gd" || exit 1
python3 "$HERE/emit_avoid_new.py" "$OUT/ai_policy_avoid_new.gd" || exit 1
NS="nostall_path=$OUT/ai_policy_nostall.gd"
AV="avoid_path=$OUT/ai_policy_avoid_new.gd"
F=2026100100; N=50; CH=${SIM_CHUNKS:-5}
for PX in same avoid_new best_loop; do
  "$HERE/run_batch.sh" "$OUT" "base_HA_${PX}" $CH $N $F map=base seats=HA diffs=shanhai proxy=$PX rounds=36 $AV
  for M in B1 B3 B7; do
    "$HERE/run_batch.sh" "$OUT" "${M}_HA_${PX}" $CH $N $F map=$M seats=HA diffs=shanhai proxy=$PX rounds=36 $AV
  done
done
for M in base B1; do
  "$HERE/run_batch.sh" "$OUT" "${M}_HAA_same" $CH 30 $F map=$M seats=HAA diffs=shanhai proxy=same rounds=24
  "$HERE/run_batch.sh" "$OUT" "${M}_HAAA_same" $CH 30 $F map=$M seats=HAAA diffs=shanhai proxy=same rounds=18
  "$HERE/run_batch.sh" "$OUT" "${M}_HA_same_vwanli" $CH 30 $F map=$M seats=HA diffs=wanli proxy=same rounds=36
  "$HERE/run_batch.sh" "$OUT" "${M}_AAA_tiers" $CH 30 $F map=$M seats=AAA diffs=qingzhuang,shanhai,wanli proxy=same rounds=24
  "$HERE/run_batch.sh" "$OUT" "${M}_HA_nostall_untimed" $CH 20 $F map=$M seats=HA diffs=shanhai rounds=0 policy=nostall $NS
  "$HERE/run_batch.sh" "$OUT" "${M}_HA_formal_untimed" $CH 20 $F map=$M seats=HA diffs=shanhai proxy=same rounds=0
done
python3 "$HERE/analyze.py" "$OUT" --report "$OUT/report.md" --summary "$OUT/summary.jsonl" --smoke \
  --title "自制地图 AI 对局模拟 · 冒烟（集成前）"
RC=$?
echo "PLAN_SMOKE_DONE $OUT rc=$RC"
exit $RC
