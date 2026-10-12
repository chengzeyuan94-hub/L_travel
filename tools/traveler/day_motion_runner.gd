extends SceneTree
## Day-motion A/B evidence. Fixed camera and original postprocessing; independent per-layer switches.
var viewport: SubViewport
var viewer: Node3D
var contract: Dictionary
var output := ""
var scope := "all"
var length_s := 60
var mode := "B"
var samples: Array = []
var stamp := 0

func _initialize() -> void:
	call_deferred("run")

func save_frame(index: int, at_time: float) -> void:
	var image := viewport.get_texture().get_image()
	var path := "%s/f%04d.png" % [output,index]
	var error := image.save_png(path)
	var record := {"scope":scope,"motion":viewer.motion_director.evidence(),"sample":index,"time_s":at_time,"image_size":[image.get_width(),image.get_height()],"viewport_size":[viewport.size.x,viewport.size.y],"capture_error":error,"anim_t":viewer.motion_director.anim_t,"wind_gust":viewer.motion_director.gust(viewer.motion_director.anim_t),"draw_calls":RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),"viewport_draw_calls":viewport.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE,Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME),"frozen_camera":contract._measured.traveler_camera,"camera_position":[viewer.camera.position.x,viewer.camera.position.y,viewer.camera.position.z],"camera_fov":viewer.camera.fov,"taa":viewport.use_taa,"msaa":viewport.msaa_3d,"look":viewer.look_profile.evidence(image)}
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
		if arg.begins_with("--motion-scope="):scope=arg.trim_prefix("--motion-scope=")
		if arg.begins_with("--motion-length="):length_s=int(arg.trim_prefix("--motion-length="))
	if output.is_empty() or mode not in ["A","B"] or scope not in ["all","clouds","leaves","fire","sparks"]:
		push_error("Required --motion-output, A/B mode, and all/clouds/leaves/fire/sparks scope")
		quit(1)
		return
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
	assert(viewer.look_on and viewer.selected=="changan" and viewer.look_far,"Use --day --far --view=changan for the frozen camera")
	# Dusk components stay installed and frozen in daytime so the interactive
	# day<->dusk transition does not rebuild the world mid-shot.
	assert(viewer.motion_director.day_components.size()==4,"Expected cloud/leaf plus period fire and sparks components")
	viewer.ui.visible=false
	viewer.set_process(false)
	viewer.set_process_unhandled_input(false)
	viewer.camera.make_current()
	Engine.max_fps=0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	viewport.use_taa=false
	viewer.motion_director.externally_clocked=true
	var active: Array[String] = ["wind","clouds","leaves"]
	if viewer.look_dusk:
		active.append_array(["fire","sparks"])
	if scope!="all":
		active.clear()
		active.append(scope)
	viewer.motion_director.set_active_items(active)
	# Preserve the existing S0 water freeze hook. No water shader/material changes.
	for material in viewer.material_list:
		if material.shader.resource_path.ends_with("atlas_water.gdshader"):
			material.set_shader_parameter("anim_t",0.0)
	viewer.motion_director.apply_time(0.0)
	viewer.motion_director.set_motion_enabled(mode!="B")
	for warmup in 60:
		await process_frame
		await RenderingServer.frame_post_draw
	var step := float(contract.gate.sampling.slow.interval_s)/float(contract.gate.sampling.slow.every_n_frames)
	var time_s := 0.0
	for frame in length_s*30+1:
		await process_frame
		viewer.motion_director.apply_time(time_s)
		await RenderingServer.frame_post_draw
		if frame % int(contract.gate.sampling.slow.every_n_frames)==0:
			save_frame(frame/int(contract.gate.sampling.slow.every_n_frames),time_s)
		# The production clock integrates delta; fixed-fps evidence samples its
		# deterministic 1/30 s trajectory, independently of rendering wall time.
		time_s += step
	var report := {"mode":mode,"samples":samples,"sample_count":samples.size(),"engine_frames":length_s*30+1,"length_s":length_s,"scope":scope,"motion":viewer.motion_director.evidence(),"wall_seconds":float(Time.get_ticks_usec()-stamp)/1000000.0,"engine_max_fps":Engine.max_fps,"vsync":DisplayServer.window_get_vsync_mode(),"renderer":RenderingServer.get_current_rendering_method(),"frozen_water_anim_t":0.0,"note":"Original camera, lighting, DOF, SSAO and SSIL retained. Only scope selects animated layers; B freezes the same initial pose using the one master switch."}
	var file := FileAccess.open(output+"/samples.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t"));file.close()
	print("MOTION_SAMPLES ",JSON.stringify({"mode":mode,"samples":samples.size(),"wall_seconds":report.wall_seconds}))
	viewer.queue_free()
	await process_frame
	await process_frame
	quit()
