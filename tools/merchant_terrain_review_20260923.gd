extends SceneTree
## Isolated Atlas terrain review. No project scene, GLB or shared Resource is saved.
## Godot --path <repo> --script res://tools/merchant_terrain_review_20260923.gd --
##   --variant=after --terrain-dir=/absolute/tiles --capture=/absolute/after.png
## Add --routes to show the EXISTING route/node meshes in both comparison captures.
## The default and only modification scope is T62, within 8 units of Heijokyo.
## --live keeps this independent preview running after its deterministic capture.
## --original-light is an optional BEFORE baseline without the local review lights.

const SOURCE_SCENE := "res://generated/traveler/atlas/atlas_world.tscn"
const SIZE := Vector2i(1920, 1080)
const PHASE_SECONDS := 7.25
const HEIGHT_CELL := 3.0
const WARMUP_FRAMES := 75
const SAMPLE_RADIUS := 8.0
const SAMPLE_TILE := 62

var variant := "before"
var terrain_dir := ""
var capture_path := ""
var view_name := "heijokyo-sample"
var show_routes := false
var live := false
var original_light := false
var live_ready := false
var live_seconds := PHASE_SECONDS
var sample_center := Vector3(53.82, 0.746, 5.724)
var viewport: SubViewport
var world: Node3D
var camera: Camera3D
var completed := false
var shader_copies: Dictionary = {}
var original_heights: Dictionary = {}
var revised_heights: Dictionary = {}
var tile_records: Array[Dictionary] = []
var scatter_records: Array[Dictionary] = []
var protected_before: Dictionary = {}
var sample_terrain: Node
var outside_scatter_unchanged := true
var city_clearance: Array[AABB] = []
var route_clearance: Dictionary = {}
var animated_materials: Array[ShaderMaterial] = []


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--variant="): variant = arg.trim_prefix("--variant=")
		elif arg.begins_with("--terrain-dir="): terrain_dir = arg.trim_prefix("--terrain-dir=")
		elif arg.begins_with("--capture="): capture_path = arg.trim_prefix("--capture=")
		elif arg.begins_with("--view="): view_name = arg.trim_prefix("--view=")
		elif arg == "--routes": show_routes = true
		elif arg == "--live": live = true
		elif arg == "--original-light": original_light = true
	if variant not in ["before", "after"] or view_name not in ["world", "east", "heijokyo-sample"]:
		fail("Expected --variant=before/after and --view=world/east/heijokyo-sample")
		return
	if original_light and variant != "before":
		fail("--original-light is only for the before baseline")
		return
	if not capture_path.is_absolute_path() or not capture_path.ends_with(".png"):
		fail("--capture must be an absolute .png path")
		return
	if variant == "after" and not terrain_dir.is_absolute_path():
		fail("after requires an absolute --terrain-dir; only optional 62.glb is used")
		return
	if DisplayServer.get_name() == "headless":
		fail("Image evidence requires a real rendering driver; headless is parse-check only")
		return
	if DirAccess.make_dir_recursive_absolute(capture_path.get_base_dir()) != OK:
		fail("Cannot create capture directory")
		return
	root.title = "商旅 · 独立地形评审 · " + variant + " / " + view_name
	root.size = Vector2i(1440, 810)
	Engine.max_fps = 30
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	viewport = SubViewport.new()
	viewport.name = "MerchantTerrainReviewViewport"
	viewport.size = SIZE
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.msaa_3d = Viewport.MSAA_4X
	viewport.use_taa = false
	root.add_child(viewport)
	var preview := TextureRect.new()
	preview.texture = viewport.get_texture()
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	root.add_child(preview)
	preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Keep unattended rendering active without bringing this window to the front.
	var draw_timer := Timer.new()
	draw_timer.wait_time = 1.0 / 30.0
	draw_timer.timeout.connect(func(): RenderingServer.force_draw(false, 1.0 / 30.0))
	root.add_child(draw_timer)
	draw_timer.start()
	var watchdog := Timer.new()
	watchdog.one_shot = true
	watchdog.wait_time = 180.0
	watchdog.timeout.connect(func(): fail("Capture watchdog timeout"))
	root.add_child(watchdog)
	watchdog.start()
	var packed := load(SOURCE_SCENE) as PackedScene
	if packed == null:
		fail("Missing saved Atlas scene: " + SOURCE_SCENE)
		return
	world = packed.instantiate() as Node3D
	viewport.add_child(world)
	camera = world.get_node_or_null("AtlasCamera") as Camera3D
	if camera == null or world.get_node_or_null("Terrain64") == null:
		fail("Saved Atlas structure changed: missing AtlasCamera or Terrain64")
		return
	sample_center = (world.get_node("Cities/heijokyo") as Node3D).global_position
	for tile: Node in world.get_node("Terrain64").get_children():
		if String(tile.name).begins_with("T62_"): sample_terrain = tile
	if sample_terrain == null:
		fail("Missing T62 sample terrain")
		return
	if view_name == "heijokyo-sample":
		# size is the full vertical extent: 5.4 units either side of this target.
		var target := Vector3(55.1, 0.9, 3.3)
		var polar := 0.68
		var azimuth := 0.10
		camera.size = 10.8
		camera.position = target + Vector3(sin(polar) * sin(azimuth), cos(polar), sin(polar) * cos(azimuth)) * 100.0
		camera.look_at(target)
	if view_name == "east":
		# Existing atlas_viewer.gd east preset, identical for before and after.
		var target := Vector3(37, 1, 9)
		var polar := 0.86
		var azimuth := 0.32
		camera.size = 44.0
		camera.position = target + Vector3(sin(polar) * sin(azimuth), cos(polar), sin(polar) * cos(azimuth)) * 230.0
		camera.look_at(target)
	camera.make_current()
	if show_routes:
		world.get_node("FormalRoutes").visible = true
		world.get_node("FormalNodes").visible = true
	protected_before = protected_state()
	original_heights = height_index(sample_terrain)
	if variant == "after":
		if not replace_terrain(): return
		revised_heights = height_index(sample_terrain)
		build_clearance()
		sparsify_natural_scatter()
	else:
		for group_name: String in ["VegetationHigh", "VegetationLow", "NaturalDetails"]:
			for node: Node in world.get_node(group_name).get_children():
				if node is MultiMeshInstance3D:
					scatter_records.append({"group": group_name, "name": node.name, "before": node.multimesh.instance_count, "after": node.multimesh.instance_count, "height_adjusted": 0})
	if not original_light: apply_review_lighting()
	freeze_shader_phase(world)
	var protected_after := protected_state()
	if protected_before != protected_after:
		fail("Protected city / route / node / camera geometry or transforms changed")
		return
	print("MERCHANT_TERRAIN_REVIEW_READY ", JSON.stringify({"variant": variant, "view": view_name, "tiles": tile_records.size(), "phase": PHASE_SECONDS}))
	for frame in WARMUP_FRAMES:
		await process_frame
	await RenderingServer.frame_post_draw
	var output_image := viewport.get_texture().get_image()
	if output_image == null or output_image.get_size() != SIZE:
		fail("Viewport did not produce a 1920x1080 image")
		return
	var save_error := output_image.save_png(capture_path)
	var evidence := {
		"schema": "silkroad.merchant-terrain-review.v1",
		"variant": variant, "view": view_name, "source_scene": SOURCE_SCENE,
		"scope": {"city": "heijokyo", "center": [sample_center.x, sample_center.y, sample_center.z], "radius": SAMPLE_RADIUS, "allowed_tile_ids": [SAMPLE_TILE]},
		"source_scene_sha256": FileAccess.get_sha256(SOURCE_SCENE),
		"cities_json_sha256": FileAccess.get_sha256("res://data/traveler/atlas/cities.json"),
		"formal_routes_json_sha256": FileAccess.get_sha256("res://data/traveler/formal-routes.json"),
		"image_size": [SIZE.x, SIZE.y], "viewport_size": [viewport.size.x, viewport.size.y],
		"renderer": RenderingServer.get_current_rendering_method(),
		"capture_path": capture_path, "capture_error": save_error,
		"fixed_shader_time_seconds": PHASE_SECONDS, "warmup_frames": WARMUP_FRAMES,
		"water_shader_preserved": true, "water_animation_frozen_for_still_only": true,
		"terrain_dir": terrain_dir, "terrain_tiles": tile_records, "scatter": scatter_records,
		"protected_state_unchanged": protected_before == protected_after,
		"protected_state": protected_after, "routes_visible": show_routes,
		"outside_sample_scatter_unchanged": outside_scatter_unchanged,
		"lighting": {"scope": "original" if original_light else "same local Heijokyo review lights for both variants", "original_sun_environment_unchanged": true, "local_warm_color": "fff0d7", "local_cool_color": "a7c5e4"},
		"live_after_capture": live,
		"limitations": ["Only optional T62 is replaced; all other terrain branches stay original. Default camera shows Heijokyo and nearby coast.", "City and baked route/node geometry, transforms and authored color parameters are preserved. Route heights are not conformed to terrain.", "Only natural scatter inside the 8-unit circle can be removed or vertically adjusted. Position sampling keeps trunk/canopy and LOD counterparts matched.", "Both normal captures use the same local review lights; --original-light explicitly requests an original-light before baseline.", "Shader materials are runtime copies solely to fix animation time. Live mode resumes those clocks after the still capture."]
	}
	var evidence_file := FileAccess.open(capture_path.get_basename() + ".json", FileAccess.WRITE)
	if evidence_file == null:
		fail("Cannot write evidence JSON")
		return
	evidence_file.store_string(JSON.stringify(evidence, "\t", false, true) + "\n")
	evidence_file.close()
	completed = true
	watchdog.stop()
	print("MERCHANT_TERRAIN_REVIEW_COMPLETE ", JSON.stringify({"image": capture_path, "capture_error": save_error, "protected_state_unchanged": true}))
	if live and save_error == OK:
		live_ready = true
		root.title += " · 实机小样"
		return
	draw_timer.stop()
	quit(0 if save_error == OK else 1)


