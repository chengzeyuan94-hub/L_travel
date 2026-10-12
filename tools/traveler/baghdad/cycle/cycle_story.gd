extends Node3D
## 雨世界（A）的时间线控制器：由 Codex 的 baghdad_ab_story.gd 改写而来，用于「下雨 → 开花发光 → 晚霞 → 下雨」循环。
##
## 与原版的区别：
## - 两个时钟分开：story_t 只决定光束 / 叶面发光 / 城灯 / 天空开口这些"剧情进度"，可以回到 0；
##   motion_t 单调递增，驱动雨、火、树风、人物动作、花的摆动，回环时不会跳变。
## - 开花的生长量由调用方直接给（growth，0..5.5 秒），这样晚霞段能保持盛开、回到下雨时能收回。
## - 叶面发光的目标强度可配（tree_glow_strength），用于软化树冠两块接近纯白的亮斑。
## 原版的时间点保持不变：光束 3.0–3.8 s 淡入、3–6 s 下探，叶面 6.2–8 s 发光，城灯 4–8 s 亮起。
const BEAM_START_SECONDS := 3.0
const BEAM_FADE_END_SECONDS := 3.8
const BEAM_ARRIVAL_SECONDS := 6.0
const TREE_GLOW_START_SECONDS := 6.2
const TRANSITION_END_SECONDS := 8.0
const CITY_START_SECONDS := 4.0

var _viewer: Node3D
var _pose: Node3D
var _flower: Node3D
var _rain: Node3D
var _motion: Node3D
var _city: Node3D
var _beam: SpotLight3D
var _bounce: SpotLight3D
var _sky: ShaderMaterial
var _camera: Camera3D
var _tree_materials: Array[Dictionary] = []
var _rain_materials: Array[Dictionary] = []
var _saved_beam: Dictionary = {}
var _saved_bounce: Dictionary = {}
var _saved_opening := 0.24
var _cfg: Dictionary = {}
var _state: Dictionary = {}
var _configured := false

func configure(viewer: Node3D, pose: Node3D, flower: Node3D, rain: Node3D, cfg: Dictionary) -> bool:
	name = "BaghdadCycleRainStory"
	_viewer = viewer
	_pose = pose
	_flower = flower
	_rain = rain
	_cfg = cfg
	var storm: Node3D = viewer.get("storm_look") as Node3D
	if storm == null:
		push_error("cycle story: 雨世界需要 storm look")
		return false
	_beam = storm.get("tree_beam") as SpotLight3D
	_bounce = storm.find_child("TreeWarmCloudBounce", true, false) as SpotLight3D
	_sky = storm.get("sky_material") as ShaderMaterial
	_camera = viewer.get("camera") as Camera3D
	if _beam == null or _bounce == null or _sky == null or _camera == null:
		push_error("cycle story: 缺光束 / 反光 / 天空 / 相机")
		return false
	# 换成可滚动的雨云天空（cycle_storm_sky.gdshader，uniform 与原版一致，cloud_scroll=0 时逐像素相同）
	var keep := {}
	for u in _sky.shader.get_shader_uniform_list():
		keep[u.name] = _sky.get_shader_parameter(u.name)
	_sky.shader = load("res://tools/traveler/baghdad/cycle/cycle_storm_sky.gdshader")
	for k in keep:
		if keep[k] != null:
			_sky.set_shader_parameter(k, keep[k])
	_saved_beam = {"energy": _beam.light_energy, "range": _beam.spot_range}
	_saved_bounce = {"energy": _bounce.light_energy}
	var opening: Variant = _sky.get_shader_parameter("opening_strength")
	_saved_opening = float(opening) if opening != null else 0.24
	_motion = load("res://scripts/traveler/baghdad/baghdad_ambient_motion.gd").new()
	add_child(_motion)
	if not bool(_motion.call("configure", viewer)):
		push_error("cycle story: 火与树风未能配置")
		return false
	_city = load("res://scripts/traveler/baghdad/baghdad_city_lights.gd").new()
	add_child(_city)
	if not bool(_city.call("configure", viewer)):
		push_error("cycle story: 远城窗灯未能配置")
		return false
	var tree: Node3D = viewer.get("tree") as Node3D
	var meshes: Array[Node] = tree.find_children("*", "MeshInstance3D", true, false)
	for item in meshes:
		var mesh := item as MeshInstance3D
		if mesh.mesh == null:
			continue
		for surface in mesh.mesh.get_surface_count():
			var material := mesh.get_active_material(surface) as ShaderMaterial
			if material != null and material.shader.code.contains("uniform float glow_strength"):
				_tree_materials.append({"material": material})
				# 软化亮斑：光锥羽化加宽（内锥角从外锥的 74% 降到 cfg 给的比例）
				var outer_cos: float = float(material.get_shader_parameter("beam_cos_outer"))
				var inner_ratio := float(cfg.get("tree_beam_inner_ratio", 0.74))
				var outer_angle := acos(clampf(outer_cos, -1.0, 1.0))
				material.set_shader_parameter("beam_cos_inner", cos(outer_angle * inner_ratio))
				if cfg.has("tree_glow_color"):
					var c: Array = cfg.tree_glow_color
					material.set_shader_parameter("glow_color", Color(float(c[0]), float(c[1]), float(c[2])))
	if _tree_materials.is_empty():
		push_error("cycle story: 找不到树冠发光材质")
		return false
	for material in _rain.get("_materials"):
		if material is ShaderMaterial and material.shader.code.contains("uniform float beam_strength"):
			_rain_materials.append({"material": material})
	var attributes := (_camera.attributes.duplicate() as CameraAttributesPractical) if _camera.attributes is CameraAttributesPractical else CameraAttributesPractical.new()
	attributes.dof_blur_near_enabled = false
	attributes.dof_blur_far_enabled = true
	attributes.dof_blur_far_distance = float(cfg.get("dof_far", 14.3))
	attributes.dof_blur_far_transition = float(cfg.get("dof_transition", 3.0))
	attributes.dof_blur_amount = float(cfg.get("dof_amount", 0.065))
	_camera.attributes = attributes
	_pose.set_process(false)
	_flower.set("autoplay", false)
	_flower.set_process(false)
	_rain.set_process(false)
	_configured = true
	set_state(0.0, 0.0, 0.0)
	return true

