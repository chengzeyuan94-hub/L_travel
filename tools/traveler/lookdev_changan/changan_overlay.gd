extends RefCounted
## 长安旅人 · 日暮光影探针（导演探针，不是交付代码）。
## 挂在 atlas_viewer 的克隆（lookdev_viewer.gd）上，在场景和 lookdev 都建好、截图之前执行，
## 按 variants/<名>.json 改光、环境、天空、地表着色器、水、金边。机位不动。
##
## 节（都可选；"base" 继承一层，同名节整节覆盖）：
##   light      太阳 sunel/sunaz/color/energy/angular_distance/shadow_blur；extra_lights: [...]
##   env        Environment 属性名 → 值（颜色写 [r,g,b]）
##   sky        ProceduralSkyMaterial 属性名 → 值；或 {"shader": res路径, 其余为 uniform}
##   surface    {"shader": res路径, 其余为 uniform}：给所有 atlas_surface 材质换 shader（uniform 名兼容）并设参数
##   water      {"rivers": {StandardMaterial3D 属性}, "sea": {uniform}}
##   rim_nodes  [{"match": 节点名子串, "color", "power", "intensity", "dir_weight"}]：菲涅尔 next_pass
##   camera     景深参数（机位不许动）
var variant: Dictionary = {}
var variant_name := ""
var ev: Dictionary = {"applied": [], "notes": []}

func apply(host: Node3D) -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--lookdev="):
			variant_name = arg.trim_prefix("--lookdev=")
		if arg.begins_with("--park="):
			_park(int(arg.trim_prefix("--park=")))
	ev["variant"] = variant_name
	if not variant_name.is_empty():
		variant = _load(variant_name)
		if variant.has("light"): _light(host, variant.light)
		if variant.has("env"): _env(host, variant.env)
		if variant.has("sky"): _sky(host, variant.sky)
		if variant.has("surface"): _surface(host, variant.surface)
		if variant.has("water"): _water(host, variant.water)
		if variant.has("rim_nodes"): _rim_nodes(host, variant.rim_nodes)
		if variant.has("camera"): _camera(host, variant.camera)
		if variant.has("shader_params"): _shader_params(host, variant.shader_params)
		if variant.has("extra_scripts"):
			for item in variant.extra_scripts:
				var r: Variant = load(str(item.script)).new().call("build", host, item.get("cfg", {}))
				ev.applied.append({"extra_script": str(item.script).get_file(), "result": r})
	_sun_evidence(host)
	print("CHANGAN_OVERLAY ", JSON.stringify(ev))

func _park(slot: int) -> void:
	var wid := DisplayServer.MAIN_WINDOW_ID
	var usable := DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen(wid))
	var size := Vector2i(400, 225)
	var col := slot % 4
	var row := slot / 4
	DisplayServer.window_set_size(size, wid)
	DisplayServer.window_set_position(usable.position + usable.size - Vector2i((col + 1) * (size.x + 8), (row + 1) * (size.y + 36)), wid)

func _load(n: String) -> Dictionary:
	var path := "res://tools/traveler/lookdev_changan/variants/%s.json" % n
	if not FileAccess.file_exists(path):
		push_error("changan variant missing: " + path)
		return {}
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	if d.has("base"):
		var b := _load(str(d.base))
		for k in d.keys():
			if k != "base":
				b[k] = d[k]
		d = b
	return d

func _rgb(v: Variant) -> Color:
	var a: Array = v
	return Color(float(a[0]), float(a[1]), float(a[2]), float(a[3]) if a.size() > 3 else 1.0)

func _val(v: Variant) -> Variant:
	if v is Array:
		var a: Array = v
		if a.size() == 2:
			return Vector2(float(a[0]), float(a[1]))
		return _rgb(a) if a.size() >= 3 else v
	return v

