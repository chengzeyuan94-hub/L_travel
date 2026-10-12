extends RefCounted
## 巴格达旅人·生命树风动 + 落叶飘散 导演探针（key: tree，2026-09-23）。
##
## 1) 树摆动：把 viewer.tree 的 material_override（_apply_lowpoly_materials 复制出的
##    StandardMaterial3D + 金边 next_pass）换成 lookdev_tree_wind.gdshader（逐项复刻原材质外观、
##    顶点里加风），金边换成 lookdev_tree_rim.gdshader（同一套顶点变形，原金边参数原样搬过来）。
##    阴影 pass 走主材质的 vertex()，长影子跟着动。
## 2) 落叶：LookdevFallingLeaves 的 ParticleProcessMaterial 换成 lookdev_tree_leaves.gdshader
##    （被风带向画面左侧、钟摆荡、边飘边翻），绘制材质换成带 BACKLIGHT 的 lookdev_tree_leaf.gdshader。
## 3) 时钟：一个 Node 子节点在 _process 里用双精度累加各周期相位并取模 2π，
##    每帧同步给树主材质、金边、落叶——无限运行也不会因 TIME 回绕跳变。
## 风向：-camera.global_basis.x 压平到水平面再归一化（画面右 → 左）。

class WindClock extends Node:
	var mats: Array = []
	var leaf_mat: ShaderMaterial
	var sway_w := [0.0, 0.0, 0.0]      # rad/s
	var flutter_w := [0.0, 0.0, 0.0]
	var sway_ph := [0.0, 0.0, 0.0]
	var flutter_ph := [0.0, 0.0, 0.0]
	var sway_weight := Vector3(0.6, 0.25, 0.15)
	var frozen := false

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		_push()

	func _process(delta: float) -> void:
		if frozen:
			return
		for i in 3:
			sway_ph[i] = fposmod(sway_ph[i] + sway_w[i] * delta, TAU)
			flutter_ph[i] = fposmod(flutter_ph[i] + flutter_w[i] * delta, TAU)
		_push()

	func gust01() -> float:
		var s := sway_weight.x * sin(sway_ph[0]) + sway_weight.y * sin(sway_ph[1]) + sway_weight.z * sin(sway_ph[2])
		return 0.5 + 0.5 * s / maxf(sway_weight.x + sway_weight.y + sway_weight.z, 0.0001)

	func _push() -> void:
		var sp := Vector3(sway_ph[0], sway_ph[1], sway_ph[2])
		var fp := Vector3(flutter_ph[0], flutter_ph[1], flutter_ph[2])
		for m in mats:
			(m as ShaderMaterial).set_shader_parameter("sway_phase", sp)
			(m as ShaderMaterial).set_shader_parameter("flutter_phase", fp)
		if leaf_mat != null:
			leaf_mat.set_shader_parameter("gust01", gust01())

const WIND_SHADER := "res://tools/traveler/lookdev_baghdad/lookdev_tree_wind.gdshader"
const RIM_SHADER := "res://tools/traveler/lookdev_baghdad/lookdev_tree_rim.gdshader"
const LEAVES_SHADER := "res://tools/traveler/lookdev_baghdad/lookdev_tree_leaves.gdshader"
const LEAF_DRAW_SHADER := "res://tools/traveler/lookdev_baghdad/lookdev_tree_leaf.gdshader"

const WIND_DEFAULTS := {
	"enabled": true,
	"sway_tip_u": 0.055,
	"sway_rest": 0.2,
	"bend_exponent": 1.5,
	"root_lock": 0.03,
	"sway_periods_s": [8.0, 13.3, 5.2],
	"sway_weight": [0.6, 0.25, 0.15],
	"gust_wave_k": 0.12,
	"flutter_u": 0.02,
	"flutter_periods_s": [1.35, 0.95, 1.9],
	"flutter_k": 5.5,
	"flutter_gust_coupling": 0.5,
	"crown_band": [0.14, 0.30],
	"normal_response": 0.6,
	"fd_eps": 0.035,
	"rim_depth_pull_u": 0.003,
	"shadow_flutter_scale": 0.3,
	"start_phase": [0.7, 2.1, 4.0],
}

