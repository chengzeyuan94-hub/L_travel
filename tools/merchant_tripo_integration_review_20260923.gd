extends Node
## Independent runtime review; never saves the original scene or shared resources.
## Godot --path <repo> res://tools/merchant_tripo_integration_review_20260923.tscn --
##   --capture [--before] [--capture=/absolute/output-directory] [--terrain=/absolute/62.glb]
## Without --capture this scene stays interactive. It is not the game's main scene.

const SOURCE_SCENE := "res://generated/traveler/atlas/atlas_world.tscn"
const DEFAULT_TERRAIN := "res://docs/design/merchant-tripo-integration-20260923/exports/62.glb"
const DEFAULT_CAPTURE_DIR := "res://docs/design/merchant-tripo-integration-20260923/review"
const IMAGE_SIZE := Vector2i(1920, 1080)
const PHASE_SECONDS := 7.25
const HEIGHT_CELL := 1.0
const PROTECTED_RADIUS := 8.0
const CLOSE_TARGET := Vector3(55.1, 0.9, 3.3)

var before := false
var capture_mode := false
var terrain_path := ""
var capture_dir := ""
var initial_view := "close"
var routes_visible := true
var failed := false
var prepared := false
var animation_time := PHASE_SECONDS
var render_viewport: SubViewport
var world: Node3D
var camera: Camera3D
var terrain_tile: Node3D
var city_center := Vector3(53.82, 0.746, 5.724)
var original_camera_transform: Transform3D
var original_camera_size := 135.0
var material_copies: Dictionary = {}
var animated_materials: Array[ShaderMaterial] = []
var protected_before: Dictionary = {}
var protected_after: Dictionary = {}
var tile_evidence: Dictionary = {}
var scatter_evidence: Array[Dictionary] = []
var source_evidence: Dictionary = {}
var current_view := "close"
var target := CLOSE_TARGET
var polar := 0.68
var azimuth := 0.10
var distance := 100.0
var camera_size := 10.8
var drag_button := 0
var status_label: Label
var draw_timer: Timer
var watchdog: Timer


func _ready() -> void:
	call_deferred("start_review")


func start_review() -> void:
	terrain_path = ProjectSettings.globalize_path(DEFAULT_TERRAIN)
	capture_dir = ProjectSettings.globalize_path(DEFAULT_CAPTURE_DIR)
	for arg: String in OS.get_cmdline_user_args():
		if arg == "--before": before = true
		elif arg == "--capture": capture_mode = true
		elif arg.begins_with("--capture="):
			capture_mode = true
			capture_dir = absolute_path(arg.trim_prefix("--capture="))
		elif arg.begins_with("--terrain="): terrain_path = absolute_path(arg.trim_prefix("--terrain="))
		elif arg == "--full": initial_view = "full"
		elif arg == "--hide-routes": routes_visible = false
		elif arg == "--routes": routes_visible = true
	if not terrain_path.is_absolute_path() or not capture_dir.is_absolute_path():
		fail("Terrain and capture paths must be absolute or res:// paths")
		return
	if DisplayServer.get_name() == "headless":
		fail("This visual review requires a real rendering driver")
		return
	get_window().title = "商旅 · Tripo 地形接入小样 · 平城京 · " + variant_name()
	get_window().size = Vector2i(1440, 810)
	Engine.max_fps = 30
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	build_viewport_and_ui()
	var packed := load(SOURCE_SCENE) as PackedScene
	if packed == null:
		fail("Cannot load original baked Atlas: " + SOURCE_SCENE)
		return
	world = packed.instantiate() as Node3D
	render_viewport.add_child(world)
	camera = world.get_node_or_null("AtlasCamera") as Camera3D
	var terrain_root := world.get_node_or_null("Terrain64")
	if camera == null or terrain_root == null:
		fail("Atlas structure changed: expected AtlasCamera and Terrain64")
		return
	for tile: Node in terrain_root.get_children():
		if String(tile.name).begins_with("T62_"): terrain_tile = tile as Node3D
	if terrain_tile == null:
		fail("Original Atlas has no T62 terrain")
		return
	city_center = (world.get_node("Cities/heijokyo") as Node3D).global_position
	original_camera_transform = camera.transform
	original_camera_size = camera.size
	camera.make_current()
	set_routes_visible(routes_visible)
	protected_before = protected_state()
	source_evidence = {
		"scene": SOURCE_SCENE,
		"scene_sha256": FileAccess.get_sha256(SOURCE_SCENE),
		"cities_sha256": FileAccess.get_sha256("res://data/traveler/atlas/cities.json"),
		"routes_sha256": FileAccess.get_sha256("res://data/traveler/formal-routes.json")
	}
	if not before:
		var old_heights := height_index(terrain_tile)
		if not replace_t62(): return
		var new_heights := height_index(terrain_tile)
		if not conform_natural_scatter(old_heights, new_heights): return
	else:
		tile_evidence = {"replaced": false, "reason": "original Atlas before baseline"}
		for group_name: String in ["VegetationHigh", "VegetationLow", "NaturalDetails"]:
			for node: Node in world.get_node(group_name).get_children():
				if node is MultiMeshInstance3D:
					scatter_evidence.append({"group": group_name, "name": node.name, "before": node.multimesh.instance_count, "after": node.multimesh.instance_count, "height_adjusted": 0})
	# Original sun, environment, water shader, city materials and route geometry stay
	# authored. Runtime shader copies change only the common animation clock.
	isolate_animation_materials(world)
	protected_after = protected_state()
	if protected_before != protected_after:
		fail("Protected city / route / node / coast / other-terrain state changed")
		return
	set_view(initial_view)
	prepared = true
	print("TRIPO_INTEGRATION_READY ", JSON.stringify({"variant": variant_name(), "terrain": terrain_path, "capture": capture_mode}))
	if capture_mode:
		await capture_pair()


