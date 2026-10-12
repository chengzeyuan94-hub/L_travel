extends RefCounted
## L2 · surface detail hook (extra_scripts module). Global rules only; nothing here knows a tile id.
##  - binds the ground maps from l2_ground_info.gd (cell colour texture, path distance texture, ground
##    height range) to every role listed in cfg.map_roles
##  - procedural water: sets the instance uniform l2_level (continuous depth colour + shore foam in
##    l2_water.gdshader); the water_side role gets l2_water_level; the web's dashed foam strips are hidden
##    when cfg.hide_proc_foam (the shader draws the shoreline instead)
##  - per light preset: l2_sun_dir on every role whose shader has it (glints on snow / sand / water)
## cfg: {"map_roles": [...], "hide_proc_foam": true, "ripple_visible": {"default": true, "night": false}}
const INFO_PATH: String = "res://tools/traveler/lookdev_lshu/modules/l2_ground_info.gd"

var host: Node3D
var cfg: Dictionary = {}
var info: RefCounted
var report: Dictionary = {}

func build(h: Node3D, c: Dictionary) -> Dictionary:
	host = h
	cfg = c
	var script: GDScript = load(INFO_PATH) as GDScript
	info = script.call("get_or_build", host) as RefCounted
	var map_roles: Array = cfg.get("map_roles", ["ground", "skirt", "cliff"])
	var materials: Dictionary = host.get("materials")
	var bound: Array[String] = []
	for r: Variant in map_roles:
		var role: String = str(r)
		if not materials.has(role):
			continue
		_role_set(role, "l2_ground_col_tex", info.get("color_tex"))
		_role_set(role, "l2_path_tex", info.get("path_tex"))
		_role_set(role, "l2_ground_range", Vector2(float(info.get("ground_min")), float(info.get("ground_max"))))
		_role_set(role, "l2_maps_ready", 1.0)
		bound.append(role)
	var level: float = float(info.get("water_level"))
	var nodes: Dictionary = host.get("proc_nodes")
	var water_set: bool = false
	if level > -50.0 and nodes.has("water"):
		(nodes["water"] as MeshInstance3D).set_instance_shader_parameter("l2_level", level)
		water_set = true
	if materials.has("water_side"):
		_role_set("water_side", "l2_water_level", level if level > -50.0 else 0.0)
	var foam_hidden: bool = false
	if bool(cfg.get("hide_proc_foam", false)) and nodes.has("foam"):
		(nodes["foam"] as Node3D).visible = false
		foam_hidden = true
	host.call("register_light_callback", _on_light)
	_on_light(str(host.get("light_name")))
	report = {"bound_roles": bound, "water_level": level, "water_depth_shader": water_set, "proc_foam_hidden": foam_hidden,
		"ground_info": info.get("stats")}
	host.call("add_report", "l2_surface_detail", report)
	return report

func _role_set(role: String, uniform: String, value: Variant) -> void:
	var m: ShaderMaterial = host.call("role_material", role) as ShaderMaterial
	var types: Dictionary = (host.get("uniform_types") as Dictionary).get(str(m.get_meta("shader_path")), {})
	if types.has(uniform):
		m.set_shader_parameter(uniform, value)   # direct: exact Vector2/Vector3/Texture values

func _on_light(light: String) -> void:
	var sun: DirectionalLight3D = host.get("sun")
	var to_sun: Vector3 = sun.global_transform.basis.z.normalized()
	var materials: Dictionary = host.get("materials")
	for role: String in materials.keys():
		_role_set(role, "l2_sun_dir", to_sun)
	var nodes: Dictionary = host.get("proc_nodes")
	if nodes.has("ripple"):
		var rv: Dictionary = cfg.get("ripple_visible", {})
		(nodes["ripple"] as Node3D).visible = bool(rv.get(light, rv.get("default", true)))
