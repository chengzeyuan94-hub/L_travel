extends Node
## 商旅模式的「声音导演」SoundDirector（B 阶段；方案 docs/design/shanhe-luren/sound-20260926/plan.md §3.2–3.4、§4.3）。
## project.godot 的 [autoload] 挂一行（Carlos 2026-09-27 同意）。它**只读变量、只连信号**，不改任何页面、棋盘或规则文件：
## - 商旅设置页（PlayerSetupScreen）：开场音乐接着放、压到 −14 dB（原文件口径），再加一层空旷风（设置页 A 方案）。
## - 加载页（LoadingScreen）：路上的风；骆驼走着时驼铃；小花每开一朵叮一下（宫商角徵羽）；走满庆祝一串铃。音乐接着放。
## - 对局（GameScreen）：
##   · 底床按当前玩家停的地方：陆路 = 空旷风 + 高空嘶风，海路 = 海浪，海陆交叉点 = 海浪 + 风；换人或到站时判断，交叉 3 秒，至少停 6 秒才再换
##   · 时段层跟 3D 棋盘的 day_stage()（没有就按对局进度算）：清晨鸟多、正午鸟少、黄昏加树风、入夜鸟停
##   · 背景音乐：对局专用曲「一路向西」（assets/audio/music/match_bgm_v1.ogg，3 分 41 秒循环，长安 → 河西 → 撒马尔罕 →
##     巴格达 → 地中海 → 海路回长安）。进对局界面时从开场曲等功率交叉 5 秒到它（从头放）；再来一局、中间的加载页接着放，
##     不重头；回开场还是开场曲。事件卡翻开时再让 4 dB
##   · 骆驼在走时叠驼铃；事件卡翻开后按事件定义的 sfx 字段（没有就按好事 / 坏事 / 中性）响一声点缀
##   · 开通商道、轮到你了、最后一轮、剩 60 秒、终局各有提示音；AI 回合补骰子和交易声（B2，交易低 3 dB）
##   · 骰子、翻牌、交易这些音效响起时，音乐和环境声靠 Music / Ambience 总线上的 sidechain 压缩器自动让开（audio_buses.gd）
## 安全：amb_kit.allowed() 为假（无界面、测试、驱动脚本）时一个节点都不建、不读任何音频；当前场景不在 SCENES 白名单里
## （比如测试场景把 main.tscn 实例化成子节点、旅人四幕）也什么都不做。
## 参数在 data/audio/sound_director.json（起点值，随时可调）；文件缺了就用下面 DEFAULTS。

const Amb := preload("res://scripts/audio/ambience/amb_kit.gd")
const Buses := preload("res://scripts/audio/audio_buses.gd")
const Launch := preload("res://scripts/traveler/traveler_launch.gd")
const MIX_PATH := "res://data/audio/sound_director.json"
const MUSIC_PATH := "res://assets/audio/title/title_bgm_loop_v1.wav"
## 对局专用曲（Carlos 2026-09-27「一首从东方到西方的贯穿循环的音乐」；工具和说明在 tools/audio/match_music/）
const MATCH_MUSIC_PATH := "res://assets/audio/music/match_bgm_v1.ogg"
## 只在这几个入口里工作
const SCENES: Array[String] = [
	"res://scenes/main.tscn",
	"res://scenes/lshu_ui/lshu_preview_main.tscn",
	"res://tools/merchant_board_claude_play.tscn",
]
## EventDrawOverlay.PresentationState 的 HIDDEN / REVEALED
const EV_HIDDEN := 0
const EV_REVEALED := 5
## 正式平面棋盘没有 day_stage() 时，按对局进度套用 3D 棋盘同一套时段划分（tools/merchant_board_claude_daycycle.gd 的 KEYS，一天 1200 秒）
const TOD_KEYS: Array = [
	[0.0, "dawn"], [150.0, "dawn"], [300.0, "noon"], [600.0, "noon"],
	[780.0, "dusk"], [960.0, "dusk"], [1080.0, "twilight"], [1200.0, "twilight"],
]
const TOD_DAY_SEC := 1200.0
const BEDS: Array[String] = ["land", "sea", "port"]
const TODS: Array[String] = ["dawn", "noon", "dusk", "twilight"]
const SHOT_PLAYERS := 8
## 显式避让（最后一轮、终局）的变化速度，dB / 秒
const DUCK_RATE_DB := 6.0