func build_viewport_and_ui() -> void:
	render_viewport = SubViewport.new()
	render_viewport.name = "TripoIntegration1920x1080"
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
	panel.position = Vector2(16, 16)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(panel)
	var margin := MarginContainer.new()
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	panel.add_child(margin)
	var stack := VBoxContainer.new()
	margin.add_child(stack)
	status_label = Label.new()
	status_label.add_theme_font_size_override("font_size", 20)
	stack.add_child(status_label)
	var help := Label.new()
	help.text = "左键旋转 · 右键 / Shift+左键平移 · 滚轮缩放 · 1 近景 / 2 全图 · R 商道 · Esc 退出小样"
	help.add_theme_font_size_override("font_size", 13)
	stack.add_child(help)
	var buttons := HBoxContainer.new()
	stack.add_child(buttons)
	for item: Array in [["平城京近景", "close"], ["全图", "full"]]:
		var button := Button.new()
		button.text = String(item[0])
		button.pressed.connect(set_view.bind(String(item[1])))
		buttons.add_child(button)
	var route_button := Button.new()
	route_button.text = "显示 / 隐藏商道"
	route_button.pressed.connect(func(): set_routes_visible(not routes_visible))
	buttons.add_child(route_button)
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


func replace_t62() -> bool:
	if not FileAccess.file_exists(terrain_path):
		fail("Missing Tripo-derived T62 export: " + terrain_path)
		return false
	var originals := mesh_nodes(terrain_tile)
	if originals.is_empty():
		fail("Original T62 has no mesh")
		return false
	var original_material: Material = originals[0].get_active_material(0)
	if not original_material is ShaderMaterial:
		fail("Expected the original T62 vertex-color ShaderMaterial")
		return false
	var state := GLTFState.new()
	var document := GLTFDocument.new()
	var error := document.append_from_file(terrain_path, state)
	if error != OK:
		fail("Cannot load Tripo-derived T62 GLB: " + error_string(error))
		return false
	var imported := document.generate_scene(state) as Node3D
	if imported == null:
		fail("GLB did not produce a Node3D")
		return false
	imported.name = "TripoTerrainT62RuntimeCopy"
	terrain_tile.add_child(imported)
	var replacements := mesh_nodes(imported)
	if replacements.is_empty():
		fail("Tripo-derived T62 export has no meshes")
		return false
	var original_bounds := combined_bounds(originals)
	var new_bounds := combined_bounds(replacements)
	var extent_error := maxf(maxf(absf(original_bounds.position.x - new_bounds.position.x), absf(original_bounds.end.x - new_bounds.end.x)), maxf(absf(original_bounds.position.z - new_bounds.position.z), absf(original_bounds.end.z - new_bounds.end.z)))
	if extent_error > 0.01:
		fail("T62 XZ bounds changed by %.6f; expected a complete world-coordinate tile" % extent_error)
		return false
	if outside_position_keys(originals) != outside_position_keys(replacements):
		fail("Replacement changes T62 outside the 8-unit Heijokyo protection radius")
		return false
	var vertex_count := 0
	var triangle_count := 0
	for mesh_node: MeshInstance3D in replacements:
		for surface in mesh_node.mesh.get_surface_count():
			var arrays := mesh_node.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			if arrays[Mesh.ARRAY_COLOR] == null or arrays[Mesh.ARRAY_COLOR].size() != vertices.size():
				fail("Replacement needs vertex colors on every vertex; original Atlas shader does not read UV textures")
				return false
			vertex_count += vertices.size()
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			triangle_count += int((indices.size() if not indices.is_empty() else vertices.size()) / 3)
			mesh_node.set_surface_override_material(surface, original_material.duplicate() as Material)
	for original: MeshInstance3D in originals: original.visible = false
	tile_evidence = {"replaced": true, "path": terrain_path, "sha256": FileAccess.get_sha256(terrain_path), "vertices": vertex_count, "triangles": triangle_count, "xz_bounds_error": extent_error, "outside_radius_positions_unchanged": true, "original_bounds": bounds_json(original_bounds), "replacement_bounds": bounds_json(new_bounds), "material": "runtime copies of original T62 shader; exported vertex colors"}
	return true


