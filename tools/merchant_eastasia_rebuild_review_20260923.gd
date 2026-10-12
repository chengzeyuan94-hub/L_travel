extends Node
## Standalone terrain-only PBR review; does not instantiate the old Atlas scene.
## open_merchant_eastasia_rebuild.command [--capture[=/absolute/directory]]
## Optional: --asset=/absolute/eastasia-terrain.glb --gray --flat --overview --top
## 1 East Asia / 2 overview / 3 world top; C gray/color; G flat/relief.

const DEFAULT_ASSET := "res://docs/design/merchant-eastasia-rebuild-20260923/exports/eastasia-terrain.glb"
const DEFAULT_CAPTURE_DIR := "res://docs/design/merchant-eastasia-rebuild-20260923/review"
const IMAGE_SIZE := Vector2i(1664, 936)
const FLAT_Y := 0.72
const EASTASIA_TARGET := Vector3(33.5, 1.0, 6.0)
const EASTASIA_SIZE := 43.0
const EASTASIA_POLAR := 0.68
const FIXED_WORLD_BOUNDS := AABB(Vector3(-86.4, 0.42, -45.36), Vector3(180.0, 7.58, 129.6))
const PROTECTED_FILES := ["res://project.godot", "res://generated/traveler/atlas/atlas_world.tscn", "res://shaders/traveler/atlas_surface.gdshader", "res://data/traveler/atlas/cities.json", "res://data/traveler/formal-routes.json"]

var asset_path := ""
var capture_dir := ""
var capture_mode := false
var gray_mode := false
var flat_mode := false
var initial_view := "eastasia"
var current_view := "eastasia"
var failed := false
var prepared := false
var render_viewport: SubViewport
var world: Node3D
var imported: Node3D
var camera: Camera3D
var review_sun: DirectionalLight3D
var source_hash := ""
var source_protection: Dictionary = {}
var records: Array[Dictionary] = []
var asset_evidence: Dictionary = {}
var role_counts: Dictionary = {}
var land_bounds := AABB()
var first_land := true
var target := EASTASIA_TARGET
var polar := EASTASIA_POLAR
var azimuth := 0.0
var distance := 260.0
var camera_size := EASTASIA_SIZE
var drag_button := 0
var status_label: Label
var draw_timer: Timer
var watchdog: Timer


func _ready() -> void:
	call_deferred("start_review")


func start_review() -> void:
	asset_path = ProjectSettings.globalize_path(DEFAULT_ASSET)
	capture_dir = ProjectSettings.globalize_path(DEFAULT_CAPTURE_DIR)
	for arg: String in OS.get_cmdline_user_args():
		if arg == "--capture": capture_mode = true
		elif arg.begins_with("--capture="):
			capture_mode = true
			capture_dir = absolute_path(arg.trim_prefix("--capture="))
		elif arg.begins_with("--asset="): asset_path = absolute_path(arg.trim_prefix("--asset="))
		elif arg == "--gray": gray_mode = true
		elif arg == "--flat": flat_mode = true
		elif arg == "--overview": initial_view = "overview"
		elif arg == "--top": initial_view = "top"
	if not asset_path.is_absolute_path() or not capture_dir.is_absolute_path():
		fail("Asset and capture paths must be absolute or res:// paths")
		return
	if not FileAccess.file_exists(asset_path):
		fail("Missing standalone terrain GLB: " + asset_path)
		return
	if DisplayServer.get_name() == "headless":
		fail("Visual review requires a real rendering driver")
		return
	source_hash = FileAccess.get_sha256(asset_path)
	for path: String in PROTECTED_FILES:
		source_protection[path] = FileAccess.get_sha256(path)
	get_window().title = "商旅 · 东亚地形重建评审 · 独立纯地形"
	get_window().size = Vector2i(1440, 810)
	Engine.max_fps = 30
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	build_viewport_and_ui()
	build_review_world()
	if not load_terrain(): return
	apply_display_modes()
	set_view(initial_view)
	prepared = true
	print("EASTASIA_REBUILD_READY ", JSON.stringify({"asset": asset_path, "sha256": source_hash, "mesh_roles": role_counts, "capture": capture_mode, "size": [IMAGE_SIZE.x, IMAGE_SIZE.y]}))
	if capture_mode: await capture_all()


