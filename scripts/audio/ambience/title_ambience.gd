extends Node
## 开场环境音（方案 §3.1）：插在 lshu_title_screen 下面，开场自己只调几个方法告诉它状态。
## - 默认开场「旅行L叔」：山坡风 + 高频空气两层底床（随草花的阵风起伏 ±2 dB）；
##   鸟群飞过时叫几声，驼队可见时驼铃跟着它的淡入淡出，点 L叔 响一串铃，纸飞机出现时一阵风（占位）。
##   插画的状态只读 lshu_home_scene 的公开变量（_t / birds / camels / plane）和信号 lshu_poked，不改它。
## - 开场换成某一幕的成片时，1.5 秒交叉到那一幕的「明信片版」（1 到 2 层，比幕里轻）。
## - 选幕页打开时整体压 4 dB；进入某一幕时 0.4 秒淡出，回来 2 秒淡入；开场隐藏时 0.8 秒淡出。
## 参数在 data/audio/ambience/title.json（起点值，随时可调）；文件缺了就用下面 DEFAULTS。
## 无界面运行、测试、驱动脚本下什么都不建（Amb.allowed()）。

const Amb := preload("res://scripts/audio/ambience/amb_kit.gd")
const SELF_PATH := "res://scripts/audio/ambience/title_ambience.gd"

const DEFAULTS: Dictionary = {
	"crossfade_sec": 1.5,
	"show_in_sec": 2.0,
	"hide_out_sec": 0.8,
	"act_out_sec": 0.4,
	"act_back_sec": 2.0,
	"picker_duck_db": -4.0,
	"picker_sec": 0.6,
	"gust_mod_db": 2.0,
	"gust_layers": ["wind_open_bed_loop_v1", "breeze_hiss_bed_loop_v1"],
	"mixes": {
		"home": {"wind_open_bed_loop_v1": -12.0, "breeze_hiss_bed_loop_v1": -10.0},
		"changan": {"wind_leaves_bed_loop_v1": -8.5},
		"panti": {"wind_open_bed_loop_v1": -9.0, "campfire_bed_loop_v1": -15.0},
		"baghdad": {"rain_bed_long_loop_v1": -7.0},
		"lshu": {"birds_day_bed_loop_v1": -8.0, "breeze_hiss_bed_loop_v1": -6.0},
	},
	"birds": {"sounds": ["bird_call_v1", "bird_call_v2", "bird_call_v3", "bird_call_v4", "bird_call_v5"],
		"count": [3, 4], "window_sec": [1.5, 20.0], "volume_db": [-16.0, -12.0], "pitch": [0.95, 1.05]},
	"camel_bells": {"sound": "bell_small_ding_v1", "interval_sec": [1.4, 2.8], "volume_db": -20.0, "pitch": [0.78, 0.9]},
	"poke": {"sound": "bell_small_jingle_v1", "volume_db": -6.0},
	"plane_gust": {"enabled": true, "sound": "wind_leaves_gust_v1", "volume_db": -24.0, "pitch": 1.25},
	"changan_bell": {"sound": "temple_bell_v1", "interval_sec": [50.0, 90.0], "first_sec": 8.0, "volume_db": -17.0},
}

## lshu_home_scene 的实例（只读）
var home: Control

var _cfg: Dictionary = {}
var _layers: Dictionary = {}  # 声音名 -> Amb.Layer（按需建）
var _w: Dictionary = {}  # 混音名 -> 交叉进度 0..1
var _scene: String = "home"
var _shown: bool = false
var _in_act: bool = false
var _picker: bool = false
var _m_amp: float = 0.0  # 总推子（线性幅度）
var _m_goal: float = 0.0
var _m_rate: float = 1.0
var _m_db_applied: float = -80.0
var _birds: Amb.Scatter
var _camel: Amb.Scatter
var _poke: Amb.Scatter
var _gust: Amb.Scatter
var _temple: Amb.Scatter
var _last_ht: float = -1.0
var _bird_times: Array[float] = []
var _birds_prev: bool = false
var _plane_prev: bool = true  # 开场第一帧纸飞机若已在飞，不补那一阵风
var _camel_left: float = 1.0
var _clock: float = 0.0  # 近似 shader 的 TIME（引擎启动以来的秒数）
var _active: bool = false
var _fired: Dictionary = {}  # 各种点缀响过几次（debug_state 里看）


