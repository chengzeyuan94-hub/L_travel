extends Node
## 第二幕「盘橐」环境声（方案 §3.6）。由 panti_viewer.gd 挂成子节点，每帧读时段权重 w（0 清晨，1 午夜）：
## - 空旷地的风：常驻，清晨→午夜略收
## - 高空嘶风：音量 × (1 − w)，午夜完全消失
## - 篝火：常驻，夜里更旺
## - 晨鸟：w 低于阈值时零星叫
## - 流星叮：到午夜后和 panti_night_sky 的流星同一时钟，每颗流星出现时叮一下（暂停时跟着停）
## 参数在 data/audio/ambience/panti.json。无界面 / 测试 / 驱动脚本下什么都不建、不读。
const Amb := preload("res://scripts/audio/ambience/amb_kit.gd")

var viewer: Node
var wind: AudioStreamPlayer
var hiss: AudioStreamPlayer
var fire: AudioStreamPlayer
var birds: Node
var dings: Node

var master_db := 0.0
var fade_in_s := 3.0
var follow_s := 0.25
var wind_db := Vector2(-2.0, -5.0)
var hiss_db := -6.0
var fire_db := Vector2(-5.0, -1.0)
var bird_max_w := 0.3
var fallback: Dictionary = {}

var meteor_on := true
var meteor_db := -22.0
var meteor_pitches: Array = [1.5, 1.68, 2.0]
var meteor_min_star := 0.05
var meteor_cycle := 32.0
var meteor_starts: Array = [2.0, 6.8, 11.6]
var _prev_phase := -1.0
var _age := 0.0


func _ready() -> void:
	if not Amb.allowed():
		set_process(false)
		queue_free()
		return
	name = "PantiAmbience"
	viewer = get_parent()
	var m: Dictionary = Amb.mix("panti")
	master_db = float(m.get("master_db", master_db))
	fade_in_s = maxf(0.05, float(m.get("fade_in_s", fade_in_s)))
	follow_s = maxf(0.05, float(m.get("follow_s", follow_s)))
	var w_cfg: Dictionary = _dict(m, "wind")
	var h_cfg: Dictionary = _dict(m, "hiss")
	var f_cfg: Dictionary = _dict(m, "fire")
	var b_cfg: Dictionary = _dict(m, "birds")
	var d_cfg: Dictionary = _dict(m, "meteor_dings")
	fallback = _dict(m, "fallback_weight")
	wind_db = Vector2(float(w_cfg.get("morning_db", wind_db.x)), float(w_cfg.get("midnight_db", wind_db.y)))
	hiss_db = float(h_cfg.get("db", hiss_db))
	fire_db = Vector2(float(f_cfg.get("morning_db", fire_db.x)), float(f_cfg.get("midnight_db", fire_db.y)))
	bird_max_w = float(b_cfg.get("max_weight", bird_max_w))

	wind = Amb.Layer.new().setup(str(w_cfg.get("sound", "wind_open_bed_loop_v1")))
	hiss = Amb.Layer.new().setup(str(h_cfg.get("sound", "breeze_hiss_bed_loop_v1")))
	fire = Amb.Layer.new().setup(str(f_cfg.get("sound", "campfire_bed_loop_v1")))
	for layer in [wind, hiss, fire]:
		add_child(layer)

	var bird_list: Array = b_cfg.get("sounds", ["bird_call_v1", "bird_call_v2", "bird_call_v3", "bird_call_v4", "bird_call_v5"])
	birds = Amb.Scatter.new().setup(bird_list, _vec2(b_cfg, "interval_s", Vector2(18, 40)),
		_vec2(b_cfg, "volume_db", Vector2(-18, -14)), _vec2(b_cfg, "pitch", Vector2(0.95, 1.05)),
		float(b_cfg.get("first_delay_s", 5.0)))
	birds.name = "AmbBirds"
	add_child(birds)

	meteor_on = bool(d_cfg.get("enabled", true))
	if meteor_on:
		meteor_db = float(d_cfg.get("volume_db", meteor_db))
		meteor_pitches = d_cfg.get("pitches", meteor_pitches)
		meteor_min_star = float(d_cfg.get("min_star_weight", meteor_min_star))
		dings = Amb.Scatter.new().setup([str(d_cfg.get("sound", "bell_small_ding_v1"))], Vector2(1e9, 1e9),
			Vector2(meteor_db, meteor_db), Vector2.ONE, 1e9)
		dings.name = "AmbMeteorDings"
		dings.enabled = false
		add_child(dings)
		_read_meteor_schedule()
	_process(0.0)
	print("PANTI_AMBIENCE_READY ", JSON.stringify({"weight": _weight(), "meteor_cycle_s": meteor_cycle, "meteor_starts_s": meteor_starts}))