func build_viewport_and_ui() -> void:
	render_viewport = SubViewport.new()
	render_viewport.name = "EastAsiaReview1664x936"
	render_viewport.size = IMAGE_SIZE
	render_viewport.own_world_3d = true
	render_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	render_viewport.msaa_3d = Viewport.MSAA_4X
	render_viewport.use_taa = false
	add_child(render_viewport)
	var preview := TextureRect.new()
	preview.texture = render_viewport.get_texture()
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(preview)
	preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel := PanelContainer.new()
	panel.position = Vector2(14, 14)
	add_child(panel)
	var margin := MarginContainer.new()
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	panel.add_child(margin)
	var stack := VBoxContainer.new()
	margin.add_child(stack)
	status_label = Label.new()
	status_label.add_theme_font_size_override("font_size", 19)
	stack.add_child(status_label)
	var help := Label.new()
	help.text = "1 东亚主镜头 · 2 全图 · 3 全图俯视 · C 灰模/着色 · G 平地/起伏 · 左拖旋转 / 右拖平移 / 滚轮缩放"
	help.add_theme_font_size_override("font_size", 12)
	stack.add_child(help)
	var buttons := HBoxContainer.new()
	stack.add_child(buttons)
	for item: Array in [["东亚 1", "eastasia"], ["全图 2", "overview"], ["俯视 3", "top"]]:
		var button := Button.new()
		button.text = String(item[0])
		button.pressed.connect(set_view.bind(String(item[1])))
		buttons.add_child(button)
	var gray_button := Button.new()
	gray_button.text = "灰模 / 着色 C"
	gray_button.pressed.connect(toggle_gray)
	buttons.add_child(gray_button)
	var flat_button := Button.new()
	flat_button.text = "平地 / 起伏 G"
	flat_button.pressed.connect(toggle_flat)
	buttons.add_child(flat_button)
	if capture_mode: panel.hide()
	draw_timer = Timer.new()
	draw_timer.wait_time = 1.0 / 30.0
	draw_timer.timeout.connect(func(): RenderingServer.force_draw(false, 1.0 / 30.0))
	add_child(draw_timer)
	draw_timer.start()
	if capture_mode:
		watchdog = Timer.new()
		watchdog.one_shot = true
		watchdog.wait_time = 240.0
		watchdog.timeout.connect(func(): fail("Capture watchdog timeout"))
		add_child(watchdog)
		watchdog.start()


func build_review_world() -> void:
	world = Node3D.new()
	world.name = "IndependentEastAsiaTerrainReview"
	render_viewport.add_child(world)
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("78c7d7")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.80, 0.88, 1.0)
	environment.ambient_light_energy = 0.30
	environment.ambient_light_sky_contribution = 0.0
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	environment.tonemap_exposure = 1.0
	environment.ssao_enabled = true
	environment.ssao_radius = 0.60
	environment.ssao_intensity = 0.25
	environment.ssao_power = 1.0
	environment.glow_enabled = false
	environment.fog_enabled = false
	environment.volumetric_fog_enabled = false
	var env_node := WorldEnvironment.new()
	env_node.name = "ReviewEnvironment"
	env_node.environment = environment
	world.add_child(env_node)
	var sun := DirectionalLight3D.new()
	sun.name = "ReviewSoftDaylight"
	sun.light_color = Color(1.0, 0.97, 0.93)
	sun.light_energy = 0.80
	sun.light_angular_distance = 0.8
	sun.shadow_enabled = true
	sun.shadow_bias = 0.10
	sun.shadow_normal_bias = 1.50
	sun.directional_shadow_max_distance = 320.0
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	sun.directional_shadow_pancake_size = 0.0
	sun.rotation = Basis.looking_at(-Vector3(-30, 55, 25).normalized()).get_euler()
	world.add_child(sun)
	review_sun = sun
	var fill := DirectionalLight3D.new()
	fill.name = "ReviewCoolFill"
	fill.light_color = Color(0.82, 0.92, 1.0)
	fill.light_energy = 0.08
	fill.shadow_enabled = false
	fill.rotation = Basis.looking_at(-Vector3(30, 25, -20).normalized()).get_euler()
	world.add_child(fill)
	camera = Camera3D.new()
	camera.name = "ReviewOrthographicCamera"
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.near = 0.1
	camera.far = 1000.0
	world.add_child(camera)
	camera.make_current()


