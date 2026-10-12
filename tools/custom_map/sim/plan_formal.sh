#!/bin/bash
# plan_formal.sh <outdir> <overlay_dir> — 正式模拟（DESIGN 4.4），WP1 集成之后才能跑：
# 走真实加载路径（mode=real：CustomMapLoader.remember → 带地图选项 prepare_new_game），每张地图一个 lshu.custom_map.v1 文件，
# 由目录的预设位、默认原型和默认特产生成（B1–B8 叫 B1.json … B8.json，A 档其余接法随意命名）。
# 样本量照 4.4：B 档 S2/S3/S6 每种代理 2000、S7 400、S8 600、S11 2000；A 档 S2 600、S3 400、S7 200。
# 跑完：python3 analyze.py <outdir> --report reports/custom_map_sim/<日期>/report.md --summary …/summary.jsonl \
#          --whitelist data/custom_map/validated_topologies_v1.json
# 成本（4.4 的估计）：B 档约 30 CPU 小时 + 原版对照 5 CPU 小时；A 档每种接法约 2600 CPU 秒。SIM_CHUNKS 按机器核数调。
#
# mode=real 的每次运行都带 --catalogue-allow-draft：5.3 的第 5 步（正式模拟）排在 WP6b 之前，那时目录条目都还是 draft，
# 不带这个开关 CustomMapLoader.remember 会以 E_ARCHETYPE 拒收、整批 SIM_FATAL。WP6b 发布（目录条目变成 shipped）之后去掉。
# 银库 k 一律用参数文件里的值（不传 bank=）；S7 需要标定时另跑、另出报告，那批数据 analyze 不拿来写白名单。
set -u
OUT="$1"; OV="$2"; mkdir -p "$OUT"
HERE="$(cd "$(dirname "$0")" && pwd)"
export SILKROAD_WORKTREE="${SILKROAD_WORKTREE:-$(cd "$HERE/../../.." && pwd)}"
python3 "$HERE/emit_nostall.py" "$OUT/ai_policy_nostall.gd" || exit 1
python3 "$HERE/emit_avoid_new.py" "$OUT/ai_policy_avoid_new.gd" || exit 1
NS="nostall_path=$OUT/ai_policy_nostall.gd"
AV="avoid_path=$OUT/ai_policy_avoid_new.gd"
DRAFT="--catalogue-allow-draft"     # WP6b 发布后去掉
F=2026100100; CH=${SIM_CHUNKS:-16}
run_set () {   # run_set <tag前缀> <tier B|A> <map 参数...>
  local P="$1"; local TIER="$2"; shift 2
  local N2=2000 N3=2000 N7=400
  if [ "$TIER" = "A" ]; then N2=600; N3=400; N7=200; fi
  for PX in same avoid_new best_loop; do
    "$HERE/run_batch.sh" "$OUT" "${P}_HA_${PX}" $CH $N2 $F "$@" seats=HA diffs=shanhai proxy=$PX rounds=36 $AV
    "$HERE/run_batch.sh" "$OUT" "${P}_HAA_${PX}" $CH $N3 $F "$@" seats=HAA diffs=shanhai proxy=$PX rounds=24 $AV
    "$HERE/run_batch.sh" "$OUT" "${P}_HAAA_${PX}" $CH $N3 $F "$@" seats=HAAA diffs=shanhai proxy=$PX rounds=18 $AV
    if [ "$TIER" = "B" ]; then
      "$HERE/run_batch.sh" "$OUT" "${P}_HA_${PX}_vqing" $CH 2000 $F "$@" seats=HA diffs=qingzhuang proxy=$PX rounds=36 $AV
      "$HERE/run_batch.sh" "$OUT" "${P}_HA_${PX}_vwanli" $CH 2000 $F "$@" seats=HA diffs=wanli proxy=$PX rounds=36 $AV
    fi
  done
  for S in HA HAA HAAA; do
    # S7：所有座位（包括真人座位）都用「不死等」策略
    "$HERE/run_batch.sh" "$OUT" "${P}_${S}_nostall" $CH $N7 $F "$@" seats=$S diffs=shanhai rounds=0 policy=nostall $NS
  done
  if [ "$TIER" = "B" ]; then
    "$HERE/run_batch.sh" "$OUT" "${P}_HA_untimed" $CH 600 $F "$@" seats=HA diffs=shanhai proxy=same rounds=0
    "$HERE/run_batch.sh" "$OUT" "${P}_AAA_tiers" $CH 2000 $F "$@" seats=AAA diffs=qingzhuang,shanhai,wanli proxy=same rounds=24
  fi
}
run_set base B map=base
for f in "$OV"/*.json; do
  name="$(basename "$f" .json)"
  case "$name" in B[1-8]) tier=B ;; *) tier=A ;; esac
  run_set "$name" "$tier" map="$name" mode=real overlay="$f" $DRAFT
done
echo "PLAN_FORMAL_DONE $OUT"
