extends RefCounted
## 巴格达「晚霞质感」导演探针（2026-09-23）。
##
## 不是交付代码：它挂在 Codex viewer 的**克隆**（lookdev_viewer.gd）末尾，
## 在场景建完之后按 variants/<名>.json 改光、改环境、换天空 shader、
## 给树和人物加金边、加落叶。Codex 的任何文件零写入。
## 目的：把"晚霞 / 厚云金边 / 主体金边 / 落叶"四件事各自的参数先试出来，
## 再写成派工单交给 Codex 正式实现。

var variant: Dictionary = {}
var variant_name: String = ""
var evidence: Dictionary = {}

func apply(viewer: Node3D) -> void:
	for arg in preload("res://scripts/traveler/traveler_launch.gd").user_args():
		if arg.begins_with("--lookdev="):
			variant_name = arg.trim_prefix("--lookdev=")
	evidence = {"variant": variant_name, "applied": [], "notes": []}
	if variant_name.is_empty():
		print("LOOKDEV_OVERLAY ", JSON.stringify(evidence))
		return
	variant = _load_variant(variant_name)
	if variant.is_empty():
		evidence.notes.append("variant 文件为空或不存在")
	if variant.has("camera"):
		_apply_camera(viewer, variant.camera)
	if variant.has("light"):
		_apply_light(viewer, variant.light)
	if variant.has("env"):
		_apply_env(viewer, variant.env)
	if variant.has("sky"):
		_apply_sky(viewer, variant.sky)
	if variant.has("rim"):
		_apply_rim(viewer, variant.rim)
	if variant.has("backlight"):
		_apply_backlight(viewer, variant.backlight)
	if variant.has("fresnel"):
		_apply_fresnel(viewer, variant.fresnel)
	if variant.has("leaves"):
		_apply_leaves(viewer, variant.leaves)
	if variant.has("ground_shader"):
		_apply_ground_shader(viewer, variant.ground_shader)
	if variant.has("extra_scripts"):
		for item in variant.extra_scripts:
			_apply_extra_script(viewer, item)
	var record_dir := ""
	for arg in preload("res://scripts/traveler/traveler_launch.gd").user_args():
		if arg.begins_with("--record-dir="):
			record_dir = arg.trim_prefix("--record-dir=")
	if not record_dir.is_empty():
		var rec_cfg: Dictionary = variant.get("record", {}).duplicate()
		rec_cfg["out_dir"] = record_dir
		for arg in preload("res://scripts/traveler/traveler_launch.gd").user_args():
			if arg.begins_with("--record-frames="):
				rec_cfg["frames"] = int(arg.trim_prefix("--record-frames="))
		var rec: Node = load("res://tools/traveler/lookdev_baghdad/lookdev_recorder.gd").new()
		rec.name = "LookdevRecorder"
		viewer.add_child(rec)
		rec.configure(rec_cfg)
		evidence.applied.append({"record": rec_cfg})
	_sun_evidence(viewer)
	print("LOOKDEV_OVERLAY ", JSON.stringify(evidence))

func _load_variant(name_value: String) -> Dictionary:
	var path := "res://tools/traveler/lookdev_baghdad/variants/%s.json" % name_value
	if not FileAccess.file_exists(path):
		push_error("lookdev variant missing: " + path)
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		push_error("lookdev variant is not an object: " + path)
		return {}
	var result: Dictionary = parsed
	# 一层继承：{"base": "v1_dusk", ...} 先取 base 的各节，再用本文件同名节整节覆盖
	if result.has("base"):
		var base := _load_variant(str(result.base))
		for key in result.keys():
			if key != "base":
				base[key] = result[key]
		result = base
	return result

func _rgb(value: Variant) -> Color:
	if value is Color:
		return value
	var a: Array = value
	return Color(float(a[0]), float(a[1]), float(a[2]))

# ---------------------------------------------------------------- 相机（只动景深，不动机位）
func _apply_camera(viewer: Node3D, cfg: Dictionary) -> void:
	var camera: Camera3D = viewer.camera
	var attrs := camera.attributes as CameraAttributesPractical
	if attrs == null:
		evidence.notes.append("相机没有 CameraAttributesPractical，景深参数跳过")
		return
	if cfg.has("dof_enabled"):
		attrs.dof_blur_far_enabled = bool(cfg.dof_enabled)
	if cfg.has("dof_blur_amount"):
		attrs.dof_blur_amount = float(cfg.dof_blur_amount)
	if cfg.has("dof_far_distance"):
		attrs.dof_blur_far_distance = float(cfg.dof_far_distance)
	if cfg.has("dof_far_transition"):
		attrs.dof_blur_far_transition = float(cfg.dof_far_transition)
	evidence.applied.append({"camera": {"dof_far_enabled": attrs.dof_blur_far_enabled, "dof_blur_amount": attrs.dof_blur_amount, "dof_far_distance": attrs.dof_blur_far_distance}})