func load_terrain() -> bool:
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	var error := document.append_from_file(asset_path, state)
	if error != OK:
		fail("GLTFDocument load failed: " + error_string(error))
		return false
	imported = document.generate_scene(state) as Node3D
	if imported == null:
		fail("GLB did not produce a Node3D")
		return false
	world.add_child(imported)
	if has_imported_camera_or_light(imported):
		fail("Terrain GLB must not include cameras or lights")
		return false
	var surfaces_report: Array[Dictionary] = []
	var total_vertices := 0
	var total_triangles := 0
	for mesh_node: MeshInstance3D in mesh_nodes(imported):
		var role := classify_mesh(mesh_node)
		if role.is_empty():
			fail("Unclassified terrain mesh: " + String(mesh_node.name) + "; use EA_Land_Top / EA_Coast_Walls / EA_Water_Deep / EA_Water_Shallow names")
			return false
		role_counts[role] = int(role_counts.get(role, 0)) + 1
		# The large ocean sheets must receive terrain shadows without self-shadowing.
		if role == "water_deep" or role == "water_shallow":
			mesh_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var color_materials: Array[Material] = []
		var gray_materials: Array[Material] = []
		var original_mesh := mesh_node.mesh
		for surface in original_mesh.get_surface_count():
			var arrays := original_mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR] if arrays[Mesh.ARRAY_COLOR] != null else PackedColorArray()
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			var has_color := colors.size() == vertices.size() and not colors.is_empty()
			var source_material := mesh_node.get_active_material(surface)
			if source_material != null and not source_material is BaseMaterial3D:
				fail("Expected standard PBR, not a custom Atlas shader: " + String(mesh_node.name))
				return false
			var color_material := source_material.duplicate() as BaseMaterial3D if source_material != null else StandardMaterial3D.new()
			color_material.vertex_color_use_as_albedo = has_color
			# glTF COLOR_0 is linear. Converting it from sRGB again changes the asset.
			color_material.vertex_color_is_srgb = false
			# Runtime material copies only: suppress the broad white dielectric sheen.
			color_material.metallic_specular = 0.04 if role.begins_with("water_") else 0.08
			if role.begins_with("water_"): color_material.roughness = maxf(color_material.roughness, 0.85)
			var gray := color_material.duplicate() as BaseMaterial3D
			gray.vertex_color_use_as_albedo = false
			gray.albedo_texture = null
			gray.normal_enabled = false
			gray.emission_enabled = false
			gray.metallic = 0.0
			gray.roughness = 0.95
			gray.albedo_color = Color(0.68, 0.68, 0.68) if role == "land" else (Color(0.53, 0.53, 0.53) if role == "coast" else (Color(0.36, 0.36, 0.36) if role == "water_deep" else Color(0.48, 0.48, 0.48)))
			color_materials.append(color_material)
			gray_materials.append(gray)
			var color_report := color_statistics(colors)
			if role == "land" and (not has_color or int(color_report.get("nonwhite_count", 0)) == 0):
				fail("Land needs non-white COLOR_0 data; check explicit named vertex-color export")
				return false
			var triangles := int((indices.size() if not indices.is_empty() else vertices.size()) / 3)
			total_vertices += vertices.size()
			total_triangles += triangles
			surfaces_report.append({"node": str(imported.get_path_to(mesh_node)), "role": role, "surface": surface, "vertices": vertices.size(), "triangles": triangles, "colors": color_report, "pbr": {"class": color_material.get_class(), "name": color_material.resource_name, "albedo": color_json(color_material.albedo_color), "vertex_color": color_material.vertex_color_use_as_albedo, "vertex_color_srgb": color_material.vertex_color_is_srgb, "metallic": color_material.metallic, "roughness": color_material.roughness, "albedo_texture": color_material.albedo_texture.resource_path if color_material.albedo_texture != null else ""}})
		var record := {"node": mesh_node, "role": role, "original_mesh": original_mesh, "original_transform": mesh_node.global_transform, "color_materials": color_materials, "gray_materials": gray_materials}
		if role == "land":
			var bounds: AABB = mesh_node.global_transform * mesh_node.get_aabb()
			land_bounds = bounds if first_land else land_bounds.merge(bounds)
			first_land = false
			var flattened := make_flat_mesh(mesh_node)
			if flattened.is_empty(): return false
			record["flat_mesh"] = flattened.mesh
			record["flat_validation"] = flattened.validation
		records.append(record)
	if int(role_counts.get("land", 0)) == 0 or int(role_counts.get("coast", 0)) == 0 or int(role_counts.get("water_deep", 0)) == 0 or int(role_counts.get("water_shallow", 0)) == 0:
		fail("Expected land, coast walls, deep water and shallow water in the standalone GLB")
		return false
	asset_evidence = {"vertices": total_vertices, "triangles": total_triangles, "meshes": records.size(), "roles": role_counts, "land_bounds": bounds_json(land_bounds), "surfaces": surfaces_report, "source_contains_no_cameras_or_lights": true, "old_atlas_loaded": false}
	return true