func _process(delta: float) -> void:
	_age += delta
	var w: float = _weight()
	var sec: float = fade_in_s if _age < fade_in_s else follow_s
	_level(wind, lerpf(wind_db.x, wind_db.y, w) + master_db, sec)
	_level(hiss, hiss_db + Amb.amp_to_db(1.0 - w) + master_db, sec)
	_level(fire, lerpf(fire_db.x, fire_db.y, w) + master_db, sec)
	if is_instance_valid(birds):
		birds.enabled = w < bird_max_w
		birds.gain_db = master_db
	_meteors(w)


func _exit_tree() -> void:
	set_process(false)
	# 子节点（各层、点缀）先于这里离树，已经各自 stop 并清空 stream；这里再兜一遍，出过声就等音频线程释放
	Amb.release(self, _age > 0.0)


## 0 清晨，1 午夜；时段过渡不存在时（比如切到 day / sunset 静态光）按 lighting_period 给一个静态值
func _weight() -> float:
	if not is_instance_valid(viewer):
		return 0.0
	var pt: Variant = viewer.get("period_transition")
	if pt is Object and is_instance_valid(pt):
		var w: Variant = (pt as Object).get("weight")
		if w is float or w is int:
			return clampf(float(w), 0.0, 1.0)
	var period: Variant = viewer.get("lighting_period")
	return clampf(float(fallback.get(str(period), 0.0)), 0.0, 1.0)


func _level(layer: AudioStreamPlayer, db: float, sec: float) -> void:
	if is_instance_valid(layer) and layer.has_method("set_level"):
		layer.set_level(db, sec)


## 流星：night_sky 在到达午夜那一刻记下 meteor_origin_t，之后流星时间 = anim_t − origin，按周期取余。
## 这里每帧看同一个时间有没有跨过某颗流星的起点，跨过就叮一下；音量乘上流星在画面里的可见度。
func _meteors(w: float) -> void:
	if not meteor_on or not is_instance_valid(dings):
		return
	var sky: Object = _night_sky()
	if sky == null or not bool(sky.get("meteor_started")):
		_prev_phase = -1.0
		return
	var t: float = maxf(float(sky.get("anim_t")) - float(sky.get("meteor_origin_t")), 0.0)
	var phase: float = fposmod(t, meteor_cycle)
	if _prev_phase >= 0.0:
		var span: float = phase - _prev_phase
		if span < 0.0:
			span += meteor_cycle
		# 只认正常的一帧推进；暂停（时间不动）或跳帧不补叮
		if span > 0.0 and span < 1.0:
			var star: float = smoothstep(0.3, 0.9, w)
			for i in meteor_starts.size():
				var ahead: float = fposmod(float(meteor_starts[i]) - _prev_phase, meteor_cycle)
				if ahead > 0.0 and ahead <= span and star > meteor_min_star:
					var pitch: float = float(meteor_pitches[i % meteor_pitches.size()]) if not meteor_pitches.is_empty() else 1.5
					dings.gain_db = master_db
					dings.fire(Amb.amp_to_db(star), pitch)
	_prev_phase = phase


func _night_sky() -> Object:
	if not is_instance_valid(viewer):
		return null
	var look: Variant = viewer.get("look_profile")
	if look is Object and is_instance_valid(look):
		var sky: Variant = (look as Object).get("night_sky")
		if sky is Object and is_instance_valid(sky):
			return sky
	return null


func _read_meteor_schedule() -> void:
	var sky: Object = _night_sky()
	var params: Variant = sky.get("meteor_params") if sky != null else null
	if not (params is Dictionary):
		var p: String = "res://data/traveler/panti_meteors.json"
		params = JSON.parse_string(FileAccess.get_file_as_string(p)) if FileAccess.file_exists(p) else null
	if params is Dictionary and (params as Dictionary).get("uniforms") is Dictionary:
		var u: Dictionary = params.uniforms
		meteor_cycle = maxf(1.0, float(u.get("meteor_cycle_s", meteor_cycle)))
		var starts: Variant = u.get("meteor_start_times_s")
		if starts is Array and not (starts as Array).is_empty():
			meteor_starts = starts


static func _dict(d: Dictionary, key: String) -> Dictionary:
	var v: Variant = d.get(key)
	return v if v is Dictionary else {}


static func _vec2(d: Dictionary, key: String, fallback_value: Vector2) -> Vector2:
	var v: Variant = d.get(key)
	if v is Array and (v as Array).size() >= 2:
		return Vector2(float(v[0]), float(v[1]))
	return fallback_value