func _process(delta: float) -> bool:
	if live_ready:
		live_seconds += delta
		for material: ShaderMaterial in animated_materials:
			material.set_shader_parameter("anim_t", live_seconds)
	return false


func replace_terrain() -> bool:
	var terrain_root: Node = world.get_node("Terrain64")
	if terrain_root.get_child_count() != 64:
		fail("Expected exactly 64 saved terrain regions")
		return false
	for tile: Node in terrain_root.get_children():
		var tile_id := int(String(tile.name).substr(1, 2))
		var file_path := terrain_dir.path_join("%02d.glb" % tile_id)
		if tile_id != SAMPLE_TILE or not FileAccess.file_exists(file_path):
			tile_records.append({"tile": tile.name, "replaced": false, "reason": "outside allowed sample tile" if tile_id != SAMPLE_TILE else "no replacement file; original retained"})
			continue
		var originals := mesh_nodes(tile)
		if originals.is_empty():
			fail("Saved tile has no mesh: " + String(tile.name))
			return false
		var source_material: Material = originals[0].get_active_material(0)
		var state := GLTFState.new()
		var document := GLTFDocument.new()
		var error := document.append_from_file(file_path, state)
		if error != OK:
			fail("GLTF load failed (%s): %s" % [error_string(error), file_path])
			return false
		var replacement := document.generate_scene(state) as Node3D
		if replacement == null:
			fail("GLTF generated no scene: " + file_path)
			return false
		replacement.name = "ReviewTerrain_%02d" % tile_id
		tile.add_child(replacement)
		var imported_meshes := mesh_nodes(replacement)
		if imported_meshes.is_empty():
			fail("Replacement terrain has no meshes: " + file_path)
			return false
		var before_bounds := combined_bounds(originals)
		var after_bounds := combined_bounds(imported_meshes)
		var xz_error := maxf(maxf(absf(before_bounds.position.x - after_bounds.position.x), absf(before_bounds.end.x - after_bounds.end.x)), maxf(absf(before_bounds.position.z - after_bounds.position.z), absf(before_bounds.end.z - after_bounds.end.z)))
		if xz_error > 0.01:
			fail("Replacement moved tile X/Z extents by %.5f: %s" % [xz_error, file_path])
			return false
		if not outside_terrain_matches(originals, imported_meshes):
			fail("T62 replacement changed vertex positions outside the Heijokyo sample radius")
			return false
		var vertices := 0
		var color_surfaces := 0
		for mesh_node: MeshInstance3D in imported_meshes:
			for surface in mesh_node.mesh.get_surface_count():
				var arrays := mesh_node.mesh.surface_get_arrays(surface)
				vertices += arrays[Mesh.ARRAY_VERTEX].size()
				if arrays[Mesh.ARRAY_COLOR] != null and arrays[Mesh.ARRAY_COLOR].size() > 0: color_surfaces += 1
				if source_material != null:
					mesh_node.set_surface_override_material(surface, source_material.duplicate() as Material)
				else:
					var material := StandardMaterial3D.new()
					material.vertex_color_use_as_albedo = true
					material.roughness = 0.95
					material.cull_mode = BaseMaterial3D.CULL_DISABLED
					mesh_node.set_surface_override_material(surface, material)
		for original: MeshInstance3D in originals: original.visible = false
		tile_records.append({"tile": tile.name, "replaced": true, "path": file_path, "sha256": FileAccess.get_sha256(file_path), "vertices": vertices, "color_surfaces": color_surfaces, "xz_extent_error": xz_error, "outside_sample_positions_unchanged": true, "before_bounds": bounds_json(before_bounds), "after_bounds": bounds_json(after_bounds)})
	return true


