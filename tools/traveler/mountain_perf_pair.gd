extends SceneTree
## Three alternating pairs in the same loaded scene reduce startup/load confounds.
func _initialize() -> void:
	call_deferred("measure")

func measure() -> void:
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP,true)
	DisplayServer.window_move_to_foreground()
	var output := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--perf-output="):output=arg.trim_prefix("--perf-output=")
	var viewport := SubViewport.new()
	viewport.size=Vector2i(1920,1080)
	viewport.own_world_3d=true
	viewport.msaa_3d=Viewport.MSAA_4X
	viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var traveler: Node3D=load("res://scenes/traveler/traveler_main.tscn").instantiate()
	viewport.add_child(traveler)
	traveler.ui.visible=false
	var mountain_nodes: Array[GeometryInstance3D]=[]
	for node in traveler.world.find_children("*","GeometryInstance3D",true,false):
		if node.get_meta("mountain_geometry",false):mountain_nodes.append(node)
	var result := {"image_size":[1920,1080],"viewport_size":[1920,1080],"pairs":[],"method":"same scene; three alternating full/hidden pairs; 2s settling and 180 frame_post_draw wall intervals per condition", "engine_max_fps":Engine.max_fps,"vsync_disabled":DisplayServer.window_get_vsync_mode()==DisplayServer.VSYNC_DISABLED}
	for pair in 3:
		var record := {}
		for enabled in [true,false]:
			for node in mountain_nodes:node.visible=enabled
			var deadline := Time.get_ticks_msec()+2000
			while Time.get_ticks_msec()<deadline:await process_frame
			await RenderingServer.frame_post_draw
			var previous := Time.get_ticks_usec()
			var samples: Array[float]=[]
			for frame in 180:
				await RenderingServer.frame_post_draw
				var current := Time.get_ticks_usec()
				samples.append(float(current-previous)/1000.0)
				previous=current
			var sorted := samples.duplicate()
			sorted.sort()
			record["full" if enabled else "hidden"]={"samples":samples,"p50":sorted[89],"p95":sorted[170],"draw_calls":RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)}
		result.pairs.append(record)
		print("MOUNTAIN_PERF_PAIR ",pair," ",record.full.p50," ",record.hidden.p50)
	for node in mountain_nodes:node.visible=true
	result["look"]=traveler.look_profile.evidence(viewport.get_texture().get_image())
	var file := FileAccess.open(output,FileAccess.WRITE)
	if file==null:push_error("Cannot write performance evidence");quit(1);return
	file.store_string(JSON.stringify(result,"\t"));file.close()
	traveler.world.queue_free()
	await process_frame
	quit()