const LEAF_DEFAULTS := {
	"enabled": true,
	"amount": 18,
	"lifetime_s": 12.0,
	"preprocess_s": 12.0,
	"randomness": 0.8,
	"crown_center_fraction": 0.55,
	"crown_radii_u": [2.45, 3.2, 2.45],
	"spawn_shell": [0.86, 1.0],
	"spawn_height": [-0.8, 0.65],
	"spawn_downwind_bias": 0.45,
	"spawn_front_bias": 0.5,
	"wind_speed": [0.45, 0.75],
	"gust_speed_gain": 0.6,
	"fall_speed": [0.12, 0.24],
	"side_speed": [-0.04, 0.12],
	"drifter_fraction": 0.15,
	"drifter_wind_speed": [0.75, 0.95],
	"drifter_fall_speed": [0.02, 0.06],
	"drifter_lift": 0.22,
	"accel_time": 1.4,
	"swing_amp": 0.12,
	"swing_hz": [0.25, 0.45],
	"swing_dip": 0.35,
	"spin_hz": [0.25, 0.8],
	"scale_range": [0.8, 1.25],
	"grow_time": 0.5,
	"shrink_time": 0.8,
	"life_fraction": [0.8, 1.0],
	"brightness_jitter": 0.06,
	"emission_boost": 0.5,
	"backlight_strength": 0.2,
	"seed": 11,
}

var viewer: Node3D

func _merge(defaults: Dictionary, over: Variant) -> Dictionary:
	var out := defaults.duplicate(true)
	if over is Dictionary:
		for k in (over as Dictionary).keys():
			out[k] = over[k]
	return out

func _v2(a: Variant) -> Vector2:
	return Vector2(float(a[0]), float(a[1]))

func _v3(a: Variant) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))