func _light(host: Node3D, c: Dictionary) -> void:
	var sun: DirectionalLight3D = host.sun
	if c.has("sunel") or c.has("sunaz"):
		sun.rotation = Vector3(deg_to_rad(float(c.get("sunel", rad_to_deg(sun.rotation.x)))), deg_to_rad(float(c.get("sunaz", rad_to_deg(sun.rotation.y)))), 0.0)
	for k in ["color", "energy", "angular_distance", "shadow_blur", "specular"]:
		if c.has(k):
			var prop: String = {"color": "light_color", "energy": "light_energy", "angular_distance": "light_angular_distance", "shadow_blur": "shadow_blur", "specular": "light_specular"}[k]
			sun.set(prop, _rgb(c[k]) if k == "color" else float(c[k]))
	for k in c.get("sun_props", {}).keys():
		sun.set(k, _val(c.sun_props[k]))
	var made := 0
	for x in c.get("extra_lights", []):
		var l: Light3D
		match str(x.get("type", "directional")):
			"omni":
				l = OmniLight3D.new()
				(l as OmniLight3D).omni_range = float(x.get("range", 5.0))
			"spot":
				l = SpotLight3D.new()
				(l as SpotLight3D).spot_range = float(x.get("range", 10.0))
				(l as SpotLight3D).spot_angle = float(x.get("angle", 30.0))
			_:
				l = DirectionalLight3D.new()
		l.name = str(x.get("name", "LookdevLight%d" % made))
		l.light_color = _rgb(x.get("color", [1, 1, 1]))
		l.light_energy = float(x.get("energy", 1.0))
		l.light_specular = float(x.get("specular", 0.5))
		l.shadow_enabled = bool(x.get("shadow", false))
		host.world.add_child(l)
		if x.has("sunel"):
			l.rotation = Vector3(deg_to_rad(float(x.sunel)), deg_to_rad(float(x.get("sunaz", 0.0))), 0.0)
		if x.has("position"):
			l.global_position = Vector3(float(x.position[0]), float(x.position[1]), float(x.position[2]))
		if x.has("look_at"):
			l.look_at(Vector3(float(x.look_at[0]), float(x.look_at[1]), float(x.look_at[2])), Vector3.UP)
		if l is DirectionalLight3D and bool(x.get("shadow", false)):
			(l as DirectionalLight3D).directional_shadow_max_distance = float(x.get("shadow_max", 60.0))
		made += 1
	ev.applied.append({"light": {"sun_rot_deg": [rad_to_deg(sun.rotation.x), rad_to_deg(sun.rotation.y)], "energy": sun.light_energy, "extra": made}})

func _env(host: Node3D, c: Dictionary) -> void:
	var e: Environment = host.environment
	for k in c.keys():
		if k.begins_with("glow_level_"):
			e.set_glow_level(int(k.trim_prefix("glow_level_")), float(c[k]))
		else:
			e.set(k, _val(c[k]))
	ev.applied.append({"env": c.keys()})

func _sky(host: Node3D, c: Dictionary) -> void:
	var e: Environment = host.environment
	if c.has("shader"):
		var sm := ShaderMaterial.new()
		sm.shader = load(str(c.shader))
		for k in c.keys():
			if k != "shader":
				sm.set_shader_parameter(k, _val(c[k]))
		sm.set_shader_parameter("sun_direction", (host.sun as DirectionalLight3D).global_basis.z.normalized())
		var sky := Sky.new()
		sky.sky_material = sm
		sky.process_mode = Sky.PROCESS_MODE_QUALITY
		e.sky = sky
	else:
		var pm := e.sky.sky_material as ProceduralSkyMaterial
		for k in c.keys():
			pm.set(k, _val(c[k]))
	ev.applied.append({"sky": c.keys()})

func _surface(host: Node3D, c: Dictionary) -> void:
	var shader: Shader = load(str(c.shader)) if c.has("shader") else null
	var n := 0
	for m in host.material_list:
		var sm := m as ShaderMaterial
		if sm == null:
			continue
		if shader != null:
			sm.shader = shader
		for k in c.keys():
			if k != "shader":
				sm.set_shader_parameter(k, _val(c[k]))
		sm.set_shader_parameter("sun_dir_world", (host.sun as DirectionalLight3D).global_basis.z.normalized())
		n += 1
	ev.applied.append({"surface": {"materials": n, "keys": c.keys()}})