const DEFAULTS: Dictionary = {
	"music": {"setup_db": -12.4, "loading_db": -13.4, "match_db": -16.4, "handoff_sec": 1.5, "fade_in_sec": 2.5,
		"fade_out_sec": 0.5, "match_lowpass_hz": 20000.0, "event_duck_db": -4.0,
		"match_track_db": -17.0, "match_track_loading_db": -15.0, "match_xfade_sec": 5.0},
	"sounds": {"wind_open": "wind_open_bed_loop_v1", "breeze": "breeze_hiss_bed_loop_v1", "waves": "waves_shore_bed_loop_v1",
		"birds": "birds_day_bed_loop_v1", "leaves": "wind_leaves_bed_loop_v1"},
	"mixes": {
		"setup": {"wind_open": -14.0}, "loading": {"wind_open": -8.0},
		"land": {"wind_open": -9.0, "breeze": -14.0}, "sea": {"waves": -9.0}, "port": {"waves": -13.0, "wind_open": -12.0},
		"dawn": {"birds": -12.0}, "noon": {"birds": -18.0}, "dusk": {"leaves": -14.0, "birds": -20.0}, "twilight": {},
	},
	"fades": {"page_in_sec": 1.5, "page_out_sec": 0.8, "match_in_sec": 2.5, "match_out_sec": 0.8,
		"bed_xfade_sec": 3.0, "bed_dwell_sec": 6.0, "tod_fade_sec": 6.0},
	"match_lowpass_hz": 7000.0,
	"loading": {
		"bells": {"sound": "bell_small_ding_v1", "interval_sec": [0.9, 1.6], "volume_db": -18.0, "pitch": [0.8, 0.9]},
		"bloom": {"sound": "bell_small_ding_v1", "volume_db": -12.0, "pitches": [1.0, 1.122, 1.26, 1.498, 1.682]},
		"done": {"sound": "bell_small_jingle_v1", "volume_db": -8.0},
	},
	"camel_bells": {"sound": "bell_small_ding_v1", "interval_sec": [1.1, 2.2], "volume_db": -16.0, "pitch": [0.78, 0.9]},
	"events": {
		"delay_sec": 0.12,
		"bed_db": -4.0,
		"by_sentiment": {"positive": "bell_jingle", "negative": "wind_gust", "neutral_land": "hooves_burst", "neutral_sea": "waves_swell"},
		"sfx": {
			"bell_jingle": {"sounds": ["bell_small_jingle_v1"], "volume_db": -10.0, "pitch": [0.98, 1.02]},
			"wind_gust": {"sounds": ["wind_leaves_gust_v1"], "volume_db": -4.0, "pitch": [0.95, 1.05]},
			"hooves_burst": {"sounds": ["hooves_burst_v1"], "volume_db": -4.0, "pitch": [0.97, 1.03]},
			"waves_swell": {"sounds": ["waves_swell_v1"], "volume_db": -10.0, "pitch": [0.97, 1.03]},
			"temple_bell": {"sounds": ["temple_bell_short_v1"], "volume_db": -10.0, "pitch": [0.98, 1.02]},
			"bird_call": {"sounds": ["bird_call_v1", "bird_call_v2", "bird_call_v3", "bird_call_v4", "bird_call_v5"], "volume_db": -8.0, "pitch": [0.95, 1.05]},
			"campfire_crackle": {"sounds": ["campfire_crackle_v1"], "volume_db": -10.0, "pitch": [0.97, 1.03]},
			"rain_burst": {"sounds": ["rain_burst_v1"], "volume_db": -10.0, "pitch": [0.97, 1.03]},
			"oars_burst": {"sounds": ["oars_burst_v1"], "volume_db": -10.0, "pitch": [0.97, 1.03]},
		},
	},
	"route_open": [
		{"sound": "bell_small_jingle_v1", "volume_db": -6.0, "pitch": 1.0, "delay_sec": 0.0},
		{"sound": "bell_small_ding_v1", "volume_db": -12.0, "pitch": 1.5, "delay_sec": 0.25},
	],
	"your_turn": {"sound": "bell_small_ding_v1", "volume_db": -12.0, "pitch": 1.26},
	"last_round": {"sound": "temple_bell_v1", "volume_db": -8.0, "duck_db": -4.0, "duck_sec": 4.0},
	"time_warning": {"sound": "temple_bell_short_v1", "volume_db": -12.0, "at_sec": 60.0},
	"game_over": {"sound": "temple_bell_v1", "volume_db": -6.0, "ambience_db": -12.0, "music_db": -6.0, "fade_sec": 2.0,
		"win": [
			{"sound": "bell_small_jingle_v1", "volume_db": -6.0, "pitch": 1.0, "delay_sec": 1.2},
			{"sound": "bell_small_jingle_v1", "volume_db": -6.0, "pitch": 1.26, "delay_sec": 1.8},
		]},
	"ai": {"trade_db": -3.0, "dice_land_after_sec": 0.55},
}

var _active: bool = false
var _started: bool = false
var _wait_frames: int = 0
var _cfg: Dictionary = {}
var _debug: bool = false
var _debug_left: float = 5.0

# 各页面（只读）
var _scene: Node
var _title: Control
var _setup: Control
var _loading: Control
var _game: Control
var _overlay: Node
var _dice: Node
var _board: Node

var _screen: String = ""
var _clock: float = 0.0
# 环境底床：混音名 -> 当前交叉进度 / 目标 / 速度（1/秒）
var _w: Dictionary = {}
var _goal: Dictionary = {}
var _rate: Dictionary = {}
var _layers: Dictionary = {}  # 声音名 -> Amb.Layer
# 音乐：_music = 开场曲（设置页、加载页，进对局时交叉出去），_mmusic = 对局曲
var _music: AudioStreamPlayer
var _music_amp: float = 0.0
var _music_fade: float = 1.0
var _mmusic: AudioStreamPlayer
var _mm_amp: float = 0.0
var _mm_fade: float = 1.0
## 等功率交叉的进度：0 = 只有开场曲，1 = 只有对局曲
var _xf: float = 0.0
var _xf_goal: float = 0.0
var _title_pos: float = -1.0
var _title_pos_usec: int = 0
var _title_db: float = -8.4
# 一次性
var _shots: Array[AudioStreamPlayer] = []
var _queue: Array = []  # [{t, sound, db, pitch, bus} | {t, call}]
# 低通（对数频率）
var _lp_amb: float = log(20000.0)
var _lp_music: float = log(20000.0)
# 对局
var _bed: String = ""
var _bed_pending: String = ""
var _bed_since: float = -100.0
var _tod: String = "noon"
var _tod_left: float = 0.0
var _duck_amb: float = 0.0
var _duck_music: float = 0.0
var _duck_until: float = -1.0
var _snap: Dictionary = {}
var _ev_state: int = EV_HIDDEN
var _camel_left: float = 0.5
var _was_moving: bool = false
var _warned: bool = false
var _last_left: float = INF
var _ai_dice_at: float = -1.0
var _ai_trade_at: float = -1.0
var _ai_roll_ours: bool = false
# 加载页
var _ld_prev: float = 0.0
var _ld_bloomed: int = 0
var _ld_done: bool = false
var _ld_bell_left: float = 0.4
var _fired: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 无界面、测试、驱动脚本：什么都不做（不建节点、不连信号、不读音频）
	set_process(Amb.allowed())


func _process(delta: float) -> void:
	if not _started:
		_try_start()
		return
	if not _active:
		return
	# 旅人模式的一幕开在开场同一个窗口里（scripts/traveler/traveler_host.gd）：那一幕有自己的环境声，导演一声不出，回来后照常
	if Launch.hosting():
		_hush()
		return
	_clock += delta
	_track_title_music()
	var s: String = _compute_screen()
	if s != _screen:
		_on_screen(s)
	var in_match: bool = _screen == "match"
	_run_queue()
	_update_ducks(delta, in_match)
	_update_mixes(delta, in_match)
	_update_music(delta)
	_update_lowpass(delta, in_match)
	if _screen == "loading":
		_drive_loading(delta)
	if in_match:
		_drive_match(delta)
	if _debug:
		_debug_left -= delta
		if _debug_left <= 0.0:
			_debug_left = 5.0
			print("SOUND_DIRECTOR ", JSON.stringify(debug_state()))


