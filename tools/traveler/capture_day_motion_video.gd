extends SceneTree
## 12 s / 30 fps review sequence: uninterrupted main, or separate pause demonstration.
## Default pause mode preserves the original command's shared freeze at seconds 6..8.
## Required new output directory; never writes over an existing sequence.
var viewport: SubViewport
var viewer: Node3D
var output := ""
var frames: Array=[]
var video_mode := "pause"
var motion_scope := "all"
var period := "day"
var duration_s := 12.0
var transition_demo := false
var open_path := false
var freeze_check := false
var character_demo := false
var round_trip := false
var character: Node3D
var telemetry: Array=[]

func _initialize() -> void:
	call_deferred("run")

func write_manifest(value: Dictionary) -> void:
	var file := FileAccess.open(output+"/manifest.json",FileAccess.WRITE)
	if file==null:
		push_error("Cannot write video manifest: "+output)
		quit(1)
		return
	file.store_string(JSON.stringify(value,"\t"))
	file.close()

func run() -> void:
	var started := Time.get_ticks_usec()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--video-output="):output=arg.trim_prefix("--video-output=")
		if arg.begins_with("--video-mode="):video_mode=arg.trim_prefix("--video-mode=")
		if arg.begins_with("--motion-only="):motion_scope=arg.trim_prefix("--motion-only=")
		if arg.begins_with("--video-length="):duration_s=float(arg.trim_prefix("--video-length="))
		if arg=="--dusk":period="dusk"
		if arg=="--transition-demo":transition_demo=true
		if arg=="--character-demo":character_demo=true
		if arg=="--open-path":open_path=true
		if arg=="--freeze-check":freeze_check=true
		if arg=="--round-trip":
			round_trip=true
			transition_demo=true
	if video_mode not in ["main", "pause"]:
		push_error("--video-mode must be main or pause")
		quit(1)
		return
	if duration_s <= 0.0:
		push_error("--video-length must be positive")
		quit(1)
		return
	var frame_count := maxi(1, int(round(duration_s * 30.0)))
	var allowed: Array[String]=["wind","clouds","leaves"]
	if transition_demo:
		period="day"
		allowed.append_array(["fire","sparks"])
	if period=="dusk":
		allowed.append_array(["fire","sparks"])
	var active: Array[String]=[]
	if motion_scope=="all":
		active.assign(allowed)
	else:
		for item in motion_scope.split(",",false):
			if not allowed.has(item) or active.has(item):
				push_error("--motion-only requires unique wind/clouds/leaves/fire/sparks names or all")
				quit(1)
				return
			active.append(item)
	if active.is_empty():
		push_error("--motion-only must select at least one layer")
		quit(1)
		return
	for arg in OS.get_cmdline_args():
		if arg=="--resolution" or arg.begins_with("--resolution="):
			push_error("Do not use --resolution; video uses the fixed 1920x1080 SubViewport")
			quit(1)
			return
	if output.is_empty() or DisplayServer.get_name()=="headless":
		push_error("Video requires a real renderer and --video-output=<new absolute/res directory>")
		quit(1)
		return
	if not output.is_absolute_path() and not output.begins_with("res://"):
		push_error("--video-output must be absolute or res://")
		quit(1)
		return
	if FileAccess.file_exists(output):
		push_error("Video output is an existing file: "+output)
		quit(1)
		return
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(output)):
		var existing := DirAccess.open(output)
		if existing==null:
			push_error("Cannot inspect video output directory: "+output)
			quit(1)
			return
		existing.include_hidden=true
		existing.list_dir_begin()
		var occupied := not existing.get_next().is_empty()
		existing.list_dir_end()
		if occupied:
			push_error("Video output is not empty; choose a new directory: "+output)
			quit(1)
			return
	var directory_error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	if directory_error!=OK:
		push_error("Cannot create video output: "+output)
		quit(1)
		return
	viewport=SubViewport.new()
	viewport.size=Vector2i(1920,1080)
	viewport.own_world_3d=true
	viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS
	viewport.msaa_3d=Viewport.MSAA_4X
	viewport.use_taa=false
	viewport.screen_space_aa=Viewport.SCREEN_SPACE_AA_DISABLED
	root.add_child(viewport)
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
	if not viewer.look_on or not viewer.look_far or viewer.selected!="changan" or (period=="day" and (viewer.look_dusk or viewer.night)) or (period=="dusk" and not viewer.look_dusk):
		push_error("Use --view=changan --day/--dusk --far for the frozen video")
		quit(1)
		return
	if viewer.motion_director.day_components.size()!=4:
		push_error("Video requires the expected cloud/leaf and period components")
		quit(1)
		return
	viewer.ui.visible=false
	viewer.set_process(false)
	viewer.set_process_unhandled_input(false)
	viewer.camera.make_current()
	Engine.max_fps=0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	viewer.motion_director.externally_clocked=true
	viewer.motion_director.set_active_items(active)
	if transition_demo and not round_trip:
		# Start from the daytime look while keeping the two dusk components
		# installed and available for the same runtime switch used by the UI.
		viewer.look_profile.start_period_transition(true,duration_s)
	viewer.motion_director.set_motion_enabled(true)
	# Identical existing gate hook: retain fixed sea time; no water resource edits.
	for material in viewer.material_list:
		if material.shader.resource_path.ends_with("atlas_water.gdshader"):
			material.set_shader_parameter("anim_t",0.0)
	viewer.motion_director.apply_time(0.0)
	while not is_instance_valid(viewer.character_controller) or not viewer.character_controller.ready_for_input:
		await process_frame
	character=viewer.character_controller
	character.set_process(false)
	for warmup in 60:
		await process_frame
		await RenderingServer.frame_post_draw
	if freeze_check:
		character.move_to(Vector2(288,792),false)
		for settle_motion in 30:
			character._process(1.0/30.0)
			viewer.motion_director.apply_time(float(settle_motion+1)/30.0)
		viewer.motion_director.set_motion_enabled(false)
		for settle in 3:
			await process_frame
			await RenderingServer.frame_post_draw
	var initial_image := viewport.get_texture().get_image()
	var initial := {"motion":viewer.motion_director.evidence(),"look":viewer.look_profile.evidence(initial_image),"look_params":viewer.look_profile.lk.duplicate(true),"frozen_camera":viewer.motion_params._measured.traveler_camera,"camera_position":[viewer.camera.position.x,viewer.camera.position.y,viewer.camera.position.z],"camera_fov":viewer.camera.fov,"image_size":[initial_image.get_width(),initial_image.get_height()],"viewport_size":[viewport.size.x,viewport.size.y],"draw_calls":RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),"viewport_draw_calls":viewport.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE,Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)}
	if initial_image.get_size()!=Vector2i(1920,1080):
		push_error("Video viewport is not 1920x1080")
		quit(1)
		return
	var events: Array=[]
	for frame in frame_count:
		await process_frame
		var video_time := float(frame)/30.0
		var motion_time := video_time
		if round_trip and frame==60:viewer.look_profile.start_period_transition(true,8.0)
		if round_trip and frame==360:viewer.look_profile.start_period_transition(false,8.0)
		if transition_demo and viewer.motion_director.motion_enabled:
			viewer.look_profile.tick_transition(1.0/30.0)
		if character_demo:
			if frame==30:character.move_to(Vector2(288,792) if open_path else Vector2(828,936),false)
			if frame==270:character.move_to(Vector2(576,846),true)
			if open_path and frame==420:character.move_to(Vector2(360,810),false)
		if video_mode=="pause":
			motion_time = video_time if frame<180 else (6.0 if frame<240 else video_time-2.0)
		if video_mode=="pause" and frame==180:
			# Advance to the exact boundary, then freeze via the public master switch.
			viewer.motion_director.apply_time(6.0)
			viewer.motion_director.set_motion_enabled(false)
			events.append({"frame":frame,"video_time_s":video_time,"anim_t":6.0,"action":"set_motion_enabled(false)"})
		elif video_mode=="pause" and frame==240:
			viewer.motion_director.set_motion_enabled(true)
			events.append({"frame":frame,"video_time_s":video_time,"anim_t":6.0,"action":"set_motion_enabled(true)"})
		# Frozen calls intentionally continue: only the master switch holds all layers.
		viewer.motion_director.apply_time(motion_time)
		character._process(1.0/30.0)
		await RenderingServer.frame_post_draw
		var image := viewport.get_texture().get_image()
		var path := output+"/f%04d.png" % frame
		var error := image.save_png(path)
		if error!=OK:
			push_error("Video PNG save failed: "+path)
			quit(1)
			return
		var cloud=viewer.motion_director.day_components["clouds"]
		var record:Dictionary=character.evidence()
		record["frame"]=frame
		record["period"]=viewer.look_profile.current_period_t
		record["cloud_phase"]=cloud._drift_phase
		record["cloud_speed"]=cloud._speed_multiplier
		record["animation_position"]=character.animator.current_animation_position
		var feet:Dictionary={}
		character.character_skeleton.force_update_all_bone_transforms()
		for bone_name in ["mixamorig_LeftToeBase","mixamorig_RightToeBase"]:
			var bone_index:int=character.character_skeleton.find_bone(bone_name)
			var local:Vector3=character.character_skeleton.get_bone_global_pose(bone_index).origin
			var world:Vector3=character.character_skeleton.global_transform*local
			var pixel:Vector2=viewer.camera.unproject_position(world)
			feet[bone_name]={"local":[local.x,local.y,local.z],"pixel":[pixel.x,pixel.y]}
		record["feet"]=feet
		telemetry.append(record)
		frames.append({"frame":frame,"video_time_s":video_time,"anim_t":viewer.motion_director.anim_t,"motion_enabled":viewer.motion_director.motion_enabled,"file":"f%04d.png" % frame})
		if frame%60==0:print("DAY_VIDEO_FRAME ",frame)
	var segments: Array=[{"video_seconds":[0,duration_s],"state":"running without pause","anim_seconds":[0,duration_s]}]
	if video_mode=="pause":
		segments=[{"video_seconds":[0,6],"state":"running","anim_seconds":[0,6]},{"video_seconds":[6,8],"state":"frozen via shared master switch","anim_seconds":[6,6]},{"video_seconds":[8,12],"state":"resumed","anim_seconds":[6,10]}]
	var trace:=FileAccess.open(output+"/telemetry.json",FileAccess.WRITE)
	trace.store_string(JSON.stringify(telemetry,"\t"))
	write_manifest({"schema":"traveler.day-motion-review-video.v1","video_mode":video_mode,"motion_scope":motion_scope,"active_items":active,"image_size":[1920,1080],"viewport_size":[1920,1080],"fps":30,"duration_s":duration_s,"frame_count":frame_count,"simulation_step_s":1.0/30.0,"warmup_frames_at_t0":60,"initial_effective_parameters":initial,"final_motion":viewer.motion_director.evidence(),"events":events,"frames":frames,"renderer":RenderingServer.get_current_rendering_method(),"vsync_disabled":DisplayServer.window_get_vsync_mode()==DisplayServer.VSYNC_DISABLED,"engine_max_fps":Engine.max_fps,"frozen_water_anim_t":0.0,"command_executable":OS.get_executable_path(),"command_args":OS.get_cmdline_args(),"user_args":OS.get_cmdline_user_args(),"wall_seconds":float(Time.get_ticks_usec()-started)/1000000.0,"segments":segments,"note":"Review at 30 fps for real-time motion. Same frozen scene/camera/lighting/DOF; no overlays or grading. PNG write wall time is not a performance sample. Last frame is presented at video time(frame_count-1)/30; duration is configurable with --video-length."})
	print("DAY_VIDEO_COMPLETE ",JSON.stringify({"video_mode":video_mode,"active_items":active,"frame_count":frames.size(),"fps":30,"duration_s":duration_s,"output":output}))
	viewer.queue_free()
	await process_frame
	await process_frame
	quit()