func build(viewer_node: Node3D, cfg: Dictionary) -> Dictionary:
	viewer = viewer_node
	var wind := _merge(WIND_DEFAULTS, cfg.get("wind", {}))
	var leaves := _merge(LEAF_DEFAULTS, cfg.get("leaves", {}))
	var ev := {"schema": "silkroad.lookdev.tree-wind.v1"}
	var camera: Camera3D = viewer.camera
	var wind_world: Vector3 = -camera.global_basis.x
	wind_world.y = 0.0
	wind_world = wind_world.normalized()
	ev["wind_world"] = [wind_world.x, wind_world.y, wind_world.z]

	var clock := WindClock.new()
	clock.name = "LookdevTreeWindClock"
	var sp: Array = wind.sway_periods_s
	var fp: Array = wind.flutter_periods_s
	var st: Array = wind.start_phase
	for i in 3:
		clock.sway_w[i] = TAU / maxf(float(sp[i]), 0.1)
		clock.flutter_w[i] = TAU / maxf(float(fp[i]), 0.05)
		clock.sway_ph[i] = float(st[i])
		clock.flutter_ph[i] = float(st[i]) * 1.7
	clock.sway_weight = _v3(wind.sway_weight)
	clock.frozen = not bool(wind.enabled)

	# ---------------------------------------------------------------- 树
	var tree: Node3D = viewer.tree
	var mi := tree.find_child("OriginalTexturedMesh", true, false) as MeshInstance3D
	if mi == null:
		ev["error"] = "no OriginalTexturedMesh under viewer.tree"
		return ev
	var src := mi.material_override as StandardMaterial3D
	var old_rim: ShaderMaterial = null
	if src != null:
		old_rim = src.next_pass as ShaderMaterial
	var aabb: AABB = mi.mesh.get_aabb()
	var root_local := Vector3(aabb.get_center().x, aabb.position.y, aabb.get_center().z)
	var root_world: Vector3 = mi.global_transform * root_local
	var height_world: float = mi.global_transform.basis.y.length() * aabb.size.y
	var mat := ShaderMaterial.new()
	mat.shader = load(WIND_SHADER)
	mat.set_shader_parameter("texture_albedo", src.albedo_texture)
	mat.set_shader_parameter("albedo_color", src.albedo_color)
	mat.set_shader_parameter("uv_scale", Vector2(src.uv1_scale.x, src.uv1_scale.y))
	mat.set_shader_parameter("uv_offset", Vector2(src.uv1_offset.x, src.uv1_offset.y))
	mat.set_shader_parameter("roughness", src.roughness)
	mat.set_shader_parameter("specular", src.metallic_specular)
	var rim := ShaderMaterial.new()
	rim.shader = load(RIM_SHADER)
	var rim_params := {}
	if old_rim != null:
		for key in ["rim_color", "rim_power", "rim_intensity", "light_dir", "dir_weight", "dir_softness"]:
			var v: Variant = old_rim.get_shader_parameter(key)
			if v != null:
				rim.set_shader_parameter(key, v)
				rim_params[key] = str(v)
	rim.set_shader_parameter("depth_pull_u", float(wind.rim_depth_pull_u))
	for m in [mat, rim]:
		var sm := m as ShaderMaterial
		sm.set_shader_parameter("wind_enabled", bool(wind.enabled))
		sm.set_shader_parameter("wind_dir", wind_world)
		sm.set_shader_parameter("root_world", root_world)
		sm.set_shader_parameter("tree_height", height_world)
		for key in ["sway_tip_u", "sway_rest", "bend_exponent", "root_lock", "gust_wave_k", "flutter_u", "flutter_k", "flutter_gust_coupling", "normal_response", "fd_eps", "shadow_flutter_scale"]:
			sm.set_shader_parameter(key, float(wind[key]))
		sm.set_shader_parameter("sway_weight", _v3(wind.sway_weight))
		sm.set_shader_parameter("crown_band", _v2(wind.crown_band))
	if old_rim != null:
		mat.next_pass = rim
	mi.material_override = mat
	# 形变最多 ~0.1u：给 AABB 留余量，避免阴影/视锥裁剪按静态包围盒误剔
	var scale_min: float = minf(mi.global_transform.basis.x.length(), minf(mi.global_transform.basis.y.length(), mi.global_transform.basis.z.length()))
	var margin_world := float(wind.sway_tip_u) + float(wind.flutter_u) * 1.5 + 0.1
	mi.custom_aabb = aabb.grow(margin_world / maxf(scale_min, 0.0001))
	clock.mats = [mat, rim]

	# 解析证据：树梢在画面上的位移区间、叶簇抖动上限
	var tip: Vector3 = root_world + Vector3.UP * height_world
	var px_per_u: float = camera.unproject_position(tip).distance_to(camera.unproject_position(tip + wind_world))
	var rest := float(wind.sway_rest)
	var tip_amp := float(wind.sway_tip_u)
	var mid: Vector3 = root_world + Vector3.UP * height_world * 0.55
	var px_mid: float = camera.unproject_position(mid).distance_to(camera.unproject_position(mid + wind_world))
	var u_mid: float = (0.55 - float(wind.root_lock)) / (1.0 - float(wind.root_lock))
	ev["tree"] = {
		"root_world": [root_world.x, root_world.y, root_world.z], "height_world_u": height_world,
		"tip_pixel": [camera.unproject_position(tip).x, camera.unproject_position(tip).y],
		"px_per_u_at_tip": px_per_u,
		"tip_offset_px_range": [px_per_u * tip_amp * rest, px_per_u * tip_amp],
		"tip_swing_px": px_per_u * tip_amp * (1.0 - rest),
		"mid_crown_swing_px": px_mid * tip_amp * (1.0 - rest) * pow(u_mid, float(wind.bend_exponent)),
		"flutter_peak_px_horizontal": px_mid * float(wind.flutter_u) * 0.9,
		"source_material": {"albedo_texture": src.albedo_texture.resource_path, "albedo_color": str(src.albedo_color), "roughness": src.roughness, "specular": src.metallic_specular, "cull_mode": src.cull_mode, "diffuse_mode": src.diffuse_mode, "specular_mode": src.specular_mode, "emission": str(src.emission) if src.emission_enabled else "off", "normal_enabled": src.normal_enabled},
		"rim_params": rim_params,
		"custom_aabb": str(mi.custom_aabb),
		"wind": wind,
	}

	# ---------------------------------------------------------------- 落叶
	var p := viewer.world.find_child("LookdevFallingLeaves", true, false) as GPUParticles3D
	if bool(leaves.enabled) and p != null:
		var pm := ShaderMaterial.new()
		pm.shader = load(LEAVES_SHADER)
		var crown_c: Vector3 = root_world + Vector3.UP * height_world * float(leaves.crown_center_fraction)
		var to_cam: Vector3 = camera.global_position - crown_c
		to_cam.y = 0.0
		to_cam = to_cam.normalized()
		pm.set_shader_parameter("wind_dir", wind_world)
		pm.set_shader_parameter("toward_camera", to_cam)
		pm.set_shader_parameter("crown_center", crown_c)
		pm.set_shader_parameter("crown_radii", _v3(leaves.crown_radii_u))
		pm.set_shader_parameter("ground_y", root_world.y)
		for key in ["spawn_shell", "spawn_height", "wind_speed", "fall_speed", "side_speed", "drifter_wind_speed", "drifter_fall_speed", "swing_hz", "spin_hz", "scale_range", "life_fraction"]:
			pm.set_shader_parameter(key, _v2(leaves[key]))
		for key in ["spawn_downwind_bias", "spawn_front_bias", "gust_speed_gain", "drifter_fraction", "drifter_lift", "accel_time", "swing_amp", "swing_dip", "grow_time", "shrink_time", "brightness_jitter"]:
			pm.set_shader_parameter(key, float(leaves[key]))
		# 颜色：沿用 LookdevFallingLeaves 的四色（原 ParticleProcessMaterial 的常量渐变）
		var old_pm := p.process_material as ParticleProcessMaterial
		if old_pm != null and old_pm.color_initial_ramp is GradientTexture1D:
			var grad: Gradient = (old_pm.color_initial_ramp as GradientTexture1D).gradient
			for i in mini(grad.get_point_count(), 4):
				var c: Color = grad.get_color(i)
				pm.set_shader_parameter("color%d" % i, Vector3(c.r, c.g, c.b))
		p.amount = int(leaves.amount)
		p.lifetime = float(leaves.lifetime_s)
		p.preprocess = float(leaves.preprocess_s)
		p.randomness = float(leaves.randomness)
		p.seed = int(leaves.seed)
		p.process_material = pm
		p.visibility_aabb = AABB(Vector3(-20.0, -10.0, -20.0), Vector3(40.0, 24.0, 40.0))
		var draw := ShaderMaterial.new()
		draw.shader = load(LEAF_DRAW_SHADER)
		draw.set_shader_parameter("emission_boost", float(leaves.emission_boost))
		draw.set_shader_parameter("backlight_strength", float(leaves.backlight_strength))
		p.material_override = draw
		p.restart()
		clock.leaf_mat = pm
		var leaf_px: float = camera.unproject_position(crown_c).distance_to(camera.unproject_position(crown_c + wind_world))
		var ws: Vector2 = _v2(leaves.wind_speed)
		var g := float(leaves.gust_speed_gain)
		ev["leaves"] = {"node": str(p.get_path()), "amount": p.amount, "lifetime_s": p.lifetime,
			"crown_center": [crown_c.x, crown_c.y, crown_c.z], "toward_camera": [to_cam.x, to_cam.y, to_cam.z],
			"px_per_u_at_crown": leaf_px,
			"screen_speed_px_s_range": [leaf_px * ws.x * (1.0 - 0.5 * g), leaf_px * ws.y * (1.0 + 0.5 * g)],
			"cfg": leaves}
	elif p != null:
		ev["leaves"] = {"node": str(p.get_path()), "untouched": true}
	else:
		ev["leaves"] = {"error": "LookdevFallingLeaves not found"}

	viewer.add_child(clock)
	ev["clock"] = {"node": str(clock.name), "sway_periods_s": sp, "flutter_periods_s": fp, "frozen": clock.frozen}
	return ev