## 开场调用：允许出声时建一个挂到 parent 下并返回，否则返回 null（什么都不建）
static func attach(parent: Node, home_node: Control) -> Node:
	if not Amb.allowed():
		return null
	var m: Node = (load(SELF_PATH) as GDScript).new()
	m.name = "TitleAmbience"
	m.set("home", home_node)
	parent.add_child(m)
	return m


func _ready() -> void:
	if not Amb.allowed():
		queue_free()
		return
	_active = true
	_cfg = _merged(Amb.mix("title"))
	var b: Dictionary = _cfg.birds
	_birds = _scatter("AmbBirds", b.sounds, _v2(b.volume_db), _v2(b.pitch))
	var c: Dictionary = _cfg.camel_bells
	_camel = _scatter("AmbCamelBells", [c.sound], Vector2(float(c.volume_db), float(c.volume_db)), _v2(c.pitch))
	_camel_left = randf_range(float(c.interval_sec[0]), float(c.interval_sec[1]))
	var p: Dictionary = _cfg.poke
	_poke = _scatter("AmbPoke", [p.sound], Vector2(float(p.volume_db), float(p.volume_db)), Vector2.ONE)
	var g: Dictionary = _cfg.plane_gust
	_gust = _scatter("AmbPlaneGust", [g.sound], Vector2(float(g.volume_db), float(g.volume_db)), Vector2(float(g.pitch), float(g.pitch)))
	var t: Dictionary = _cfg.changan_bell
	_temple = _scatter("AmbTempleBell", [t.sound], Vector2(float(t.volume_db), float(t.volume_db)), Vector2(0.98, 1.02))
	_temple.interval = _v2(t.interval_sec)
	if home != null and is_instance_valid(home) and home.has_signal("lshu_poked"):
		home.connect("lshu_poked", _on_poked)
	if _w.is_empty():
		_w[_scene] = 1.0
	_clock = Time.get_ticks_msec() * 0.001
	_retarget(float(_cfg.show_in_sec))


func _exit_tree() -> void:
	if not _active:
		return
	if home != null and is_instance_valid(home) and home.is_connected("lshu_poked", _on_poked):
		home.disconnect("lshu_poked", _on_poked)
	for s: Amb.Scatter in _scatters():
		s.enabled = false
	Amb.release(self)


# ------------------------------------------------------------------ 开场调用的几个方法
## 开场背景换成 id（home / changan / panti / baghdad / lshu）；animate=false 时直接切，不交叉
func set_scene(id: String, animate: bool = true) -> void:
	if not _active:
		_scene = id
		return
	if not (_cfg.mixes as Dictionary).has(id):
		id = "home"
	if id == "changan" and _scene != "changan":
		_temple.setup(_temple.sounds, _temple.interval, _temple.volume, _temple.pitch, float(_cfg.changan_bell.first_sec))
	_scene = id
	if not animate:
		_w.clear()
		_w[id] = 1.0
	elif not _w.has(id):
		_w[id] = 0.0


func set_picker(open: bool) -> void:
	_picker = open
	if _active:
		_retarget(float(_cfg.picker_sec))


## 进入某一幕（true）/ 那一幕关掉回到开场（false）
func set_act(on: bool) -> void:
	_in_act = on
	if _active:
		_retarget(float(_cfg.act_out_sec) if on else float(_cfg.act_back_sec))


## 开场显示 / 隐藏
func set_shown(on: bool) -> void:
	_shown = on
	if _active:
		_retarget(float(_cfg.show_in_sec) if on else float(_cfg.hide_out_sec))


func debug_state() -> Dictionary:
	var layers: Dictionary = {}
	for k: String in _layers:
		var l: Amb.Layer = _layers[k]
		layers[k] = {"db": snappedf(l.volume_db, 0.1), "playing": l.playing}
	var w: Dictionary = {}
	for k: String in _w:
		w[k] = snappedf(float(_w[k]), 0.01)
	return {"scene": _scene, "weights": w, "master_db": snappedf(Amb.amp_to_db(_m_amp), 0.1), "shown": _shown,
		"in_act": _in_act, "picker": _picker, "layers": layers, "fired": _fired.duplicate()}


