#!/bin/zsh
# Act 4 「L叔在哪儿」 director tests.
#   1. headless: tools/traveler/lshu/tests/test_director.gd      -> LSHU_DIRECTOR_TESTS passed=N failed=M
#   2. windowed smoke (window slot 24, fresh save in the out dir): tools/traveler/lshu/tests/director_smoke.gd
#                                                                 -> LSHU_DIRECTOR_SMOKE checks=C failed=F
# Strict log rule: any line with ERROR or WARNING fails (except the known editor import line).
# Pass --headless-only to skip the windowed smoke. Exit code is non-zero when anything failed.
GODOT=${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}
ROOT=${0:A:h:h:h:h:h}
OUT=${LSHU_DIRECTOR_SMOKE_OUT:-$ROOT/docs/reports/traveler-lshu-integrate-20260924/director_smoke}
LOG_DIR=$(mktemp -d)
"$GODOT" --headless --path "$ROOT" --script res://tools/traveler/lshu/tests/test_director.gd > "$LOG_DIR/test_director.log" 2>&1
unit=$?
grep -E '^(FAIL|LSHU_DIRECTOR_TESTS)' "$LOG_DIR/test_director.log"
unit_err=$(grep -E 'ERROR|WARNING' "$LOG_DIR/test_director.log" | grep -v 'Attempting to parent and popup a dialog' | wc -l | tr -d ' ')
smoke=0
smoke_err=0
if [[ "$1" != "--headless-only" ]]; then
	mkdir -p "$OUT"
	"$GODOT" --path "$ROOT" --script res://tools/traveler/lshu/tests/director_smoke.gd -- --park=24 --out="$OUT" > "$OUT/director_smoke.log" 2>&1
	smoke=$?
	grep -E '^(FAIL|LSHU_DIRECTOR_SMOKE)' "$OUT/director_smoke.log"
	smoke_err=$(grep -E 'ERROR|WARNING' "$OUT/director_smoke.log" | grep -v 'Attempting to parent and popup a dialog' | wc -l | tr -d ' ')
fi
echo "LSHU_DIRECTOR_SUMMARY unit_exit=$unit unit_log_errors=$unit_err smoke_exit=$smoke smoke_log_errors=$smoke_err logs=$LOG_DIR"
[[ $unit -eq 0 && $unit_err -eq 0 && $smoke -eq 0 && $smoke_err -eq 0 ]]