# ------------------------------------------------------------------ 启动：等主场景就位，再看它在不在白名单里
func _try_start() -> void:
	var scene: Node = get_tree().current_scene
	if scene == null:
		_wait_frames += 1
		if _wait_frames > 120:
			set_process(false)
		return
	_started = true
	if not SCENES.has(scene.scene_file_path) or not Amb.allowed() or _is_traveler_act():
		set_process(false)
		return
	_scene = scene
	_cfg = _merged(_load_json())
	_debug = OS.get_cmdline_user_args().has("--sound-debug")
	# 量响度用：-- --sound-solo=music 只留音乐，--sound-solo=ambience 只留环境声（另一条总线静音）
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--sound-solo="):
			var keep: String = a.trim_prefix("--sound-solo=")
			for b in [Buses.MUSIC, Buses.AMBIENCE, Buses.SFX, Buses.UI, Buses.MOVEMENT]:
				if AudioServer.get_bus_index(b) != -1 and b.to_lower() != keep:
					AudioServer.set_bus_mute(AudioServer.get_bus_index(b), true)
	_title = _find("StartScreen") as Control
	_setup = _find("PlayerSetupScreen") as Control
	_loading = _find("LoadingScreen") as Control
	_game = _find("GameScreen") as Control
	if _game != null:
		_overlay = _game.find_child("EventDrawOverlay", true, false)
		_dice = _game.find_child("Dice3DView", true, false)
		_board = _game.find_child("BoardView", true, false)
	for page: Control in [_title, _setup, _loading, _game]:
		if page != null:
			page.visibility_changed.connect(_on_pages_changed)
	GameState.state_changed.connect(_on_state)
	if _board != null and _board.has_signal("move_animation_finished"):
		_board.connect("move_animation_finished", _on_move_finished)
	if _dice != null:
		if _dice.has_signal("roll_started"):
			_dice.connect("roll_started", _on_dice_roll_started)
		if _dice.has_signal("face_revealed"):
			_dice.connect("face_revealed", _on_dice_face_revealed)
	_build_music_players()
	for i in SHOT_PLAYERS:
		var p := AudioStreamPlayer.new()
		p.name = "DirectorShot%d" % i
		add_child(p)
		_shots.append(p)
	_active = true
	_snapshot()
	_on_screen(_compute_screen())


## 单独开的旅人模式一幕（正式包 -- --lshu-act…，经 tools/merchant_board_claude_play.tscn 这个白名单里的入口换场景）：
## 那一幕自己有环境声，导演不管；换场景之前那一两帧 current_scene 还是入口，这里先挡住。
## 开场里「进入」的一幕开在同一个窗口里，由 _process 里的 Launch.hosting() 挡住。
static func _is_traveler_act() -> bool:
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--lshu-act"):
			return true
	return false


## 一幕开着时：音乐、底床、排着的一次性声音全停（开场只会在开场页进一幕，那时导演本来就几乎没声）
func _hush() -> void:
	if _music != null and _music.playing:
		_music.stop()
	_music_amp = 0.0
	# 对局专用曲（合并时补上：只从开场进一幕，那时它本来就停了；保险起见一起停）
	if _mmusic != null and _mmusic.playing:
		_mmusic.stop()
	_mm_amp = 0.0
	_title_pos = -1.0
	_queue.clear()
	for l: Amb.Layer in _layers.values():
		l.set_level(-80.0, 0.05)
	for p: AudioStreamPlayer in _shots:
		if p.playing:
			p.stop()


func _find(node_name: String) -> Node:
	if _scene.name == node_name:
		return _scene
	return _scene.find_child(node_name, true, false)


## 退出、测试收尾时：停掉所有播放器、清空 stream（AudioManager.silence_all() 会调）
func stop_all() -> void:
	_active = false
	set_process(false)
	_queue.clear()
	Amb.release(self, false)


## 退出时：停掉所有播放器、清空 stream，再给音频线程 EXIT_DRAIN_MSEC 把停掉的播放收走，不然关音频时报
## “ObjectDB instances leaked / resources still in use”（音乐 + 两三条底床）。
## 60 毫秒（amb_kit.release 的默认）不够：2026-09-27 复核用实时混音的无声驱动跑「开场 → 设置页 → 加载页 → 对局」再退出，
## 6 次里 1 次漏；和 AudioManager 一样等 200 毫秒。底床 Layer 在自己的 _exit_tree 里先停了，这里看不到它们在响，
## 所以导演开着（_active）就当有声音没收。只在退出时等这一次。
const EXIT_DRAIN_MSEC := 200


func _exit_tree() -> void:
	if not _started:
		return
	var busy: bool = _active
	for p in find_children("*", "AudioStreamPlayer", true, false):
		busy = busy or (p as AudioStreamPlayer).has_stream_playback()
	Amb.release(self, false)
	if busy:
		OS.delay_msec(EXIT_DRAIN_MSEC)


# ------------------------------------------------------------------ 现在是哪一页
func _compute_screen() -> String:
	if _vis(_loading):
		return "loading"
	if _vis(_game) and not GameState.players.is_empty():
		return "match"
	if _vis(_setup):
		return "setup"
	if _vis(_title):
		return "title"
	return ""


## 参数不标 Control：退出时页面可能已释放，已释放的对象转成 Control 会先报错
static func _vis(c: Variant) -> bool:
	return is_instance_valid(c) and (c as Control).is_visible_in_tree()


## 页面显示 / 隐藏：等这一帧里几页都切完再判断（_show_only 先藏开场、再显示设置页）
func _on_pages_changed() -> void:
	if _active and not is_queued_for_deletion():
		call_deferred("_check_screen")


func _check_screen() -> void:
	if not _active:
		return
	var s: String = _compute_screen()
	if s != _screen:
		_on_screen(s)
		_update_music(0.0)


func _on_screen(s: String) -> void:
	var prev: String = _screen
	_screen = s
	var m: Dictionary = _cfg.music
	if s == "match":
		_snapshot()
		_request_bed(true)
		_update_tod(true)
		_reset_match_flags()
		_ev_state = _overlay_state()
		_was_moving = false
		_camel_left = randf_range(0.3, 0.9)
	elif s == "loading":
		_ld_prev = _loading_display()
		_ld_bloomed = _loading_bloomed()
		_ld_done = _loading_done()
		_ld_bell_left = 0.4
	# 音乐：有音乐的页面之间平滑过渡；从开场过来就接着开场音乐的位置放。
	# 这一页要对局曲（对局界面，或者对局曲已经响着的加载页 = 再来一局）就不再起开场曲，交叉在 _update_music 里走
	var track: String = music_track_for(s, _match_track_on())
	var wants: bool = _music_goal_db() > -79.0
	if wants and track == "title" and _music != null and not _music.playing:
		_start_music()
	elif wants:
		_music_fade = float(m.handoff_sec) if prev != "" else float(m.fade_in_sec)
	else:
		_music_fade = float(m.fade_out_sec)
	_mm_fade = float(m.handoff_sec) if track == "match" else float(m.fade_out_sec)
	_count("screen_" + (s if s != "" else "none"))
	if prev == "match" and s != "match":
		_queue.clear()
		_ai_dice_at = -1.0
		_ai_trade_at = -1.0


