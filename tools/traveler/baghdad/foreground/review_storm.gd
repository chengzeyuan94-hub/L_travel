extends SceneTree
## Isolated, background-safe review using a read-only frozen editor layout.
const REPORT := "res://docs/reports/traveler-baghdad-001/storm-stone-20260923"

func _initialize() -> void:
	call_deferred("review")

func review() -> void:
	var output := REPORT.path_join("v1")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--storm-output="):
			output = arg.trim_prefix("--storm-output=")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1920,1080)
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
	timer.wait_time = 1.0/30.0
	timer.timeout.connect(func() -> void: RenderingServer.force_draw(false))
	root.add_child(timer)
	timer.start()
	var source := FileAccess.get_file_as_string("res://scripts/traveler/baghdad/baghdad_viewer.gd")
	source = source.replace("res://data/traveler/baghdad_scene.json", REPORT.path_join("layout-snapshot.json"))
	var script := GDScript.new()
	script.source_code = source
	if script.reload() != OK:
		push_error("Storm review viewer did not compile")
		quit(1)
		return
	var viewer: Node3D = script.new()
	viewport.add_child(viewer)
	var deadline := Time.get_ticks_msec()+60000
	while not bool(viewer.get("ready_for_capture")):
		if Time.get_ticks_msec()>deadline:
			push_error("Storm review readiness timeout")
			quit(1)
			return
		await process_frame
	# Launch with --clear-weather --legacy-foreground for the first frame.
	await viewer.capture(output.path_join("before.png"))
	var previous: Node = viewer.world.get_node("BaghdadForegroundDetails")
	previous.free()
	var builder = load("res://scripts/traveler/baghdad/baghdad_foreground_details.gd").new()
	var road_asset: String = builder.LEGACY_ASSET if OS.get_cmdline_user_args().has("--storm-old-stones") else builder.ASSET
	var road: Node3D = builder.build(viewer,road_asset)
	viewer.world.add_child(road)
	var storm: Node3D = load("res://scripts/traveler/baghdad/baghdad_storm_look.gd").new()
	viewer.add_child(storm)
	storm.configure(viewer)
	var surface_evidence: Dictionary = viewer.ground.get_meta("storm_surface",{})
	await viewer.capture(output.path_join("after.png"))
	var composition: Dictionary = viewer.composition_evidence()
	var original: Transform3D = viewer.camera.transform
	var fov: float = viewer.camera.fov
	viewer.camera.position = viewer.stage_point(Vector3(.1,.5,.80))
	viewer.camera.look_at(viewer.stage_point(Vector3(0,.015,2.1)))
	viewer.camera.fov = 52.0
	await viewer.capture(output.path_join("road-detail.png"))
	viewer.camera.transform = original
	viewer.camera.fov = fov
	var receipt := {"foreground":road.get_meta("evidence",{}),"composition":composition,"ground":surface_evidence,
		"same_process":true,"frozen_layout":REPORT.path_join("layout-snapshot.json"),
		"visual_only_forced_draw":true,"volumetric_fog_enabled":viewer.environment.volumetric_fog_enabled,
		"sky_shader":viewer.environment.sky.sky_material.shader.resource_path}
	if storm.has_method("evidence"):
		receipt["storm"] = storm.evidence()
	var handle := FileAccess.open(output.path_join("review-evidence.json"),FileAccess.WRITE)
	handle.store_string(JSON.stringify(receipt,"\t"))
	handle.close()
	print("BAGHDAD_STORM_REVIEW_COMPLETE ", output)
	quit(0)
