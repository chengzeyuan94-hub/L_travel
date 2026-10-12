extends Node
## Independent runtime review; never saves the original scene or shared resources.
## Godot --path <repo> res://tools/merchant_japan_region_review_20260923.tscn --
##   --capture [--before] [--capture=/absolute/output-directory] [--terrain-dir=/absolute/exports]
## Defaults: Japan region view, routes shown, isolated soft ambient/SSAO. --original-light opts out.
## Without --capture this scene stays interactive. It is not the game's main scene.

const SOURCE_SCENE := "res://generated/traveler/atlas/atlas_world.tscn"
const DEFAULT_TERRAIN_DIR := "res://docs/design/merchant-japan-region-20260923/exports"
const DEFAULT_CAPTURE_DIR := "res://docs/design/merchant-japan-region-20260923/review"
const TREE_RETENTION_CONFIG := "res://docs/design/merchant-japan-region-20260923/config/tree-retention.json"
const IMAGE_SIZE := Vector2i(1920, 1080)
const PHASE_SECONDS := 7.25
const HEIGHT_CELL := 1.0
const ALLOWED_TILE_IDS := [62, 63]
const RELOAD_STATE_KEY := "merchant_japan_region_review_state"
const REGION_TARGET := Vector3(55.3, 1.0, 1.0)
const CLOSE_TARGET := Vector3(55.1, 0.9, 3.3)

