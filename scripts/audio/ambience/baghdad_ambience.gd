extends Node
## 第三幕「巴格达」环境声（方案 §3.7）。review_cycle.gd 在 ready_state 置真之后 root.add_child 挂上来，
## 每帧读 SceneTree（review_cycle）上的 i_state / i_trans / _state，直接驱动各层音量：
## - 下雨：雨声底床 + 空旷地的风（暴风天）
## - 转开花（to_bloom，8 s）：雨按 cos 淡出、白天鸟底床按 sin 淡入；进度过 0.35 时响「雨停了」的第一声鸟叫；
##   土豆花长到 0.3 / 0.6 / 0.9 时各叮一下（可在参数里关掉）
## - 转晚霞（to_dusk）：鸟降下去，树风升起，篝火淡入；晚霞停留时零星鸟叫
## - 转回雨（to_rain）：开头一阵风，雨淡入；鸟和篝火用一半时间淡出
## 每个过渡都用进度 p 做等功率交叉（出 = cos(p·π/2)，入 = sin(p·π/2)，两头都有的层按功率插值，不会鼓包）。
## to_bloom 的 _state.progress 恒为 0，所以用 story_t / 8 s（Codex 开花剧情的长度）当进度；另外两段用 _state.progress。
## 点击模式读 i_state / i_trans；自动循环（--cycle-auto、抽查、测帧）按 _state.cycle_t 和 cfg.timeline 推出同样的状态。
## 读不到这些量时退回参数里的 fallback_state 静态混音。空格暂停只冻结画面，环境照常播。
## 参数在 data/audio/ambience/baghdad.json（起点值，可以随时调）。无界面 / 测试 / 驱动脚本下什么都不建、不读。
## 自检用：-- --amb-log 每次状态变化、每个事件音（第一声鸟叫 / 土豆花叮 / 阵风）打印一行，带进程帧号，方便对照 Movie Maker 录音。
const Amb := preload("res://scripts/audio/ambience/amb_kit.gd")
const SCENE := "baghdad"
const LAYERS := ["rain", "wind_open", "birds", "wind_leaves", "campfire"]
const BLOOM_STORY_END := 8.0   # cycle_story.gd 的 TRANSITION_END_SECONDS：开花剧情到 8 s 走完
const FROM_TO := {"to_bloom": ["rain", "bloom"], "to_dusk": ["bloom", "dusk"], "to_rain": ["dusk", "rain"]}

## 循环状态在哪儿读：2026-09-27 起循环是节点 baghdad_cycle.gd（挂的时候把自己设进来）；没设时退回读 SceneTree（旧用法）
var driver: Object
var m: Dictionary = {}
var master_db := 0.0
var fade_in_s := 3.0
var follow_s := 0.3
var fallback_state := "rain"
var _layers: Dictionary = {}
var _states: Dictionary = {}
var _speed: Dictionary = {}
var _first_bird: Node
var _dings: Node
var _gust: Node
var _dusk_birds: Node
var _first_bird_at := 0.35
var _ding_fracs: Array = [0.3, 0.6, 0.9]
var _ding_pitches: Array = [1.26, 1.5, 1.68]
var _dings_on := true
var _age := 0.0
var _label := ""
var _trans := ""
var _prev_p := 0.0
var _prev_frac := -1.0
var _bird_done := false
var _log := false
var _dusk_busy := 0