func classify_mesh(node: MeshInstance3D) -> String:
	var label := String(node.name).to_lower() + " " + str(imported.get_path_to(node)).to_lower()
	if label.contains("water_shallow"): return "water_shallow"
	if label.contains("water_deep"): return "water_deep"
	if label.contains("coast") or label.contains("wall"): return "coast"
	if label.contains("land_top"): return "land"
	return ""


func make_flat_mesh(node: MeshInstance3D) -> Dictionary:
	var result := ArrayMesh.new()
	var inverse := node.global_transform.affine_inverse()
	var local_up := (node.global_transform.basis.transposed() * Vector3.UP).normalized()
	var max_xz_error := 0.0
	var max_y_error := 0.0
	for surface in node.mesh.get_surface_count():
		var arrays := node.mesh.surface_get_arrays(surface).duplicate(true)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals := PackedVector3Array()
		normals.resize(vertices.size())
		for index in vertices.size():
			var old_world := node.global_transform * vertices[index]
			var desired := Vector3(old_world.x, FLAT_Y, old_world.z)
			vertices[index] = inverse * desired
			normals[index] = local_up
			var written := node.global_transform * vertices[index]
			max_xz_error = maxf(max_xz_error, maxf(absf(written.x - old_world.x), absf(written.z - old_world.z)))
			max_y_error = maxf(max_y_error, absf(written.y - FLAT_Y))
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_TANGENT] = null
		result.add_surface_from_arrays(node.mesh.surface_get_primitive_type(surface), arrays)
	if max_xz_error > 0.0001 or max_y_error > 0.0001:
		fail("Flat review mesh could not preserve world XZ / target Y")
		return {}
	return {"mesh": result, "validation": {"world_y": FLAT_Y, "max_xz_error": max_xz_error, "max_y_error": max_y_error, "coast_wall_and_water_geometry_untouched": true}}


func apply_display_modes() -> void:
	for record: Dictionary in records:
		var node: MeshInstance3D = record.node
		node.mesh = record.flat_mesh if flat_mode and String(record.role) == "land" else record.original_mesh
		node.material_override = null
		var materials: Array = record.gray_materials if gray_mode else record.color_materials
		for surface in materials.size(): node.set_surface_override_material(surface, materials[surface])
	update_status()


func toggle_gray() -> void:
	if not prepared or capture_mode: return
	gray_mode = not gray_mode
	apply_display_modes()


func toggle_flat() -> void:
	if not prepared or capture_mode: return
	flat_mode = not flat_mode
	apply_display_modes()


