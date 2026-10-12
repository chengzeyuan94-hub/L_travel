extends SceneTree
## Standalone GLB studio. Run in a separate scratch project, not the game scene.
## SILKROAD_LIBRARY_ROOT, SILKROAD_LIBRARY_OUTPUT; optional SILKROAD_LIBRARY_IDS.

var library: String
var output: String
var stage: Node3D
var camera: Camera3D
var preview_subdir := "previews"
var export_dir: String
var report := {"task": "TASK-CITY-LIBRARY-019", "assets": [], "errors": []}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	library = OS.get_environment("SILKROAD_LIBRARY_ROOT")
	output = OS.get_environment("SILKROAD_LIBRARY_OUTPUT")
	if library.is_empty() or output.is_empty() or DisplayServer.get_name() == "headless":
		push_error("Library capture needs explicit paths and a rendered window")
		quit(1)
		return
	export_dir = OS.get_environment("SILKROAD_LIBRARY_EXPORTS")
	if export_dir.is_empty():
		export_dir = library.path_join("exports")
	if not OS.get_environment("SILKROAD_LIBRARY_PREVIEW_SUBDIR").is_empty():
		preview_subdir = OS.get_environment("SILKROAD_LIBRARY_PREVIEW_SUBDIR")
	root.size = Vector2i(768, 768)
	root.title = "SilkRoad · City asset studio"
	root.msaa_3d = Viewport.MSAA_4X
	root.use_taa = RenderingServer.get_current_rendering_method() == "forward_plus"
	Engine.max_fps = 60
	DirAccess.make_dir_recursive_absolute(output)
	DirAccess.make_dir_recursive_absolute(library.path_join(preview_subdir))
	stage = Node3D.new()
	root.add_child(stage)
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("e1ddd4")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("c4d1d9")
	env.ambient_light_energy = 0.18
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	if RenderingServer.get_current_rendering_method() == "forward_plus":
		env.ambient_light_energy = 0.42
		env.ssao_enabled = true
		env.ssao_radius = 0.3
		env.ssao_intensity = 1.0
	env_node.environment = env
	stage.add_child(env_node)
	var light := DirectionalLight3D.new()
	light.light_color = Color("fff4dd")
	light.light_energy = 0.5
	if RenderingServer.get_current_rendering_method() == "forward_plus":
		light.light_energy = 1.1
	light.shadow_enabled = true
	light.light_angular_distance = 4.0
	light.shadow_opacity = 0.7
	light.directional_shadow_max_distance = 50
	light.shadow_bias = 0.04
	light.shadow_normal_bias = 1.0
	stage.add_child(light)
	light.position = Vector3(-4, 7, 5)
	light.look_at(Vector3.ZERO)
	var fill := DirectionalLight3D.new()
	fill.light_color = Color("c7dcec")
	fill.light_energy = 0.12
	if RenderingServer.get_current_rendering_method() == "forward_plus":
		fill.light_energy = 0.28
	stage.add_child(fill)
	fill.position = Vector3(4, 3, -3)
	fill.look_at(Vector3.ZERO)
	var floor_node := MeshInstance3D.new()
	floor_node.name = "StudioOnlyFloor"
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(200, 200)
	floor_node.mesh = floor_mesh
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color("e1ddd4")
	floor_mat.roughness = 1.0
	floor_node.material_override = floor_mat
	floor_node.position.y = -0.025
	stage.add_child(floor_node)
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.near = 0.01
	camera.far = 200
	stage.add_child(camera)
	camera.current = true
	report["godot"] = Engine.get_version_info()
	report["renderer"] = RenderingServer.get_current_rendering_method()
	report["device"] = RenderingServer.get_video_adapter_name()
	report["note"] = "Actual exported GLBs, uniform studio lighting; not a game performance test. Fixed camera target, direction and orthographic size for all cities, before and after; studio presentation is separate from unchanged game-view comparisons."
	report["capture_script_sha256"] = FileAccess.get_sha256(get_script().resource_path)
	var allowed := OS.get_environment("SILKROAD_LIBRARY_IDS").split(",", false)
	var names := DirAccess.get_files_at(export_dir)
	names.sort()
	for filename in names:
		if not filename.ends_with(".glb") or filename.contains("-"):
			continue
		var id := filename.get_basename()
		if not allowed.is_empty() and not id in allowed:
			continue
		await _asset(id, export_dir.path_join(filename))
	report["asset_count"] = report["assets"].size()
	var file := FileAccess.open(output.path_join("godot-capture-report.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("CITY_019_CAPTURE_COMPLETE assets=", report["asset_count"], " errors=", report["errors"].size())
	quit(0 if report["errors"].is_empty() else 1)

func _asset(id: String, path: String) -> void:
	var before := FileAccess.get_sha256(path)
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var error := doc.append_from_file(path, state, 64)
	if error != OK:
		report["errors"].append({"id": id, "error": error})
		return
	var instance := doc.generate_scene(state)
	if instance == null:
		report["errors"].append({"id": id, "error": "generate_scene returned null"})
		return
	stage.add_child(instance)
	var corners: Array[Vector3] = []
	var mesh_count := 0
	var surfaces := 0
	var vertex_color_surfaces := 0
	var queue: Array[Node] = [instance]
	while not queue.is_empty():
		var node: Node = queue.pop_back()
		for child in node.get_children():
			queue.append(child)
		if node is MeshInstance3D:
			mesh_count += 1
			surfaces += node.mesh.get_surface_count()
			# Runtime GLTFDocument currently leaves this disabled. Honor COLOR_0,
			# as the existing game loader does; do not recolor the exported asset.
			for surface in range(node.mesh.get_surface_count()):
				var material: Material = node.mesh.surface_get_material(surface)
				var colors = node.mesh.surface_get_arrays(surface)[Mesh.ARRAY_COLOR]
				if material is StandardMaterial3D and colors != null and colors.size() > 0:
					material.vertex_color_use_as_albedo = true
					material.vertex_color_is_srgb = false
					vertex_color_surfaces += 1
			var bounds: AABB = node.get_aabb()
			for i in range(8):
				corners.append(node.global_transform * bounds.get_endpoint(i))
	if corners.is_empty():
		report["errors"].append({"id": id, "error": "No meshes"})
		instance.queue_free()
		await process_frame
		return
	var bounds := AABB(corners[0], Vector3.ZERO)
	for point in corners:
		bounds = bounds.expand(point)
	var target := Vector3(0, 0.55, 0)
	var captures := []
	var directions := {"three-quarter": Vector3(4, 3.4, 6), "side": Vector3(7, 1.2, 0), "top": Vector3(0, 8, 0.001)}
	for view in directions:
		camera.position = target + directions[view].normalized() * maxf(10.0, bounds.size.length() * 3)
		camera.look_at(target, Vector3.UP)
		var inverse := camera.global_transform.affine_inverse()
		var max_x := 0.0
		var max_y := 0.0
		for point in corners:
			var p := inverse * point
			max_x = maxf(max_x, absf(p.x))
			max_y = maxf(max_y, absf(p.y))
		camera.size = 2.95 # Fixed for every city and both revisions.
		for i in range(24):
			await process_frame
		await RenderingServer.frame_post_draw
		var picture := root.get_texture().get_image()
		var basename: String = id + "-" + view
		var raw_path := output.path_join(basename + ".png")
		var preview_path := library.path_join(preview_subdir).path_join(basename + ".jpg")
		var raw_error := picture.save_png(raw_path)
		var preview_error := picture.save_jpg(preview_path, 0.94)
		if raw_error != OK or preview_error != OK:
			report["errors"].append({"id": id, "view": view, "error": "image save"})
		captures.append({"view": view, "raw": raw_path, "preview": preview_path,
			"sha256": FileAccess.get_sha256(preview_path), "camera_position": [camera.position.x,camera.position.y,camera.position.z], "camera_size": camera.size})
	var after := FileAccess.get_sha256(path)
	if before != after:
		report["errors"].append({"id": id, "error": "GLB changed while rendering"})
	report["assets"].append({"id": id, "glb": path, "sha256": before, "inputs_stable": before == after,
		"mesh_count": mesh_count, "surfaces": surfaces, "vertex_color_surfaces": vertex_color_surfaces, "bounds_min": [bounds.position.x,bounds.position.y,bounds.position.z],
		"bounds_size": [bounds.size.x,bounds.size.y,bounds.size.z], "captures": captures})
	print("LIBRARY_ASSET_CAPTURED ", id)
	instance.queue_free()
	await process_frame
