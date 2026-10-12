extends SceneTree
## Independent rain preview and deterministic 12 s / 30 fps Godot capture.
## The scene and camera come from a frozen layout, compiled only in memory.
const REPORT := "res://docs/reports/traveler-baghdad-001/rain-20260923"
const VIEWER_SOURCE := "res://scripts/traveler/baghdad/baghdad_viewer.gd"
const RAIN_SOURCE := "res://scripts/traveler/baghdad/baghdad_rain_look.gd"
const SIZE := Vector2i(1920, 1080)
const FPS := 30
const DURATION_SECONDS := 12.0
const WARMUP_FRAMES := 30

var viewport: SubViewport
var viewer: Node3D
var rain: Node3D
var output := REPORT
var mode := "video"
var post_draw_serial := 0
var started_usec := 0
var live_started_usec := 0
var ready := false
var frame_records: Array[Dictionary] = []

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	started_usec = Time.get_ticks_usec()
	var args := OS.get_cmdline_user_args()
	for arg in args:
		if arg.begins_with("--rain-output="):
			output = arg.trim_prefix("--rain-output=")
	if args.has("--rain-still") and args.has("--rain-live"):
		fail("Choose one of --rain-still or --rain-live")
		return
	if args.has("--rain-still"):
		mode = "still"
	elif args.has("--rain-live"):
		mode = "live"
	if not args.has("--view=baghdad"):
		fail("Rain review requires --view=baghdad")
		return
	if DisplayServer.get_name() == "headless":
		fail("Rain review requires a real renderer")
		return
	if not output.is_absolute_path() and not output.begins_with("res://"):
		fail("--rain-output must be an absolute path or res:// path")
		return
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output)) != OK:
		fail("Cannot create rain output: " + output)
		return
	var snapshot := REPORT.path_join("layout-snapshot.json")
	if not FileAccess.file_exists(snapshot):
		fail("Missing frozen rain layout: " + snapshot)
		return
	if not JSON.parse_string(FileAccess.get_file_as_string(snapshot)) is Dictionary:
		fail("Rain layout is not a JSON object: " + snapshot)
		return
	if mode == "video":
		var frames_directory := output.path_join("frames")
		var directory := DirAccess.open(frames_directory)
		if directory != null and not directory.get_files().is_empty():
			fail("Rain frames directory is occupied; use a new --rain-output directory")
			return
		if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(frames_directory)) != OK:
			fail("Cannot create rain frames directory")
			return

	root.title = "巴格达 · 雨中的生命之树"
	root.size = Vector2i(1440, 810)
	viewport = SubViewport.new()
	viewport.name = "RainReviewViewport"
	viewport.size = SIZE
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.msaa_3d = Viewport.MSAA_4X
	viewport.use_taa = false
	viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	root.add_child(viewport)
	var preview := TextureRect.new()
	preview.texture = viewport.get_texture()
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	root.add_child(preview)
	preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	RenderingServer.frame_post_draw.connect(_on_frame_post_draw)
	var source := FileAccess.get_file_as_string(VIEWER_SOURCE)
	source = source.replace("res://data/traveler/baghdad_scene.json", snapshot)
	var script := GDScript.new()
	script.source_code = source
	if script.reload() != OK:
		fail("Rain review viewer did not compile")
		return
	viewer = script.new()
	viewport.add_child(viewer)
	var deadline := Time.get_ticks_msec() + 60000
	while not bool(viewer.get("ready_for_capture")):
		if Time.get_ticks_msec() > deadline:
			fail("Rain review readiness timeout")
			return
		await process_frame
	var rain_script := load(RAIN_SOURCE) as GDScript
	if rain_script == null or not rain_script.can_instantiate():
		fail("Rain layer did not compile: " + RAIN_SOURCE)
		return
	rain = rain_script.new()
	viewer.add_child(rain)
	rain.call("configure", viewer)
	rain.set_process(false)
	viewer.camera.make_current()
	Engine.max_fps = 30
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	rain.call("set_time", 0.0)
	for warmup in WARMUP_FRAMES:
		await draw_frame()
	var initial_image := viewport.get_texture().get_image()
	if initial_image == null or initial_image.get_size() != SIZE:
		fail("Rain capture did not return a 1920 x 1080 image")
		return
	ready = true
	print("BAGHDAD_RAIN_REVIEW_READY ", JSON.stringify({"mode":mode, "image_size":[SIZE.x,SIZE.y], "output":output}))
	if mode == "live":
		live_started_usec = Time.get_ticks_usec()
		if not write_evidence("live_ready"):
			return
		var timer := Timer.new()
		timer.wait_time = 1.0 / FPS
		timer.timeout.connect(live_draw)
		root.add_child(timer)
		timer.start()
		print("BAGHDAD_RAIN_LIVE_PREVIEW_READY ", output)
		return
	if mode == "still":
		if not save_image(initial_image, output.path_join("still.png")):
			return
		if not write_evidence("complete"):
			return
		print("BAGHDAD_RAIN_STILL_COMPLETE ", output)
		quit(0)
		return
	var count := int(DURATION_SECONDS * FPS)
	for frame in count:
		var seconds := float(frame) / FPS
		rain.call("set_time", seconds)
		await draw_frame()
		var image := viewport.get_texture().get_image()
		var relative_path := "frames/f%04d.png" % frame
		if not save_image(image, output.path_join(relative_path)):
			return
		if frame == 0 and not save_image(image, output.path_join("still.png")):
			return
		frame_records.append({"frame":frame, "rain_time_seconds":seconds, "file":relative_path})
		if (frame + 1) % 90 == 0:
			print("BAGHDAD_RAIN_VIDEO_PROGRESS ", frame + 1, "/", count)
	if not write_evidence("complete"):
		return
	print("BAGHDAD_RAIN_VIDEO_COMPLETE ", JSON.stringify({"frames":count,"fps":FPS,"duration_seconds":DURATION_SECONDS,"output":output}))
	quit(0)

