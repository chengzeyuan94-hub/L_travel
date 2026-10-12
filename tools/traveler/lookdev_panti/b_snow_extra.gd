extends RefCounted
## B 线 · 盘橐雪地表面 extra 脚本（探针，2026-09-23）。
## 1. 把 PantiWorld/SnowGround 的 material_override（纯色 StandardMaterial3D）换成 b_snow_surface.gdshader 的 ShaderMaterial；
##    反照率照抄原材质的 albedo_color，其余 uniform 取 cfg.uniforms（随时段变化的交给 variant 的 morning / midnight "shaders" 节）。
## 2. 闪粉的参考机位（位置、水平朝向、每像素角度）按当前相机写一次（相机固定）。
## 3. 挂一个小 Node，每帧把 weather.anim_t 写进 anim_t（按空格暂停时闪粉也停）。
const SHADER_PATH := "res://tools/traveler/lookdev_panti/b_snow_surface.gdshader"

const VR_LIGHTS: Array = ["CampFireWarmLight", "LanternWarmth", "gate-interior", "left-market", "front-market", "right-market"]

class AnimFeed extends Node:
	var host: Node3D
	var mat: ShaderMaterial
	var lights: Array = []
	var vr_gain: Array = []
	var anim_offset: float = 0.0
	func _process(_d: float) -> void:
		var w: Node = host.get("weather") as Node
		if w != null:
			mat.set_shader_parameter("anim_t", float(w.get("anim_t")) + anim_offset)
		feed_lights()
	func feed_lights() -> void:
		var pos := PackedVector3Array()
		var col := PackedVector3Array()
		for i in 6:
			var l: Light3D = lights[i] as Light3D if i < lights.size() else null
			if l == null or not l.is_visible_in_tree():
				pos.append(Vector3.ZERO)
				col.append(Vector3.ZERO)
				continue
			var c: Color = l.light_color.srgb_to_linear()
			var g: float = float(vr_gain[i]) if i < vr_gain.size() else 1.0
			pos.append(l.global_position)
			col.append(Vector3(c.r, c.g, c.b) * l.light_energy * g)
		mat.set_shader_parameter("vr_pos", pos)
		mat.set_shader_parameter("vr_col", col)

## 注意：Color 写进 vec3 uniform 时引擎会做一次 sRGB→线性转换（即使没有 source_color）。
## 所以先把每个 uniform 的默认值按原类型写进材质（非 source_color 的 vec3 = Vector3），
## watcher 读到的基值是 Vector3，就会按 Vector3 插值写入，倍率不会被偷偷转成线性。
func _uval(v: Variant, like: Variant) -> Variant:
	if v is Array:
		var a: Array = v
		if a.size() == 2:
			return Vector2(float(a[0]), float(a[1]))
		if a.size() >= 3:
			if like is Vector3:
				return Vector3(float(a[0]), float(a[1]), float(a[2]))
			return Color(float(a[0]), float(a[1]), float(a[2]))
	return v

func build(host: Node3D, cfg: Dictionary) -> Dictionary:
	var ground: MeshInstance3D = host.get("snow_ground") as MeshInstance3D
	if ground == null:
		ground = host.find_child("SnowGround", true, false) as MeshInstance3D
	if ground == null:
		return {"error": "SnowGround not found"}
	var src: StandardMaterial3D = ground.material_override as StandardMaterial3D
	var mat := ShaderMaterial.new()
	mat.shader = load(SHADER_PATH) as Shader
	var alb := Color(0.86, 0.91, 0.97)
	if src != null:
		alb = src.albedo_color
	var sh: Shader = mat.shader
	for u in sh.get_shader_uniform_list():
		var un: String = str((u as Dictionary).get("name", ""))
		var dv: Variant = RenderingServer.shader_get_parameter_default(sh.get_rid(), un)
		if dv != null:
			mat.set_shader_parameter(un, dv)
	mat.set_shader_parameter("albedo", alb)
	var uni: Dictionary = cfg.get("uniforms", {})
	for k in uni.keys():
		mat.set_shader_parameter(str(k), _uval(uni[k], mat.get_shader_parameter(str(k))))
	var cam: Camera3D = host.get("camera") as Camera3D
	var ref := {}
	if cam != null:
		var fwd3: Vector3 = -cam.global_basis.z
		var fwd := Vector2(fwd3.x, fwd3.z).normalized()
		var rad_per_px: float = deg_to_rad(cam.fov) / 1080.0
		mat.set_shader_parameter("ref_cam_pos", cam.global_position)
		mat.set_shader_parameter("ref_cam_fwd", fwd)
		mat.set_shader_parameter("ref_rad_per_px", rad_per_px)
		ref = {"pos": str(cam.global_position), "fwd": str(fwd), "rad_per_px": rad_per_px}
	var w: Node = host.get("weather") as Node
	if w != null:
		mat.set_shader_parameter("anim_t", float(w.get("anim_t")))
	ground.material_override = mat
	var feed := AnimFeed.new()
	feed.name = "BSnowAnimFeed"
	feed.host = host
	feed.mat = mat
	feed.anim_offset = float(cfg.get("anim_offset", 0.0))
	var found: Array = []
	var gains: Dictionary = cfg.get("vr_gain", {})
	for n in VR_LIGHTS:
		var l: Light3D = host.find_child(str(n), true, false) as Light3D
		feed.lights.append(l)
		feed.vr_gain.append(float(gains.get(n, 1.0)))
		if l != null:
			found.append(n)
	host.add_child(feed)
	feed.feed_lights()
	var types := {}
	for k in ["hollow_tint", "sun_warm", "vr_color", "sheen_tint", "glit_tint", "wind_dir"]:
		types[k] = type_string(typeof(mat.get_shader_parameter(k)))
	return {"albedo": alb.to_html(false), "uniforms": uni.size(), "types": types, "ref": ref, "weather": w != null, "vr_lights": found}
