extends Node
## 第一幕「长安」环境音（方案 §3.5）。由 atlas_viewer.gd 在 motion_director 装好之后调用 install(self)，
## 挂在 World 下；每帧读 host.look_profile.current_period_t（0 白天，1 黄昏），直接驱动各层音量。
## - 秋叶哗哗（常驻，白天→黄昏按 t 插值，另随画面里的树风 gust 轻微起伏）+ 低频风（常驻）
## - 白天鸟底床：振幅 ×(1−t)；城门火光：振幅 ×t（与 DuskFire 同一个 t）
## - 阵风随机点缀；t>0.5 时零星鸟叫
## - 寺庙钟：开场 +6 s 一次，之后 70–130 s 随机；L叔 在城门鞠躬时马上一下；过渡到黄昏落定后连敲 3 下
## 只在长安视图下出声（换到别的视图就淡出）；无界面、测试、探针脚本、截图模式下什么都不建。
## 参数：data/audio/ambience/changan.json（起点值，可以随时调）。
## 自检用：-- --amb-toggle-at=20,60 在这些秒数自动切一次白天/黄昏（等同点城门）；-- --amb-log 打印每一下钟声；
## -- --amb-stop-after=88 到这个秒数全部停掉（Movie Maker 录制用：假音频驱动在退出时不再混音，
## 退出那一刻还在播的循环来不及被音频线程回收，会报 ObjectDB leaked；真机关窗口没有这个问题）。

const Amb := preload("res://scripts/audio/ambience/amb_kit.gd")
const SCENE := "changan"
const SELF_PATH := "res://scripts/audio/ambience/changan_ambience.gd"

var host: Node3D
var p: Dictionary = {}
var _layers: Dictionary = {}
var _gusts: Node
var _calls: Node
var _bell: Node
var _elapsed := 0.0
var _gate := 0.0
var _bell_next := 6.0
var _bell_last := -1000.0
var _strikes: Array[float] = []
var _was_transition := false
var _last_state := ""
var _toggle_at: Array[float] = []
var _log := false
var _stop_after := -1.0


## 外面只调这一个：判断通过才新建节点（无界面 / 测试 / 探针 / 截图 / 非长安视图一律返回 null）
static func install(viewer: Node3D) -> Node:
	if not Amb.allowed() or viewer == null or not is_instance_valid(viewer):
		return null
	if str(viewer.get("selected")) != SCENE:
		return null
	var capture: Variant = viewer.get("capture_path")
	if capture is String and not (capture as String).is_empty():
		return null
	var node: Node = load(SELF_PATH).new()
	node.name = "ChanganAmbience"
	node.set("host", viewer)
	var parent: Variant = viewer.get("world")
	if parent is Node:
		(parent as Node).add_child(node)
	else:
		viewer.add_child(node)
	return node


func _ready() -> void:
	if not Amb.allowed() or host == null or not is_instance_valid(host):
		set_process(false)
		queue_free()
		return
	p = Amb.mix(SCENE)
	_layers["leaves"] = _add_layer(_s("leaves_bed", "sound", "wind_leaves_bed_loop_v1"))
	_layers["low_wind"] = _add_layer(_s("low_wind", "sound", "wind_open_bed_loop_v1"))
	_layers["day_birds"] = _add_layer(_s("day_birds", "sound", "birds_day_bed_loop_v1"))
	_layers["fire"] = _add_layer(_s("campfire", "sound", "campfire_bed_loop_v1"))
	_gusts = _add_scatter("gusts", ["wind_leaves_gust_v1"], Vector2(14, 32), Vector2(-9, -4), Vector2(0.94, 1.06))
	_calls = _add_scatter("dusk_calls", ["bird_call_v1", "bird_call_v2", "bird_call_v3", "bird_call_v4", "bird_call_v5"], Vector2(25, 50), Vector2(-16, -12), Vector2(0.95, 1.05))
	_bell = _add_scatter("temple_bell", [_s("temple_bell", "sound", "temple_bell_v1")], Vector2(70, 130), Vector2(-11, -9), Vector2(0.98, 1.02))
	_bell.set("enabled", false)  # 钟由下面的时间表敲，不用 Scatter 自己的随机计时
	_bell_next = _f("temple_bell", "first_s", 6.0)
	for a in preload("res://scripts/traveler/traveler_launch.gd").user_args():
		if a.begins_with("--amb-toggle-at="):
			for v in a.trim_prefix("--amb-toggle-at=").split(",", false):
				if v.is_valid_float():
					_toggle_at.append(float(v))
			_toggle_at.sort()
		if a == "--amb-log":
			_log = true
		if a.begins_with("--amb-stop-after=") and a.trim_prefix("--amb-stop-after=").is_valid_float():
			_stop_after = float(a.trim_prefix("--amb-stop-after="))
	print("CHANGAN_AMBIENCE_ON bus=", AudioServer.get_bus_index(Amb.BUS))