func _ready() -> void:
	if not Amb.allowed():
		set_process(false)
		queue_free()
		return
	name = "BaghdadAmbience"
	_log = preload("res://scripts/traveler/traveler_launch.gd").user_args().has("--amb-log")
	m = Amb.mix(SCENE)
	master_db = float(m.get("master_db", master_db))
	fade_in_s = maxf(0.05, float(m.get("fade_in_s", fade_in_s)))
	follow_s = maxf(0.05, float(m.get("follow_s", follow_s)))
	fallback_state = str(m.get("fallback_state", fallback_state))
	_states = _dict(m, "states")
	if _states.is_empty():
		_states = {"rain": {"rain": 1.5, "wind_open": -2.5}, "bloom": {"birds": 5.0, "wind_open": -4.0},
			"dusk": {"birds": -2.0, "wind_leaves": 0.0, "campfire": -4.0, "wind_open": -8.0}}
	var trans_cfg: Dictionary = _dict(m, "transitions")
	for key in FROM_TO:
		_speed[key] = _dict(_dict(trans_cfg, key), "speed")
	var sounds: Dictionary = _dict(m, "sounds")
	var default_sounds := {"rain": "rain_bed_long_loop_v1", "wind_open": "wind_open_bed_loop_v1", "birds": "birds_day_bed_loop_v1",
		"wind_leaves": "wind_leaves_bed_loop_v1", "campfire": "campfire_bed_loop_v1"}
	for key in LAYERS:
		var layer: Node = Amb.Layer.new().setup(str(sounds.get(key, default_sounds[key])))
		_layers[key] = layer
		add_child(layer)

	var fb: Dictionary = _dict(m, "first_bird_call")
	_first_bird_at = float(fb.get("at_progress", _first_bird_at))
	var fb_db := float(fb.get("volume_db", -3.0))
	_first_bird = _one_shot("AmbFirstBird", [str(fb.get("sound", "bird_call_v6"))], Vector2(fb_db, fb_db), _vec2(fb, "pitch", Vector2(0.98, 1.02)))

	var dg: Dictionary = _dict(m, "potato_dings")
	_dings_on = bool(dg.get("enabled", true))
	if _dings_on:
		_ding_fracs = dg.get("growth_fractions", _ding_fracs)
		_ding_pitches = dg.get("pitches", _ding_pitches)
		var dg_db := float(dg.get("volume_db", -14.0))
		_dings = _one_shot("AmbPotatoDings", [str(dg.get("sound", "bell_small_ding_v1"))], Vector2(dg_db - 1.0, dg_db + 1.0), Vector2.ONE)

	var gu: Dictionary = _dict(m, "rain_gust")
	var gu_db := float(gu.get("volume_db", 0.0))
	_gust = _one_shot("AmbRainGust", [str(gu.get("sound", "wind_leaves_gust_v1"))], Vector2(gu_db - 1.0, gu_db + 1.0), _vec2(gu, "pitch", Vector2(0.96, 1.04)))

	var db_cfg: Dictionary = _dict(m, "dusk_birds")
	_dusk_birds = Amb.Scatter.new().setup(db_cfg.get("sounds", ["bird_call_v1", "bird_call_v2", "bird_call_v3", "bird_call_v4", "bird_call_v5"]),
		_vec2(db_cfg, "interval_s", Vector2(12, 25)), _vec2(db_cfg, "volume_db", Vector2(-11, -8)),
		_vec2(db_cfg, "pitch", Vector2(0.95, 1.05)), float(db_cfg.get("first_delay_s", 4.0)))
	_dusk_birds.name = "AmbDuskBirds"
	_dusk_birds.enabled = false
	add_child(_dusk_birds)

	_process(0.0)
	print("BAGHDAD_AMBIENCE_READY ", JSON.stringify({"state": _label, "frame": Engine.get_process_frames()}))


func _process(delta: float) -> void:
	_age += delta
	var d: Dictionary = _drive()
	var trans: String = d.trans
	var p: float = d.p
	var label: String = trans if trans != "" else str(d.state)
	var sec: float = fade_in_s if _age < fade_in_s else follow_s
	if label != _label:
		_label = label
		_event("state")

	# 过渡开始（换了一段，或同一段被重播、进度倒回去）：重置这一段的一次性触发
	if trans != "" and (trans != _trans or p < _prev_p - 0.2):
		_bird_done = false
		if trans == "to_rain" and is_instance_valid(_gust):
			_gust.gain_db = master_db
			_gust.fire()
			_event("rain_gust")
	_trans = trans
	_prev_p = p if trans != "" else 0.0

	# 各层音量
	var from_mix: Dictionary
	var to_mix: Dictionary
	if trans != "":
		var pair: Array = FROM_TO[trans]
		from_mix = _dict(_states, pair[0])
		to_mix = _dict(_states, pair[1])
	else:
		from_mix = _dict(_states, str(d.state))
		to_mix = from_mix
	var speed: Dictionary = _speed.get(trans, {}) if trans != "" else {}
	for key in LAYERS:
		var a: float = Amb.db_to_amp(float(from_mix.get(key, -80.0)))
		var b: float = Amb.db_to_amp(float(to_mix.get(key, -80.0)))
		var q: float = clampf(p * float(speed.get(key, 1.0)), 0.0, 1.0) if trans != "" else 1.0
		var co: float = cos(q * PI * 0.5)
		var si: float = sin(q * PI * 0.5)
		var amp: float = sqrt(a * a * co * co + b * b * si * si)
		var layer: Node = _layers.get(key)
		if is_instance_valid(layer):
			layer.set_level(Amb.amp_to_db(amp) + master_db if amp > 0.0001 else -80.0, sec)

	# 「雨停了」的第一声鸟叫：只在正常推进的转开花里响一次（跳段直接越过的不补）
	if trans == "to_bloom" and not _bird_done and p >= _first_bird_at:
		_bird_done = true
		if p < _first_bird_at + 0.3 and is_instance_valid(_first_bird):
			_first_bird.gain_db = master_db
			_first_bird.fire()
			_event("first_bird_call")

	# 土豆花叮：生长比例向上跨过阈值时叮一下；一帧里跨过不止一个就是跳段，不叮
	var frac: float = d.growth_frac
	if _dings_on and is_instance_valid(_dings) and trans == "to_bloom" and _prev_frac >= 0.0 and frac > _prev_frac:
		var crossed: Array = []
		for i in _ding_fracs.size():
			var th := float(_ding_fracs[i])
			if _prev_frac < th and frac >= th:
				crossed.append(i)
		if crossed.size() == 1:
			var i: int = crossed[0]
			_dings.gain_db = master_db
			_dings.fire(0.0, float(_ding_pitches[i % _ding_pitches.size()]) if not _ding_pitches.is_empty() else 1.5)
			_event("potato_ding_%d" % i)
	_prev_frac = frac

	if is_instance_valid(_dusk_birds):
		_dusk_birds.enabled = trans == "" and str(d.state) == "dusk"
		_dusk_birds.gain_db = master_db
		if _log:
			var busy := 0
			for q in _dusk_birds.get_children():
				if q is AudioStreamPlayer and (q as AudioStreamPlayer).playing:
					busy += 1
			if busy > _dusk_busy:
				_event("dusk_bird_call")
			_dusk_busy = busy