func set_view(view: String) -> void:
	if camera == null: return
	current_view = view
	azimuth = 0.0
	distance = 260.0
	if view == "overview" or view == "top":
		target = Vector3(FIXED_WORLD_BOUNDS.get_center().x, FLAT_Y, FIXED_WORLD_BOUNDS.get_center().z)
		polar = EASTASIA_POLAR if view == "overview" else 0.0
		update_camera()
		camera_size = fitted_size(FIXED_WORLD_BOUNDS, 1.07)
	elif view == "eastasia-top":
		target = EASTASIA_TARGET
		polar = 0.0
		camera_size = EASTASIA_SIZE
	else:
		target = EASTASIA_TARGET
		polar = EASTASIA_POLAR
		camera_size = EASTASIA_SIZE
	update_camera()
	update_status()


func update_camera() -> void:
	if polar <= 0.0001:
		camera.position = target + Vector3(0, distance, 0)
		camera.look_at(target, Vector3(0, 0, -1))
	else:
		camera.position = target + Vector3(sin(polar) * sin(azimuth), cos(polar), sin(polar) * cos(azimuth)) * distance
		camera.look_at(target)
	camera.size = camera_size
	# Orthographic directional shadows use camera.far, not the sun max-distance.
	# Fit depth to the known land volume; the giant ocean sheets are excluded.
	var depth_bounds := FIXED_WORLD_BOUNDS
	depth_bounds.position.y = -0.5
	depth_bounds.size.y = 9.0
	var world_to_camera := camera.global_transform.affine_inverse()
	var minimum_depth := INF
	var maximum_depth := -INF
	for corner in 8:
		var camera_point := world_to_camera * depth_bounds.get_endpoint(corner)
		minimum_depth = minf(minimum_depth, -camera_point.z)
		maximum_depth = maxf(maximum_depth, -camera_point.z)
	camera.near = maxf(0.1, minimum_depth - 10.0)
	camera.far = maxf(camera.near + 1.0, maximum_depth + 10.0)
	if review_sun != null: review_sun.directional_shadow_max_distance = camera.far


func fitted_size(bounds: AABB, margin: float) -> float:
	var horizontal := 0.0
	var vertical := 0.0
	for index in 8:
		var offset := bounds.get_endpoint(index) - target
		horizontal = maxf(horizontal, absf(offset.dot(camera.global_basis.x)))
		vertical = maxf(vertical, absf(offset.dot(camera.global_basis.y)))
	return maxf(vertical * 2.0, horizontal * 2.0 * float(IMAGE_SIZE.y) / float(IMAGE_SIZE.x)) * margin


func update_status() -> void:
	if status_label == null: return
	var title := "东亚固定主镜头" if current_view == "eastasia" else ("全图固定镜头" if current_view == "overview" else ("东亚俯视" if current_view == "eastasia-top" else "全图俯视"))
	status_label.text = "东亚地形重建 · %s  |  %s  |  %s" % [title, "灰模" if gray_mode else "着色", "扁平轮廓 Y=0.72" if flat_mode else "立体地形"]


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and not event.pressed and event.button_index == drag_button: drag_button = 0


func _unhandled_input(event: InputEvent) -> void:
	if not prepared or capture_mode or failed: return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE: get_tree().quit()
		elif event.keycode == KEY_1 or event.keycode == KEY_HOME: set_view("eastasia")
		elif event.keycode == KEY_2: set_view("overview")
		elif event.keycode == KEY_3: set_view("top")
		elif event.keycode == KEY_C: toggle_gray()
		elif event.keycode == KEY_G: toggle_flat()
		return
	if event is InputEventMouseButton:
		if event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]: drag_button = event.button_index if event.pressed else 0
		if event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			camera_size = clampf(camera_size * (0.88 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.12), 4.0, 220.0)
			update_camera()
	elif event is InputEventMouseMotion and drag_button != 0:
		if drag_button == MOUSE_BUTTON_RIGHT or event.shift_pressed:
			var right := Vector3(camera.global_basis.x.x, 0, camera.global_basis.x.z).normalized()
			var vertical := Vector3(camera.global_basis.y.x, 0, camera.global_basis.y.z).normalized()
			var factor := camera_size / maxf(get_viewport().get_visible_rect().size.y, 1.0)
			target += (-right * event.relative.x + vertical * event.relative.y) * factor
		else:
			azimuth -= event.relative.x * 0.005
			polar = clampf(polar - event.relative.y * 0.004, 0.02, 1.32)
		update_camera()