# ---------------------------------------------------------------- 光
func _apply_light(viewer: Node3D, cfg: Dictionary) -> void:
	var sun: DirectionalLight3D = viewer.sun
	var el := float(cfg.get("sunel", rad_to_deg(sun.rotation.x)))
	var az := float(cfg.get("sunaz", rad_to_deg(sun.rotation.y)))
	sun.rotation = Vector3(deg_to_rad(el), deg_to_rad(az), 0.0)
	if cfg.has("color"):
		sun.light_color = _rgb(cfg.color)
	if cfg.has("energy"):
		sun.light_energy = float(cfg.energy)
	if cfg.has("angular_distance"):
		sun.light_angular_distance = float(cfg.angular_distance)
	if cfg.has("shadow_blur"):
		sun.shadow_blur = float(cfg.shadow_blur)
	var sky_mat: ShaderMaterial = viewer.look_profile.sky_material
	if sky_mat != null:
		sky_mat.set_shader_parameter("sun_direction", sun.global_basis.z.normalized())
	var cool := viewer.get_node_or_null("CinematicCoolSkyFill") as DirectionalLight3D
	if cool != null:
		if cfg.has("cool_fill_energy"):
			cool.light_energy = float(cfg.cool_fill_energy)
		if cfg.has("cool_fill_color"):
			cool.light_color = _rgb(cfg.cool_fill_color)
	var spot := viewer.get_node_or_null("CinematicTravelerFill") as SpotLight3D
	if spot != null:
		if cfg.has("character_fill_energy"):
			spot.light_energy = float(cfg.character_fill_energy)
		if cfg.has("character_fill_color"):
			spot.light_color = _rgb(cfg.character_fill_color)
	evidence.applied.append({"light": {"sunel": el, "sunaz": az, "color": [sun.light_color.r, sun.light_color.g, sun.light_color.b], "energy": sun.light_energy, "cool_fill_energy": cool.light_energy if cool != null else null}})

# ---------------------------------------------------------------- 环境
func _apply_env(viewer: Node3D, cfg: Dictionary) -> void:
	var env: Environment = viewer.environment
	var set_keys: Array = []
	for key in cfg.keys():
		var value: Variant = cfg[key]
		if value is Array and (value as Array).size() == 3:
			value = _rgb(value)
		env.set(key, value)
		set_keys.append(key)
	evidence.applied.append({"env": set_keys})

# ---------------------------------------------------------------- 天空
func _apply_sky(viewer: Node3D, cfg: Dictionary) -> void:
	var look: RefCounted = viewer.look_profile
	var mat: ShaderMaterial = look.sky_material
	if mat == null:
		evidence.notes.append("没有 sky_material（棚拍模式？），跳过天空")
		return
	if cfg.has("shader"):
		mat.shader = load(str(cfg.shader))
	# 先把配方里的天空参数原样重设一遍（换 shader 不丢参数），再用本 variant 覆盖
	var theme: Dictionary = look.recipe.sky
	_set_sky_params(mat, theme)
	_set_sky_params(mat, cfg)
	mat.set_shader_parameter("sun_direction", (viewer.sun as DirectionalLight3D).global_basis.z.normalized())
	evidence.applied.append({"sky": {"shader": mat.shader.resource_path, "keys": cfg.keys()}})

func _set_sky_params(mat: ShaderMaterial, src: Dictionary) -> void:
	for key in src.keys():
		if key == "shader":
			continue
		var v: Variant = src[key]
		if v is Array:
			var arr: Array = v
			if arr.size() == 3:
				mat.set_shader_parameter(key, _rgb(arr))
			elif arr.size() == 2:
				mat.set_shader_parameter(key, Vector2(float(arr[0]), float(arr[1])))
		elif v is float or v is int or v is bool:
			mat.set_shader_parameter(key, float(v))

# ---------------------------------------------------------------- 主体金边（材质 rim）
func _subject_roots(viewer: Node3D, cfg: Dictionary) -> Array:
	var roots: Array = []
	if bool(cfg.get("tree", true)) and viewer.tree != null:
		roots.append(viewer.tree)
	if bool(cfg.get("character", true)) and viewer.character != null:
		roots.append(viewer.character)
	return roots

