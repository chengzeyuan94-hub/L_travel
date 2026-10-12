extends SceneTree
## 卡通风格对照测试。**只在运行时覆盖材质，不修改任何已有脚本、场景或资产。**
##
## 四种模式，用来分清「改善来自贴图、光照，还是轮廓」：
##   original      原样
##   albedo        只显示颜色、不计算光照（用来查原贴图里是不是已经烘了阴影）
##   toon          柔和卡通明暗：diffuse_mode=TOON、关高光、roughness 控过渡软硬
##   toon_outline  卡通 + 反向外壳细描边
##
## 两条路径：
##   --mode=... --asset=res://scenes/traveler/chibi_character.tscn --out=<前缀>
##       角色特写（正交四视）
##   --mode=... --scene --out=<前缀> [--char-pos=x,y,z] [--char-scale=0.85]
##       旅人长安实景（冻结机位），角色摆在城门口，**只卡通化角色**
##
## 描边粗细：--outline=<世界单位>。报告会换算成该次渲染下的实际像素，
## 因为「1–2 px 的细线」是画面目标，不是参数值——同一个 grow_amount
## 在特写和远景里差十倍。

const CHAR_SCENE := "res://scenes/traveler/chibi_character.tscn"
const TRAVELER_SCENE := "res://scenes/traveler/traveler_main.tscn"
# 独立路径：直接加载烘好的世界，自己套光照预设与冻结机位。
# 这样完全不经过 Codex 正在编辑的 atlas_viewer.gd / character_controller.gd。
const WORLD_SCENE := "res://generated/traveler/atlas/atlas_world.tscn"
const PRESETS := "res://data/traveler/look_presets.json"
# 冻结机位的实测值（来自已入库的 current-dusk-1920x1080.json）
const CAM_POS := Vector3(34.5735778808594, 3.96782684326172, 14.9224071502686)
const CAM_TARGET := Vector3(28.3460006713867, 1.49336516857147, 6.19920015335083)
const VIEWS := ["front", "left"]
const TOON_SHADER := "res://shaders/traveler/atlas_surface_toon.gdshader"
# 描边只给「物件」，不给地形与水面——这是那份风格分析的建议，也是为了看得出区别。
const OUTLINE_PARENTS := ["Cities", "VegetationHigh", "VegetationLow", "NaturalDetails"]
const NO_OUTLINE_PARENTS := ["Terrain64", "Water", "FarBackdrop", "FormalRoutes", "FormalNodes"]

var mode := "toon"
var asset_path := ""
var out_prefix := ""
var use_scene := false
var outline_world := 0.004
var char_pos := Vector3(30.2, 0.66, 8.8)
var char_scale := 0.85
var toon_roughness := 0.5
var period := "day"
var via_viewer := false
var scales: Array = []
var outline_color := Color(0.16, 0.12, 0.13)
var size_px := Vector2i(1920, 1080)
var touched: Array = []


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--mode="):
			mode = a.trim_prefix("--mode=")
		elif a.begins_with("--asset="):
			asset_path = a.trim_prefix("--asset=")
		elif a.begins_with("--out="):
			out_prefix = a.trim_prefix("--out=")
		elif a == "--scene":
			use_scene = true
		elif a.begins_with("--outline="):
			outline_world = float(a.trim_prefix("--outline="))
		elif a == "--via-viewer":
			via_viewer = true
		elif a.begins_with("--scales="):
			for t in a.trim_prefix("--scales=").split(","):
				scales.append(float(t))
		elif a == "--dusk":
			period = "dusk"
		elif a == "--day":
			period = "day"
		elif a.begins_with("--rough="):
			toon_roughness = float(a.trim_prefix("--rough="))
		elif a.begins_with("--char-scale="):
			char_scale = float(a.trim_prefix("--char-scale="))
		elif a.begins_with("--char-pos="):
			var p: PackedStringArray = a.trim_prefix("--char-pos=").split(",")
			if p.size() == 3:
				char_pos = Vector3(float(p[0]), float(p[1]), float(p[2]))
	if out_prefix.is_empty():
		push_error("需要 --out=")
		quit(1)
		return
	if asset_path.is_empty():
		asset_path = CHAR_SCENE
	call_deferred("run_scene" if use_scene else "run_closeup")


