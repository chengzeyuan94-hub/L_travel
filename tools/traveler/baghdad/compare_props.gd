extends SceneTree
## Same-process static before/after: preserve the camera, look and posed actor.
var output:=""
var before_settings:=""

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):output=arg.trim_prefix("--out=")
		if arg.begins_with("--before-settings="):before_settings=arg.trim_prefix("--before-settings=")
	if output.is_empty() or before_settings.is_empty():
		push_error("Provide --out=<new directory> and --before-settings=<JSON>");quit(1);return
	call_deferred("run")

func run() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED);Engine.max_fps=0
	var viewport:=SubViewport.new();viewport.size=Vector2i(1920,1080)
	viewport.own_world_3d=true;viewport.msaa_3d=Viewport.MSAA_4X
	viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS;root.add_child(viewport)
	var preview:=TextureRect.new();preview.texture=viewport.get_texture()
	preview.expand_mode=TextureRect.EXPAND_IGNORE_SIZE;preview.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	root.add_child(preview);preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var viewer:Node3D=load("res://scenes/traveler/baghdad_main.tscn").instantiate();viewport.add_child(viewer)
	while not viewer.ready_for_capture:await process_frame
	var current:Dictionary=viewer.settings.supporting_props.duplicate(true)
	var before:Dictionary=JSON.parse_string(FileAccess.get_file_as_string(before_settings))
	viewer.supporting_props._root.free();viewer.supporting_props=null
	viewer.settings.supporting_props=before.supporting_props.duplicate(true)
	viewer.build_supporting_props()
	await viewer.capture(output+"/before.png")
	viewer.supporting_props._root.free();viewer.supporting_props=null
	viewer.settings.supporting_props=current
	viewer.build_supporting_props()
	await viewer.capture(output+"/after.png")
	var report:Dictionary={"same_process":true,"static_scene":true,"before_settings":before_settings,"unchanged_camera":viewer.camera_params,"unchanged_main_anchors":["arch","life tree","character","skyline"],"before":output+"/before.json","after":output+"/after.json"}
	FileAccess.open(output+"/comparison.json",FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("BAGHDAD_PROPS_COMPARISON ",JSON.stringify(report))
	quit()
