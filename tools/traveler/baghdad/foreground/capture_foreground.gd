extends SceneTree
## A/B capture without making any window always-on-top or requesting foreground focus.
func _initialize() -> void:
	call_deferred("run_capture")

func run_capture() -> void:
	var output := "res://docs/reports/traveler-baghdad-001/foreground-20260922/cinematic"
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--fg-output-dir="):
			output = argument.trim_prefix("--fg-output-dir=")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1920, 1080)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.msaa_3d = Viewport.MSAA_4X
	root.add_child(viewport)
	var force_offscreen := OS.get_cmdline_user_args().has("--fg-force-draw")
	if force_offscreen:
		# macOS can suspend normal frame presentation when a background window
		# becomes fully occluded. This optional mode is visual QA, not a benchmark.
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
			push_error("Foreground capture timed out waiting for scene")
			quit(1)
			return
		await process_frame
	var detail := viewer.world.get_node("BaghdadForegroundDetails") as Node3D
	if detail.get_child_count() == 0 or not detail.has_meta("evidence"):
		push_error("Foreground layer did not load; refusing an empty success capture")
		quit(1)
		return
	detail.visible = false
	await viewer.capture(output.path_join("before.png"))
	detail.visible = true
	await viewer.capture(output.path_join("after.png"))
	var receipt: Dictionary = detail.get_meta("evidence")
	receipt["composition"] = viewer.composition_evidence()
	receipt["same_process"] = true
	receipt["only_foreground_layer_toggled"] = true
	receipt["forced_draw_visual_only"] = force_offscreen
	var handle := FileAccess.open(output.path_join("foreground-evidence.json"), FileAccess.WRITE)
	handle.store_string(JSON.stringify(receipt, "\t"))
	handle.close()
	print("BAGHDAD_FOREGROUND_CAPTURE_COMPLETE ", output)
	quit(0)