func in_sample(point: Vector3) -> bool:
	return Vector2(point.x - sample_center.x, point.z - sample_center.z).length_squared() <= SAMPLE_RADIUS * SAMPLE_RADIUS


func outside_position_keys(nodes: Array[MeshInstance3D]) -> Dictionary:
	var result: Dictionary = {}
	for mesh_node: MeshInstance3D in nodes:
		for surface in mesh_node.mesh.get_surface_count():
			var arrays := mesh_node.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			for vertex: Vector3 in vertices:
				var p := mesh_node.global_transform * vertex
				if in_sample(p): continue
				# Ignore split-normal duplicate multiplicity, preserve actual XYZ geometry.
				var key := Vector3i(roundi(p.x * 1000.0), roundi(p.y * 1000.0), roundi(p.z * 1000.0))
				result[key] = true
	return result


func outside_terrain_matches(before: Array[MeshInstance3D], after: Array[MeshInstance3D]) -> bool:
	var old_keys := outside_position_keys(before)
	var new_keys := outside_position_keys(after)
	return old_keys == new_keys


func mesh_nodes(node: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	if node is MeshInstance3D: result.append(node)
	for child: Node in node.get_children(): result.append_array(mesh_nodes(child))
	return result


func combined_bounds(nodes: Array[MeshInstance3D]) -> AABB:
	var result := AABB()
	var first := true
	for node: MeshInstance3D in nodes:
		var box: AABB = node.global_transform * node.get_aabb()
		result = box if first else result.merge(box)
		first = false
	return result


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


func sparsify_natural_scatter() -> void:
	for group_name: String in ["VegetationHigh", "VegetationLow", "NaturalDetails"]:
		for node: Node in world.get_node(group_name).get_children():
			if not node is MultiMeshInstance3D: continue
			var instance := node as MultiMeshInstance3D
			var original := instance.multimesh
			var local_indices: Dictionary = {}
			var candidates: Array[Dictionary] = []
			var fraction := 0.38
			if group_name == "NaturalDetails":
				fraction = 0.30 if String(node.name) == "Grass" else 0.23
			for index in original.instance_count:
				var p := instance.global_transform * original.get_instance_transform(index).origin
				# Radius alone could include Korea: require an actual T62 land triangle.
				if not in_sample(p) or not is_finite(ground_height(original_heights, p)): continue
				local_indices[index] = true
				if blocked_by_clearance(p): continue
				# Two small groves with a clear grassy saddle between them.
				var grove_distance := minf(Vector2(p.x, p.z).distance_to(Vector2(55.8, 3.9)), Vector2(p.x, p.z).distance_to(Vector2(58.1, 1.1)))
				# Position-only score keeps all trunk/canopy and LOD counterparts matched.
				var key := "%d:%d" % [roundi(p.x * 1000.0), roundi(p.z * 1000.0)]
				var sample := float(key.hash() & 0x7fffffff) / 2147483647.0
				candidates.append({"index": index, "score": grove_distance + sample * 0.18})
			if local_indices.is_empty():
				scatter_records.append({"group": group_name, "name": node.name, "before": original.instance_count, "after": original.instance_count, "local_before": 0, "local_after": 0, "height_adjusted": 0, "runtime_multimesh_preserved": true})
				continue
			candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.score) < float(b.score))
			var local_kept: Dictionary = {}
			var desired := mini(roundi(local_indices.size() * fraction), candidates.size())
			for index in desired: local_kept[int(candidates[index].index)] = true
			var kept: Array[int] = []
			for index in original.instance_count:
				if not local_indices.has(index) or local_kept.has(index): kept.append(index)
			var replacement := MultiMesh.new()
			replacement.transform_format = original.transform_format
			replacement.use_colors = original.use_colors
			replacement.use_custom_data = original.use_custom_data
			replacement.mesh = original.mesh
			replacement.instance_count = kept.size()
			var adjusted := 0
			var bounds := AABB()
			for new_index in kept.size():
				var old_index := kept[new_index]
				var transform := original.get_instance_transform(old_index)
				var p := instance.global_transform * transform.origin
				if local_indices.has(old_index):
					var old_y := ground_height(original_heights, p)
					var new_y := ground_height(revised_heights, p)
					if is_finite(old_y) and is_finite(new_y):
						p.y += new_y - old_y
						transform.origin = instance.global_transform.affine_inverse() * p
						if absf(new_y - old_y) > 0.0001: adjusted += 1
				elif transform != original.get_instance_transform(old_index):
					outside_scatter_unchanged = false
				replacement.set_instance_transform(new_index, transform)
				if original.use_colors: replacement.set_instance_color(new_index, original.get_instance_color(old_index))
				if original.use_custom_data: replacement.set_instance_custom_data(new_index, original.get_instance_custom_data(old_index))
				var box: AABB = transform * original.mesh.get_aabb()
				bounds = box if new_index == 0 else bounds.merge(box)
			instance.multimesh = replacement
			instance.custom_aabb = bounds.grow(0.4)
			if kept.is_empty(): instance.visible = false
			scatter_records.append({"group": group_name, "name": node.name, "before": original.instance_count, "after": kept.size(), "local_before": local_indices.size(), "local_after": local_kept.size(), "local_target_fraction": fraction, "height_adjusted": adjusted, "outside_instances_preserved": original.instance_count - local_indices.size()})