## 每局各自的一次性标记：进对局界面时、以及同一个对局界面里开了新局（再来一局、读档，session_generation 变了）时重来。
## 已经剩不到 60 秒才进来（读档）就不再敲「剩 60 秒」；「最后一轮」的压低不带进新局。
func _reset_match_flags() -> void:
	var left: float = GameState.match_time_left_sec
	_warned = GameState.match_limit_sec > 0.0 and left <= float(_cfg.time_warning.at_sec)
	_last_left = left
	_duck_until = -1.0
	_ai_dice_at = -1.0
	_ai_trade_at = -1.0
	_ai_roll_ours = false


# ------------------------------------------------------------------ 音乐
func _music_goal_db() -> float:
	var m: Dictionary = _cfg.music
	match _screen:
		"setup":
			return float(m.setup_db)
		"loading":
			return float(m.loading_db)
		"match":
			return float(m.match_db) + _duck_music
	return -80.0


## 开场音乐在放时每帧记下它的位置；开场一隐藏它就停，导演从这个位置接着放
func _track_title_music() -> void:
	if not is_instance_valid(_title):
		return
	var bgm := _title.get("bgm") as AudioStreamPlayer
	if bgm != null and bgm.playing and bgm.stream != null:
		_title_pos = bgm.get_playback_position() + AudioServer.get_time_since_last_mix()
		_title_pos_usec = Time.get_ticks_usec()
		_title_db = bgm.volume_db


func _start_music() -> void:
	if _music == null or _music.stream == null:
		return
	var m: Dictionary = _cfg.music
	var length: float = maxf(0.1, _music.stream.get_length())
	var pos: float = 0.0
	var since: float = float(Time.get_ticks_usec() - _title_pos_usec) / 1000000.0
	if _title_pos >= 0.0 and since < 0.5:
		# 开场刚刚还在放：同一首、同一位置、同一音量接上，再慢慢压到这一页的音量
		pos = fposmod(_title_pos + since, length)
		_music_amp = Amb.db_to_amp(_title_db)
		_music_fade = float(m.handoff_sec)
		_count("music_handoff")
	else:
		_music_amp = 0.0
		_music_fade = float(m.fade_in_sec)
	_music.volume_db = Amb.amp_to_db(_music_amp)
	_music.play(pos)
	_title_pos = -1.0


func _update_music(delta: float) -> void:
	if _music == null:
		return
	var m: Dictionary = _cfg.music
	# 这一页该放哪一首 → 交叉往哪边走（对局曲不在就一直是开场曲）
	var want_match: bool = music_track_for(_screen, _match_track_on()) == "match" \
		and _mmusic != null and _mmusic.stream != null
	_xf_goal = 1.0 if want_match else 0.0
	if want_match and not _mmusic.playing:
		_start_match_music()
	_xf = move_toward(_xf, _xf_goal, delta / maxf(0.05, float(m.match_xfade_sec)))
	var g: Vector2 = xfade_gains(_xf)
	# 开场曲：这一页的音量（原来的淡变）× 交叉系数
	var goal: float = Amb.db_to_amp(_music_goal_db())
	if goal > 0.0 and _xf_goal <= 0.0 and not _music.playing:
		_start_music()
	var rate: float = maxf(goal, _music_amp) / maxf(0.05, _music_fade)
	_music_amp = move_toward(_music_amp, goal, maxf(rate, 0.02) * delta)
	_write_volume(_music, _music_amp * g.x, _music_amp == goal and _xf == _xf_goal)
	if _music.playing and ((_music_amp <= 0.0001 and goal <= 0.0) or (_xf_goal >= 1.0 and _xf >= 1.0)):
		_music.stop()
	# 对局曲
	if _mmusic != null:
		var mgoal: float = Amb.db_to_amp(_match_goal_db())
		var mrate: float = maxf(mgoal, _mm_amp) / maxf(0.05, _mm_fade)
		_mm_amp = move_toward(_mm_amp, mgoal, maxf(mrate, 0.02) * delta)
		_write_volume(_mmusic, _mm_amp * g.y, _mm_amp == mgoal and _xf == _xf_goal)
		if _mmusic.playing and ((_mm_amp <= 0.0001 and mgoal <= 0.0) or (_xf_goal <= 0.0 and _xf <= 0.0)):
			_mmusic.stop()
	# 两首都停了（开场页、没有页面）：交叉直接落到目标，下次从头算
	if not _music.playing and (_mmusic == null or not _mmusic.playing):
		_xf = _xf_goal


## 只在真的变了时写（同 amb_kit.Layer：播放中逐帧写 volume_db 会撞上引擎的混音参数释放竞态，夜测 STRESS-1）；
## 淡变和交叉都走完时（settled）把最后那一点差补上
static func _write_volume(p: AudioStreamPlayer, amp: float, settled: bool) -> void:
	var db: float = Amb.amp_to_db(amp)
	if absf(db - p.volume_db) >= 0.2 or (settled and db != p.volume_db):
		p.volume_db = db


## 对局曲这一页的音量：对局界面 match_track_db（加上事件卡、最后一轮、终局的避让）；加载页（再来一局）match_track_loading_db
func _match_goal_db() -> float:
	var m: Dictionary = _cfg.music
	match _screen:
		"match":
			return float(m.match_track_db) + _duck_music
		"loading":
			return float(m.match_track_loading_db)
	return -80.0


## 对局曲是不是正在响（算「再来一局」的加载页要不要留在对局曲上）
func _match_track_on() -> bool:
	return _mmusic != null and _mmusic.playing and _xf > 0.0


## 对局曲总是从头开始；交叉系数从 0 起，所以音量直接给这一页的值
func _start_match_music() -> void:
	if _mmusic == null or _mmusic.stream == null:
		return
	_mm_amp = Amb.db_to_amp(_match_goal_db())
	_mm_fade = float(_cfg.music.handoff_sec)
	_mmusic.volume_db = -80.0
	_mmusic.play(0.0)
	_count("match_music_start")


func _build_music_players() -> void:
	_music = AudioStreamPlayer.new()
	_music.name = "DirectorMusic"
	_music.bus = Buses.bus_or_master(Buses.MUSIC)
	if ResourceLoader.exists(MUSIC_PATH):
		_music.stream = load(MUSIC_PATH)
	add_child(_music)
	_mmusic = AudioStreamPlayer.new()
	_mmusic.name = "DirectorMatchMusic"
	_mmusic.bus = Buses.bus_or_master(Buses.MUSIC)
	if ResourceLoader.exists(MATCH_MUSIC_PATH):
		_mmusic.stream = load(MATCH_MUSIC_PATH)
	add_child(_mmusic)


## 某一页该放哪一首："match" = 对局曲，"title" = 开场曲，"" = 导演不放（开场页自己放开场曲）。
## 加载页：对局曲已经在响（结算页点「再来一局」）就留在对局曲上，不然（设置页出发、开场读档）是开场曲。
static func music_track_for(screen: String, match_track_playing: bool) -> String:
	match screen:
		"match":
			return "match"
		"loading":
			return "match" if match_track_playing else "title"
		"setup":
			return "title"
	return ""