func capture_all() -> void:
	if DirAccess.make_dir_recursive_absolute(capture_dir) != OK:
		fail("Cannot create capture directory: " + capture_dir)
		return
	var captures := [
		{"name": "color", "view": "eastasia", "gray": false, "flat": false},
		{"name": "gray", "view": "eastasia", "gray": true, "flat": false},
		{"name": "top-flat", "view": "top", "gray": false, "flat": true},
		{"name": "eastasia-top-flat", "view": "eastasia-top", "gray": false, "flat": true},
		{"name": "overview", "view": "overview", "gray": false, "flat": false}
	]
	var output_paths: Array[String] = []
	for shot: Dictionary in captures:
		gray_mode = bool(shot.gray)
		flat_mode = bool(shot.flat)
		apply_display_modes()
		set_view(String(shot.view))
		for frame in 60: await get_tree().process_frame
		await RenderingServer.frame_post_draw
		if not validate_source_unchanged(): return
		var image := render_viewport.get_texture().get_image()
		if image == null or image.get_size() != IMAGE_SIZE:
			fail("Viewport capture did not produce 1664x936")
			return
		var image_path := capture_dir.path_join(String(shot.name) + ".png")
		var error := image.save_png(image_path)
		if error != OK:
			fail("PNG save failed: " + error_string(error))
			return
		var flat_report: Array[Dictionary] = []
		for record: Dictionary in records:
			if String(record.role) == "land": flat_report.append(record.flat_validation)
		var report := {
			"schema": "silkroad.eastasia-rebuild-review.v1", "name": shot.name,
			"view": current_view, "gray": gray_mode, "flat": flat_mode,
			"source": {"path": asset_path, "sha256": source_hash, "sha256_at_capture": FileAccess.get_sha256(asset_path), "unchanged": true},
			"protected_source_files": source_protection, "protected_source_files_unchanged": true,
			"image": image_path, "image_size": [IMAGE_SIZE.x, IMAGE_SIZE.y],
			"renderer": RenderingServer.get_current_rendering_method(),
			"camera": {"target": [target.x, target.y, target.z], "size": camera.size, "width": camera.size * float(IMAGE_SIZE.x) / float(IMAGE_SIZE.y), "near": camera.near, "far": camera.far, "projection": camera.projection, "polar": polar, "azimuth": azimuth, "transform": transform_json(camera.transform)},
			"fixed_world_frame": bounds_json(FIXED_WORLD_BOUNDS), "water_excluded_from_framing": true,
			"asset": asset_evidence, "flat_preview_validation": flat_report,
			"lighting": {"tone_mapper": "linear", "exposure": 1.0, "ambient_color": [0.80, 0.88, 1.0], "ambient_energy": 0.30, "sun_color": [1.0, 0.97, 0.93], "sun_energy": 0.80, "sun_angular_distance": 0.8, "cool_fill_energy": 0.08, "sun_shadow_bias": review_sun.shadow_bias, "sun_shadow_normal_bias": review_sun.shadow_normal_bias, "sun_shadow_max_distance": review_sun.directional_shadow_max_distance, "sun_shadow_pancake_size": review_sun.directional_shadow_pancake_size, "water_casts_shadow": false, "runtime_specular_land": 0.08, "runtime_specular_water": 0.04, "ssao_radius": 0.60, "ssao_intensity": 0.25},
			"notes": ["Standalone imported standard-PBR terrain only. No old Atlas scene, city, route, vegetation, boat, cloud or decoration is instantiated.", "C uses material copies. G uses land-top mesh copies with original XZ and world Y=0.72; coast walls and water keep their original geometry.", "Fixed overview bounds cover longitude -20..180 and latitude -38..82 in the shared map projection. Ocean extent does not change the camera.", "Toolbar is outside the captured SubViewport. No resource is saved back to the source GLB or game project."]
		}
		var file := FileAccess.open(image_path.get_basename() + ".json", FileAccess.WRITE)
		if file == null:
			fail("Cannot write capture evidence")
			return
		file.store_string(JSON.stringify(report, "\t", false, true) + "\n")
		file.close()
		output_paths.append(image_path)
		print("EASTASIA_REBUILD_CAPTURE ", image_path)
	watchdog.stop()
	draw_timer.stop()
	print("EASTASIA_REBUILD_COMPLETE ", JSON.stringify({"images": output_paths, "source_unchanged": true}))
	get_tree().quit(0)