var before := false
var capture_mode := false
var terrain_dir := ""
var soft_light := true
var restored_state: Dictionary = {}
var replacement_ids: Array[int] = []
var candidate_tree_keys: Dictionary = {}
var retained_tree_keys: Dictionary = {}
var japan_rings: Array[PackedVector2Array] = []
var tree_mask_evidence: Dictionary = {}
var capture_dir := ""
var initial_view := "region"
var routes_visible := true
var failed := false
var prepared := false
var animation_time := PHASE_SECONDS
var render_viewport: SubViewport
var world: Node3D
var camera: Camera3D
var terrain_tiles: Dictionary = {}
var original_camera_transform: Transform3D
var original_camera_size := 135.0
var material_copies: Dictionary = {}
var animated_materials: Array[ShaderMaterial] = []
var protected_before: Dictionary = {}
var protected_after: Dictionary = {}
var tile_evidence: Array[Dictionary] = []
var scatter_evidence: Array[Dictionary] = []
var source_evidence: Dictionary = {}
var current_view := "region"
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
	terrain_dir = ProjectSettings.globalize_path(DEFAULT_TERRAIN_DIR)
	capture_dir = ProjectSettings.globalize_path(DEFAULT_CAPTURE_DIR)
	for arg: String in OS.get_cmdline_user_args():
		if arg == "--before": before = true
		elif arg == "--capture": capture_mode = true
		elif arg.begins_with("--capture="):
			capture_mode = true
			capture_dir = absolute_path(arg.trim_prefix("--capture="))
		elif arg.begins_with("--terrain-dir="): terrain_dir = absolute_path(arg.trim_prefix("--terrain-dir="))
		elif arg == "--close": initial_view = "close"
		elif arg == "--full": initial_view = "full"
		elif arg == "--region": initial_view = "region"
		elif arg == "--hide-routes": routes_visible = false
		elif arg == "--routes": routes_visible = true
		elif arg == "--original-light": soft_light = false
		elif arg == "--soft-light": soft_light = true
	if not capture_mode and get_tree().has_meta(RELOAD_STATE_KEY):
		restored_state = get_tree().get_meta(RELOAD_STATE_KEY)
		before = bool(restored_state.get("before", before))
		routes_visible = bool(restored_state.get("routes_visible", routes_visible))
		animation_time = float(restored_state.get("animation_time", PHASE_SECONDS))
	if not terrain_dir.is_absolute_path() or not capture_dir.is_absolute_path():
		fail("Terrain directory and capture paths must be absolute or res:// paths")
		return
	if DisplayServer.get_name() == "headless":
		fail("This visual review requires a real rendering driver")
		return
	get_window().title = "商旅 · 日本区域样板 · " + variant_name()
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
		var tile_id := int(String(tile.name).substr(1, 2))
		if tile_id in ALLOWED_TILE_IDS: terrain_tiles[tile_id] = tile
	for tile_id: int in ALLOWED_TILE_IDS:
		if not terrain_tiles.has(tile_id):
			fail("Original Atlas has no T%02d terrain" % tile_id)
			return
		if FileAccess.file_exists(tile_path(tile_id)): replacement_ids.append(tile_id)
	if not before and 62 not in replacement_ids:
		fail("Missing required Japanese mainland export: " + tile_path(62))
		return
	original_camera_transform = camera.transform
	original_camera_size = camera.size
	camera.make_current()
	set_routes_visible(routes_visible)
	if not load_tree_policy(): return
	protected_before = protected_state()
	source_evidence = {
		"scene": SOURCE_SCENE,
		"scene_sha256": FileAccess.get_sha256(SOURCE_SCENE),
		"cities_sha256": FileAccess.get_sha256("res://data/traveler/atlas/cities.json"),
		"routes_sha256": FileAccess.get_sha256("res://data/traveler/formal-routes.json")
	}
	if not before:
		var old_heights := region_height_index()
		if not replace_region_tiles(): return
		var new_heights := region_height_index()
		if not conform_natural_scatter(old_heights, new_heights): return
	else:
		for tile_id: int in ALLOWED_TILE_IDS:
			tile_evidence.append({"tile_id": tile_id, "replaced": false, "reason": "original Atlas before baseline"})
		for group_name: String in ["VegetationHigh", "VegetationLow", "NaturalDetails"]:
			for node: Node in world.get_node(group_name).get_children():
				if node is MultiMeshInstance3D:
					scatter_evidence.append({"group": group_name, "name": node.name, "before": node.multimesh.instance_count, "after": node.multimesh.instance_count, "height_adjusted": 0})
	if soft_light: apply_soft_environment()
	# Original sun, sea, city materials and route geometry remain authored. Copies
	# below affect only the common animation clock; no global shader is edited.
	isolate_animation_materials(world)
	protected_after = protected_state()
	if protected_before != protected_after:
		fail("Protected city / route / node / coast / other-terrain state changed")
		return
	set_view(initial_view)
	restore_camera_state()
	prepared = true
	print("JAPAN_REGION_READY ", JSON.stringify({"variant": variant_name(), "terrain_dir": terrain_dir, "replacement_ids": replacement_ids, "capture": capture_mode, "soft_light": soft_light}))
	if capture_mode:
		await capture_views()


func build_viewport_and_ui() -> void:
	render_viewport = SubViewport.new()
	render_viewport.name = "JapanRegion1920x1080"
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
	help.text = "左键旋转 · 右键 / Shift+左键平移 · 滚轮缩放 · 1 城市 / 2 日本 / 3 全图 · B 原图/样板 · R 商道 · Esc 退出"
	help.add_theme_font_size_override("font_size", 13)
	stack.add_child(help)
	var buttons := HBoxContainer.new()
	stack.add_child(buttons)
	for item: Array in [["平城京近景 1", "close"], ["日本区域 2", "region"], ["全图 3", "full"]]:
		var button := Button.new()
		button.text = String(item[0])
		button.pressed.connect(set_view.bind(String(item[1])))
		buttons.add_child(button)
	var route_button := Button.new()
	route_button.text = "显示 / 隐藏商道"
	route_button.pressed.connect(func(): set_routes_visible(not routes_visible))
	buttons.add_child(route_button)
	var compare_button := Button.new()
	compare_button.text = "原图 / 样板 B"
	compare_button.pressed.connect(toggle_comparison)
	buttons.add_child(compare_button)
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