func _exit_tree() -> void:
	set_process(false)
	Amb.release(self)


func _event(what: String) -> void:
	if _log:
		print("BAGHDAD_AMBIENCE_EVENT ", JSON.stringify({"event": what, "state": _label, "frame": Engine.get_process_frames(), "age": snappedf(_age, 0.01)}))


## 当前状态：{state, trans, p, growth_frac}。trans 为空表示停在某个状态。
func _drive() -> Dictionary:
	var out := {"state": fallback_state, "trans": "", "p": 0.0, "growth_frac": 0.0}
	var tree: Object = driver if driver != null and is_instance_valid(driver) else get_tree()
	if tree == null:
		return out
	var st: Variant = tree.get("_state")
	if not (st is Dictionary) or (st as Dictionary).is_empty():
		return out
	var s: Dictionary = st
	var cfg: Variant = tree.get("cfg")
	var timeline: Dictionary = _dict(cfg, "timeline") if cfg is Dictionary else {}
	var flower: Dictionary = _dict(cfg, "flower") if cfg is Dictionary else {}
	var t1 := float(timeline.get("bloom_story_seconds", BLOOM_STORY_END))
	var full := maxf(0.001, float(flower.get("growth_full", 5.5)))
	out.growth_frac = clampf(float(s.get("growth", 0.0)) / full, 0.0, 1.0)
	var state := ""
	var trans := ""
	var interactive: Variant = tree.get("interactive")
	var i_state: Variant = tree.get("i_state")
	var i_trans: Variant = tree.get("i_trans")
	if interactive is bool and interactive and i_state is String and i_trans is String:
		state = i_state
		trans = i_trans
	elif s.has("cycle_t") and not timeline.is_empty():
		var c := float(s.cycle_t)
		var t2 := t1 + float(timeline.get("to_dusk_seconds", 8.0))
		var t3 := t2 + float(timeline.get("dusk_hold_seconds", 10.0))
		var t4 := t3 + float(timeline.get("to_rain_seconds", 4.0))
		if c < t1:
			trans = "to_bloom"
		elif c < t2:
			trans = "to_dusk"
		elif c < t3:
			state = "dusk"
		elif c < t4:
			trans = "to_rain"
		else:
			state = "rain"
	else:
		return out
	if trans != "" and not FROM_TO.has(trans):
		trans = ""
	if trans == "to_bloom":
		out.p = clampf(float(s.get("story_t", 0.0)) / maxf(0.001, minf(t1, BLOOM_STORY_END)), 0.0, 1.0)
	elif trans != "":
		out.p = clampf(float(s.get("progress", 0.0)), 0.0, 1.0)
	out.trans = trans
	out.state = state if _states.has(state) else fallback_state
	return out


func _one_shot(node_name: String, list: Array, vol: Vector2, pit: Vector2) -> Node:
	var s: Node = Amb.Scatter.new().setup(list, Vector2(1e9, 1e9), vol, pit, 1e9)
	s.name = node_name
	s.enabled = false
	add_child(s)
	return s


static func _dict(d: Variant, key: String) -> Dictionary:
	if not (d is Dictionary):
		return {}
	var v: Variant = (d as Dictionary).get(key)
	return v if v is Dictionary else {}


static func _vec2(d: Dictionary, key: String, fallback_value: Vector2) -> Vector2:
	var v: Variant = d.get(key)
	if v is Array and (v as Array).size() >= 2:
		return Vector2(float(v[0]), float(v[1]))
	return fallback_value