func validate_source_unchanged() -> bool:
	if FileAccess.get_sha256(asset_path) != source_hash:
		fail("Source GLB changed during review; reload for a consistent capture set")
		return false
	for path: String in source_protection:
		if FileAccess.get_sha256(path) != String(source_protection[path]):
			fail("Protected game source changed during review: " + path)
			return false
	for record: Dictionary in records:
		var node: MeshInstance3D = record.node
		if not node.global_transform.is_equal_approx(record.original_transform):
			fail("Imported object transform changed during review")
			return false
		if String(record.role) != "land" and node.mesh != record.original_mesh:
			fail("Coast or water geometry changed during flat preview")
			return false
	return true


func color_statistics(colors: PackedColorArray) -> Dictionary:
	if colors.is_empty(): return {"present": false, "count": 0}
	var minimum := Vector4(INF, INF, INF, INF)
	var maximum := Vector4(-INF, -INF, -INF, -INF)
	# GDScript float is double precision; avoid float32 accumulation on large meshes.
	var total: Array[float] = [0.0, 0.0, 0.0, 0.0]
	var squared: Array[float] = [0.0, 0.0, 0.0, 0.0]
	var unique: Dictionary = {}
	var white_count := 0
	for color: Color in colors:
		var value := Vector4(color.r, color.g, color.b, color.a)
		for axis in 4:
			minimum[axis] = minf(minimum[axis], value[axis])
			maximum[axis] = maxf(maximum[axis], value[axis])
			total[axis] += float(value[axis])
			squared[axis] += float(value[axis]) * float(value[axis])
		var key := Vector3i(roundi(color.r * 255.0), roundi(color.g * 255.0), roundi(color.b * 255.0))
		unique[key] = true
		if color.r >= 0.999 and color.g >= 0.999 and color.b >= 0.999: white_count += 1
	var mean: Array[float] = [0.0, 0.0, 0.0, 0.0]
	var deviation: Array[float] = [0.0, 0.0, 0.0, 0.0]
	for axis in 4:
		mean[axis] = total[axis] / float(colors.size())
		deviation[axis] = sqrt(maxf(0.0, squared[axis] / float(colors.size()) - mean[axis] * mean[axis]))
	return {"present": true, "count": colors.size(), "min_rgba": vector4_json(minimum), "max_rgba": vector4_json(maximum), "mean_rgba": mean, "std_rgba": deviation, "unique_rgb_8bit": unique.size(), "white_count": white_count, "nonwhite_count": colors.size() - white_count, "white_fraction": float(white_count) / float(colors.size())}


func has_imported_camera_or_light(node: Node) -> bool:
	if node is Camera3D or node is Light3D: return true
	for child: Node in node.get_children():
		if has_imported_camera_or_light(child): return true
	return false


func mesh_nodes(node: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	if node is MeshInstance3D: result.append(node)
	for child: Node in node.get_children(): result.append_array(mesh_nodes(child))
	return result


func vector4_json(value: Vector4) -> Array:
	return [value.x, value.y, value.z, value.w]


func color_json(value: Color) -> Array:
	return [value.r, value.g, value.b, value.a]


func transform_json(value: Transform3D) -> Array:
	return [value.basis.x.x, value.basis.x.y, value.basis.x.z, value.basis.y.x, value.basis.y.y, value.basis.y.z, value.basis.z.x, value.basis.z.y, value.basis.z.z, value.origin.x, value.origin.y, value.origin.z]


func bounds_json(value: AABB) -> Array:
	return [value.position.x, value.position.y, value.position.z, value.size.x, value.size.y, value.size.z]


func absolute_path(path: String) -> String:
	return ProjectSettings.globalize_path(path) if path.begins_with("res://") else path


func fail(message: String) -> void:
	if failed: return
	failed = true
	push_error("EASTASIA_REBUILD_FAILED: " + message)
	if status_label != null: status_label.text = "地形评审失败：" + message
	get_tree().quit(1)