func replace_region_tiles() -> bool:
	for tile_id: int in ALLOWED_TILE_IDS:
		if tile_id not in replacement_ids:
			tile_evidence.append({"tile_id": tile_id, "replaced": false, "reason": "export absent; original tile retained"})
			continue
		var tile: Node3D = terrain_tiles[tile_id]
		var path := tile_path(tile_id)
		var originals := mesh_nodes(tile)
		if originals.is_empty():
			fail("Original T%d has no mesh" % tile_id)
			return false
		var original_material: Material = originals[0].get_active_material(0)
		if not original_material is ShaderMaterial:
			fail("Expected original vertex-color ShaderMaterial on T%d" % tile_id)
			return false
		var state := GLTFState.new()
		var document := GLTFDocument.new()
		var error := document.append_from_file(path, state)
		if error != OK:
			fail("Cannot load region GLB %s: %s" % [path, error_string(error)])
			return false
		var imported := document.generate_scene(state) as Node3D
		if imported == null:
			fail("GLB did not produce a Node3D: " + path)
			return false
		imported.name = "JapanRegionT%dRuntimeCopy" % tile_id
		tile.add_child(imported)
		var replacements := mesh_nodes(imported)
		if replacements.is_empty():
			fail("Region export has no meshes: " + path)
			return false
		var original_bounds := combined_bounds(originals)
		var new_bounds := combined_bounds(replacements)
		var extent_error := maxf(maxf(absf(original_bounds.position.x - new_bounds.position.x), absf(original_bounds.end.x - new_bounds.end.x)), maxf(absf(original_bounds.position.z - new_bounds.position.z), absf(original_bounds.end.z - new_bounds.end.z)))
		if extent_error > 0.01:
			fail("T%d XZ bounds changed by %.6f; expected a complete world-coordinate tile" % [tile_id, extent_error])
			return false
		var coastline := compare_boundaries(originals, replacements)
		if not bool(coastline.passed):
			fail("T%d outer boundary changed: %s" % [tile_id, JSON.stringify(coastline)])
			return false
		var vertex_count := 0
		var triangle_count := 0
		for mesh_node: MeshInstance3D in replacements:
			for surface in mesh_node.mesh.get_surface_count():
				var arrays := mesh_node.mesh.surface_get_arrays(surface)
				var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				if arrays[Mesh.ARRAY_COLOR] == null or arrays[Mesh.ARRAY_COLOR].size() != vertices.size():
					fail("T%d needs vertex colors on every vertex; Atlas shader does not read UV textures" % tile_id)
					return false
				vertex_count += vertices.size()
				var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
				triangle_count += int((indices.size() if not indices.is_empty() else vertices.size()) / 3)
				mesh_node.set_surface_override_material(surface, original_material.duplicate() as Material)
		for original: MeshInstance3D in originals: original.visible = false
		tile_evidence.append({"tile_id": tile_id, "replaced": true, "path": path, "sha256": FileAccess.get_sha256(path), "vertices": vertex_count, "triangles": triangle_count, "xz_bounds_error": extent_error, "boundary": coastline, "original_bounds": bounds_json(original_bounds), "replacement_bounds": bounds_json(new_bounds), "material": "runtime copies of original tile shader; exported vertex colors"})
	return true


