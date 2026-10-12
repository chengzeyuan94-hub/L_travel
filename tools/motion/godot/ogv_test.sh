#!/bin/bash
# Prove an intro .ogv plays in Godot 4.7.1 and measure its CPU cost.
#   tools/motion/godot/ogv_test.sh <film.ogv> [<audio.ogg>] [--audible]
# Copies the film under tools/motion/godot/_test/ (git-ignored) so it is loaded with load("res://...") exactly like
# game code; runs a windowed 960x540 player with vsync on (like the game) and the audio on bus "IntroVideo";
# then a baseline run of the same length without video. Audio driver is Dummy (silent, still mixed and metered)
# unless --audible. Prints: advances / ends / audio peak, and process CPU seconds (user+sys) video vs baseline.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(cd "$HERE/../../.." && pwd)"
GODOT=/Applications/Godot.app/Contents/MacOS/Godot
SCRATCH=/private/tmp/claude-501/-Users-chengzeyuan-Developer-SilkRoad/881e8717-f317-4a7f-9cf5-81713e061c3a/scratchpad/motion
OGV="$1"; shift || true
OGG=""; AUD="--audio-driver Dummy"
for a in "$@"; do case "$a" in --audible) AUD="";; *.ogg) OGG="$a";; esac; done
mkdir -p "$HERE/_test" "$SCRATCH/ogv_test"
NAME="$(basename "$OGV")"
cp "$OGV" "$HERE/_test/$NAME"
OUT="$SCRATCH/ogv_test/${NAME%.ogv}"
GHOME="${MOTION_HOME:-$SCRATCH/home_ogvtest}"   # HOME for Godot only (python3 here is a wrapper that needs the real HOME)
mkdir -p "$GHOME"
EXTRA=""; [ -n "$OGG" ] && EXTRA="--ogg=$OGG"
run() {  # $1 = tag, rest = user args
  local tag="$1"; shift
  HOME="$GHOME" /usr/bin/time -p perl -e 'alarm shift; exec @ARGV' 120 "$GODOT" --path "$PROJECT" $AUD --resolution 960x540 --always-on-top \
    res://tools/motion/godot/ogv_test.tscn -- "$@" --report="$OUT.$tag.json" > "$OUT.$tag.log" 2>&1
  local u s
  u=$(grep '^user' "$OUT.$tag.log" | awk '{print $2}'); s=$(grep '^sys' "$OUT.$tag.log" | awk '{print $2}')
  echo "$tag cpu_user=$u cpu_sys=$s"
}
run video --ogv="res://tools/motion/godot/_test/$NAME" $EXTRA
LEN=$(python3 -c "import json;print(json.load(open('$OUT.video.json'))['wall_s'])")
run baseline --baseline --seconds="$LEN"
python3 - "$OUT" <<'PY'
import json, sys
o = sys.argv[1]
v, b = json.load(open(o + ".video.json")), json.load(open(o + ".baseline.json"))
def cpu(tag):
    d = {}
    for line in open(o + "." + tag + ".log"):
        p = line.split()
        if len(p) == 2 and p[0] in ("user", "sys"):
            d[p[0]] = float(p[1])
    return d.get("user", 0) + d.get("sys", 0)
cv, cb = cpu("video"), cpu("baseline")
print(json.dumps({
  "plays": v["position_advances"] > 0, "position_advances": v["position_advances"], "last_position_s": v["last_position_s"],
  "stream_length_s": v["stream_length_s"], "finished_at_wall_s": v["finished_at_wall_s"],
  "audio_peak_max_db": v["audio_peak_max_db"], "frames_with_audio": v["frames_with_audio"], "frames": v["frames"], "fps_avg": round(v["fps_avg"], 1),
  "process_ms_video": v["process_ms"], "process_ms_baseline": b["process_ms"],
  "cpu_s_video_run": cv, "cpu_s_baseline_run": cb, "wall_s": v["wall_s"],
  "decode_cpu_cores_avg": round((cv - cb) / max(0.001, v["wall_s"]), 3),
  "error": v["error"]}, indent=1))
PY