## 等功率交叉：x = 0 只有开场曲，x = 1 只有对局曲；返回 (开场曲, 对局曲) 的幅度系数，平方和恒为 1
static func xfade_gains(x: float) -> Vector2:
	var c: float = clampf(x, 0.0, 1.0)
	return Vector2(cos(c * PI * 0.5), sin(c * PI * 0.5))


# ------------------------------------------------------------------ 环境底床
func _set_goal(id: String, on: bool, sec: float) -> void:
	var g: float = 1.0 if on else 0.0
	if float(_goal.get(id, -1.0)) != g:
		_goal[id] = g
		_rate[id] = 1.0 / maxf(0.05, sec)
		if not _w.has(id):
			_w[id] = 0.0


func _update_mixes(delta: float, in_match: bool) -> void:
	var f: Dictionary = _cfg.fades
	_set_goal("setup", _screen == "setup", float(f.page_in_sec) if _screen == "setup" else float(f.page_out_sec))
	_set_goal("loading", _screen == "loading", float(f.page_in_sec) if _screen == "loading" else float(f.page_out_sec))
	var beds_on: bool = _group_level(BEDS) > 0.001
	for b in BEDS:
		var on: bool = in_match and _bed == b
		var sec: float = float(f.bed_xfade_sec)
		if not in_match:
			sec = float(f.match_out_sec)
		elif on and not beds_on:
			sec = float(f.match_in_sec)
		_set_goal(b, on, sec)
	var tods_on: bool = _group_level(TODS) > 0.001
	for t in TODS:
		var on: bool = in_match and _tod == t
		var sec: float = float(f.tod_fade_sec)
		if not in_match:
			sec = float(f.match_out_sec)
		elif on and not tods_on:
			sec = float(f.match_in_sec)
		_set_goal(t, on, sec)
	for id: String in _goal:
		_w[id] = move_toward(float(_w.get(id, 0.0)), float(_goal[id]), float(_rate[id]) * delta)
	# 每一层 = √(Σ 各混音进度 × 这一层在该混音里的功率)，再加避让
	var mixes: Dictionary = _cfg.mixes
	var names: Dictionary = _cfg.sounds
	var want: Dictionary = {}
	for id: String in _w:
		var w: float = float(_w[id])
		if w <= 0.0:
			continue
		var levels: Dictionary = mixes.get(id, {})
		for key: String in levels:
			var sound: String = str(names.get(key, key))
			var a: float = Amb.db_to_amp(float(levels[key]))
			want[sound] = float(want.get(sound, 0.0)) + w * a * a
	for sound: String in want:
		if not _layers.has(sound) and float(want[sound]) > 0.0:
			var l: Amb.Layer = Amb.Layer.new().setup(sound, -80.0)
			add_child(l)
			_layers[sound] = l
	for sound: String in _layers:
		var db: float = Amb.amp_to_db(sqrt(float(want.get(sound, 0.0)))) + _duck_amb
		(_layers[sound] as Amb.Layer).set_level(db if db > -60.0 else -80.0, 0.12)


func _group_level(ids: Array[String]) -> float:
	var s: float = 0.0
	for id in ids:
		s += float(_w.get(id, 0.0))
	return s


## 对局界面：Ambience 低通到 7 kHz（新素材比对局音效亮得多）、音乐低通到 5 kHz（更柔）；离开对局再打开
func _update_lowpass(delta: float, in_match: bool) -> void:
	var open: float = log(Buses.LOWPASS_OPEN_HZ)
	var ta: float = log(float(_cfg.match_lowpass_hz)) if in_match else open
	var tm: float = log(float(_cfg.music.match_lowpass_hz)) if in_match else open
	var step: float = delta * 1.0  # 约 2 秒走完 20k → 5k（ln 4 ≈ 1.4）
	var na: float = move_toward(_lp_amb, ta, step)
	var nm: float = move_toward(_lp_music, tm, step)
	if na != _lp_amb:
		_lp_amb = na
		Buses.set_lowpass(Buses.AMBIENCE, exp(_lp_amb))
	if nm != _lp_music:
		_lp_music = nm
		Buses.set_lowpass(Buses.MUSIC, exp(_lp_music))


## 显式避让：最后一轮压 4 dB 4 秒；终局环境压到 −12、音乐 −6；事件卡在桌上时音乐再让 4 dB
func _update_ducks(delta: float, in_match: bool) -> void:
	var ta: float = 0.0
	var tm: float = 0.0
	if in_match:
		if GameState.phase == GameState.Phase.GAME_OVER:
			ta = float(_cfg.game_over.ambience_db)
			tm = float(_cfg.game_over.music_db)
		if _clock < _duck_until:
			ta = minf(ta, float(_cfg.last_round.duck_db))
			tm = minf(tm, float(_cfg.last_round.duck_db))
		if _overlay_state() != EV_HIDDEN:
			tm = minf(tm, float(_cfg.music.event_duck_db))
	var rate: float = absf(float(_cfg.game_over.ambience_db)) / maxf(0.1, float(_cfg.game_over.fade_sec))
	_duck_amb = move_toward(_duck_amb, ta, maxf(rate, DUCK_RATE_DB) * delta)
	_duck_music = move_toward(_duck_music, tm, maxf(rate, DUCK_RATE_DB) * delta)


# ------------------------------------------------------------------ 加载页
func _loading_display() -> float:
	var v: Variant = _loading.get("_display") if _loading != null else null
	return float(v) if (v is float or v is int) else 0.0


func _loading_bloomed() -> int:
	var v: Variant = _loading.get("_bloomed") if _loading != null else null
	var n: int = 0
	if v is Array:
		for b in v:
			if bool(b):
				n += 1
	return n


func _loading_done() -> bool:
	var v: Variant = _loading.get("_done") if _loading != null else null
	return v is bool and bool(v)


func _drive_loading(delta: float) -> void:
	var c: Dictionary = _cfg.loading
	var disp: float = _loading_display()
	var walking: bool = disp > _ld_prev + 0.00001 and not _ld_done
	_ld_prev = disp
	if walking:
		_ld_bell_left -= delta
		if _ld_bell_left <= 0.0:
			var b: Dictionary = c.bells
			_ld_bell_left = randf_range(float(b.interval_sec[0]), float(b.interval_sec[1]))
			_shot(str(b.sound), float(b.volume_db), randf_range(float(b.pitch[0]), float(b.pitch[1])), Buses.AMBIENCE)
			_count("loading_bells")
	var n: int = _loading_bloomed()
	if n > _ld_bloomed:
		var bl: Dictionary = c.bloom
		var pitches: Array = bl.pitches
		for i in range(_ld_bloomed, n):
			_later(0.06 * float(i - _ld_bloomed), str(bl.sound), float(bl.volume_db), float(pitches[mini(i, pitches.size() - 1)]), Buses.UI)
			_count("loading_bloom")
	_ld_bloomed = n
	var done: bool = _loading_done()
	if done and not _ld_done:
		_shot(str(c.done.sound), float(c.done.volume_db), 1.0, Buses.UI)
		_count("loading_done")
	_ld_done = done


