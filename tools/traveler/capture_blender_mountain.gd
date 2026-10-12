extends SceneTree
## Asset review only; leaves the traveler's frozen perspective camera unchanged.
const OUT := "res://docs/design/shanhe-luren/mountain-rework/blender/"

func _initialize() -> void:
	call_deferred("capture")

func capture() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1920, 1080)
	viewport.own_world_3d = true
	viewport.msaa_3d = Viewport.MSAA_4X
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var world := Node3D.new()
	viewport.add_child(world)
	var model := load("res://assets/traveler/mountains/t7-snow-massif.glb") as PackedScene
	if model == null:
		push_error("Mountain GLB could not be imported")
		quit(1)
		return
	world.add_child(model.instantiate())
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.97, 0.965, 0.95)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.52, 0.65, 0.87)
	environment.ambient_light_energy = 0.25
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = environment
	world.add_child(we)
	var lights := Node3D.new()
	world.add_child(lights)
	for spec in [[Vector3(-24, 18, 8), 1.6, Color(1, 0.93, 0.82)], [Vector3(12, 16, 8), 0.4, Color(0.65, 0.75, 1)]]:
		var light := DirectionalLight3D.new()
		lights.add_child(light)
		light.position = spec[0]
		light.look_at(Vector3(0, 6, 0))
		light.light_energy = spec[1]
		light.light_color = spec[2]
		light.shadow_enabled = true
	var camera := Camera3D.new()
	viewport.add_child(camera)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 17.8
	camera.make_current()
	var views := ["front", "right", "back", "left"]
	for index in 4:
		var azimuth := float(index) * PI / 2.0
		camera.position = Vector3(40 * sin(azimuth), 14.5, 40 * cos(azimuth))
		camera.look_at(Vector3(0, 6.5, 0))
		lights.rotation.y = azimuth
		for frame in 24:
			await process_frame
		await RenderingServer.frame_post_draw
		var image := viewport.get_texture().get_image()
		var stem: String = OUT + "godot-" + views[index]
		var error := image.save_png(stem + ".png")
		var report := {"image_size": [image.get_width(), image.get_height()], "viewport_size": [viewport.size.x, viewport.size.y], "window_size": [DisplayServer.window_get_size().x, DisplayServer.window_get_size().y], "renderer": RenderingServer.get_current_rendering_method(), "view": views[index], "projection": "orthographic", "orthographic_size": camera.size, "camera_position": [camera.position.x, camera.position.y, camera.position.z], "camera_target": [0, 6.5, 0], "review_light_rig": "rotates with view for shape comparison", "key_energy": 1.6, "fill_energy": 0.4, "key_color": [1, 0.93, 0.82], "fill_color": [0.65, 0.75, 1], "ambient_energy": 0.25, "source_model": "assets/traveler/mountains/t7-snow-massif.glb", "save_error": error, "scope": "asset inspection, not traveler frozen-camera acceptance"}
		FileAccess.open(stem + ".json", FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
		if error != OK:
			push_error("Cannot save mountain review image")
			quit(1)
			return
		print("MOUNTAIN_REVIEW ", views[index], " ", JSON.stringify(report))
	quit(0)