func _apply_rim(viewer: Node3D, cfg: Dictionary) -> void:
	var amount := float(cfg.get("amount", 0.6))
	var tint := float(cfg.get("tint", 0.2))
	var count := 0
	for root in _subject_roots(viewer, cfg):
		for item in (root as Node).find_children("*", "MeshInstance3D", true, false):
			var mi := item as MeshInstance3D
			if mi.name.begins_with("CharacterOutline_"):
				continue
			if mi.material_override is BaseMaterial3D:
				var m := (mi.material_override as BaseMaterial3D).duplicate() as BaseMaterial3D
				m.rim_enabled = true
				m.rim = amount
				m.rim_tint = tint
				mi.material_override = m
				count += 1
			else:
				for s in mi.get_surface_override_material_count():
					var sm := mi.get_surface_override_material(s) as BaseMaterial3D
					if sm == null:
						continue
					var m2 := sm.duplicate() as BaseMaterial3D
					m2.rim_enabled = true
					m2.rim = amount
					m2.rim_tint = tint
					mi.set_surface_override_material(s, m2)
					count += 1
	evidence.applied.append({"rim": {"amount": amount, "tint": tint, "materials": count}})

# ---------------------------------------------------------------- 主体金边（专用逆光灯，按层裁剪）
func _apply_backlight(viewer: Node3D, cfg: Dictionary) -> void:
	var layer_index := int(cfg.get("layer", 2))
	var bit: int = 1 << (layer_index - 1)
	var light := DirectionalLight3D.new()
	light.name = "LookdevGoldBacklight"
	light.light_color = _rgb(cfg.get("color", [1.0, 0.72, 0.35]))
	light.light_energy = float(cfg.get("energy", 1.6))
	light.light_specular = float(cfg.get("specular", 0.0))
	light.shadow_enabled = false
	light.rotation = Vector3(deg_to_rad(float(cfg.get("el", -22.0))), deg_to_rad(float(cfg.get("az", -45.0))), 0.0)
	light.light_cull_mask = bit
	viewer.add_child(light)
	var meshes := 0
	for root in _subject_roots(viewer, cfg):
		for item in (root as Node).find_children("*", "MeshInstance3D", true, false):
			var mi := item as MeshInstance3D
			if mi.name.begins_with("CharacterOutline_"):
				continue
			mi.layers = mi.layers | bit
			meshes += 1
	var excluded := false
	if bool(cfg.get("exclude_cool_fill", false)):
		var cool := viewer.get_node_or_null("CinematicCoolSkyFill") as DirectionalLight3D
		if cool != null:
			cool.light_cull_mask = cool.light_cull_mask & ~bit
			excluded = true
	evidence.applied.append({"backlight": {"el": float(cfg.get("el", -22.0)), "az": float(cfg.get("az", -45.0)), "energy": light.light_energy, "layer": layer_index, "meshes_on_layer": meshes, "cool_fill_excluded": excluded}})

# ---------------------------------------------------------------- 主体金边（菲涅尔叠加 pass，next_pass）
func _apply_fresnel(viewer: Node3D, cfg: Dictionary) -> void:
	var shader: Shader = load("res://tools/traveler/lookdev_baghdad/lookdev_fresnel_rim.gdshader")
	var sun: DirectionalLight3D = viewer.sun
	var light_dir: Vector3 = sun.global_basis.z.normalized()
	if cfg.has("light_dir"):
		light_dir = _vec(cfg.light_dir).normalized()
	var count := 0
	for root in _subject_roots(viewer, cfg):
		var is_tree: bool = root == viewer.tree
		var intensity := float(cfg.get("tree_intensity" if is_tree else "character_intensity", cfg.get("intensity", 1.3)))
		var power := float(cfg.get("tree_power" if is_tree else "character_power", cfg.get("power", 3.0)))
		for item in (root as Node).find_children("*", "MeshInstance3D", true, false):
			var mi := item as MeshInstance3D
			if mi.name.begins_with("CharacterOutline_"):
				continue
			var pass_mat := ShaderMaterial.new()
			pass_mat.shader = shader
			pass_mat.set_shader_parameter("rim_color", _rgb(cfg.get("color", [1.0, 0.78, 0.40])))
			pass_mat.set_shader_parameter("rim_power", power)
			pass_mat.set_shader_parameter("rim_intensity", intensity)
			pass_mat.set_shader_parameter("light_dir", light_dir)
			pass_mat.set_shader_parameter("dir_weight", float(cfg.get("dir_weight", 0.6)))
			pass_mat.set_shader_parameter("dir_softness", float(cfg.get("dir_softness", 0.35)))
			if mi.material_override is Material:
				var m := (mi.material_override as Material).duplicate() as Material
				m.next_pass = pass_mat
				mi.material_override = m
				count += 1
			else:
				for s in mi.get_surface_override_material_count():
					var sm := mi.get_surface_override_material(s) as Material
					if sm == null:
						continue
					var m2 := sm.duplicate() as Material
					m2.next_pass = pass_mat
					mi.set_surface_override_material(s, m2)
					count += 1
	evidence.applied.append({"fresnel": {"materials": count, "power": float(cfg.get("power", 3.0)), "intensity": float(cfg.get("intensity", 1.3)), "dir_weight": float(cfg.get("dir_weight", 0.6)), "light_dir": [light_dir.x, light_dir.y, light_dir.z]}})