func _process(delta: float) -> void:
	if host == null or not is_instance_valid(host):
		return
	_elapsed += delta
	if _stop_after > 0.0 and _elapsed >= _stop_after:
		_silence(false)
		return
	_run_toggles()
	var on: bool = str(host.get("selected")) == SCENE
	var fade_in: float = maxf(0.1, _f("", "fade_in_s", 3.0))
	_gate = move_toward(_gate, 1.0 if on else 0.0, delta / fade_in)
	var t: float = _period_t()

	var master: float = _f("", "master_db", 0.0)
	var leaves_db: float = master + lerpf(_f("leaves_bed", "day_db", -2.0), _f("leaves_bed", "dusk_db", -4.0), t) + _visual_gust_db()
	_drive("leaves", leaves_db, _gate)
	_drive("low_wind", master + _f("low_wind", "db", -12.0), _gate)
	_drive("day_birds", master + _f("day_birds", "db", 0.0), _gate * (1.0 - t))
	_drive("fire", master + _f("campfire", "db", -10.0), _gate * t)

	if is_instance_valid(_gusts):
		_gusts.set("enabled", on)
		_gusts.set("gain_db", master + _f("gusts", "dusk_offset_db", -2.0) * t)
	if is_instance_valid(_calls):
		_calls.set("enabled", on and t > _f("dusk_calls", "min_t", 0.5))
		_calls.set("gain_db", master)
	if is_instance_valid(_bell):
		_bell.set("gain_db", master)
	_bells(delta, on)


func _exit_tree() -> void:
	_silence(true)
	_layers.clear()
	Amb.release(self)


## 全部停掉。release=true 时连流一起放掉（退出场景用）
func _silence(release: bool) -> void:
	set_process(false)
	for key in _layers:
		var l: Variant = _layers[key]
		if is_instance_valid(l):
			(l as Node).set_process(false)
			(l as AudioStreamPlayer).stop()
			if release:
				(l as AudioStreamPlayer).stream = null
	for s in [_gusts, _calls, _bell]:
		if is_instance_valid(s):
			s.set("enabled", false)
			for c in (s as Node).get_children():
				if c is AudioStreamPlayer:
					(c as AudioStreamPlayer).stop()
					if release:
						(c as AudioStreamPlayer).stream = null


# ---------- 驱动量 ----------

func _period_t() -> float:
	var lp: Variant = host.get("look_profile")
	if lp is Object and is_instance_valid(lp):
		var v: Variant = (lp as Object).get("current_period_t")
		if v is float or v is int:
			return clampf(float(v), 0.0, 1.0)
	# 没有 lookdev（比如不带 --dusk/--look 打开）：按静态白天/黄昏
	return 1.0 if bool(host.get("look_dusk")) or bool(host.get("night")) else 0.0


## 画面里的树风：motion_director.gust(anim_t) 约 0.55–1.55，映射成 ±follow_visual_gust_db
func _visual_gust_db() -> float:
	var depth: float = _f("leaves_bed", "follow_visual_gust_db", 1.5)
	var md: Variant = host.get("motion_director")
	if depth == 0.0 or not (md is Object) or not is_instance_valid(md) or not (md as Object).has_method("gust"):
		return 0.0
	var g: float = float((md as Object).call("gust", float((md as Object).get("anim_t"))))
	return clampf((g - 1.05) / 0.5, -1.0, 1.0) * depth


func _run_toggles() -> void:
	while not _toggle_at.is_empty() and _elapsed >= _toggle_at[0]:
		_toggle_at.pop_front()
		if host.has_method("toggle_period_transition"):
			host.call("toggle_period_transition")
			print("CHANGAN_AMBIENCE_TOGGLE t=", snappedf(_elapsed, 0.1))


# ---------- 寺庙钟 ----------