func conform_natural_scatter(old_heights: Dictionary, new_heights: Dictionary) -> bool:
	var seen_japan: Dictionary = {}
	var kept_japan: Dictionary = {}
	for group_name: String in ["VegetationHigh", "VegetationLow", "NaturalDetails"]:
		var is_tree_group := group_name != "NaturalDetails"
		for node: Node in world.get_node(group_name).get_children():
			if not node is MultiMeshInstance3D: continue
			var instance := node as MultiMeshInstance3D
			var original := instance.multimesh
			var changes: Dictionary = {}
			var kept: Array[int] = []
			var max_delta := 0.0
			var local_before := 0
			var local_after := 0
			for index in original.instance_count:
				var transform := original.get_instance_transform(index)
				var p := instance.global_transform * transform.origin
				if is_tree_group and in_japan(p):
					var key := tree_xz_key(p)
					if not candidate_tree_keys.has(key):
						fail("Japanese tree positions changed; update the explicit retention policy: " + key)
						return false
					seen_japan[key] = true
					local_before += 1
					if not retained_tree_keys.has(key): continue
					kept_japan[key] = true
					local_after += 1
				kept.append(index)
				var old_y := ground_height(old_heights, p)
				var new_y := ground_height(new_heights, p)
				if not is_finite(old_y) or not is_finite(new_y): continue
				var delta := new_y - old_y
				if absf(delta) <= 0.00001: continue
				p.y += delta
				transform.origin = instance.global_transform.affine_inverse() * p
				changes[index] = transform
				max_delta = maxf(max_delta, absf(delta))
			if not changes.is_empty() or kept.size() != original.instance_count:
				var result := MultiMesh.new()
				result.transform_format = original.transform_format
				result.use_colors = original.use_colors
				result.use_custom_data = original.use_custom_data
				result.mesh = original.mesh
				result.instance_count = kept.size()
				var bounds := AABB()
				for new_index in kept.size():
					var old_index := kept[new_index]
					var old_transform := original.get_instance_transform(old_index)
					var new_transform: Transform3D = changes.get(old_index, old_transform)
					result.set_instance_transform(new_index, new_transform)
					if original.use_colors: result.set_instance_color(new_index, original.get_instance_color(old_index))
					if original.use_custom_data: result.set_instance_custom_data(new_index, original.get_instance_custom_data(old_index))
					var written := result.get_instance_transform(new_index)
					var a := instance.global_transform * old_transform.origin
					var b := instance.global_transform * written.origin
					if absf(a.x - b.x) > 0.00001 or absf(a.z - b.z) > 0.00001 or not old_transform.basis.is_equal_approx(written.basis):
						fail("Retained natural scatter changed XZ, rotation or scale: " + String(instance.name))
						return false
					if original.use_colors and original.get_instance_color(old_index) != result.get_instance_color(new_index):
						fail("Retained natural scatter color changed")
						return false
					if original.use_custom_data and original.get_instance_custom_data(old_index) != result.get_instance_custom_data(new_index):
						fail("Retained natural scatter custom data changed")
						return false
					var box: AABB = written * original.mesh.get_aabb()
					bounds = box if new_index == 0 else bounds.merge(box)
				instance.multimesh = result
				instance.custom_aabb = bounds.grow(0.4)
				if kept.is_empty(): instance.visible = false
			scatter_evidence.append({"group": group_name, "name": node.name, "before": original.instance_count, "after": instance.multimesh.instance_count, "japan_before": local_before, "japan_after": local_after, "height_adjusted": changes.size(), "max_abs_y_delta": max_delta, "retained_xz_basis_colors_custom_data_preserved": true, "outside_japan_count_preserved": true})
	if seen_japan.size() != candidate_tree_keys.size() or kept_japan.size() != retained_tree_keys.size():
		fail("Baked-scene Japanese tree count does not match the explicit retention JSON")
		return false
	tree_mask_evidence["observed_unique_before"] = seen_japan.size()
	tree_mask_evidence["observed_unique_after"] = kept_japan.size()
	return true


