extends SceneTree
## Fixed-resolution evidence. Keep the project window at 1280×720.
## wp_capture.gd：capture_traveler.gd 的副本，只多一个 --wp-size=WxH（默认 1920x1080），
## 用于 macOS 动态壁纸的画幅试验（2026-09-23）。其余逐字不变。
func _initialize() -> void:
	call_deferred("capture")

func capture() -> void:
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP,true)
	DisplayServer.window_move_to_foreground()
	var viewport := SubViewport.new()
	var wp_size := Vector2i(1920, 1080)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--wp-size="):
			var parts := arg.trim_prefix("--wp-size=").split("x")
			if parts.size() == 2:
				wp_size = Vector2i(int(parts[0]), int(parts[1]))
	viewport.size = wp_size
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.msaa_3d = Viewport.MSAA_4X
	root.add_child(viewport)
	var scene_path:="res://scenes/traveler/traveler_main.tscn"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--capture-scene="):scene_path=arg.trim_prefix("--capture-scene=")
	var traveler := load(scene_path) as PackedScene
	viewport.add_child(traveler.instantiate())
	# A displayed texture keeps the macOS drawable active for unattended captures.
	if OS.get_cmdline_user_args().has("--capture-preview"):
		var preview := TextureRect.new()
		preview.texture=viewport.get_texture()
		preview.expand_mode=TextureRect.EXPAND_IGNORE_SIZE
		preview.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		root.add_child(preview)
		preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var camera := viewport.get_camera_3d()
	camera.make_current()
	# atlas_viewer warms up, measures completed frames, captures this viewport,
	# records image_size + viewport_size, then exits with the PNG save status.