func build_clearance() -> void:
	for city: Node in world.get_node("Cities").get_children():
		var meshes := mesh_nodes(city)
		if meshes.is_empty(): continue
		city_clearance.append(combined_bounds(meshes).grow(0.20))
	for mesh_node: MeshInstance3D in mesh_nodes(world.get_node("FormalRoutes")):
		if String(mesh_node.name) not in ["land", "approach"]: continue
		for surface in mesh_node.mesh.get_surface_count():
			var arrays := mesh_node.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			for vertex: Vector3 in vertices:
				var p := mesh_node.global_transform * vertex
				if not in_sample(p): continue
				var key := Vector2i(floori(p.x / 0.6), floori(p.z / 0.6))
				if not route_clearance.has(key): route_clearance[key] = []
				route_clearance[key].append(Vector2(p.x, p.z))


func blocked_by_clearance(point: Vector3) -> bool:
	for box: AABB in city_clearance:
		if point.x >= box.position.x and point.x <= box.end.x and point.z >= box.position.z and point.z <= box.end.z: return true
	var key := Vector2i(floori(point.x / 0.6), floori(point.z / 0.6))
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			for p: Vector2 in route_clearance.get(key + Vector2i(dx, dz), []):
				if p.distance_squared_to(Vector2(point.x, point.z)) < 0.32 * 0.32: return true
	return false