func load_tree_policy() -> bool:
	if not FileAccess.file_exists(TREE_RETENTION_CONFIG):
		fail("Missing Japanese tree retention policy: " + TREE_RETENTION_CONFIG)
		return false
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(TREE_RETENTION_CONFIG))
	if not parsed is Dictionary:
		fail("Invalid tree retention JSON")
		return false
	var policy: Dictionary = parsed
	var ring_ids: Array[int] = []
	for raw_id in policy.get("coast_ring_indices", []):
		if typeof(raw_id) not in [TYPE_INT, TYPE_FLOAT] or float(raw_id) != float(int(raw_id)):
			fail("Coast ring IDs must be integer-valued JSON numbers")
			return false
		ring_ids.append(int(raw_id))
	if ring_ids.size() != 3 or ring_ids[0] != 13 or ring_ids[1] != 17 or ring_ids[2] != 18:
		fail("Tree retention must be restricted to Japan coast rings 13/17/18")
		return false
	var candidates: Array = policy.get("candidate_xz_keys", [])
	var retained: Array = policy.get("retain_xz_keys", [])
	for key: String in candidates: candidate_tree_keys[key] = true
	for key: String in retained:
		if not candidate_tree_keys.has(key):
			fail("Retained tree key is not in source candidate mask")
			return false
		retained_tree_keys[key] = true
	if candidate_tree_keys.size() != candidates.size() or retained_tree_keys.size() != retained.size() or retained.size() < 24 or retained.size() > 30:
		fail("Tree policy has duplicate keys or a retained total outside 24–30")
		return false
	var coasts = JSON.parse_string(FileAccess.get_file_as_string("res://data/traveler/atlas/coasts.json"))
	if not coasts is Array:
		fail("Cannot read Atlas coastline rings")
		return false
	for ring_id in ring_ids:
		var ring := PackedVector2Array()
		for point: Array in coasts[int(ring_id)]: ring.append(Vector2(float(point[0]), float(point[1])))
		japan_rings.append(ring)
	tree_mask_evidence = {"config": TREE_RETENTION_CONFIG, "sha256": FileAccess.get_sha256(TREE_RETENTION_CONFIG), "applied": not before, "coast_ring_indices": ring_ids, "candidate_unique": candidates.size(), "retained_unique": retained.size(), "xz_key_precision": 0.001, "city_embedded_plants_untouched": true, "high_low_trunk_canopy_share_same_mask": true}
	return true


func in_japan(point: Vector3) -> bool:
	var xz := Vector2(point.x, point.z)
	for ring: PackedVector2Array in japan_rings:
		if Geometry2D.is_point_in_polygon(xz, ring): return true
	return false


func tree_xz_key(point: Vector3) -> String:
	return "%d:%d" % [roundi(point.x * 1000.0), roundi(point.z * 1000.0)]


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
	copy.set_shader_parameter("anim_t", PHASE_SECONDS if capture_mode else animation_time)
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
	elif view == "region":
		target = REGION_TARGET
		polar = 0.70
		azimuth = 0.10
		distance = 100.0
		camera_size = 16.0
		update_camera()
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
		var view_label := "全图" if current_view == "full" else ("日本区域" if current_view == "region" else "平城京近景")
		status_label.text = "日本区域样板  |  %s  |  %s  |  商道%s  |  %s" % ["原图 before" if before else "新样板 after", view_label, "显示" if routes_visible else "隐藏", "柔和评审光" if soft_light else "原始光照"]


func _input(event: InputEvent) -> void:
	# GUI buttons can consume mouse-up before _unhandled_input sees it.
	if event is InputEventMouseButton and not event.pressed and event.button_index == drag_button:
		drag_button = 0


func _unhandled_input(event: InputEvent) -> void:
	if not prepared or capture_mode or failed: return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE: get_tree().quit()
		elif event.keycode == KEY_1: set_view("close")
		elif event.keycode == KEY_2 or event.keycode == KEY_HOME: set_view("region")
		elif event.keycode == KEY_3: set_view("full")
		elif event.keycode == KEY_B: toggle_comparison()
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


