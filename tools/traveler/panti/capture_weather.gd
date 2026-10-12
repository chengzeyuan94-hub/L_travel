extends SceneTree
## Fixed-step uninterrupted 10 s preview; freeze verification follows separately.
var viewport:SubViewport
var viewer:Node3D
var output:=""

func _initialize() -> void:call_deferred("run")

func run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--weather-output="):output=arg.trim_prefix("--weather-output=")
	if output.is_empty() or not output.is_absolute_path() or DirAccess.dir_exists_absolute(output):
		push_error("Provide --weather-output=<new absolute directory>");quit(1);return
	DirAccess.make_dir_recursive_absolute(output)
	viewport=SubViewport.new();viewport.size=Vector2i(1920,1080)
	viewport.own_world_3d=true;viewport.msaa_3d=Viewport.MSAA_4X
	viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS;root.add_child(viewport)
	var preview:=TextureRect.new();preview.texture=viewport.get_texture()
	preview.expand_mode=TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	root.add_child(preview);preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	viewer=load("res://scenes/traveler/panti_main.tscn").instantiate();viewport.add_child(viewer)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED);Engine.max_fps=0
	while viewer.weather==null:await process_frame
	for i in 90:
		await process_frame;await RenderingServer.frame_post_draw
	var timeline:Array=[]
	var active_sample_changed:Array=[]
	var previous_bytes:=PackedByteArray()
	for frame in 300:
		await process_frame;await RenderingServer.frame_post_draw
		var frame_image:=viewport.get_texture().get_image()
		assert(frame_image.get_size()==Vector2i(1920,1080))
		assert(frame_image.save_jpg(output+"/f%04d.jpg"%frame,0.94)==OK)
		if frame%30==0:
			assert(frame_image.save_png(output+"/sample-%02d.png"%(frame/30))==OK)
			var current_bytes:=frame_image.get_data()
			if not previous_bytes.is_empty():active_sample_changed.append(current_bytes!=previous_bytes)
			previous_bytes=current_bytes
			timeline.append({"frame":frame,"time_s":float(frame)/30.0,"motion":viewer.weather.evidence()})
	viewer.set_motion_frozen(true)
	for i in 5:
		await process_frame;await RenderingServer.frame_post_draw
	var frozen_image:=viewport.get_texture().get_image()
	assert(frozen_image.save_png(output+"/freeze-reference.png")==OK)
	var reference:=frozen_image.get_data()
	var identical_pairs:=0
	for i in 30:
		await process_frame;await RenderingServer.frame_post_draw
		var current:=viewport.get_texture().get_image().get_data()
		if current==reference:identical_pairs+=1
		else:push_error("Frozen Panti frame changed at pair "+str(i))
	var report:Dictionary={"image_size":[1920,1080],"fps":30,"duration_s":10,"main_frames":300,"main_contains_pause":false,"active_one_second_samples_changed":active_sample_changed,"freeze_check":{"compared_to":"freeze-reference.png","settling_frames":5,"pairs":30,"exactly_identical_pairs":identical_pairs,"all_equal":identical_pairs==30},"timeline":timeline,"frozen_final_state":viewer.weather.evidence()}
	# Same-process frozen comparisons isolate visible particles and outline width.
	viewer.weather.snow.visible=false
	await save_settled("no-snow.png")
	viewer.weather.snow.visible=true
	viewer.weather.mist.visible=false
	await save_settled("no-mist.png")
	viewer.weather.mist.visible=true
	viewer.weather.tree_wind.set_enabled(false)
	await save_settled("no-wind.png")
	viewer.weather.tree_wind.set_enabled(true)
	var outline:StandardMaterial3D=viewer.character_style.shell.material_override
	var thin:float=outline.grow_amount
	outline.grow_amount=thin*2.0
	await save_settled("outline-before.png")
	outline.grow_amount=thin
	await save_settled("outline-after.png")
	report["outline_model_u"]={"before":thin*2.0,"after":thin,"ratio":0.5}
	FileAccess.open(output+"/motion-check.json",FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("PANTI_WEATHER_MOTION ",JSON.stringify({"main_frames":300,"active_samples_changed":active_sample_changed,"freeze_identical":identical_pairs}))
	quit(0 if identical_pairs==30 else 1)

func save_settled(filename:String) -> void:
	for i in 4:
		await process_frame;await RenderingServer.frame_post_draw
	assert(viewport.get_texture().get_image().save_png(output+"/"+filename)==OK)
