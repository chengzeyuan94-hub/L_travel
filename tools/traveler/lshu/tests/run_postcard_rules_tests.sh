#!/bin/zsh
# Act 4 「L叔在哪儿」 postcard rules: exports the Python reference cards
# (postcard_rules_export.py -> postcard_lines_check.py), then compares the GDScript port card by card
# (test_postcard_rules.gd). Prints PASS/FAIL/METRIC/DIFF lines and
#   LSHU_POSTCARD_RULES passed=N failed=M
# Exit code is non-zero when the export or any test fails.
GODOT=${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}
# works under zsh and bash (the orchestrator calls these with bash)
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
TMP=${TMPDIR:-/tmp}
REF=${TMP%/}/lshu_postcard_rules_ref_$$.json
python3 -B "$ROOT/tools/traveler/lshu/tests/postcard_rules_export.py" --out "$REF" || exit 1
"$GODOT" --headless --path "$ROOT" --script res://tools/traveler/lshu/tests/test_postcard_rules.gd -- --ref="$REF"
code=$?
rm -f "$REF"
exit $code