# ------------------------------------------------------------------ 对局
func _drive_match(delta: float) -> void:
	# 事件卡：翻开那一刻响点缀
	var st: int = _overlay_state()
	if st == EV_REVEALED and _ev_state != EV_REVEALED:
		_on_event_revealed()
	_ev_state = st
	# 行进：骆驼在走就叠驼铃；走完（循环停了）判断一次底床
	var mv := AudioManager.get("_movement") as AudioStreamPlayer
	var moving: bool = mv != null and mv.playing
	var transport: int = int(AudioManager.get("movement_transport"))
	if moving and transport == GameData.Transport.CAMEL:
		_camel_left -= delta
		if _camel_left <= 0.0:
			var cb: Dictionary = _cfg.camel_bells
			_camel_left = randf_range(float(cb.interval_sec[0]), float(cb.interval_sec[1]))
			_shot(str(cb.sound), float(cb.volume_db), randf_range(float(cb.pitch[0]), float(cb.pitch[1])), Buses.AMBIENCE)
			_count("camel_bells")
	elif not moving:
		_camel_left = randf_range(0.3, 0.9)
	if _was_moving and not moving:
		_request_bed(false)
	_was_moving = moving
	if _bed_pending != "" and _clock - _bed_since >= float(_cfg.fades.bed_dwell_sec):
		_request_bed(false)
	# 最后一轮：时间到触发终局时对局界面不发 state_changed，所以每帧也看一眼
	_check_last_round()
	# 时段
	_tod_left -= delta
	if _tod_left <= 0.0:
		_update_tod(false)
	# 剩 60 秒
	var left: float = GameState.match_time_left_sec
	var at: float = float(_cfg.time_warning.at_sec)
	if not _warned and GameState.match_limit_sec > 0.0 and time_crossed(_last_left, left, at) \
			and GameState.phase != GameState.Phase.GAME_OVER and not GameState.players.is_empty():
		_warned = true
		_shot(str(_cfg.time_warning.sound), float(_cfg.time_warning.volume_db), 1.0, Buses.SFX)
		_count("time_warning")
	_last_left = left
	# AI 掷骰：没有骰子动画时自己补
	if _ai_dice_at > 0.0 and _clock >= _ai_dice_at:
		_ai_dice_at = -1.0
		var busy: bool = is_instance_valid(_dice) and _dice.has_method("is_rolling") and bool(_dice.call("is_rolling"))
		if not busy and Time.get_ticks_msec() - int(AudioManager.last_dice_roll_msec) > 400:
			AudioManager.play_dice_roll()
			_later_call(float(_cfg.ai.dice_land_after_sec), func() -> void: AudioManager.play_dice_land())
			_count("ai_dice")
	# AI 交易：同样晚 0.05 秒再补。规则层在交易里同步发 state_changed，别处（对局界面、AI 控制器）若在交易之后
	# 也放交易声，那一声会在这之前记进 last_trade_msec，这里就不重复（两头都挡住，不只挡「别处先放」）
	if _ai_trade_at > 0.0 and _clock >= _ai_trade_at:
		_ai_trade_at = -1.0
		if Time.get_ticks_msec() - int(AudioManager.last_trade_msec) > 300:
			AudioManager.play_trade_success(float(_cfg.ai.trade_db))
			_count("ai_trade")


## 剩余时间这一帧是不是真的「走过」了 at 秒这条线。开局 / 读档时剩余时间先是 INF（对局界面下一帧才写进来），
## 从 INF 直接跳到线下不算走过（读档时已经不到 1 分钟，就不敲「剩 60 秒」）
static func time_crossed(last_left: float, left: float, at: float) -> bool:
	return left <= at and last_left > at and last_left < INF


func _overlay_state() -> int:
	if not is_instance_valid(_overlay):
		return EV_HIDDEN
	var v: Variant = _overlay.get("state")
	return int(v) if (v is int) else EV_HIDDEN


func _on_event_revealed() -> void:
	var e: Dictionary = _cfg.events
	var table: Dictionary = e.sfx
	var sentiment: String = "neutral"
	if _overlay.has_method("debug_selected_card"):
		var card: Variant = _overlay.call("debug_selected_card")
		if card is Object and card != null:
			sentiment = str((card as Object).get("sentiment"))
	var ev: Variant = _overlay.get("_event")
	var evd: Dictionary = ev if ev is Dictionary else {}
	var ctx: Dictionary = _event_content()
	var key: String = event_sfx_key(evd, ctx)
	if key == "" or not table.has(key):
		var by: Dictionary = e.by_sentiment
		if sentiment == "positive":
			key = str(by.positive)
		elif sentiment == "negative":
			key = str(by.negative)
		else:
			var sea: bool = not GameState.players.is_empty() and GameState.current_player().active_transport == GameData.Transport.SHIP
			key = str(by.neutral_sea if sea else by.neutral_land)
	var delay: float = float(e.delay_sec)
	if _event_shot(key, delay, 0.0):
		_count("event_" + key)
	# 趣味事件扩展（data/expansions/lshu_fun_events）的另外两个字段：sfx_bed = 底下垫的一声（比主点缀低 bed_db），
	# sfx_cues.layer = 同时叠的一声。其它时刻的 cue（winner、reveal_win、reveal_lose、confirm）由那一步的界面调 play_event_cue()
	var bed: String = event_sfx_key(evd, ctx, "sfx_bed")
	if _event_shot(bed, delay, float(e.get("bed_db", -4.0))):
		_count("event_bed_" + bed)
	var layer: String = event_cue_key(evd, ctx, "layer")
	if _event_shot(layer, delay, 0.0):
		_count("event_layer_" + layer)


## 按点缀名（sound_director.json 的 events.sfx 表）播一声；名字不认识（含空）就不播，返回 false
func _event_shot(key: String, delay: float, extra_db: float) -> bool:
	var table: Dictionary = _cfg.events.sfx
	if key == "" or not table.has(key):
		return false
	var s: Dictionary = table[key]
	var sounds: Array = s.sounds
	if sounds.is_empty():
		return false
	var pit: Array = s.get("pitch", [1.0, 1.0])
	_later(delay, str(sounds[randi() % sounds.size()]), float(s.volume_db) + extra_db, randf_range(float(pit[0]), float(pit[1])), Buses.SFX)
	return true