# ---------------------------------------------------------------- 落叶
func _apply_leaves(viewer: Node3D, cfg: Dictionary) -> void:
	var tree: Node3D = viewer.tree
	if tree == null:
		evidence.notes.append("没有生命树节点，落叶跳过")
		return
	var tree_h := float(viewer.settings.tree.get("height_u", 7.65))
	var crown_y := tree_h * float(cfg.get("crown_center_fraction", 0.62))
	var half: Vector3 = _vec(cfg.get("crown_half_extents_u", [2.4, 1.6, 2.4]))
	var p := GPUParticles3D.new()
	p.name = "LookdevFallingLeaves"
	p.amount = int(cfg.get("amount", 48))
	p.lifetime = float(cfg.get("lifetime_s", 9.0))
	p.preprocess = float(cfg.get("preprocess_s", 9.0))
	p.randomness = float(cfg.get("randomness", 0.5))
	p.fixed_fps = 30
	p.use_fixed_seed = true
	p.seed = int(cfg.get("seed", 7))
	p.local_coords = false
	p.draw_order = GPUParticles3D.DRAW_ORDER_INDEX
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.visibility_aabb = AABB(Vector3(-8.0, -crown_y - 1.0, -8.0), Vector3(16.0, crown_y + 8.0, 16.0))
	p.position = tree.position + Vector3(0.0, crown_y, 0.0)
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = half
	pm.direction = Vector3(0.0, -1.0, 0.0)
	pm.spread = float(cfg.get("spread_deg", 60.0))
	pm.initial_velocity_min = float(cfg.get("velocity_u_per_s", [0.05, 0.2])[0])
	pm.initial_velocity_max = float(cfg.get("velocity_u_per_s", [0.05, 0.2])[1])
	pm.gravity = _vec(cfg.get("gravity", [0.0, -0.10, 0.0]))
	pm.damping_min = float(cfg.get("damping", [0.15, 0.35])[0])
	pm.damping_max = float(cfg.get("damping", [0.15, 0.35])[1])
	pm.angle_min = 0.0
	pm.angle_max = 360.0
	pm.use_rotation_velocity_3d = true
	pm.rotation_velocity_3d_min = _vec(cfg.get("rot_vel_min_deg_s", [-70.0, -90.0, -70.0]))
	pm.rotation_velocity_3d_max = _vec(cfg.get("rot_vel_max_deg_s", [70.0, 90.0, 70.0]))
	pm.scale_min = float(cfg.get("scale", [0.8, 1.25])[0])
	pm.scale_max = float(cfg.get("scale", [0.8, 1.25])[1])
	pm.lifetime_randomness = float(cfg.get("lifetime_randomness", 0.25))
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = float(cfg.get("turbulence_strength", 0.35))
	pm.turbulence_noise_scale = float(cfg.get("turbulence_scale", 3.0))
	pm.turbulence_noise_speed = _vec(cfg.get("turbulence_speed", [0.15, 0.05, 0.12]))
	pm.turbulence_influence_min = float(cfg.get("turbulence_influence", [0.2, 0.5])[0])
	pm.turbulence_influence_max = float(cfg.get("turbulence_influence", [0.2, 0.5])[1])
	var gradient := Gradient.new()
	var colors := PackedColorArray()
	var offsets := PackedFloat32Array()
	var palette: Array = cfg.get("colors", [[0.36, 0.55, 0.18], [0.55, 0.62, 0.16], [0.82, 0.62, 0.18], [0.72, 0.42, 0.12]])
	for i in palette.size():
		colors.append(_rgb(palette[i]))
		offsets.append(float(i) / float(palette.size()))
	gradient.colors = colors
	gradient.offsets = offsets
	gradient.interpolation_mode = Gradient.GRADIENT_INTERPOLATE_CONSTANT
	var ramp := GradientTexture1D.new()
	ramp.gradient = gradient
	pm.color_initial_ramp = ramp
	p.process_material = pm
	var mesh := _leaf_mesh(float(cfg.get("leaf_height_u", 0.13)), float(cfg.get("leaf_width_u", 0.09)), float(cfg.get("leaf_fold_u", 0.02)))
	var mat := ShaderMaterial.new()
	mat.shader = load("res://tools/traveler/lookdev_baghdad/lookdev_leaf.gdshader")
	mat.set_shader_parameter("emission_boost", float(cfg.get("emission_boost", 0.35)))
	mesh.surface_set_material(0, mat)
	p.draw_pass_1 = mesh
	viewer.world.add_child(p)
	p.emitting = true
	evidence.applied.append({"leaves": {"amount": p.amount, "lifetime_s": p.lifetime, "origin": [p.position.x, p.position.y, p.position.z], "half_extents": [half.x, half.y, half.z], "leaf_u": [float(cfg.get("leaf_height_u", 0.13)), float(cfg.get("leaf_width_u", 0.09))]}})