# ------------------------------------------------------------------ 每帧
func _process(delta: float) -> void:
	if not _active:
		return
	_clock += delta
	var xf: float = maxf(0.05, float(_cfg.crossfade_sec))
	for id: String in _w.keys():
		var goal: float = 1.0 if id == _scene else 0.0
		_w[id] = move_toward(float(_w[id]), goal, delta / xf)
		if id != _scene and float(_w[id]) <= 0.0:
			_w.erase(id)
	_m_amp = move_toward(_m_amp, _m_goal, _m_rate * delta)
	var m_db: float = Amb.amp_to_db(_m_amp)
	_drive_layers()
	_follow_master(m_db)
	_drive_home(delta)
	_temple.enabled = _scene == "changan" and _m_amp > 0.002
	_temple.gain_db = _mix_gain_db("changan") + m_db


## 每条底床的实际音量 = √(Σ 各混音交叉进度 × 该混音里这一层的功率) × 总推子
func _drive_layers() -> void:
	var mixes: Dictionary = _cfg.mixes
	var mod: float = _gust_db()
	var gust_layers: Array = _cfg.gust_layers
	var want: Dictionary = {}
	for id: String in _w:
		var w: float = float(_w[id])
		if w <= 0.0:
			continue
		var levels: Dictionary = mixes.get(id, {})
		for sound: String in levels:
			var db: float = float(levels[sound])
			if id == "home" and gust_layers.has(sound):
				db += mod
			var a: float = Amb.db_to_amp(db)
			want[sound] = float(want.get(sound, 0.0)) + w * a * a
	for sound: String in want:
		if not _layers.has(sound) and float(want[sound]) > 0.0:
			_layer(sound)
	for sound: String in _layers:
		var amp: float = sqrt(float(want.get(sound, 0.0))) * _m_amp
		var db_out: float = Amb.amp_to_db(amp)
		(_layers[sound] as Amb.Layer).set_level(db_out if db_out > -60.0 else -80.0, 0.12)


## 总推子变了：正在响的一次性声音跟着一起变；几乎无声时直接停掉
func _follow_master(m_db: float) -> void:
	var d: float = m_db - _m_db_applied
	if absf(d) < 0.001:
		return
	_m_db_applied = m_db
	var mute: bool = _m_amp <= 0.002
	for s: Amb.Scatter in _scatters():
		for q in s.get_children():
			var p := q as AudioStreamPlayer
			if p == null or not p.playing:
				continue
			if mute:
				p.stop()
			else:
				p.volume_db += d


## 默认开场插画的事件：鸟、驼铃、纸飞机（按插画自己的时间 _t 走，插画停了就不响）
func _drive_home(_delta: float) -> void:
	if home == null or not is_instance_valid(home):
		return
	var tv: Variant = home.get("_t")
	if not (tv is float):
		return
	var ht: float = tv
	var dh: float = 0.0 if _last_ht < 0.0 else ht - _last_ht
	if dh < 0.0:
		_bird_times.clear()
		dh = 0.0
	_last_ht = ht
	var m_db: float = Amb.amp_to_db(_m_amp)
	var home_db: float = _mix_gain_db("home") + m_db
	var audible: bool = _m_amp > 0.002 and float(_w.get("home", 0.0)) > 0.05
	for s: Amb.Scatter in [_birds, _camel, _gust]:
		s.gain_db = home_db
	if dh <= 0.0:
		return
	# 鸟群飞进画面的那一刻，排好接下来几声鸟叫
	var bv: bool = _birds_visible()
	if bv and not _birds_prev:
		var b: Dictionary = _cfg.birds
		var n: int = randi_range(int(b.count[0]), int(b.count[1]))
		_bird_times.clear()
		for i in n:
			_bird_times.append(ht + randf_range(float(b.window_sec[0]), float(b.window_sec[1])))
		_bird_times.sort()
	_birds_prev = bv
	while not _bird_times.is_empty() and ht >= _bird_times[0]:
		_bird_times.remove_at(0)
		if audible:
			_birds.fire()
			_count("birds")
	# 驼铃：驼队的淡入淡出系数就是它的音量
	_camel_left -= dh
	if _camel_left <= 0.0:
		var c: Dictionary = _cfg.camel_bells
		_camel_left = randf_range(float(c.interval_sec[0]), float(c.interval_sec[1]))
		var fade: float = _camel_fade(ht)
		if audible and fade > 0.05:
			_camel.fire(Amb.amp_to_db(fade))
			_count("camel_bells")
	# 纸飞机出现：一阵风（占位）
	var pv: bool = _plane_visible()
	if pv and not _plane_prev and audible and bool(_cfg.plane_gust.get("enabled", true)):
		_gust.fire()
		_count("plane_gust")
	_plane_prev = pv


