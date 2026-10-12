#!/bin/zsh
# 旅人模式 · 正式包冒烟（2026-09-27：夜测发现正式包里四幕一幕都开不了，TL-1 / TRV-1 / LSHU-1）。
# ① 单独开：对导出的「旅行L叔.app」逐幕只带用户参数 -- --lshu-act=<幕> ...（导出模板不许命令行指定场景），
#    由入口 tools/merchant_board_claude_play.gd 换到那一幕；幕里 4 秒、16 秒各自动点一次（城门 / 篝火 / 土豆），
#    到点按「返回」同样的流程退出（scripts/traveler/act_exit_button.gd 的 --lshu-act-smoke*）。
# ② 从开场进（2026-09-27 起一幕开在开场同一个窗口里，scripts/traveler/traveler_host.gd）：每一幕各跑一遍
#    「开场 → 进入 → 那一幕就绪 → 返回 → 开场回来」（开场的 --lshu-smoke-enter），全程只有这一个进程：
#    跑的时候每秒 pgrep 一次它的子进程，一个都不许有；日志里要有进场、就绪、回来三行，回来那行里窗口只有一个。
# ③ 长安还在载入（场景在后台线程读 5–6 秒）时点窗口的关闭按钮（开场的 --lshu-smoke-enter-close）：开场那一层等场景读完再退出，
#    退出码 0，日志里有 TRAVELER_HOST_QUIT_DEFERRED 和 TRAVELER_HOST_QUIT_AFTER_READ，而且退出时没有任何引擎报错 / 泄漏
#    （以前引擎会把读到一半的场景硬停：一串解析错误 +「475 ObjectDB instances were leaked」）。
# 每一幕检查：退出码 0、日志里有入口换场（LSHU_ACT_ROUTE）、这一幕自己的就绪行、LSHU_ACT_READY、自动点击、按时退出，
# 且没有 SCRIPT ERROR / ERROR / 资源找不到。每个进程的 HOME 都指到临时目录，不碰真存档。
# 用法：tools/traveler/release_act_smoke.sh <旅行L叔.app> [每幕秒数，默认 30] [输出目录，默认临时目录]
# 截图：<输出目录>/<幕>_3.png（就绪后 3 秒，带底部提示）。退出码非 0 = 有一幕没过。
set -u
# 默认不出声（不在 Carlos 的 Mac 上放声音）；要用真声卡：AUDIO_ARGS="" tools/traveler/release_act_smoke.sh …
AUDIO_ARGS=${AUDIO_ARGS---audio-driver Dummy}
APP=${1:?用法：release_act_smoke.sh <旅行L叔.app> [秒数] [输出目录]}
SECS=${2:-30}
OUT=${3:-$(mktemp -d -t lshu_act_smoke)}
BIN=$(ls "$APP"/Contents/MacOS/* | head -1)
mkdir -p "$OUT"
typeset -A ARGS READY
# 和 scripts/lshu_ui/lshu_progress.gd 的 ACTS[].args 一致
ARGS[changan]="--view=changan --far --dusk"
ARGS[panti]="--view=panti --morning"
ARGS[baghdad]="--view=baghdad --lookdev=m_grass"
ARGS[lshu]=""
READY[changan]="ATLAS_READY"
READY[panti]="PANTI_READY"
READY[baghdad]="BAGHDAD_CYCLE_READY"
READY[lshu]="LSHU_READY"
fails=0
for act in changan panti baghdad lshu; do
	log="$OUT/$act.log"
	mkdir -p "$OUT/home_$act"
	HOME="$OUT/home_$act" perl -e 'alarm shift; exec @ARGV' $((SECS + 150)) "$BIN" ${=AUDIO_ARGS} --position 40,60 --resolution 1280x720 -- \
		--lshu-act=$act ${=ARGS[$act]} --lshu-act-on-top --lshu-act-smoke --lshu-act-smoke-quit=$SECS \
		--lshu-act-shot="$OUT/$act,3" > "$log" 2>&1
	rc=$?
	miss=()
	for tag in LSHU_ACT_ROUTE ${READY[$act]} LSHU_ACT_READY LSHU_ACT_SMOKE_QUIT; do
		grep -q "^$tag" "$log" || miss+=($tag)
	done
	[[ $act != lshu ]] && { grep -q '^LSHU_ACT_POKE .*"called":true' "$log" || miss+=(POKE); }
	# 退出时引擎自己报的释放 / 泄漏（盘橐的粒子着色器等）单独计数，不算这一幕坏了
	teardown='never freed|leaked at exit|still in use at exit|instances leaked'
	errs=$(grep -E '^(SCRIPT ERROR|ERROR|USER ERROR)|Resource file not found|Failed loading resource|Cannot open file' "$log" | grep -vE "$teardown" | head -5)
	exit_warn=$(grep -cE "$teardown" "$log")
	ready_ms=$(grep -o '^LSHU_ACT_READY {[^}]*}' "$log" | grep -o '"msec":[0-9]*' | cut -d: -f2)
	if [[ $rc -eq 0 && ${#miss[@]} -eq 0 && -z "$errs" ]]; then
		echo "PASS $act ready_ms=${ready_ms:-?} exit_warnings=$exit_warn log=$log"
	else
		fails=$((fails + 1))
		echo "FAIL $act rc=$rc missing=${miss[*]:-none} log=$log"
		[[ -n "$errs" ]] && echo "$errs" | sed 's/^/    /'
	fi
done
# ② 开场 → 进入 → 返回 → 开场回来（同一个窗口、同一个进程），四幕各一遍
for act in changan panti baghdad lshu; do
	log="$OUT/title_flow_$act.log"
	mkdir -p "$OUT/home_title_$act"
	HOME="$OUT/home_title_$act" perl -e 'alarm shift; exec @ARGV' 240 "$BIN" ${=AUDIO_ARGS} --position 40,60 --resolution 1280x720 -- \
		--lshu-unlock-all --lshu-smoke-enter=$act --lshu-smoke-enter-quit=10 > "$log" 2>&1 &
	pid=$!
	kids=0
	while kill -0 $pid 2>/dev/null; do
		n=$(pgrep -P $pid | wc -l | tr -d ' ')
		(( n > kids )) && kids=$n
		sleep 1
	done
	wait $pid
	rc=$?
	miss=()
	for tag in LSHU_TITLE_ENTER LSHU_TITLE_ACT_READY LSHU_TITLE_ACT_RETURNED; do
		grep -q "^$tag" "$log" || miss+=($tag)
	done
	grep -q '^LSHU_TITLE_SMOKE .*"ok":true' "$log" || miss+=(SMOKE_OK)
	grep -q '^LSHU_TITLE_SMOKE .*"windows":1' "$log" || miss+=(ONE_WINDOW)
	teardown='never freed|leaked at exit|still in use at exit|instances leaked'
	errs=$(grep -E '^(SCRIPT ERROR|ERROR|USER ERROR)|Resource file not found|Failed loading resource|Cannot open file' "$log" | grep -vE "$teardown" | head -5)
	exit_warn=$(grep -cE "$teardown" "$log")
	ready_ms=$(grep -o '^LSHU_TITLE_ACT_READY {"act":"[a-z]*","ms":[0-9]*' "$log" | grep -o '[0-9]*$')
	if [[ $rc -eq 0 && ${#miss[@]} -eq 0 && -z "$errs" && $kids -eq 0 ]]; then
		echo "PASS title_flow_$act click_to_ready_ms=${ready_ms:-?} child_processes=0 exit_warnings=$exit_warn log=$log"
	else
		fails=$((fails + 1))
		echo "FAIL title_flow_$act rc=$rc missing=${miss[*]:-none} child_processes=$kids log=$log"
		[[ -n "$errs" ]] && echo "$errs" | sed 's/^/    /'
	fi
done
# ③ 长安载入中关窗口
log="$OUT/close_while_loading_changan.log"
mkdir -p "$OUT/home_close_changan"
HOME="$OUT/home_close_changan" perl -e 'alarm shift; exec @ARGV' 120 "$BIN" ${=AUDIO_ARGS} --position 40,60 --resolution 1280x720 -- \
	--lshu-unlock-all --lshu-smoke-enter=changan --lshu-smoke-enter-close=1.5 > "$log" 2>&1
rc=$?
miss=()
for tag in LSHU_TITLE_SMOKE_CLOSE TRAVELER_HOST_QUIT_DEFERRED TRAVELER_HOST_QUIT_AFTER_READ; do
	grep -q "^$tag" "$log" || miss+=($tag)
done
errs=$(grep -E '^(SCRIPT ERROR|ERROR|USER ERROR|WARNING)|never freed|leaked|still in use' "$log" | head -5)
if [[ $rc -eq 0 && ${#miss[@]} -eq 0 && -z "$errs" ]]; then
	echo "PASS close_while_loading_changan log=$log"
else
	fails=$((fails + 1))
	echo "FAIL close_while_loading_changan rc=$rc missing=${miss[*]:-none} log=$log"
	[[ -n "$errs" ]] && echo "$errs" | sed 's/^/    /'
fi
echo "RELEASE_ACT_SMOKE fails=$fails out=$OUT"
[[ $fails -eq 0 ]]
