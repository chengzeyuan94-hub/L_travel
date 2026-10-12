#!/bin/zsh
# Act 4 「L叔在哪儿」 postcard camera: windowed harness + contact sheets.
#   zsh tools/traveler/lshu/tests/run_postcard_cam_tests.sh [--park=21]
# 1. tools/traveler/lshu/tests/postcard_cam_harness.gd (real stage, window parked at the slot, --motion-freeze)
#      -> LSHU_POSTCARD_CAM_HARNESS errors=N warnings=W checks=C failed=F renders=R timeouts=T
# 2. tools/traveler/lshu/tests/postcard_cam_sheet.py -> postcards_sheet.png, postcard_snaps.png
# Strict: any log line containing ERROR or WARNING, a non-zero exit code or a failed check is a failure.
# Output: docs/reports/traveler-lshu-integrate-20260924/ (postcard_cam/, postcard_cam_report.json, sheets, harness.log).
GODOT=${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}
UV=${UV:-$HOME/.local/bin/uv}
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
PARK="--park=21"
for a in "$@"; do
	[[ "$a" == --park=* ]] && PARK="$a"
done
OUT="$ROOT/docs/reports/traveler-lshu-integrate-20260924"
mkdir -p "$OUT"
LOG="$OUT/postcard_cam_harness.log"
"$GODOT" --path "$ROOT" --script res://tools/traveler/lshu/tests/postcard_cam_harness.gd -- "$PARK" --motion-freeze > "$LOG" 2>&1
code=$?
grep -E '^(FAIL|LSHU_POSTCARD_CAM_HARNESS)' "$LOG"
strict=$(grep -E 'ERROR|WARNING' "$LOG" | grep -v -c 'Attempting to parent and popup a dialog')
"$UV" run -q --with pillow --with numpy python "$ROOT/tools/traveler/lshu/tests/postcard_cam_sheet.py" "$OUT"
sheet=$?
echo "LSHU_POSTCARD_CAM_SUMMARY harness_exit=$code strict_error_lines=$strict sheet_exit=$sheet log=$LOG"
[[ $code -eq 0 && $strict -eq 0 && $sheet -eq 0 ]]