func apply_review_lighting() -> void:
	# No global sun/environment edits. Both cones point down and end within ~8 XZ
	# units, so this small-sample preview cannot restyle the rest of the map.
	var warm := SpotLight3D.new()
	warm.name = "ReviewHeijokyoWarm"
	world.add_child(warm)
	warm.position = sample_center + Vector3(0, 10, 0)
	warm.look_at(sample_center, Vector3.FORWARD)
	warm.spot_range = 12.8
	warm.spot_angle = 38.0
	warm.spot_attenuation = 0.6
	warm.light_color = Color("fff0d7")
	warm.light_energy = 1.1
	warm.light_size = 2.0
	warm.shadow_enabled = true
	var cool := SpotLight3D.new()
	cool.name = "ReviewHeijokyoCool"
	world.add_child(cool)
	cool.position = sample_center + Vector3(0, 7, 0)
	cool.look_at(sample_center, Vector3.FORWARD)
	cool.spot_range = 10.5
	cool.spot_angle = 48.0
	cool.spot_attenuation = 0.8
	cool.light_color = Color("a7c5e4")
	cool.light_energy = 0.30
	cool.shadow_enabled = false


func frozen_material(source: Material) -> Material:
	if not source is ShaderMaterial: return source
	var key := source.get_instance_id()
	if shader_copies.has(key): return shader_copies[key]
	var result := source.duplicate() as ShaderMaterial
	var uniforms: Dictionary = {}
	for entry: Dictionary in result.shader.get_shader_uniform_list(): uniforms[String(entry.name)] = true
	if uniforms.has("anim_t"):
		result.set_shader_parameter("anim_t", PHASE_SECONDS)
		animated_materials.append(result)
	if uniforms.has("wind_gust"): result.set_shader_parameter("wind_gust", 1.0)
	shader_copies[key] = result
	return result