func conform_natural_scatter(old_heights: Dictionary, new_heights: Dictionary) -> bool:
	for group_name: String in ["VegetationHigh", "VegetationLow", "NaturalDetails"]:
		for node: Node in world.get_node(group_name).get_children():
			if not node is MultiMeshInstance3D: continue
			var instance := node as MultiMeshInstance3D
			var original := instance.multimesh
			var changes: Dictionary = {}
			var max_delta := 0.0
			for index in original.instance_count:
				var transform := original.get_instance_transform(index)
				var p := instance.global_transform * transform.origin
				if not in_protected_circle(p): continue
				var old_y := ground_height(old_heights, p)
				var new_y := ground_height(new_heights, p)
				if not is_finite(old_y) or not is_finite(new_y): continue
				var delta := new_y - old_y
				if absf(delta) <= 0.00001: continue
				p.y += delta
				transform.origin = instance.global_transform.affine_inverse() * p
				changes[index] = transform
				max_delta = maxf(max_delta, absf(delta))
			if not changes.is_empty():
				var replacement := original.duplicate() as MultiMesh
				for index: int in changes: replacement.set_instance_transform(index, changes[index])
				# Validate every instance. No removal, reordering, XZ move or basis edit.
				var bounds := AABB()
				for index in original.instance_count:
					var old_transform := original.get_instance_transform(index)
					var new_transform := replacement.get_instance_transform(index)
					var a := instance.global_transform * old_transform.origin
					var b := instance.global_transform * new_transform.origin
					if absf(a.x - b.x) > 0.00001 or absf(a.z - b.z) > 0.00001 or not old_transform.basis.is_equal_approx(new_transform.basis):
						fail("Natural scatter changed XZ, rotation or scale: " + String(instance.name))
						return false
					if original.use_colors and original.get_instance_color(index) != replacement.get_instance_color(index):
						fail("Natural scatter color changed")
						return false
					if original.use_custom_data and original.get_instance_custom_data(index) != replacement.get_instance_custom_data(index):
						fail("Natural scatter custom data changed")
						return false
					var box: AABB = new_transform * original.mesh.get_aabb()
					bounds = box if index == 0 else bounds.merge(box)
				instance.multimesh = replacement
				instance.custom_aabb = bounds.grow(0.4)
			scatter_evidence.append({"group": group_name, "name": node.name, "before": original.instance_count, "after": instance.multimesh.instance_count, "height_adjusted": changes.size(), "max_abs_y_delta": max_delta, "xz_basis_colors_custom_data_preserved": true})
	return true


