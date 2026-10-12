extends SceneTree
## Same-process visual comparison: only the canopy emission strength changes.
const REPORT := "res://docs/reports/traveler-baghdad-001/tree-glow-20260923"

func _initialize() -> void:
	call_deferred("review")

func review() -> void:
	var output := REPORT.path_join("v1")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--glow-output="):
			output = arg.trim_prefix("--glow-output=")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1920, 1080)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.msaa_3d = Viewport.MSAA_4X
	root.add_child(viewport)
	var preview := TextureRect.new()
	preview.texture = viewport.get_texture()
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	root.add_child(preview)
	preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var timer := Timer.new()
	timer.wait_time = 1.0 / 30.0
	timer.timeout.connect(func() -> void: RenderingServer.force_draw(false))
	root.add_child(timer)
	timer.start()
	var source := FileAccess.get_file_as_string("res://scripts/traveler/baghdad/baghdad_viewer.gd")
	source = source.replace("res://data/traveler/baghdad_scene.json", REPORT.path_join("layout-snapshot.json"))
	var script := GDScript.new()
	script.source_code = source
	if script.reload() != OK:
		push_error("Tree glow review viewer did not compile")
		quit(1)
		return
	var viewer: Node3D = script.new()
	viewport.add_child(viewer)
	var deadline := Time.get_ticks_msec() + 60000
	while not bool(viewer.get("ready_for_capture")):
		if Time.get_ticks_msec() > deadline:
			push_error("Tree glow review readiness timeout")
			quit(1)
			return
		await process_frame
	var storm: Node3D = viewer.storm_look
	var strength: float = storm.tree_glow_strength
	storm.set_tree_glow_strength(0.0)
	await viewer.capture(output.path_join("before.png"))
	storm.set_tree_glow_strength(strength)
	await viewer.capture(output.path_join("after.png"))
	var evidence := {"same_scene_and_camera":true, "only_changed_parameter":"tree_glow_strength",
		"before_strength":0.0, "after_strength":strength, "storm":storm.evidence(),
		"visual_only_forced_draw":true}
	FileAccess.open(output.path_join("review-evidence.json"), FileAccess.WRITE).store_string(JSON.stringify(evidence, "\t"))
	print("BAGHDAD_TREE_GLOW_REVIEW_COMPLETE ", output)
	quit(0)