## 趣味事件某一时刻的音（事件或其定义的 sfx_cues[cue]，例如 "winner"、"reveal_win"、"reveal_lose"、"confirm"）。
## 给那一步的界面调：SoundDirector.play_event_cue(event, "winner")。导演没在对局里工作（无界面、测试、别的入口）就什么都不做。
## 返回是否真的排上了一声。
func play_event_cue(event: Dictionary, cue: String) -> bool:
	if not _active or _screen != "match":
		return false
	var key: String = event_cue_key(event, _event_content(), cue)
	if not _event_shot(key, 0.0, 0.0):
		return false
	_count("event_cue_" + cue)
	return true


func _event_content() -> Dictionary:
	var o: Variant = _overlay.get("_content_override") if is_instance_valid(_overlay) else null
	if o is Dictionary and not (o as Dictionary).is_empty():
		return o
	return GameState.content


## 事件的点缀名：事件本身（抽到的那张）或它的定义（content.event_definitions[event_id]）上的可选字段（默认 sfx；
## 趣味事件还有 sfx_bed）；没有就返回 ""
static func event_sfx_key(event: Dictionary, content: Dictionary, field: String = "sfx") -> String:
	var v: Variant = event.get(field, "")
	if v is String and v != "":
		return v
	var def: Dictionary = _event_definition(event, content)
	var d: Variant = def.get(field, "")
	return d if d is String else ""


## 趣味事件 sfx_cues 里某一时刻的点缀名：事件本身优先，其次事件定义；没有就返回 ""
static func event_cue_key(event: Dictionary, content: Dictionary, cue: String) -> String:
	for src: Dictionary in [event, _event_definition(event, content)]:
		var cues: Variant = src.get("sfx_cues", {})
		if cues is Dictionary and (cues as Dictionary).get(cue, "") is String and str((cues as Dictionary).get(cue, "")) != "":
			return str((cues as Dictionary)[cue])
	return ""


static func _event_definition(event: Dictionary, content: Dictionary) -> Dictionary:
	var defs: Variant = content.get("event_definitions", {})
	var id: String = str(event.get("event_id", ""))
	if defs is Dictionary and (defs as Dictionary).has(id) and (defs as Dictionary)[id] is Dictionary:
		return (defs as Dictionary)[id]
	return {}


func _on_state() -> void:
	if not _active:
		return
	if GameState.players.is_empty():
		_snap = {}
		return
	if _snap.is_empty() or int(_snap.get("gen", -1)) != GameState.session_generation:
		_snapshot()
		_reset_match_flags()   # 开了新局（可能一直停在对局界面上）：剩 60 秒、最后一轮压低、AI 补声都重来
		return
	var in_match: bool = _compute_screen() == "match"
	var cur: PlayerState = GameState.current_player()
	var idx: int = GameState.current_player_index
	var same: bool = idx == int(_snap.idx)
	if in_match:
		# AI 回合补声（B2）：掷骰、交易（低 3 dB）都晚 0.05 秒再补（没有骰子动画、别处也没放过时才放，见 _drive_match）
		if cur.is_ai() and same and _snap.die == null and cur.die_result != null:
			_ai_dice_at = _clock + 0.05
		if cur.is_ai() and same and not bool(_snap.trade_used) and cur.trade_action_used:
			_ai_trade_at = _clock + 0.05
		# 开通商道
		var routes: Dictionary = _open_routes()
		for city: String in routes:
			if not (_snap.routes as Dictionary).has(city):
				for r: Dictionary in _cfg.route_open:
					_later(float(r.get("delay_sec", 0.0)), str(r.sound), float(r.volume_db), float(r.get("pitch", 1.0)), Buses.SFX)
				_count("route_open")
				break
		# 轮到你了（多人同屏，或者从 AI 回合回到真人）
		if not same and cur.is_local_human() and GameState.phase != GameState.Phase.GAME_OVER:
			var y: Dictionary = _cfg.your_turn
			_shot(str(y.sound), float(y.volume_db), float(y.get("pitch", 1.0)), Buses.SFX)
			_count("your_turn")
		_check_last_round()
		# 终局
		if GameState.phase == GameState.Phase.GAME_OVER and int(_snap.phase) != GameState.Phase.GAME_OVER:
			var go: Dictionary = _cfg.game_over
			_shot(str(go.sound), float(go.volume_db), 1.0, Buses.SFX)
			if _human_won():
				for w: Dictionary in go.win:
					_later(float(w.delay_sec), str(w.sound), float(w.volume_db), float(w.get("pitch", 1.0)), Buses.SFX)
			_count("game_over")
	if not same:
		_request_bed(false)
	_snapshot()


## 最后一轮：终局刚被触发（白银拿空，或时间到）、还没结算时响寺庙钟，环境和音乐压 4 dB 4 秒；同一局只响一次
func _check_last_round() -> void:
	if _snap.is_empty() or int(_snap.get("gen", -1)) != GameState.session_generation or bool(_snap.get("end", true)):
		return
	if not GameState.end_triggered:
		return
	_snap["end"] = true
	if GameState.phase == GameState.Phase.GAME_OVER:
		return  # 直接结算了：只响终局的钟
	var lr: Dictionary = _cfg.last_round
	_shot(str(lr.sound), float(lr.volume_db), 1.0, Buses.SFX)
	_duck_until = _clock + float(lr.duck_sec)
	_count("last_round")


func _snapshot() -> void:
	if GameState.players.is_empty():
		_snap = {}
		return
	var cur: PlayerState = GameState.current_player()
	_snap = {"gen": GameState.session_generation, "idx": GameState.current_player_index, "phase": int(GameState.phase),
		"end": GameState.end_triggered, "routes": _open_routes(), "die": cur.die_result, "trade_used": cur.trade_action_used}


func _open_routes() -> Dictionary:
	var out: Dictionary = {}
	for city: Variant in GameState.city_market_states:
		var m: Variant = GameState.city_market_states[city]
		if m is Dictionary and bool((m as Dictionary).get("trade_route_open", false)):
			out[str(city)] = true
	return out


func _human_won() -> bool:
	var ids: Array = GameState.result.get("winner_ids", [])
	for p: PlayerState in GameState.players:
		if ids.has(p.player_id) and p.is_local_human():
			return true
	return false


func _on_move_finished(_player_id: Variant = null) -> void:
	if _active and _screen == "match":
		_request_bed(false)