# ---------------------------------------------------------------- 材质改写

func _toonify(mat: StandardMaterial3D) -> void:
	mat.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	mat.metallic = 0.0
	# Godot 的 toon 漫反射用 roughness 控制明暗过渡的软硬：0 = 硬切，1 = 很软。
	# Carlos 的参考是「柔和卡通」，所以不要 0。
	mat.roughness = toon_roughness


func _albedo_only(mat: StandardMaterial3D) -> void:
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED


func _outline_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = outline_color
	m.cull_mode = BaseMaterial3D.CULL_FRONT
	m.grow = true
	m.grow_amount = outline_world
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	m.metallic = 0.0
	return m


func _apply(target: Node, local_outline: float) -> void:
	## 就地改写 target 子树里的材质；original 模式什么都不做。
	if mode == "original":
		return
	for mi in target.find_children("*", "MeshInstance3D", true, false):
		var mesh: Mesh = mi.mesh
		if mesh == null:
			continue
		for s in mesh.get_surface_count():
			var src: Material = mesh.surface_get_material(s)
			if src is StandardMaterial3D:
				var dup: StandardMaterial3D = src.duplicate()
				if mode == "albedo":
					_albedo_only(dup)
				else:
					_toonify(dup)
				mi.set_surface_override_material(s, dup)
				touched.append({"node": String(mi.name), "surface": s,
					"material": src.resource_name, "class": "StandardMaterial3D"})
			else:
				touched.append({"node": String(mi.name), "surface": s,
					"material": (src.resource_name if src != null else "<null>"),
					"class": (src.get_class() if src != null else "<null>"),
					"skipped": "非 StandardMaterial3D，本测试不改写"})
	if mode != "toon_outline" and mode != "world_toon_outline":
		return
	# 反向外壳：复制一份 MeshInstance3D，外撑、只画背面、无光照。
	# grow 在蒙皮之后作用于顶点，所以会跟着骨骼动画走。
	var shells: Array = []
	for mi in target.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh == null or String(mi.name).begins_with("Outline_"):
			continue
		var shell := MeshInstance3D.new()
		shell.name = "Outline_" + String(mi.name)
		shell.mesh = mi.mesh
		shell.transform = Transform3D.IDENTITY
		shell.material_override = _outline_material()
		shell.material_override.grow_amount = local_outline
		shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if mi is MeshInstance3D and mi.skeleton != NodePath(""):
			shell.skeleton = mi.skeleton
			shell.skin = mi.skin
		shells.append([mi, shell])
	for pair in shells:
		var mi: MeshInstance3D = pair[0]
		var shell: MeshInstance3D = pair[1]
		mi.get_parent().add_child(shell)
		shell.transform = mi.transform


func _swap_world_shader(world: Node) -> Dictionary:
	## 把世界里所有 ShaderMaterial 的 shader 换成 toon 版。
	## uniform 同名同序，所以材质上已设好的参数（风、亮度、岩石偏色）全部保留。
	var toon: Shader = load(TOON_SHADER)
	if toon == null:
		return {"error": "toon shader 加载失败"}
	var seen: Dictionary = {}
	var swapped := 0
	var kinds: Array = []
	for n in world.find_children("*", "GeometryInstance3D", true, false):
		var mats: Array = []
		if n.material_override != null:
			mats.append(n.material_override)
		if n is MeshInstance3D and n.mesh != null:
			for i in n.mesh.get_surface_count():
				var so: Material = n.get_surface_override_material(i)
				mats.append(so if so != null else n.mesh.surface_get_material(i))
		elif n is MultiMeshInstance3D and n.multimesh != null and n.multimesh.mesh != null:
			for i in n.multimesh.mesh.get_surface_count():
				mats.append(n.multimesh.mesh.surface_get_material(i))
		for m in mats:
			if m == null or not (m is ShaderMaterial):
				continue
			var sm: ShaderMaterial = m
			var id: int = sm.get_instance_id()
			if seen.has(id):
				continue
			seen[id] = true
			var old_name: String = sm.shader.resource_path if sm.shader != null else "<null>"
			sm.shader = toon
			# 卡通参数取默认值即可；这里只显式设一次，方便报告记录
			sm.set_shader_parameter("toon_bands", 4.0)
			sm.set_shader_parameter("toon_soft", 0.35)
			sm.set_shader_parameter("toon_wrap", 0.5)
			swapped += 1
			kinds.append({"material": sm.resource_name, "was": old_name})
	return {"swapped": swapped, "materials": kinds}