func _bells(delta: float, on: bool) -> void:
	if not on:
		_strikes.clear()
		_bell_next += delta
		_was_transition = false
		return
	var lp: Variant = host.get("look_profile")
	var has_lp: bool = lp is Object and is_instance_valid(lp)
	var in_transition: bool = has_lp and bool((lp as Object).get("transition_active"))
	# ④ 过渡到黄昏落定：连敲 3 下；刚刚响过一下（比如鞠躬那一下）就把它算作第一下
	if _was_transition and not in_transition and has_lp and bool((lp as Object).get("look_dusk")):
		var gap: float = _f("temple_bell", "strike_gap_s", 5.5)
		var count: int = int(_f("temple_bell", "dusk_strikes", 3.0))
		var start: float = _elapsed
		if _elapsed - _bell_last < gap:
			start = _bell_last + gap
			count -= 1
		_strikes.clear()
		for i in maxi(count, 0):
			_strikes.append(start + gap * i)
	# 往回切到白天：没敲完的就不敲了
	if in_transition and has_lp and not bool((lp as Object).get("transition_target_dusk")):
		_strikes.clear()
	_was_transition = in_transition
	if not _strikes.is_empty():
		if _elapsed >= _strikes[0]:
			_strikes.pop_front()
			_ring("dusk_strike")
		return
	# ③ L叔 在城门鞠躬：马上一下（离上一下太近就不重复）
	var cc: Variant = host.get("character_controller")
	if cc is Object and is_instance_valid(cc):
		var st: String = str((cc as Object).get("state"))
		if _log and st != _last_state:
			print("CHANGAN_AMBIENCE_CHARACTER ", st, " t=", snappedf(_elapsed, 0.01))
		if st == "bow" and _last_state != "bow" and _f("temple_bell", "on_bow", 1.0) > 0.0:
			if _elapsed - _bell_last >= _f("temple_bell", "min_gap_s", 4.0):
				_ring("bow")
		_last_state = st
	# ① 开场 +6 s、② 之后每 70–130 s
	if _elapsed >= _bell_next:
		_ring("schedule")


func _ring(reason: String) -> void:
	if is_instance_valid(_bell):
		_bell.call("fire")
	if _log:
		print("CHANGAN_AMBIENCE_BELL ", reason, " t=", snappedf(_elapsed, 0.01), " period_t=", snappedf(_period_t(), 0.01))
	_bell_last = _elapsed
	var every: Vector2 = _v2("temple_bell", "interval_s", Vector2(70, 130))
	_bell_next = _elapsed + randf_range(every.x, every.y)


# ---------- 节点与参数 ----------

func _add_layer(sound: String) -> Node:
	var l: Node = Amb.Layer.new().setup(sound, -80.0)
	add_child(l)
	return l


func _add_scatter(key: String, sounds: Array, every: Vector2, vol: Vector2, pit: Vector2) -> Node:
	var list: Variant = _sec(key).get("sounds", sounds)
	var first: float = _f(key, "first_delay_s", -1.0)
	var s: Node = Amb.Scatter.new().setup(list if list is Array else sounds, _v2(key, "interval_s", every), _v2(key, "db", vol), _v2(key, "pitch", pit), first)
	s.name = "Amb_" + key
	add_child(s)
	return s


## 振幅乘数 gain（0–1）叠到 db 上：gain 近 0 时直接 −80，让 Layer 停播省 CPU
func _drive(key: String, db: float, gain: float) -> void:
	var l: Variant = _layers.get(key)
	if not is_instance_valid(l):
		return
	var level: float = -80.0 if gain <= 0.002 else db + Amb.amp_to_db(gain)
	(l as Node).call("set_level", level, 0.25)


func _sec(key: String) -> Dictionary:
	if key.is_empty():
		return p
	var d: Variant = p.get(key)
	return d if d is Dictionary else {}


func _f(key: String, field: String, fallback: float) -> float:
	var v: Variant = _sec(key).get(field)
	if v is bool:
		return 1.0 if v else 0.0
	return float(v) if (v is float or v is int) else fallback


func _s(key: String, field: String, fallback: String) -> String:
	var v: Variant = _sec(key).get(field)
	return v if v is String and not (v as String).is_empty() else fallback


func _v2(key: String, field: String, fallback: Vector2) -> Vector2:
	var v: Variant = _sec(key).get(field)
	if v is Array and (v as Array).size() >= 2:
		return Vector2(float(v[0]), float(v[1]))
	return fallback
