extends SceneTree
## Fixed-camera, real-GPU sampling. Invoke with --fixed-fps 30, never --headless.
var viewport: SubViewport
var viewer: Node3D
var contract: Dictionary
var output := "res://docs/reports/traveler-motion-001/B"
var mode := "B"
var samples: Array = []
var stamp := 0

func _initialize() -> void:
	call_deferred("run")

func save_frame(index: int, at_time: float) -> void:
	var image := viewport.get_texture().get_image()
	var path := "%s/f%04d.png" % [output,index]
	var error := image.save_png(path)
	var record := {"sample":index,"time_s":at_time,"image_size":[image.get_width(),image.get_height()],"viewport_size":[viewport.size.x,viewport.size.y],"capture_error":error,"anim_t":viewer.motion_director.anim_t,"wind_gust":viewer.motion_director.gust(at_time),"frozen_camera":contract._measured.traveler_camera,"camera_position":[viewer.camera.position.x,viewer.camera.position.y,viewer.camera.position.z],"camera_fov":viewer.camera.fov,"taa":viewport.use_taa,"msaa":viewport.msaa_3d,"look":viewer.look_profile.evidence(image)}
	var file := FileAccess.open(path.trim_suffix(".png")+".json",FileAccess.WRITE)
	file.store_string(JSON.stringify(record,"\t"))
	file.close()
	samples.append(record)
	if error != OK:
		push_error("Motion capture failed: "+path)
		quit(1)

func run() -> void:
	stamp = Time.get_ticks_usec()
	if DisplayServer.get_name() == "headless":
		push_error("Motion evidence needs a real rendering window")
		quit(1)
		return
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--motion-mode="):mode=arg.trim_prefix("--motion-mode=")
		if arg.begins_with("--motion-output="):output=arg.trim_prefix("--motion-output=")
	contract=JSON.parse_string(FileAccess.get_file_as_string("res://data/traveler/motion_params.json"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	viewport=SubViewport.new()
	viewport.size=Vector2i(1920,1080)
	viewport.own_world_3d=true
	viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS
	viewport.msaa_3d=Viewport.MSAA_4X
	viewport.use_taa=false
	viewport.screen_space_aa=Viewport.SCREEN_SPACE_AA_DISABLED
	root.add_child(viewport)
	# Keep macOS presenting the offscreen target during unattended real-GPU runs.
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP,true)
	DisplayServer.window_move_to_foreground()
	var preview := TextureRect.new()
	preview.texture=viewport.get_texture()
	preview.expand_mode=TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	root.add_child(preview)
	preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	viewer=load("res://scenes/traveler/traveler_main.tscn").instantiate()
	viewport.add_child(viewer)
	assert(viewer.look_on and viewer.selected=="changan","Use --look --view=changan for the frozen camera")
	viewer.ui.visible=false
	viewer.set_process(false)
	viewer.set_process_unhandled_input(false)
	viewer.camera.make_current()
	Engine.max_fps=0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	viewport.use_taa=false
	viewer.motion_director.externally_clocked=true
	viewer.motion_director.set_active_items(["wind"])
	viewer.motion_director.set_wind_enabled(mode!="B")
	# Round one isolates WIND. Existing sea motion is frozen identically in A/B;
	# no cloud, light, particle, fire or water motion is introduced.
	for material in viewer.material_list:
		if material.shader.resource_path.ends_with("atlas_water.gdshader"):
			material.set_shader_parameter("anim_t",0.0)
	viewer.motion_director.apply_time(0.0)
	for warmup in 60:
		await process_frame
		await RenderingServer.frame_post_draw
	var step := float(contract.gate.sampling.slow.interval_s)/float(contract.gate.sampling.slow.every_n_frames)
	var time_s := 0.0
	for frame in int(contract.gate.engine_frames):
		await process_frame
		viewer.motion_director.apply_time(time_s)
		await RenderingServer.frame_post_draw
		if frame % int(contract.gate.sampling.slow.every_n_frames)==0:
			save_frame(frame/int(contract.gate.sampling.slow.every_n_frames),time_s)
		# The production clock integrates delta; fixed-fps evidence samples its
		# deterministic 1/30 s trajectory, independently of rendering wall time.
		time_s += step
	var report := {"mode":mode,"samples":samples,"sample_count":samples.size(),"engine_frames":int(contract.gate.engine_frames),"wall_seconds":float(Time.get_ticks_usec()-stamp)/1000000.0,"engine_max_fps":Engine.max_fps,"vsync":DisplayServer.window_get_vsync_mode(),"renderer":RenderingServer.get_current_rendering_method(),"frozen_water_anim_t":0.0,"scope":"Round one wind only; static recipe lighting and backdrop, SSIL and SSAO unchanged"}
	var file := FileAccess.open(output+"/samples.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t"));file.close()
	print("MOTION_SAMPLES ",JSON.stringify({"mode":mode,"samples":samples.size(),"wall_seconds":report.wall_seconds}))
	viewer.queue_free()
	await process_frame
	await process_frame
	quit()
