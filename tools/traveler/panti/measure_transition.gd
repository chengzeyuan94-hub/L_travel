extends SceneTree
var viewport:SubViewport
var viewer:Node3D
var output:=""

func _initialize() -> void:call_deferred("run")

func run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--measure-output="):output=arg.trim_prefix("--measure-output=")
	if output.is_empty() or not output.is_absolute_path() or DirAccess.dir_exists_absolute(output):
		push_error("Provide --measure-output=<new absolute directory>");quit(1);return
	DirAccess.make_dir_recursive_absolute(output)
	viewport=SubViewport.new();viewport.size=Vector2i(1920,1080);viewport.own_world_3d=true
	viewport.msaa_3d=Viewport.MSAA_4X;viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS;root.add_child(viewport)
	var preview:=TextureRect.new();preview.texture=viewport.get_texture()
	preview.expand_mode=TextureRect.EXPAND_IGNORE_SIZE;preview.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	root.add_child(preview);preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	viewer=load("res://scenes/traveler/panti_main.tscn").instantiate();viewport.add_child(viewer)
	while viewer.period_transition==null:await process_frame
	await viewer.capture(output+"/morning.png")
	viewer.request_lighting_period("midnight")
	var previous:=Time.get_ticks_usec()
	var start:=previous
	var samples:Array[float]=[]
	var draws:Array[int]=[]
	while viewer.period_transition.active:
		await process_frame;await RenderingServer.frame_post_draw
		var now:=Time.get_ticks_usec();samples.append(float(now-previous)/1000.0);previous=now
		draws.append(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
	var elapsed_ms:=float(Time.get_ticks_usec()-start)/1000.0
	var sorted:=samples.duplicate();sorted.sort();draws.sort()
	var report:Dictionary={"image_size":[1920,1080],"transition":viewer.period_transition.evidence(),"wall_elapsed_ms":elapsed_ms,
		"frame_ms":{"p50":sorted[int(sorted.size()*0.5)],"p95":sorted[int(sorted.size()*0.95)],"max":sorted[-1],"samples":samples},
		"global_draw_calls_range":[draws[0],draws[-1]],"main_viewport_draw_calls":viewport.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE,Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME),
		"vsync_disabled":DisplayServer.window_get_vsync_mode()==DisplayServer.VSYNC_DISABLED,"engine_max_fps":Engine.max_fps}
	FileAccess.open(output+"/transition-performance.json",FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	await viewer.capture(output+"/midnight.png")
	print("PANTI_TRANSITION_PERFORMANCE ",JSON.stringify({"p50":report.frame_ms.p50,"p95":report.frame_ms.p95,"wall_ms":elapsed_ms}))
	quit()
