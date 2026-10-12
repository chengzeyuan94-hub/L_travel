#!/bin/zsh
# Act 4 「L叔在哪儿」 accelerated day run (tools/traveler/lshu/tests/day_run.gd) + contact sheet.
#   run_day_run.sh [out dir] [sheet png] [extra day_run args...]
# Defaults: out = docs/reports/traveler-lshu-integrate-20260924/day_run, sheet = docs/reports/traveler-lshu-integrate-20260924/day_48.png,
# window slot --park=24. Strict log rule: any line with ERROR or WARNING fails the run (except the known editor import
# line), as does a non-zero exit. Last line: LSHU_DAY_RUN_SUMMARY exit=E log_errors=N failed=F
GODOT=${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}
ROOT=${0:A:h:h:h:h:h}
REPORT=$ROOT/docs/reports/traveler-lshu-integrate-20260924
OUT=${1:-$REPORT/day_run}
SHEET=${2:-$REPORT/day_48.png}
shift 2 2>/dev/null
mkdir -p "$OUT"
OUT=${OUT:A}
SHEET=${SHEET:A}
"$GODOT" --path "$ROOT" --script res://tools/traveler/lshu/tests/day_run.gd -- --park=24 --out="$OUT" "$@" > "$OUT/day_run.log" 2>&1
code=$?
log_errors=$(grep -E 'ERROR|WARNING' "$OUT/day_run.log" | grep -v 'Attempting to parent and popup a dialog' | wc -l | tr -d ' ')
grep -E '^(PASS|FAIL|LSHU_DAY_RUN)' "$OUT/day_run.log"
grep -E 'ERROR|WARNING' "$OUT/day_run.log" | grep -v 'Attempting to parent and popup a dialog' | head -20
$HOME/.local/bin/uv run -q --with pillow python "$ROOT/tools/traveler/lshu/tests/day_run_sheet.py" "$OUT" "$SHEET"
failed=$(grep -o 'failed=[0-9]*' "$OUT/day_run.log" | tail -1 | cut -d= -f2)
echo "LSHU_DAY_RUN_SUMMARY exit=$code log_errors=$log_errors failed=${failed:-?} log=$OUT/day_run.log sheet=$SHEET"
[[ $code -eq 0 && $log_errors -eq 0 ]]
