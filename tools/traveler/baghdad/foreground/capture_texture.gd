extends SceneTree
## Same-process stone-texture A/B without requesting foreground focus.
const DEFAULT_OUTPUT := "res://docs/reports/traveler-baghdad-001/foreground-texture-20260922/cinematic"

func _initialize() -> void:
	call_deferred("run_capture")

func run_capture() -> void:
	var output := DEFAULT_OUTPUT
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--fg-output-dir="):
			output = argument.trim_prefix("--fg-output-dir=")
	if DirAccess.make_dir_recursive_absolute(output) != OK:
		push_error("Unable to create foreground texture capture directory: " + output)
		quit(1)
		return
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1920, 1080)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.msaa_3d = Viewport.MSAA_4X
	root.add_child(viewport)
	var force_offscreen := OS.get_cmdline_user_args().has("--fg-force-draw")
	if force_offscreen:
		# Optional visual QA mode keeps an occluded macOS window drawing.
		var draw_timer := Timer.new()
		draw_timer.wait_time = 1.0 / 30.0
		draw_timer.timeout.connect(func() -> void: RenderingServer.force_draw(false))
		root.add_child(draw_timer)
		draw_timer.start()
	var preview := TextureRect.new()
	preview.texture = viewport.get_texture()
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	root.add_child(preview)
	preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var viewer: Node3D = load("res://tools/traveler/baghdad/foreground/viewer_snapshot.gd").new()
	viewport.add_child(viewer)
	var deadline := Time.get_ticks_msec() + 60000
	while not bool(viewer.get("ready_for_capture")):
		if Time.get_ticks_msec() > deadline:
			push_error("Texture capture timed out waiting for scene")
			quit(1)
			return
		await process_frame
	var detail := viewer.world.get_node_or_null("BaghdadForegroundDetails") as Node3D
	if detail == null or detail.get_child_count() == 0 or not detail.has_meta("evidence"):
		push_error("Foreground layer did not load; refusing an empty texture capture")
		quit(1)
		return
	var targets: Array[Dictionary] = []
	for item in detail.find_children("*", "MeshInstance3D", true, false):
		var mesh := item as MeshInstance3D
		if not (str(mesh.name).begins_with("StonePaving") or str(mesh.name).begins_with("FineGravel")):
			continue
		for surface_index in mesh.mesh.get_surface_count():
			var material := mesh.get_active_material(surface_index) as StandardMaterial3D
			if material == null:
				continue
			if material.albedo_texture == null and material.normal_texture == null and material.roughness_texture == null:
				continue
			targets.append({"mesh": str(mesh.name), "surface": surface_index, "material": material,
				"albedo_texture": material.albedo_texture, "normal_texture": material.normal_texture,
				"roughness_texture": material.roughness_texture, "normal_enabled": material.normal_enabled,
				"roughness": material.roughness})
	if targets.is_empty():
		push_error("No textured stone surfaces loaded; refusing an unchanged texture capture")
		quit(1)
		return
	_set_textures_enabled(targets, false)
	await viewer.capture(output.path_join("before.png"))
	_set_textures_enabled(targets, true)
	await viewer.capture(output.path_join("after.png"))
	var original_camera_transform: Transform3D = viewer.camera.transform
	var original_camera_fov: float = viewer.camera.fov
	var original_composition: Dictionary = viewer.composition_evidence()
	# Additional low-angle crop resolves the surface grain at game scale.
	viewer.camera.position = viewer.stage_point(Vector3(0.10, 0.48, 0.84))
	viewer.camera.look_at(viewer.stage_point(Vector3(0.0, 0.01, 2.05)))
	viewer.camera.fov = 52.0
	_set_textures_enabled(targets, false)
	await viewer.capture(output.path_join("detail-before.png"))
	_set_textures_enabled(targets, true)
	await viewer.capture(output.path_join("detail-after.png"))
	if OS.get_cmdline_user_args().has("--fg-debug-materials"):
		for target in targets:
			(target.material as StandardMaterial3D).normal_enabled = false
		await viewer.capture(output.path_join("detail-albedo-only.png"))
		_set_textures_enabled(targets, true)
		for target in targets:
			(target.material as StandardMaterial3D).albedo_texture = null
		await viewer.capture(output.path_join("detail-normal-only.png"))
		_set_textures_enabled(targets, true)
	viewer.camera.transform = original_camera_transform
	viewer.camera.fov = original_camera_fov
	var materials: Array[Dictionary] = []
	for target in targets:
		var material: StandardMaterial3D = target.material
		materials.append({"mesh": target.mesh, "surface": target.surface,
			"albedo_texture_size": _texture_size(material.albedo_texture),
			"normal_texture_size": _texture_size(material.normal_texture),
			"roughness_texture_size": _texture_size(material.roughness_texture),
			"normal_enabled": material.normal_enabled, "normal_scale": material.normal_scale,
			"before_roughness": 0.94, "after_roughness": material.roughness,
			"vertex_color_use_as_albedo": material.vertex_color_use_as_albedo})
	var receipt: Dictionary = detail.get_meta("evidence").duplicate(true)
	receipt["composition"] = original_composition
	receipt["same_process"] = true
	receipt["only_stone_texture_inputs_toggled"] = true
	receipt["toggle_fields"] = ["albedo_texture", "normal_texture", "roughness_texture", "normal_enabled", "roughness"]
	receipt["vertex_colours_preserved"] = true
	receipt["grass_cracks_and_geometry_unchanged"] = true
	receipt["forced_draw_visual_only"] = force_offscreen
	receipt["texture_materials"] = materials
	var handle := FileAccess.open(output.path_join("texture-evidence.json"), FileAccess.WRITE)
	if handle == null:
		push_error("Unable to write foreground texture evidence: " + output)
		quit(1)
		return
	handle.store_string(JSON.stringify(receipt, "\t"))
	handle.close()
	print("BAGHDAD_FOREGROUND_TEXTURE_CAPTURE_COMPLETE ", output)
	quit(0)

func _set_textures_enabled(targets: Array[Dictionary], enabled: bool) -> void:
	for target in targets:
		var material: StandardMaterial3D = target.material
		material.albedo_texture = target.albedo_texture if enabled else null
		material.normal_texture = target.normal_texture if enabled else null
		material.roughness_texture = target.roughness_texture if enabled else null
		material.normal_enabled = bool(target.normal_enabled) if enabled else false
		material.roughness = float(target.roughness) if enabled else 0.94

func _texture_size(texture: Texture2D) -> Array:
	return [texture.get_width(), texture.get_height()] if texture != null else []