func _outline_world(world: Node) -> Dictionary:
	## 反向外壳描边，只加在物件类父节点下；地形/水面/远景不加。
	var made := 0
	var skipped: Array = []
	for group in OUTLINE_PARENTS:
		if not world.has_node(String(group)):
			skipped.append({"group": group, "why": "节点不存在"})
			continue
		var parent: Node = world.get_node(String(group))
		var targets: Array = []
		for n in parent.find_children("*", "GeometryInstance3D", true, false):
			if String(n.name).begins_with("Outline_"):
				continue
			targets.append(n)
		for n in targets:
			var shell: GeometryInstance3D
			if n is MeshInstance3D and n.mesh != null:
				var mi := MeshInstance3D.new()
				mi.mesh = n.mesh
				shell = mi
			elif n is MultiMeshInstance3D and n.multimesh != null:
				var mm := MultiMeshInstance3D.new()
				mm.multimesh = n.multimesh
				shell = mm
			else:
				continue
			shell.name = "Outline_" + String(n.name)
			shell.material_override = _outline_material()
			shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			n.get_parent().add_child(shell)
			shell.transform = n.transform
			made += 1
	return {"shells": made, "groups": OUTLINE_PARENTS, "not_outlined": NO_OUTLINE_PARENTS,
		"skipped": skipped}


# ---------------------------------------------------------------- 角色特写

func run_closeup() -> void:
	var packed: PackedScene = load(asset_path)
	if packed == null:
		print("[TOON] 加载失败 ", asset_path)
		quit(1)
		return
	var vp := SubViewport.new()
	vp.size = size_px
	vp.own_world_3d = true
	vp.msaa_3d = Viewport.MSAA_4X
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.60, 0.61, 0.65)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.70, 0.75, 0.85)
	env.ambient_light_energy = 0.5
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)

	var subject: Node3D = packed.instantiate()
	vp.add_child(subject)
	await process_frame

	var ap: AnimationPlayer = null
	for a in subject.find_children("*", "AnimationPlayer", true, false):
		ap = a
		break
	if ap != null and ap.has_animation("walk"):
		ap.play("walk")
		ap.seek(0.42, true)
		ap.advance(0.0)

	var aabb := _aabb(subject)
	var span: float = maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))
	_apply(subject, outline_world)

	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = span * 1.18
	cam.near = 0.01
	cam.far = span * 40.0
	vp.add_child(cam)
	cam.make_current()
	var key := DirectionalLight3D.new()
	key.light_color = Color(1.0, 0.95, 0.87)
	key.light_energy = 1.55
	vp.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.light_color = Color(0.72, 0.80, 1.0)
	fill.light_energy = 0.40
	fill.shadow_enabled = false
	vp.add_child(fill)

	var centre: Vector3 = aabb.position + aabb.size * 0.5
	var written: Array = []
	for i in VIEWS.size():
		var yaw: float = 0.62 if i == 0 else 1.9
		var b := Basis(Vector3.UP, yaw)
		cam.transform = Transform3D(b, centre + b * Vector3(0.0, 0.0, span * 3.0))
		key.transform = Transform3D(Basis(Vector3.UP, yaw - 0.75) * Basis(Vector3.RIGHT, -0.6), Vector3.ZERO)
		fill.transform = Transform3D(Basis(Vector3.UP, yaw + 2.3) * Basis(Vector3.RIGHT, -0.2), Vector3.ZERO)
		for f in 4:
			await process_frame
		await RenderingServer.frame_post_draw
		var img: Image = vp.get_texture().get_image()
		var path := "%s-%s.png" % [out_prefix, VIEWS[i]]
		img.save_png(path)
		written.append(path)
		print("[TOON] ", path)
	# 正交下每世界单位的像素数 = 视口高 / cam.size
	var px_per_unit: float = float(size_px.y) / cam.size
	_report({"path": "closeup", "asset": asset_path, "views": written,
		"ortho_size": cam.size, "px_per_world_unit": px_per_unit,
		"outline_world": outline_world,
		"outline_px_estimate": outline_world * px_per_unit,
		"subject_height_px": aabb.size.y * px_per_unit})
	quit(0)