func _on_dice_roll_started() -> void:
	if not _active or _screen != "match" or GameState.players.is_empty() or not GameState.current_player().is_ai():
		return
	_ai_dice_at = -1.0  # 骰子在动：跟着动画出声
	_ai_roll_ours = Time.get_ticks_msec() - int(AudioManager.last_dice_roll_msec) > 300
	if _ai_roll_ours:
		AudioManager.play_dice_roll()
		_count("ai_dice")


func _on_dice_face_revealed(_face: Variant = null) -> void:
	if _ai_roll_ours:
		_ai_roll_ours = false
		AudioManager.play_dice_land()


## 当前玩家停在哪种地方：只有陆路 = land，只有海路 = sea，海陆交叉点 = port；换人或到站时判断，至少停 6 秒才再换
func _request_bed(immediate: bool) -> void:
	if GameState.players.is_empty():
		return
	var b: String = bed_for(GameState.content, GameState.current_player())
	if b == _bed:
		_bed_pending = ""
		return
	if immediate or _bed == "" or _clock - _bed_since >= float(_cfg.fades.bed_dwell_sec):
		_bed = b
		_bed_since = _clock
		_bed_pending = ""
		_count("bed_" + b)
	else:
		_bed_pending = b


static func bed_for(content: Dictionary, player: PlayerState) -> String:
	var nodes: Variant = content.get("board_nodes", {})
	var routes: Array = []
	if nodes is Dictionary and (nodes as Dictionary).has(player.current_node_id):
		var n: Variant = (nodes as Dictionary)[player.current_node_id]
		if n is Dictionary:
			routes = (n as Dictionary).get("allowed_routes", [])
	if routes.has("LAND") and routes.has("SEA"):
		return "port"
	if routes.has("SEA"):
		return "sea"
	if routes.has("LAND"):
		return "land"
	return "sea" if player.active_transport == GameData.Transport.SHIP else "land"


func _update_tod(_force: bool) -> void:
	_tod_left = 1.0
	var st: String = ""
	if is_instance_valid(_board) and _board.has_method("day_stage"):
		st = str(_board.call("day_stage"))
	else:
		st = tod_from_progress(GameState.match_elapsed_sec, GameState.match_limit_sec)
	var t: String = tod_name(st)
	if t != _tod:
		_tod = t
		_count("tod_" + t)


## 「dawn」「noon->dusk」这种时段名 → 四档之一：渐变段取要去的那一档；入夜那段（twilight->dawn）算 twilight
static func tod_name(stage: String) -> String:
	var s: String = stage
	if s.contains("->"):
		var parts: PackedStringArray = s.split("->")
		s = parts[0] if parts[0] == "twilight" else parts[1]
	return s if TODS.has(s) else "noon"


static func tod_from_progress(elapsed: float, limit: float) -> String:
	if limit <= 0.0:
		return "noon"
	var sec: float = clampf(elapsed * TOD_DAY_SEC / limit, 0.0, TOD_DAY_SEC)
	for i in range(TOD_KEYS.size() - 1):
		if sec <= float(TOD_KEYS[i + 1][0]):
			var a: String = str(TOD_KEYS[i][1])
			var b: String = str(TOD_KEYS[i + 1][1])
			return a if a == b else "%s->%s" % [a, b]
	return str(TOD_KEYS[TOD_KEYS.size() - 1][1])


# ------------------------------------------------------------------ 一次性声音
func _shot(sound: String, db: float, pitch: float, bus_name: String) -> void:
	var s: AudioStream = Amb.stream(sound)
	if s == null or _shots.is_empty():
		return
	var p: AudioStreamPlayer = null
	for q in _shots:
		if not q.playing:
			p = q
			break
	if p == null:
		p = _shots[0]
	p.stream = s
	p.volume_db = db
	p.pitch_scale = pitch
	p.bus = Buses.bus_or_master(bus_name)
	p.play()


func _later(sec: float, sound: String, db: float, pitch: float, bus_name: String) -> void:
	if sec <= 0.0:
		_shot(sound, db, pitch, bus_name)
		return
	_queue.append({"t": _clock + sec, "sound": sound, "db": db, "pitch": pitch, "bus": bus_name})


func _later_call(sec: float, fn: Callable) -> void:
	_queue.append({"t": _clock + sec, "call": fn})


func _run_queue() -> void:
	if _queue.is_empty():
		return
	var keep: Array = []
	var due: Array = []
	for q: Dictionary in _queue:
		if _clock >= float(q.t):
			due.append(q)
		else:
			keep.append(q)
	_queue = keep
	for q: Dictionary in due:
		if q.has("call"):
			(q.call as Callable).call()
		else:
			_shot(str(q.sound), float(q.db), float(q.pitch), str(q.bus))


# ------------------------------------------------------------------ 小工具
func _count(k: String) -> void:
	_fired[k] = int(_fired.get(k, 0)) + 1


func debug_state() -> Dictionary:
	var layers: Dictionary = {}
	for k: String in _layers:
		var l: Amb.Layer = _layers[k]
		layers[k] = snappedf(l.volume_db, 0.1) if l.playing else -80.0
	var w: Dictionary = {}
	for k: String in _w:
		if float(_w[k]) > 0.0:
			w[k] = snappedf(float(_w[k]), 0.01)
	return {"active": _active, "screen": _screen, "bed": _bed, "tod": _tod, "weights": w, "layers": layers,
		"music_db": snappedf(_music.volume_db, 0.1) if _music != null and _music.playing else -80.0,
		"match_music_db": snappedf(_mmusic.volume_db, 0.1) if _mmusic != null and _mmusic.playing else -80.0,
		"match_music_pos": snappedf(_mmusic.get_playback_position(), 0.1) if _mmusic != null and _mmusic.playing else -1.0,
		"music_xfade": snappedf(_xf, 0.01),
		"duck_amb": snappedf(_duck_amb, 0.1), "duck_music": snappedf(_duck_music, 0.1),
		"lp_amb_hz": int(exp(_lp_amb)), "lp_music_hz": int(exp(_lp_music)), "fired": _fired.duplicate()}


func _load_json() -> Dictionary:
	if not FileAccess.file_exists(MIX_PATH):
		return {}
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(MIX_PATH))
	return d if d is Dictionary else {}


## JSON 盖在 DEFAULTS 上（字典往下合一层，缺的键用默认；下划线开头的是说明）
static func _merged(j: Dictionary) -> Dictionary:
	var out: Dictionary = DEFAULTS.duplicate(true)
	for k: String in j:
		if k.begins_with("_"):
			continue
		if out.get(k) is Dictionary and j[k] is Dictionary:
			var sub: Dictionary = (out[k] as Dictionary).duplicate(true)
			for kk: String in j[k]:
				if not kk.begins_with("_"):
					sub[kk] = j[k][kk]
			out[k] = sub
		else:
			out[k] = j[k]
	return out