func _on_poked() -> void:
	if _active and _m_amp > 0.002 and float(_w.get("home", 0.0)) > 0.5:
		_poke.gain_db = _mix_gain_db("home") + Amb.amp_to_db(_m_amp)
		_poke.fire()
		_count("poke")


# ------------------------------------------------------------------ 小工具
func _count(k: String) -> void:
	_fired[k] = int(_fired.get(k, 0)) + 1


func _retarget(sec: float) -> void:
	var goal_db: float = 0.0
	if not _shown or _in_act:
		goal_db = -80.0
	elif _picker:
		goal_db = float(_cfg.picker_duck_db)
	_m_goal = Amb.db_to_amp(goal_db)
	_m_rate = maxf(absf(_m_goal - _m_amp), 0.05) / maxf(0.05, sec)


## 某个混音当前的交叉增益（dB）：等功率，√进度
func _mix_gain_db(id: String) -> float:
	var w: float = float(_w.get(id, 0.0))
	return -80.0 if w <= 0.0001 else 10.0 * log(w) / log(10.0)


## 阵风：和插画里草花摆动的 shader 同一条曲线（0.6 + 0.4·sin(TIME·0.43 + 1.1)），映射到 ±gust_mod_db
func _gust_db() -> float:
	return sin(_clock * 0.43 + 1.1) * float(_cfg.gust_mod_db)


func _birds_visible() -> bool:
	var arr: Variant = home.get("birds")
	if arr is Array and not (arr as Array).is_empty():
		var d: Variant = (arr as Array)[0]
		if d is Dictionary and (d as Dictionary).get("node") is CanvasItem:
			return ((d as Dictionary).node as CanvasItem).visible
	# 读不到就按插画的公式算（每 38 秒一群，飞 24 秒）
	var ht: float = float(home.get("_t"))
	return fposmod(ht + 6.0, 38.0) < 24.0


func _plane_visible() -> bool:
	var p: Variant = home.get("plane")
	if p is CanvasItem:
		return (p as CanvasItem).visible
	var ht: float = float(home.get("_t"))
	return fposmod(ht + 12.0, 26.0) < 12.0


func _camel_fade(ht: float) -> float:
	var arr: Variant = home.get("camels")
	if arr is Array and not (arr as Array).is_empty():
		var d: Variant = (arr as Array)[0]
		if d is Dictionary and (d as Dictionary).get("node") is CanvasItem:
			return clampf(((d as Dictionary).node as CanvasItem).modulate.a, 0.0, 1.0)
	var cu: float = fposmod(ht * 3.2, 150.0)
	return clampf(cu / 12.0, 0.0, 1.0) * clampf((150.0 - cu) / 12.0, 0.0, 1.0)


func _layer(sound: String) -> Amb.Layer:
	var l: Amb.Layer = Amb.Layer.new().setup(sound, -80.0)
	add_child(l)
	_layers[sound] = l
	return l


func _scatter(name_: String, sounds: Array, vol: Vector2, pit: Vector2) -> Amb.Scatter:
	var s: Amb.Scatter = Amb.Scatter.new().setup(sounds, Vector2(3600, 3600), vol, pit, 3600.0)
	s.name = name_
	s.enabled = false
	add_child(s)
	return s


func _scatters() -> Array:
	var out: Array = []
	for s in [_birds, _camel, _poke, _gust, _temple]:
		if s != null and is_instance_valid(s):
			out.append(s)
	return out


static func _v2(a: Variant) -> Vector2:
	if a is Array and (a as Array).size() >= 2:
		return Vector2(float(a[0]), float(a[1]))
	var f: float = float(a) if (a is float or a is int) else 0.0
	return Vector2(f, f)


## JSON 盖在 DEFAULTS 上（字典往下合一层，缺的键用默认）
static func _merged(j: Dictionary) -> Dictionary:
	var out: Dictionary = DEFAULTS.duplicate(true)
	for k: String in j:
		if k.begins_with("_"):
			continue
		if out.get(k) is Dictionary and j[k] is Dictionary:
			var sub: Dictionary = (out[k] as Dictionary).duplicate(true)
			sub.merge(j[k] as Dictionary, true)
			out[k] = sub
		else:
			out[k] = j[k]
	return out