# ---------------------------------------------------------------- 实景

func run_scene() -> void:
	## 两条路径：
	##   默认      直接加载烘好的 atlas_world.tscn，自己建相机/太阳/环境并套 look_presets.json，
	##             完全不经过 scripts/traveler/ 下任何脚本（Codex 编辑期间用这条最安全），
	##             代价是没有 traveler_lookdev 运行时生成的远景山与云。
	##   --via-viewer  走完整的 traveler_main.tscn，画面完整，但依赖 Codex 的脚本当前可解析。
	var vp := SubViewport.new()
	vp.size = size_px
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.msaa_3d = Viewport.MSAA_4X
	root.add_child(vp)

	var world: Node3D
	var cam: Camera3D
	var preset_info: Dictionary = {}

	if via_viewer:
		var vpk: PackedScene = load(TRAVELER_SCENE)
		var viewer: Node3D = vpk.instantiate()
		vp.add_child(viewer)
		await process_frame
		await process_frame
		if viewer.has_method("set_view"):
			viewer.set_view("changan")
		if viewer.has_method("update_camera"):
			viewer.update_camera()
		cam = viewer.camera if "camera" in viewer else vp.get_camera_3d()
		if cam != null:
			cam.make_current()
		world = viewer.world if "world" in viewer else viewer
		var ui = viewer.get("ui")
		if ui != null and is_instance_valid(ui):
			ui.visible = false
		var md = viewer.get("motion_director")
		if md != null and md.has_method("set_wind_enabled"):
			md.set_wind_enabled(false)
		if md != null and md.has_method("apply_time"):
			md.apply_time(0.0)
		preset_info = {"via": "traveler_main.tscn", "period": period}
	else:
		var packed: PackedScene = load(WORLD_SCENE)
		if packed == null:
			print("[TOON] 世界加载失败 ", WORLD_SCENE)
			quit(1)
			return
		world = packed.instantiate()
		vp.add_child(world)
		var env := Environment.new()
		var we := WorldEnvironment.new()
		we.environment = env
		vp.add_child(we)
		var sun := DirectionalLight3D.new()
		vp.add_child(sun)
		cam = Camera3D.new()
		vp.add_child(cam)
		cam.make_current()
		preset_info = _apply_preset(env, sun, cam, period)
		cam.global_position = CAM_POS
		cam.look_at(CAM_TARGET, Vector3.UP)
		await process_frame
		await process_frame

	var dist: float = (CAM_POS - char_pos).length()
	var px_per_unit: float = (float(size_px.y) * 0.5) / (dist * tan(deg_to_rad(cam.fov) * 0.5))

	var modes: Array = mode.split(",")
	var results: Array = []
	var world_log: Array = []
	var char_packed: PackedScene = load(CHAR_SCENE)
	if scales.is_empty():
		scales = [char_scale]
	var jobs: Array = []
	for m in modes:
		for sc in scales:
			jobs.append([String(m), float(sc)])
	for job in jobs:
		mode = String(job[0])
		char_scale = float(job[1])
		touched.clear()
		if mode.begins_with("world"):
			var sw := _swap_world_shader(world)
			var ol := {}
			if mode == "world_toon_outline":
				ol = _outline_world(world)
			world_log.append({"mode": mode, "shader_swap": sw, "outline": ol})
			print("[TOON] 世界材质换 toon %d 份；外壳 %d 个" % [
				int(sw.get("swapped", 0)), int(ol.get("shells", 0))])
		var ch: Node3D = char_packed.instantiate()
		ch.name = "ToonTestCharacter"
		ch.position = char_pos
		ch.scale = Vector3(char_scale, char_scale, char_scale)
		ch.rotation.y = 2.35
		world.add_child(ch)
		await process_frame
		var ap: AnimationPlayer = null
		for a in ch.find_children("*", "AnimationPlayer", true, false):
			ap = a
			break
		if ap != null and ap.has_animation("walk"):
			ap.play("walk")
			ap.seek(0.42, true)
			ap.advance(0.0)
		_apply(ch, outline_world)
		for f in 10:
			await process_frame
		await RenderingServer.frame_post_draw
		var img: Image = vp.get_texture().get_image()
		var path := "%s-%s-s%0.4f.png" % [out_prefix, mode, char_scale]
		var err: int = img.save_png(path)
		var head: Vector2 = cam.unproject_position(char_pos + Vector3.UP * char_scale)
		var feet: Vector2 = cam.unproject_position(char_pos)
		results.append({"mode": mode, "scale": char_scale, "path": path, "save_error": err,
			"feet_px": [feet.x, feet.y], "head_px": [head.x, head.y],
			"height_px_measured": absf(feet.y - head.y)})
		print("[TOON] %s  缩放 %.4f  角色 %.1f px  描边约 %.2f px" % [
			path.get_file(), char_scale, absf(feet.y - head.y),
			outline_world * char_scale * ((float(size_px.y) * 0.5) / ((cam.global_position - char_pos).length() * tan(deg_to_rad(cam.fov) * 0.5)))])
		ch.queue_free()
		await process_frame

	_report({"path": "standalone_world", "period": period, "preset": preset_info,
		"modes": results, "world": world_log,
		"image_size": [size_px.x, size_px.y],
		"world_scene": WORLD_SCENE,
		"camera": {"pos": [CAM_POS.x, CAM_POS.y, CAM_POS.z],
			"target": [CAM_TARGET.x, CAM_TARGET.y, CAM_TARGET.z], "fov": cam.fov},
		"char_pos": [char_pos.x, char_pos.y, char_pos.z], "char_scale": char_scale,
		"px_per_world_unit": px_per_unit,
		"outline_world": outline_world,
		"outline_px_estimate": outline_world * char_scale * px_per_unit,
		"caveat": "独立视图不含 traveler_lookdev 运行时生成的远景山与云。"})
	quit(0)