func height_index(node: Node) -> Dictionary:
	var buckets: Dictionary = {}
	for mesh_node: MeshInstance3D in mesh_nodes(node):
		if not mesh_node.is_visible_in_tree(): continue
		for surface in mesh_node.mesh.get_surface_count():
			var arrays := mesh_node.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			var count := indices.size() if not indices.is_empty() else vertices.size()
			for offset in range(0, count - 2, 3):
				var a: Vector3 = mesh_node.global_transform * vertices[indices[offset] if not indices.is_empty() else offset]
				var b: Vector3 = mesh_node.global_transform * vertices[indices[offset + 1] if not indices.is_empty() else offset + 1]
				var c: Vector3 = mesh_node.global_transform * vertices[indices[offset + 2] if not indices.is_empty() else offset + 2]
				var determinant := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
				if absf(determinant) < 0.000001: continue
				for x in range(floori(minf(a.x, minf(b.x, c.x)) / HEIGHT_CELL), floori(maxf(a.x, maxf(b.x, c.x)) / HEIGHT_CELL) + 1):
					for z in range(floori(minf(a.z, minf(b.z, c.z)) / HEIGHT_CELL), floori(maxf(a.z, maxf(b.z, c.z)) / HEIGHT_CELL) + 1):
						var key := Vector2i(x, z)
						if not buckets.has(key): buckets[key] = []
						buckets[key].append([a, b, c, determinant])
	return buckets


func ground_height(buckets: Dictionary, point: Vector3) -> float:
	var best := -INF
	var key := Vector2i(floori(point.x / HEIGHT_CELL), floori(point.z / HEIGHT_CELL))
	for triangle: Array in buckets.get(key, []):
		var a: Vector3 = triangle[0]
		var b: Vector3 = triangle[1]
		var c: Vector3 = triangle[2]
		var determinant: float = triangle[3]
		var u := ((b.z - c.z) * (point.x - c.x) + (c.x - b.x) * (point.z - c.z)) / determinant
		var v := ((c.z - a.z) * (point.x - c.x) + (a.x - c.x) * (point.z - c.z)) / determinant
		if u >= -0.0001 and v >= -0.0001 and u + v <= 1.0001:
			best = maxf(best, u * a.y + v * b.y + (1.0 - u - v) * c.y)
	return best


func isolate_animation_material(source: Material) -> Material:
	if not source is ShaderMaterial: return source
	var key := source.get_instance_id()
	if material_copies.has(key): return material_copies[key]
	var has_time := false
	for uniform: Dictionary in source.shader.get_shader_uniform_list():
		if String(uniform.name) == "anim_t": has_time = true
	if not has_time: return source
	var copy := source.duplicate() as ShaderMaterial
	copy.set_shader_parameter("anim_t", PHASE_SECONDS)
	material_copies[key] = copy
	animated_materials.append(copy)
	return copy


func isolate_animation_materials(node: Node) -> void:
	if node is MeshInstance3D:
		if node.material_override != null:
			node.material_override = isolate_animation_material(node.material_override)
		elif node.mesh != null:
			for surface in node.mesh.get_surface_count():
				var material: Material = node.get_active_material(surface)
				if material is ShaderMaterial: node.set_surface_override_material(surface, isolate_animation_material(material))
	elif node is MultiMeshInstance3D:
		if node.material_override != null:
			node.material_override = isolate_animation_material(node.material_override)
		elif node.multimesh != null and node.multimesh.mesh != null:
			var multimesh := node.multimesh.duplicate() as MultiMesh
			var mesh := multimesh.mesh.duplicate() as ArrayMesh
			if mesh != null:
				for surface in mesh.get_surface_count():
					mesh.surface_set_material(surface, isolate_animation_material(mesh.surface_get_material(surface)))
				multimesh.mesh = mesh
				node.multimesh = multimesh
	for child: Node in node.get_children(): isolate_animation_materials(child)


func _process(delta: float) -> void:
	if not prepared or capture_mode or failed: return
	animation_time += delta
	for material: ShaderMaterial in animated_materials:
		material.set_shader_parameter("anim_t", animation_time)


