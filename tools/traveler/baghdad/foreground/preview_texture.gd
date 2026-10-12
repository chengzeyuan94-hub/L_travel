extends SceneTree
## Independent visual review; reads the latest edited layout without writing it.
var viewer: Node3D
var original_camera: Transform3D
var original_fov: float
var closeup := false
var ready := false
var space_down := false

func _initialize() -> void:
	call_deferred("show_scene")

func show_scene() -> void:
	root.title = "巴格达 · 乌云与生命之树 · 空格切换石路近景"
	root.size = Vector2i(1440, 810)
	root.msaa_3d = Viewport.MSAA_4X
	var source := FileAccess.get_file_as_string("res://scripts/traveler/baghdad/baghdad_viewer.gd")
	source = source.replace("res://data/traveler/baghdad_scene.json", "res://data/traveler/baghdad_scene.edited.json")
	var script := GDScript.new()
	script.source_code = source
	if script.reload() != OK:
		push_error("Unable to load independent Baghdad preview")
		quit(1)
		return
	viewer = script.new()
	root.add_child(viewer)
	while not bool(viewer.get("ready_for_capture")):
		await process_frame
	original_camera = viewer.camera.transform
	original_fov = viewer.camera.fov
	Engine.max_fps = 60
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	ready = true
	print("BAGHDAD_TEXTURE_LIVE_PREVIEW_READY storm=",is_instance_valid(viewer.get("storm_look")))

func _process(_delta: float) -> bool:
	var pressed := Input.is_physical_key_pressed(KEY_SPACE)
	if ready and pressed and not space_down:
		closeup = not closeup
		if closeup:
			viewer.camera.position = viewer.stage_point(Vector3(0.10, 0.48, 0.84))
			viewer.camera.look_at(viewer.stage_point(Vector3(0.0, 0.01, 2.05)))
			viewer.camera.fov = 52.0
		else:
			viewer.camera.transform = original_camera
			viewer.camera.fov = original_fov
	space_down = pressed
	return false
