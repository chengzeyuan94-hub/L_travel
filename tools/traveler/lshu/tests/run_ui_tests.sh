#!/bin/zsh
# Act 4 「L叔在哪儿」 UI tests.
#   1. headless: tools/traveler/lshu/tests/test_ui.gd   -> LSHU_UI_TESTS passed=N failed=M
#   2. windowed harness (parks at slot 10, writes screenshots to docs/reports/traveler-lshu-ui-20260924/)
#                                                         -> LSHU_UI_HARNESS errors=N warnings=W checks=C failed=F
# Any engine ERROR / SCRIPT ERROR line in either run also counts as a failure.
# Pass --headless-only to skip the windowed harness. Exit code is non-zero when anything failed.
GODOT=${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}
# works under zsh and bash (the orchestrator calls these with bash)
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
LOG_DIR=$(mktemp -d)
"$GODOT" --headless --path "$ROOT" --script res://tools/traveler/lshu/tests/test_ui.gd > "$LOG_DIR/test_ui.log" 2>&1
unit=$?
grep -E '^(FAIL|METRIC|LSHU_UI_TESTS)' "$LOG_DIR/test_ui.log"
unit_err=$(grep -c -E '^(ERROR|SCRIPT ERROR)' "$LOG_DIR/test_ui.log")
harness=0
harness_err=0
if [[ "$1" != "--headless-only" ]]; then
	"$GODOT" --path "$ROOT" res://tools/traveler/lshu/tests/ui_harness.tscn > "$LOG_DIR/ui_harness.log" 2>&1
	harness=$?
	grep -E '^(FAIL|LSHU_UI_HARNESS)' "$LOG_DIR/ui_harness.log"
	harness_err=$(grep -c -E '^(ERROR|SCRIPT ERROR)' "$LOG_DIR/ui_harness.log")
fi
echo "LSHU_UI_SUMMARY unit_exit=$unit unit_engine_errors=$unit_err harness_exit=$harness harness_engine_errors=$harness_err logs=$LOG_DIR"
[[ $unit -eq 0 && $unit_err -eq 0 && $harness -eq 0 && $harness_err -eq 0 ]]