func set_view(view: String) -> void:
	if camera == null: return
	current_view = view
	if view == "full":
		target = Vector3(3, 0, 4)
		var offset := original_camera_transform.origin - target
		distance = offset.length()
		polar = acos(clampf(offset.y / distance, -1.0, 1.0))
		azimuth = atan2(offset.x, offset.z)
		camera_size = original_camera_size
		camera.transform = original_camera_transform
		camera.size = original_camera_size
	else:
		target = CLOSE_TARGET
		polar = 0.68
		azimuth = 0.10
		distance = 100.0
		camera_size = 10.8
		update_camera()
	update_status()


func update_camera() -> void:
	camera.position = target + Vector3(sin(polar) * sin(azimuth), cos(polar), sin(polar) * cos(azimuth)) * distance
	camera.look_at(target)
	camera.size = camera_size


func set_routes_visible(value: bool) -> void:
	routes_visible = value
	if world == null: return
	for branch: String in ["FormalRoutes", "FormalNodes"]:
		var node := world.get_node_or_null(branch) as Node3D
		if node != null: node.visible = value
	update_status()


func update_status() -> void:
	if status_label != null:
		status_label.text = "平城京 · Tripo 地形接入小样  |  %s  |  %s  |  商道%s" % ["原图 before" if before else "接入 after", "全图" if current_view == "full" else "近景", "显示" if routes_visible else "隐藏"]


func _input(event: InputEvent) -> void:
	# GUI buttons can consume mouse-up before _unhandled_input sees it.
	if event is InputEventMouseButton and not event.pressed and event.button_index == drag_button:
		drag_button = 0


func _unhandled_input(event: InputEvent) -> void:
	if not prepared or capture_mode or failed: return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE: get_tree().quit()
		elif event.keycode == KEY_1: set_view("close")
		elif event.keycode == KEY_2 or event.keycode == KEY_HOME: set_view("full")
		elif event.keycode == KEY_R: set_routes_visible(not routes_visible)
		return
	if event is InputEventMouseButton:
		if event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
			drag_button = event.button_index if event.pressed else 0
		if event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			camera_size = clampf(camera_size * (0.88 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.12), 2.0, 180.0)
			update_camera()
	elif event is InputEventMouseMotion and drag_button != 0:
		if drag_button == MOUSE_BUTTON_RIGHT or event.shift_pressed:
			var right := Vector3(camera.global_basis.x.x, 0, camera.global_basis.x.z).normalized()
			var vertical := Vector3(camera.global_basis.y.x, 0, camera.global_basis.y.z).normalized()
			var factor := camera_size / maxf(get_viewport().get_visible_rect().size.y, 1.0)
			target += (-right * event.relative.x + vertical * event.relative.y) * factor
		else:
			azimuth -= event.relative.x * 0.006
			polar = clampf(polar - event.relative.y * 0.005, 0.20, 1.35)
		update_camera()


func capture_pair() -> void:
	if DirAccess.make_dir_recursive_absolute(capture_dir) != OK:
		fail("Cannot create capture directory: " + capture_dir)
		return
	var files: Array[String] = []
	for view: String in ["close", "full"]:
		set_view(view)
		for frame in 75: await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var image := render_viewport.get_texture().get_image()
		if image == null or image.get_size() != IMAGE_SIZE:
			fail("SubViewport did not produce a 1920x1080 image")
			return
		var image_path := capture_dir.path_join(variant_name() + "-" + view + ".png")
		var error := image.save_png(image_path)
		if error != OK:
			fail("PNG save failed: " + error_string(error))
			return
		var report := {
			"schema": "silkroad.tripo-integration-review.v1",
			"variant": variant_name(), "view": view, "source": source_evidence,
			"image": image_path, "size": [IMAGE_SIZE.x, IMAGE_SIZE.y],
			"renderer": RenderingServer.get_current_rendering_method(),
			"phase_seconds": PHASE_SECONDS, "routes_visible": routes_visible,
			"camera": {"transform": transform_json(camera.transform), "size": camera.size, "target": [target.x, target.y, target.z], "projection": camera.projection},
			"terrain": tile_evidence, "natural_scatter": scatter_evidence,
			"protected_unchanged": protected_before == protected_after,
			"protected_state": protected_after,
			"lighting": "Original baked Sun and WorldEnvironment; no added lights or color grading",
			"material_policy": "Original T62 shader on imported vertex colors; runtime copies only for common animation phase",
			"notes": ["Only T62 is replaced in memory; no source scene, city, route, coast, global shader or project setting is saved.", "Natural instances preserve counts, XZ, basis, colors and custom data; only terrain-relative Y is conformed.", "Cities, baked routes/nodes and other terrain branches stay original. Capture images exclude the interactive helper UI."]
		}
		var file := FileAccess.open(image_path.get_basename() + ".json", FileAccess.WRITE)
		if file == null:
			fail("Cannot save capture evidence JSON")
			return
		file.store_string(JSON.stringify(report, "\t", false, true) + "\n")
		file.close()
		files.append(image_path)
		print("TRIPO_INTEGRATION_CAPTURE ", image_path)
	if watchdog != null: watchdog.stop()
	draw_timer.stop()
	print("TRIPO_INTEGRATION_COMPLETE ", JSON.stringify({"variant": variant_name(), "images": files, "protected_unchanged": true}))
	get_tree().quit(0)