func set_state(story_t: float, motion_t: float, growth: float) -> void:
	if not _configured:
		return
	var t := clampf(story_t, 0.0, TRANSITION_END_SECONDS)
	var blend := smoothstep(BEAM_START_SECONDS, BEAM_FADE_END_SECONDS, t)
	var reach := smoothstep(BEAM_START_SECONDS, BEAM_ARRIVAL_SECONDS, t)
	var glow := smoothstep(TREE_GLOW_START_SECONDS, TRANSITION_END_SECONDS, t)
	var city := smoothstep(CITY_START_SECONDS, TRANSITION_END_SECONDS, t)
	_pose.call("set_time", motion_t)
	_flower.call("set_story_time", growth, motion_t)
	_rain.call("set_time", motion_t)
	_motion.call("set_time", motion_t)
	_city.call("set_amount", city, motion_t)
	_beam.visible = blend > 0.000001
	_beam.light_energy = float(_saved_beam.energy) * blend
	_beam.spot_range = float(_saved_beam.range) * lerpf(0.70, 1.0, reach)
	_bounce.visible = glow > 0.000001
	_bounce.light_energy = float(_saved_bounce.energy) * glow
	var glow_target := float(_cfg.get("tree_glow_strength", 6.5))
	for record in _tree_materials:
		(record.material as ShaderMaterial).set_shader_parameter("glow_strength", glow_target * glow)
		(record.material as ShaderMaterial).set_shader_parameter("beam_range", _beam.spot_range)
	for record in _rain_materials:
		(record.material as ShaderMaterial).set_shader_parameter("beam_strength", blend)
		(record.material as ShaderMaterial).set_shader_parameter("beam_range", _beam.spot_range)
	_sky.set_shader_parameter("opening_strength", _saved_opening * blend)
	_state = {"story_t": t, "motion_t": motion_t, "growth": growth, "beam": blend, "beam_reach": reach, "leaf_glow": glow, "city": city}

func set_sky_scroll(radians: float) -> void:
	if _sky != null:
		_sky.set_shader_parameter("cloud_scroll", radians)

func evidence() -> Dictionary:
	return {"configured": _configured, "state": _state, "tree_glow_strength": float(_cfg.get("tree_glow_strength", 6.5)),
		"tree_beam_inner_ratio": float(_cfg.get("tree_beam_inner_ratio", 0.74)), "tree_surfaces": _tree_materials.size(),
		"rain_beam_materials": _rain_materials.size()}