func _apply_preset(env: Environment, sun: DirectionalLight3D, cam: Camera3D, period: String) -> Dictionary:
	## 照 scripts/traveler/traveler_lookdev.gd 的 apply_lookdev() 复现环境与太阳，
	## 数值取自 data/traveler/look_presets.json 的 changan/<period>。**只读那个文件，不改。**
	var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(PRESETS))
	if typeof(doc) != TYPE_DICTIONARY:
		return {"error": "预设读不动"}
	var preset: Dictionary = doc.scenes.changan.get(period, {})
	var lk: Dictionary = preset.get("params", {})
	var dusk: bool = bool(preset.get("dusk_colors", period == "dusk"))

	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(0.07, 0.09, 0.26) if dusk else Color(0.26, 0.30, 0.64)
	sm.sky_horizon_color = Color(0.66, 0.42, 0.54) if dusk else Color(0.99, 0.74, 0.58)
	sm.sky_curve = 0.10
	sm.ground_bottom_color = Color(0.08, 0.08, 0.13) if dusk else Color(0.30, 0.27, 0.30)
	sm.ground_horizon_color = Color(0.46, 0.34, 0.42) if dusk else Color(0.86, 0.66, 0.58)
	sm.ground_curve = 0.08
	sm.sun_angle_max = 4.5
	sm.sun_curve = 0.06
	sky.sky_material = sm
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.ambient_light_energy = float(lk.get("amb", 0.26))
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.ssao_enabled = true
	env.ssao_radius = float(lk.get("ao", 0.16))
	env.ssao_intensity = float(lk.get("aoi", 4.0))
	env.ssao_power = 1.6
	env.ssao_detail = 0.6
	env.ssao_horizon = 0.06
	env.ssao_light_affect = 0.18
	env.ssil_enabled = true
	env.ssil_radius = float(lk.get("ssil", 0.6))
	env.ssil_intensity = float(lk.get("ssili", 0.7))
	env.glow_enabled = true
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	env.glow_intensity = float(lk.get("glow", 0.55))
	env.glow_bloom = 0.16
	env.glow_hdr_threshold = 0.92
	env.set_glow_level(3, 1.0); env.set_glow_level(4, 1.0); env.set_glow_level(5, 0.6)
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = Color(0.79, 0.70, 0.78)
	env.fog_sun_scatter = 0.28
	env.fog_density = float(lk.get("fogd", 1.0))
	env.fog_depth_begin = float(lk.get("fogb", 70.0))
	env.fog_depth_end = float(lk.get("foge", 380.0))
	env.fog_depth_curve = 1.35
	env.fog_sky_affect = 0.0
	env.fog_aerial_perspective = float(lk.get("aerial", 0.36))
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = float(lk.get("exp", 0.95))
	env.tonemap_white = float(lk.get("white", 1.5))
	env.adjustment_enabled = true
	env.adjustment_saturation = float(lk.get("sat", 1.26))
	env.adjustment_contrast = float(lk.get("con", 1.16))

	sun.light_color = Color(0.58, 0.62, 0.95) if dusk else Color(1.0, 0.80, 0.62)
	sun.light_energy = float(lk.get("sun", 3.4))
	sun.light_angular_distance = float(lk.get("ang", 0.35))
	sun.shadow_enabled = true
	sun.shadow_blur = float(lk.get("sblur", 0.8))
	sun.shadow_bias = float(lk.get("bias", 0.045))
	sun.shadow_normal_bias = float(lk.get("nbias", 0.12))
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_split_1 = 0.08
	sun.directional_shadow_max_distance = float(lk.get("shmax", 60.0))
	sun.rotation = Vector3(deg_to_rad(float(lk.get("sunel", -32.0))),
		deg_to_rad(float(lk.get("sunaz", 70.0))), 0.0)

	cam.fov = 36.0
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	if float(lk.get("dof", 0.0)) > 0.0:
		var ca := CameraAttributesPractical.new()
		ca.dof_blur_amount = float(lk.get("blur", 0.16))
		ca.dof_blur_far_enabled = true
		ca.dof_blur_far_distance = float(lk.get("dof", 19.0))
		ca.dof_blur_far_transition = float(lk.get("dof", 19.0)) * 0.55
		if float(lk.get("dofn", 0.0)) > 0.0:
			ca.dof_blur_near_enabled = true
			ca.dof_blur_near_distance = float(lk.get("dofn", 5.5))
			ca.dof_blur_near_transition = float(lk.get("dofn", 5.5)) * 0.6
		cam.attributes = ca
	return {"period": period, "dusk_colors": dusk, "params": lk}


func _aabb(n: Node) -> AABB:
	var out := AABB()
	var first := true
	for mi in n.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh == null:
			continue
		var t: Transform3D = mi.global_transform if mi.is_inside_tree() else mi.transform
		var b: AABB = t * mi.mesh.get_aabb()
		if first:
			out = b
			first = false
		else:
			out = out.merge(b)
	return out


func _report(extra: Dictionary) -> void:
	var doc := {"mode": mode, "toon_roughness": toon_roughness,
		"outline_color": [outline_color.r, outline_color.g, outline_color.b],
		"materials_touched": touched}
	doc.merge(extra)
	var f := FileAccess.open("%s.json" % out_prefix, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(doc, "  "))
		f.close()