func capture_views() -> void:
	if DirAccess.make_dir_recursive_absolute(capture_dir) != OK:
		fail("Cannot create capture directory: " + capture_dir)
		return
	var files: Array[String] = []
	for view: String in ["close", "region", "full"]:
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
			"schema": "silkroad.japan-region-review.v1",
			"variant": variant_name(), "view": view, "source": source_evidence,
			"image": image_path, "size": [IMAGE_SIZE.x, IMAGE_SIZE.y],
			"renderer": RenderingServer.get_current_rendering_method(),
			"phase_seconds": PHASE_SECONDS, "routes_visible": routes_visible,
			"camera": {"transform": transform_json(camera.transform), "size": camera.size, "target": [target.x, target.y, target.z], "projection": camera.projection},
			"terrain": tile_evidence, "natural_scatter": scatter_evidence,
			"tree_retention": tree_mask_evidence,
			"allowed_tile_ids": ALLOWED_TILE_IDS, "loaded_tile_ids": replacement_ids,
			"protected_unchanged": protected_before == protected_after,
			"protected_state": protected_after,
			"lighting": {"original_sun_preserved": true, "isolated_environment_copy": soft_light, "ambient_energy": 0.12 if soft_light else 0.0, "ambient_color": [0.72, 0.80, 0.88] if soft_light else [], "ssao_radius": 0.35 if soft_light else 0.0, "ssao_intensity": 0.25 if soft_light else 0.0, "ssao_power": 1.0 if soft_light else 0.0},
			"material_policy": "Original shader of each tile on imported vertex colors; runtime copies only for common animation phase",
			"notes": ["Only explicitly present T62/T63 exports replace terrain in memory; no source scene, city, route, coast, global shader or project setting is saved.", "Only natural trees inside coast rings 13/17/18 use the stable XZ retention mask. Remaining instances preserve XZ, basis, colors and custom data; only terrain-relative Y is conformed.", "City-contained vegetation is untouched. Natural trees outside the three Japan rings and all rocks/grass retain counts.", "Cities, baked routes/nodes and other terrain branches stay original. Capture images exclude the interactive helper UI."]
		}
		var file := FileAccess.open(image_path.get_basename() + ".json", FileAccess.WRITE)
		if file == null:
			fail("Cannot save capture evidence JSON")
			return
		file.store_string(JSON.stringify(report, "\t", false, true) + "\n")
		file.close()
		files.append(image_path)
		print("JAPAN_REGION_CAPTURE ", image_path)
	if watchdog != null: watchdog.stop()
	draw_timer.stop()
	print("JAPAN_REGION_COMPLETE ", JSON.stringify({"variant": variant_name(), "images": files, "protected_unchanged": true}))
	get_tree().quit(0)


func protected_state() -> Dictionary:
	var result: Dictionary = {}
	for branch: String in ["Cities", "FormalRoutes", "FormalNodes", "Coast"]:
		var rows: Array[Dictionary] = []
		collect_state(world.get_node(branch), rows)
		result[branch] = rows
	var other_terrain: Array[Dictionary] = []
	for tile: Node in world.get_node("Terrain64").get_children():
		if int(String(tile.name).substr(1, 2)) not in replacement_ids: collect_state(tile, other_terrain)
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


func boundary_segments(nodes: Array[MeshInstance3D]) -> Array:
	# Weld split-normal/color vertices by world position before counting triangle
	# edges, so ordinary flat-shaded GLBs do not look like disconnected triangles.
	var edges: Dictionary = {}
	for mesh_node: MeshInstance3D in nodes:
		for surface in mesh_node.mesh.get_surface_count():
			var arrays := mesh_node.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			var count := indices.size() if not indices.is_empty() else vertices.size()
			for offset in range(0, count - 2, 3):
				var triangle: Array[Vector3] = []
				for corner in 3:
					triangle.append(mesh_node.global_transform * vertices[indices[offset + corner] if not indices.is_empty() else offset + corner])
				for corner in 3:
					var a := triangle[corner]
					var b := triangle[(corner + 1) % 3]
					var a_key := position_key(a)
					var b_key := position_key(b)
					if a_key == b_key: continue
					var key := a_key + "|" + b_key if a_key < b_key else b_key + "|" + a_key
					if edges.has(key):
						edges[key]["count"] += 1
					else:
						edges[key] = {"count": 1, "a": a, "b": b}
	var result: Array = []
	for edge: Dictionary in edges.values():
		if int(edge.count) == 1: result.append([edge.a, edge.b])
	return result