func protected_state() -> Dictionary:
	var result: Dictionary = {}
	for branch: String in ["Cities", "FormalRoutes", "FormalNodes", "Coast"]:
		var rows: Array[Dictionary] = []
		collect_state(world.get_node(branch), rows)
		result[branch] = rows
	var other_terrain: Array[Dictionary] = []
	for tile: Node in world.get_node("Terrain64").get_children():
		if tile != terrain_tile: collect_state(tile, other_terrain)
	result["other_terrain"] = other_terrain
	return result


func collect_state(node: Node, rows: Array[Dictionary]) -> void:
	var row := {"path": str(world.get_path_to(node)), "type": node.get_class()}
	if node is Node3D:
		row["transform"] = transform_json(node.transform)
		row["visible"] = node.visible
	if node is MeshInstance3D and node.mesh != null:
		row["mesh_path"] = node.mesh.resource_path
		row["surfaces"] = node.mesh.get_surface_count()
		row["bounds"] = bounds_json(node.get_aabb())
	rows.append(row)
	for child: Node in node.get_children(): collect_state(child, rows)


func outside_position_keys(nodes: Array[MeshInstance3D]) -> Dictionary:
	var result: Dictionary = {}
	for mesh_node: MeshInstance3D in nodes:
		for surface in mesh_node.mesh.get_surface_count():
			var arrays := mesh_node.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			for vertex: Vector3 in vertices:
				var p := mesh_node.global_transform * vertex
				if in_protected_circle(p): continue
				result[Vector3i(roundi(p.x * 1000.0), roundi(p.y * 1000.0), roundi(p.z * 1000.0))] = true
	return result


func in_protected_circle(point: Vector3) -> bool:
	return Vector2(point.x - city_center.x, point.z - city_center.z).length_squared() <= PROTECTED_RADIUS * PROTECTED_RADIUS


func mesh_nodes(node: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	if node is MeshInstance3D: result.append(node)
	for child: Node in node.get_children(): result.append_array(mesh_nodes(child))
	return result


func combined_bounds(nodes: Array[MeshInstance3D]) -> AABB:
	var result := AABB()
	var first := true
	for node: MeshInstance3D in nodes:
		var bounds: AABB = node.global_transform * node.get_aabb()
		result = bounds if first else result.merge(bounds)
		first = false
	return result


func transform_json(value: Transform3D) -> Array:
	return [value.basis.x.x, value.basis.x.y, value.basis.x.z, value.basis.y.x, value.basis.y.y, value.basis.y.z, value.basis.z.x, value.basis.z.y, value.basis.z.z, value.origin.x, value.origin.y, value.origin.z]


func bounds_json(value: AABB) -> Array:
	return [value.position.x, value.position.y, value.position.z, value.size.x, value.size.y, value.size.z]


func absolute_path(path: String) -> String:
	return ProjectSettings.globalize_path(path) if path.begins_with("res://") else path


func variant_name() -> String:
	return "before" if before else "after"


func fail(message: String) -> void:
	if failed: return
	failed = true
	push_error("TRIPO_INTEGRATION_FAILED: " + message)
	if status_label != null: status_label.text = "小样加载失败：" + message
	get_tree().quit(1)
