#!/bin/zsh
# Act 4 「L叔在哪儿」 loop tests. Prints PASS/FAIL/METRIC lines and
#   LSHU_LOOP_TESTS passed=N failed=M
# then one LSHU_LOOP_TZ line per time zone (the clock's local time must match the wall clock).
# Exit code is non-zero when any test fails.
GODOT=${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}
ROOT=${0:A:h:h:h:h:h}
"$GODOT" --headless --path "$ROOT" --script res://tools/traveler/lshu/tests/test_loop.gd
main=$?
tz_failed=0
for zone in Asia/Shanghai America/New_York Asia/Kolkata Asia/Kathmandu America/St_Johns Pacific/Marquesas; do
	TZ=$zone "$GODOT" --headless --path "$ROOT" --script res://tools/traveler/lshu/tests/test_loop_tz.gd 2>&1 | grep '^LSHU_LOOP_TZ'
	[[ ${pipestatus[1]} -ne 0 ]] && tz_failed=$((tz_failed + 1))
done
echo "LSHU_LOOP_TZ_SUMMARY zones=6 failed=$tz_failed"
[[ $main -eq 0 && $tz_failed -eq 0 ]]
