extends SceneTree
## Run with --fixed-fps 30. Continuous preview excludes the separate pause audit.
var viewport:SubViewport
var viewer:Node3D
var output:=""
var frames_dir:=""

func _initialize() -> void:call_deferred("run")

func frame() -> void:
	await process_frame
	await RenderingServer.frame_post_draw

func save(name_value:String) -> void:
	var image:=viewport.get_texture().get_image()
	assert(image.get_size()==Vector2i(1920,1080))
	assert(image.save_png(output+"/"+name_value+".png")==OK)

func run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--transition-output="):output=arg.trim_prefix("--transition-output=")
		if arg.begins_with("--video-frames="):frames_dir=arg.trim_prefix("--video-frames=")
	if output.is_empty() or not output.is_absolute_path() or DirAccess.dir_exists_absolute(output):
		push_error("Provide --transition-output=<new absolute directory>");quit(1);return
	DirAccess.make_dir_recursive_absolute(output)
	if not frames_dir.is_empty():DirAccess.make_dir_recursive_absolute(frames_dir)
	viewport=SubViewport.new();viewport.size=Vector2i(1920,1080)
	viewport.own_world_3d=true;viewport.msaa_3d=Viewport.MSAA_4X
	viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS;root.add_child(viewport)
	var preview:=TextureRect.new();preview.texture=viewport.get_texture()
	preview.expand_mode=TextureRect.EXPAND_IGNORE_SIZE;preview.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	root.add_child(preview);preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	viewer=load("res://scenes/traveler/panti_main.tscn").instantiate();viewport.add_child(viewer)
	while viewer.period_transition==null:await frame()
	for i in 90:await frame()
	var camera_before:Transform3D=viewer.camera.global_transform
	var timeline:Array=[]
	save("morning")
	viewer.request_lighting_period("midnight")
	var first_night_frame:=-1
	for i in range(1,721):
		await frame()
		var state:Dictionary=viewer.period_transition.evidence()
		if first_night_frame<0 and not state.active:first_night_frame=i
		if i%15==0:
			timeline.append({"frame":i,"video_time_s":float(i)/30.0,"transition":state,"lamp":viewer.castle_lighting.evidence(),"sky":viewer.look_profile.night_sky.evidence()})
		if i in [1,2,30,60,120,180,239,240,241,330,360,465,600,660,720]:save("frame-%04d"%i)
		if not frames_dir.is_empty():
			assert(viewport.get_texture().get_image().save_jpg(frames_dir+"/f%04d.jpg"%(i-1),0.93)==OK)
	viewer.set_motion_frozen(true)
	for i in 5:await frame()
	var reference:=viewport.get_texture().get_image().get_data()
	var time_before:float=viewer.weather.anim_t
	var identical:=0
	for i in 30:
		await frame()
		if viewport.get_texture().get_image().get_data()==reference:identical+=1
	var frozen_time_unchanged:bool=viewer.weather.anim_t==time_before
	# A period request during pause queues the transition without advancing it.
	viewer.request_lighting_period("morning")
	for i in 10:await frame()
	var paused_transition_held:bool=viewer.period_transition.elapsed==0.0 and viewer.period_transition.weight==1.0
	viewer.set_motion_frozen(false)
	for i in 240:await frame()
	save("returned-morning")
	var reverse_complete:bool=not viewer.period_transition.active and viewer.period_transition.weight==0.0
	var morning_restored:bool=not viewer.castle_lighting.night_enabled and not viewer.period_lighting.character_fill.visible and not viewer.look_profile.night_sky.composite_layer.visible
	# Mid-transition reversal must preserve the current image weight.
	viewer.request_lighting_period("midnight")
	for i in 60:await frame()
	var before_reversal:float=viewer.period_transition.weight
	viewer.request_lighting_period("morning")
	var no_reversal_jump:bool=viewer.period_transition.weight==before_reversal
	for i in 10:await frame()
	var elapsed_before:float=viewer.period_transition.elapsed
	viewer.request_lighting_period("morning")
	var duplicate_request_ignored:bool=viewer.period_transition.elapsed==elapsed_before
	for i in 230:await frame()
	var click:=InputEventMouseButton.new()
	click.position=viewer.camera.unproject_position(viewer.camp.fire.global_position)
	click.button_index=MOUSE_BUTTON_LEFT;click.pressed=true
	viewport.push_input(click,true)
	var campfire_click_works:bool=viewer.period_transition.active and viewer.period_transition.target_period=="midnight"
	var result:Dictionary={"image_size":[1920,1080],"fixed_fps":30,"video_duration_s":24.0,"video_contains_pause":false,
		"first_complete_night_frame":first_night_frame,"transition_duration_s":float(first_night_frame)/30.0,
		"frozen_identical_pairs":identical,"frozen_pairs":30,"frozen_clock_unchanged":frozen_time_unchanged,
		"paused_transition_held":paused_transition_held,"reverse_complete":reverse_complete,"morning_state_restored":morning_restored,
		"reversal_preserves_weight":no_reversal_jump,"duplicate_request_ignored":duplicate_request_ignored,
		"campfire_click_works":campfire_click_works,"campfire_click_position_px":[click.position.x,click.position.y],"camera_unchanged":camera_before==viewer.camera.global_transform,"timeline":timeline}
	var passed:bool=first_night_frame>=239 and first_night_frame<=241 and identical==30 and frozen_time_unchanged and paused_transition_held and reverse_complete and morning_restored and no_reversal_jump and duplicate_request_ignored and campfire_click_works and result.camera_unchanged
	result["passed"]=passed
	FileAccess.open(output+"/transition-check.json",FileAccess.WRITE).store_string(JSON.stringify(result,"\t"))
	print("PANTI_TRANSITION_CHECK ",JSON.stringify({"passed":passed,"night_frame":first_night_frame,"freeze_pairs":identical,"reverse":reverse_complete,"click":campfire_click_works}))
	quit(0 if passed else 1)