func _water(host: Node3D, c: Dictionary) -> void:
	var water: Node = host.world.get_node_or_null("Water")
	if water == null:
		ev.notes.append("no Water node")
		return
	var n := 0
	for item in water.find_children("*", "MeshInstance3D", true, false):
		var mi := item as MeshInstance3D
		var m := mi.get_active_material(0)
		if m is StandardMaterial3D and c.has("rivers"):
			var d := (m as StandardMaterial3D).duplicate() as StandardMaterial3D
			for k in c.rivers.keys():
				d.set(k, _val(c.rivers[k]))
			mi.material_override = d
			n += 1
		elif m is ShaderMaterial and c.has("sea"):
			for k in c.sea.keys():
				(m as ShaderMaterial).set_shader_parameter(k, _val(c.sea[k]))
			n += 1
		if c.has("river_shader") and m is StandardMaterial3D:
			var sm := ShaderMaterial.new()
			sm.shader = load(str(c.river_shader.shader))
			for k in c.river_shader.keys():
				if k != "shader":
					sm.set_shader_parameter(k, _val(c.river_shader[k]))
			sm.set_shader_parameter("base_color", (m as StandardMaterial3D).albedo_color)
			sm.set_shader_parameter("sun_dir_world", (host.sun as DirectionalLight3D).global_basis.z.normalized())
			mi.material_override = sm
	ev.applied.append({"water": n})

func _rim_nodes(host: Node3D, list: Array) -> void:
	var shader: Shader = load("res://tools/traveler/lookdev_baghdad/lookdev_fresnel_rim.gdshader")
	var sun_dir: Vector3 = (host.sun as DirectionalLight3D).global_basis.z.normalized()
	var count := 0
	for spec in list:
		var needle := str(spec.match)
		for item in host.world.find_children("*" + needle + "*", "GeometryInstance3D", true, false):
			var gi := item as GeometryInstance3D
			if str(gi.name).begins_with("CharacterOutline_"):
				continue
			var pm := ShaderMaterial.new()
			pm.shader = shader
			pm.set_shader_parameter("rim_color", _rgb(spec.get("color", [1.0, 0.72, 0.32])))
			pm.set_shader_parameter("rim_power", float(spec.get("power", 3.0)))
			pm.set_shader_parameter("rim_intensity", float(spec.get("intensity", 1.2)))
			var ld: Vector3 = sun_dir
			if spec.has("light_dir"):
				ld = Vector3(float(spec.light_dir[0]), float(spec.light_dir[1]), float(spec.light_dir[2])).normalized()
			pm.set_shader_parameter("light_dir", ld)
			pm.set_shader_parameter("dir_weight", float(spec.get("dir_weight", 0.7)))
			pm.set_shader_parameter("dir_softness", float(spec.get("dir_softness", 0.35)))
			if gi is MeshInstance3D and (gi as MeshInstance3D).mesh != null:
				var mi := gi as MeshInstance3D
				for s in mi.mesh.get_surface_count():
					var m := mi.get_active_material(s)
					if m == null:
						continue
					var d := m.duplicate() as Material
					d.next_pass = pm
					mi.set_surface_override_material(s, d)
					count += 1
	ev.applied.append({"rim_nodes": count})

## [{"match": 节点名通配（如 "CloudDusk*"）, "child": 可选子节点名, "params": {uniform: 值}}]：改 material_override 的 shader 参数
func _shader_params(host: Node3D, list: Array) -> void:
	var n := 0
	for spec in list:
		for item in host.world.find_children(str(spec.match), "", true, false):
			var node: Node = item
			if spec.has("child"):
				node = item.get_node_or_null(str(spec.child))
			var gi := node as GeometryInstance3D
			if gi == null or not (gi.material_override is ShaderMaterial):
				continue
			for k in spec.params.keys():
				(gi.material_override as ShaderMaterial).set_shader_parameter(k, _val(spec.params[k]))
			n += 1
	ev.applied.append({"shader_params": n})

func _camera(host: Node3D, c: Dictionary) -> void:
	var a := host.camera.attributes as CameraAttributesPractical
	if a == null:
		return
	for k in c.keys():
		a.set(k, c[k])
	ev.applied.append({"camera": c.keys()})

func _sun_evidence(host: Node3D) -> void:
	var cam: Camera3D = host.camera
	var sun: DirectionalLight3D = host.sun
	var d: Vector3 = sun.global_basis.z.normalized()
	var fwd: Vector3 = -cam.global_basis.z
	var info := {"direction_to_sun": [d.x, d.y, d.z], "elevation_deg": rad_to_deg(asin(d.y)), "in_front": d.dot(fwd) > 0.0,
		"angle_from_view_deg": rad_to_deg(acos(clampf(d.dot(fwd), -1.0, 1.0)))}
	if d.dot(fwd) > 0.0:
		var px := cam.unproject_position(cam.global_position + d * 1000.0)
		info["pixel"] = [px.x, px.y]
	var right := cam.global_basis.x
	info["screen_side"] = "right" if d.dot(right) > 0.0 else "left"
	ev["sun"] = info