func freeze_shader_phase(node: Node) -> void:
	if node is MeshInstance3D:
		if node.material_override != null:
			node.material_override = frozen_material(node.material_override)
		else:
			for surface in node.mesh.get_surface_count():
				var material: Material = node.get_active_material(surface)
				if material is ShaderMaterial: node.set_surface_override_material(surface, frozen_material(material))
	elif node is MultiMeshInstance3D:
		if node.material_override != null:
			node.material_override = frozen_material(node.material_override)
		else:
			# Isolate both MultiMesh and its mesh before changing surface materials.
			var multimesh := node.multimesh.duplicate() as MultiMesh
			var mesh := multimesh.mesh.duplicate() as ArrayMesh
			for surface in mesh.get_surface_count():
				mesh.surface_set_material(surface, frozen_material(mesh.surface_get_material(surface)))
			multimesh.mesh = mesh
			node.multimesh = multimesh
	for child: Node in node.get_children(): freeze_shader_phase(child)


func protected_state() -> Dictionary:
	var result: Dictionary = {}
	for group_name: String in ["Cities", "FormalRoutes", "FormalNodes"]:
		var rows: Array[Dictionary] = []
		collect_protected(world.get_node(group_name), rows)
		result[group_name] = rows
	result["camera"] = {"transform": transform_json(camera.transform), "projection": camera.projection, "size": camera.size, "fov": camera.fov, "near": camera.near, "far": camera.far}
	return result


func collect_protected(node: Node, rows: Array[Dictionary]) -> void:
	var row := {"path": str(world.get_path_to(node)), "type": node.get_class()}
	if node is Node3D:
		row["transform"] = transform_json(node.transform)
		row["visible"] = node.visible
	if node is MeshInstance3D:
		row["mesh_path"] = node.mesh.resource_path
		row["mesh_instance_id"] = node.mesh.get_instance_id()
		row["surfaces"] = node.mesh.get_surface_count()
		row["bounds"] = bounds_json(node.get_aabb())
	rows.append(row)
	for child: Node in node.get_children(): collect_protected(child, rows)


func transform_json(value: Transform3D) -> Array:
	return [value.basis.x.x, value.basis.x.y, value.basis.x.z, value.basis.y.x, value.basis.y.y, value.basis.y.z, value.basis.z.x, value.basis.z.y, value.basis.z.z, value.origin.x, value.origin.y, value.origin.z]


func bounds_json(value: AABB) -> Array:
	return [value.position.x, value.position.y, value.position.z, value.size.x, value.size.y, value.size.z]


func fail(message: String) -> void:
	if completed: return
	completed = true
	push_error("MERCHANT_TERRAIN_REVIEW_FAILED: " + message)
	quit(1)