func _on_frame_post_draw() -> void:
	post_draw_serial += 1

func draw_frame() -> void:
	# Force an actual draw even when macOS keeps this independent window behind
	# another app. Observe the signal before force_draw: it can fire synchronously.
	await process_frame
	var target_serial := post_draw_serial + 1
	RenderingServer.force_draw(false)
	if post_draw_serial < target_serial:
		await RenderingServer.frame_post_draw

func live_draw() -> void:
	if not ready or not is_instance_valid(rain):
		return
	var seconds := float(Time.get_ticks_usec() - live_started_usec) / 1000000.0
	rain.call("set_time", seconds)
	RenderingServer.force_draw(false)

func save_image(image: Image, path: String) -> bool:
	if image == null or image.get_size() != SIZE:
		fail("Invalid rain frame: " + path)
		return false
	if image.save_png(path) != OK:
		fail("Cannot save rain frame: " + path)
		return false
	return true

func write_evidence(status: String) -> bool:
	var environment: Environment = viewer.environment
	var evidence := {
		"schema":"silkroad.baghdad-rain-review.v1", "status":status, "mode":mode,
		"image_size":[SIZE.x,SIZE.y], "msaa":"4x", "fps":FPS,
		"duration_seconds":DURATION_SECONDS if mode == "video" else 0.0,
		"frame_count":frame_records.size(), "frames":frame_records,
		"simulation_step_seconds":1.0 / FPS, "warmup_frames_at_time_zero":WARMUP_FRAMES,
		"fixed_camera":true, "camera":viewer.camera_params,
		"camera_transform":str(viewer.camera.global_transform),
		"layout_snapshot":REPORT.path_join("layout-snapshot.json"),
		"layout_sha256":FileAccess.get_sha256(REPORT.path_join("layout-snapshot.json")),
		"viewer_source_sha256":FileAccess.get_sha256(VIEWER_SOURCE),
		"rain_source_sha256":FileAccess.get_sha256(RAIN_SOURCE),
		"rain":rain.call("evidence") if rain.has_method("evidence") else {},
		"storm":viewer.storm_look.evidence() if is_instance_valid(viewer.storm_look) else {},
		"rendering_method":RenderingServer.get_current_rendering_method(),
		"rendering_driver":RenderingServer.get_current_rendering_driver_name(),
		"glow_enabled":environment.glow_enabled,
		"executable":OS.get_executable_path(), "arguments":OS.get_cmdline_args(),
		"user_arguments":OS.get_cmdline_user_args(),
		"wall_seconds":float(Time.get_ticks_usec() - started_usec) / 1000000.0,
		"note":"Actual Godot SubViewport frames, fixed camera, deterministic rain time; no image overlays or post grading. Capture wall time is not a performance benchmark."
	}
	var file := FileAccess.open(output.path_join("evidence.json"), FileAccess.WRITE)
	if file == null:
		fail("Cannot write rain evidence")
		return false
	file.store_string(JSON.stringify(evidence, "\t"))
	file.close()
	return true

func fail(message: String) -> void:
	push_error(message)
	quit(1)