func position_key(point: Vector3) -> String:
	return "%d,%d,%d" % [roundi(point.x * 10000.0), roundi(point.y * 10000.0), roundi(point.z * 10000.0)]


func boundary_distance(from_segments: Array, to_segments: Array) -> float:
	var maximum := 0.0
	for segment: Array in from_segments:
		for point: Vector3 in segment:
			var nearest := INF
			for other: Array in to_segments:
				var a: Vector3 = other[0]
				var b: Vector3 = other[1]
				var direction := b - a
				if direction.length_squared() < 0.00000001: continue
				var ratio := clampf((point - a).dot(direction) / direction.length_squared(), 0.0, 1.0)
				nearest = minf(nearest, point.distance_to(a + direction * ratio))
			maximum = maxf(maximum, nearest)
	return maximum


func boundary_length(segments: Array) -> float:
	var result := 0.0
	for segment: Array in segments:
		var a: Vector3 = segment[0]
		var b: Vector3 = segment[1]
		result += a.distance_to(b)
	return result


func compare_boundaries(originals: Array[MeshInstance3D], replacements: Array[MeshInstance3D]) -> Dictionary:
	var old_segments := boundary_segments(originals)
	var new_segments := boundary_segments(replacements)
	if old_segments.is_empty() or new_segments.is_empty():
		return {"passed": false, "reason": "expected open terrain-top boundary segments"}
	var error := maxf(boundary_distance(old_segments, new_segments), boundary_distance(new_segments, old_segments))
	var length_error := absf(boundary_length(old_segments) - boundary_length(new_segments))
	return {"passed": error <= 0.003 and length_error <= 0.03, "max_xyz_distance": error, "length_error": length_error, "original_segments": old_segments.size(), "replacement_segments": new_segments.size(), "position_weld_precision": 0.0001, "scope": "all tile outer boundary components, including island and mainland fragments"}


func tile_path(tile_id: int) -> String:
	return terrain_dir.path_join("%02d.glb" % tile_id)


func region_height_index() -> Dictionary:
	var result: Dictionary = {}
	for tile_id: int in replacement_ids:
		var index := height_index(terrain_tiles[tile_id])
		for key: Vector2i in index:
			if not result.has(key): result[key] = []
			result[key].append_array(index[key])
	return result


func apply_soft_environment() -> void:
	var environment_node := world.get_node("WorldEnvironment") as WorldEnvironment
	var environment := environment_node.environment.duplicate() as Environment
	environment_node.environment = environment
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.72, 0.80, 0.88)
	environment.ambient_light_energy = 0.12
	environment.ambient_light_sky_contribution = 0.0
	environment.ssao_enabled = true
	environment.ssao_radius = 0.35
	environment.ssao_intensity = 0.25
	environment.ssao_power = 1.0


func toggle_comparison() -> void:
	if not prepared or capture_mode or failed: return
	get_tree().set_meta(RELOAD_STATE_KEY, {
		"before": not before, "routes_visible": routes_visible,
		"animation_time": animation_time, "view": current_view,
		"target": target, "polar": polar, "azimuth": azimuth,
		"distance": distance, "camera_size": camera_size,
		"camera_transform": camera.transform
	})
	var error := get_tree().reload_current_scene()
	if error != OK: fail("Cannot reload independent review scene: " + error_string(error))


func restore_camera_state() -> void:
	if capture_mode or restored_state.is_empty(): return
	current_view = String(restored_state.get("view", initial_view))
	target = restored_state.get("target", target)
	polar = float(restored_state.get("polar", polar))
	azimuth = float(restored_state.get("azimuth", azimuth))
	distance = float(restored_state.get("distance", distance))
	camera_size = float(restored_state.get("camera_size", camera_size))
	camera.transform = restored_state.get("camera_transform", camera.transform)
	camera.size = camera_size
	update_status()


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
	push_error("JAPAN_REGION_FAILED: " + message)
	if status_label != null: status_label.text = "小样加载失败：" + message
	get_tree().quit(1)