func _leaf_mesh(height_u: float, width_u: float, fold_u: float) -> ArrayMesh:
	var h := height_u * 0.5
	var w := width_u * 0.5
	var points := [Vector3(0, h, 0), Vector3(-w, 0, 0), Vector3(0, -h, 0), Vector3(w, 0, 0)]
	var center := Vector3(0, 0, fold_u)
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface.set_color(Color.WHITE)
	for index in points.size():
		for vertex in [center, points[index], points[(index + 1) % points.size()]]:
			surface.add_vertex(vertex)
	surface.generate_normals()
	return surface.commit()

func _vec(value: Variant) -> Vector3:
	if value is Vector3:
		return value
	var a: Array = value
	return Vector3(float(a[0]), float(a[1]), float(a[2]))

# ---------------------------------------------------------------- 地面材质（换成探针 shader，几何不动，道具贴地不受影响）
func _apply_ground_shader(viewer: Node3D, cfg: Dictionary) -> void:
	var ground := viewer.get("ground") as MeshInstance3D
	if ground == null:
		evidence.notes.append("没有 ground 节点，地面 shader 跳过")
		return
	var mat := ShaderMaterial.new()
	mat.shader = load(str(cfg.get("shader", "res://tools/traveler/lookdev_baghdad/lookdev_sand.gdshader")))
	var alb: Array = viewer.settings.ground.get("albedo", [0.84, 0.67, 0.45])
	mat.set_shader_parameter("sand_color", Color(float(alb[0]), float(alb[1]), float(alb[2])))
	mat.set_shader_parameter("sun_dir_world", (viewer.sun as DirectionalLight3D).global_basis.z.normalized())
	_set_sky_params(mat, cfg)
	ground.material_override = mat
	evidence.applied.append({"ground_shader": {"shader": mat.shader.resource_path, "keys": cfg.keys()}})

# ---------------------------------------------------------------- 额外图层（探针脚本：build(viewer, cfg) -> Dictionary）
func _apply_extra_script(viewer: Node3D, item: Dictionary) -> void:
	var path := str(item.get("script", ""))
	if path.is_empty() or not ResourceLoader.exists(path):
		evidence.notes.append("extra script 不存在: " + path)
		return
	var layer: Object = load(path).new()
	var result: Variant = layer.call("build", viewer, item.get("cfg", {}))
	evidence.applied.append({"extra_script": {"script": path, "result": result}})

# ---------------------------------------------------------------- 证据
func _sun_evidence(viewer: Node3D) -> void:
	var camera: Camera3D = viewer.camera
	var sun: DirectionalLight3D = viewer.sun
	var dir: Vector3 = sun.global_basis.z.normalized()
	var px: Vector2 = camera.unproject_position(camera.global_position + dir * 1000.0)
	var size: Vector2 = viewer.get_viewport().get_visible_rect().size
	evidence["sun"] = {"direction": [dir.x, dir.y, dir.z], "elevation_deg": rad_to_deg(asin(dir.y)), "pixel": [px.x, px.y], "uv": [px.x / size.x, px.y / size.y], "in_front": dir.dot(-camera.global_basis.z) > 0.0}
